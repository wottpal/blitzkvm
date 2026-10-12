package emulator

import (
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/wottpal/blitzkvm/pkg/client"
	"github.com/wottpal/blitzkvm/pkg/video"
)

// Slow links: the client's traffic runs through the BLITZKVM_IMPAIR link
// model (both ways) while the emulator streams with the fork's keyframe
// policy, so a loss that NACKs do not repair stalls the picture until a
// requested keyframe arrives.

type slowLinkRun struct {
	Frames        int
	DroppedFrames uint64
	KeyframeWaits uint64
	LateRepairs   uint64
	PLIs          int64 // keyframe requests the device received
	// VideoLost and VideoResent are bytes of RTP the link lost, and the
	// device sent again in answer to NACKs.
	VideoLost, VideoResent int
	LongestFreeze          time.Duration
	// Frame delay above the run's fastest frame, from capture (the RTP
	// timestamp) to delivery.
	DelayP50, DelayP95 time.Duration
}

// runSlowLink streams 960×540 at 30 fps through spec ("" for no
// impairment) for d. The picture is constant motion (about 2.2 Mbit/s,
// keyframes of 20 kB), or with desktop a box moving over a still screen of
// text (0.2 Mbit/s between keyframes of 190-230 kB, sent every 10 s).
func runSlowLink(t *testing.T, spec string, desktop bool, d time.Duration) slowLinkRun {
	t.Helper()
	t.Setenv("BLITZKVM_IMPAIR", spec)
	cfg := Config{Width: 960, Height: 540, FPS: 30, GOP: 3600, KeyframeOnRequest: true}
	if desktop {
		cfg.Desktop, cfg.GOP = true, 300
	}
	srv := startTestServer(t, cfg)
	type arrival struct {
		rtp uint32
		at  time.Time
	}
	var mu sync.Mutex
	var units []arrival
	c := connectClient(t, client.Config{BaseURL: srv.BaseURL(), OnAccessUnit: func(au video.AccessUnit) {
		mu.Lock()
		units = append(units, arrival{au.RTPTimestamp, time.Now()})
		mu.Unlock()
	}})
	time.Sleep(d)
	stats := c.Stats()
	link, _ := c.Impairment()
	_ = c.Close()
	run := slowLinkRun{DroppedFrames: stats.FramesDropped, KeyframeWaits: stats.KeyframeWaits, LateRepairs: stats.LateRepairs,
		PLIs: srv.KeyframeRequests(), VideoLost: link.VideoLost, VideoResent: link.VideoResent}

	mu.Lock()
	defer mu.Unlock()
	run.Frames = len(units)
	if len(units) < 2 {
		run.LongestFreeze = d // the picture never started
		return run
	}
	delays := make([]time.Duration, len(units))
	for i, u := range units {
		captured := time.Duration(int32(u.rtp-units[0].rtp)) * time.Second / 90000
		delays[i] = u.at.Sub(units[0].at) - captured
		if i > 0 {
			run.LongestFreeze = max(run.LongestFreeze, u.at.Sub(units[i-1].at))
		}
	}
	fastest := slices.Min(delays)
	for i := range delays {
		delays[i] -= fastest
	}
	slices.Sort(delays)
	run.DelayP50, run.DelayP95 = delays[len(delays)/2], delays[len(delays)*95/100]
	return run
}

// NACK repair at cellular and satellite round trips, with 2 % loss both
// ways (NACKs and keyframe requests get lost too).
func TestNACKRepairAtLongRoundTrips(t *testing.T) {
	if raceEnabled {
		t.Skip("timing-sensitive: retransmission deadlines are unrealistic under -race")
	}
	t.Run("300ms", func(t *testing.T) {
		// Each loss is resent about once, not once per 40 ms until the
		// repair arrives (six times), and the repair, due after up to
		// 340 ms, is still in time.
		run := runSlowLink(t, "delay=150ms,loss=2%,seed=1", false, 5*time.Second)
		t.Logf("%+v", run)
		if run.VideoLost == 0 {
			t.Fatal("nothing was lost")
		}
		if ratio := float64(run.VideoResent) / float64(run.VideoLost); ratio > 1.5 {
			t.Errorf("resent %.1f× the lost bytes", ratio)
		}
		if unrepaired := run.KeyframeWaits - run.LateRepairs; unrepaired > 1 {
			t.Errorf("%d losses were not repaired", unrepaired)
		}
	})
	t.Run("700ms", func(t *testing.T) {
		// Repairs arrive after the longest wait (600 ms) but before the
		// keyframe requested then: they cancel the keyframe wait.
		run := runSlowLink(t, "delay=350ms,loss=1%,seed=1", false, 6*time.Second)
		t.Logf("%+v", run)
		if run.LateRepairs == 0 || 2*run.LateRepairs < run.KeyframeWaits {
			t.Errorf("only %d of %d keyframe waits ended by a late repair", run.LateRepairs, run.KeyframeWaits)
		}
	})
}

// TestSlowLinkBenchmark streams through each profile and prints the median
// of the runs as a table row. BLITZKVM_BENCH=60s runs it;
// BLITZKVM_BENCH_RUNS (default 1), BLITZKVM_BENCH_SEED (of the first run,
// default 1), BLITZKVM_BENCH_PROFILES (default: none and every profile) and
// BLITZKVM_BENCH_CONTENT (desktop or motion, see runSlowLink; default
// desktop) adjust it. Equal seeds give two builds the same random losses.
func TestSlowLinkBenchmark(t *testing.T) {
	d, err := time.ParseDuration(os.Getenv("BLITZKVM_BENCH"))
	if err != nil {
		t.Skip("set BLITZKVM_BENCH=<duration> to run")
	}
	if raceEnabled {
		t.Skip("timing-sensitive")
	}
	runs, _ := strconv.Atoi(os.Getenv("BLITZKVM_BENCH_RUNS"))
	seed, _ := strconv.Atoi(os.Getenv("BLITZKVM_BENCH_SEED"))
	desktop := os.Getenv("BLITZKVM_BENCH_CONTENT") != "motion"
	profiles := []string{"none", "lte", "lte-congested", "wifi-hotel", "derp"}
	if p := os.Getenv("BLITZKVM_BENCH_PROFILES"); p != "" {
		profiles = strings.Split(p, ",")
	}
	fmt.Println("| profile | frames | dropped | keyframe waits (late repairs) | PLIs | resent ÷ lost | longest freeze | delay excess p50 / p95 |")
	fmt.Println("|---|---|---|---|---|---|---|---|")
	for _, profile := range profiles {
		var all []slowLinkRun
		for i := range max(runs, 1) {
			spec := ""
			if profile != "none" {
				spec = fmt.Sprintf("%s,seed=%d", profile, max(seed, 1)+i)
			}
			run := runSlowLink(t, spec, desktop, d)
			line, _ := json.Marshal(run)
			t.Logf("BENCH %s %s", profile, line)
			all = append(all, run)
		}
		median := func(f func(slowLinkRun) float64) float64 {
			v := make([]float64, len(all))
			for i, r := range all {
				v[i] = f(r)
			}
			slices.Sort(v)
			return (v[(len(v)-1)/2] + v[len(v)/2]) / 2
		}
		ms := func(f func(slowLinkRun) time.Duration) float64 {
			return median(func(r slowLinkRun) float64 { return float64(f(r)) / float64(time.Millisecond) })
		}
		fmt.Printf("| %s | %.0f | %.0f | %.1f (%.1f) | %.1f | %.2f | %.0f ms | %.0f / %.0f ms |\n", profile,
			median(func(r slowLinkRun) float64 { return float64(r.Frames) }),
			median(func(r slowLinkRun) float64 { return float64(r.DroppedFrames) }),
			median(func(r slowLinkRun) float64 { return float64(r.KeyframeWaits) }),
			median(func(r slowLinkRun) float64 { return float64(r.LateRepairs) }),
			median(func(r slowLinkRun) float64 { return float64(r.PLIs) }),
			median(func(r slowLinkRun) float64 { return float64(r.VideoResent) / float64(max(r.VideoLost, 1)) }),
			ms(func(r slowLinkRun) time.Duration { return r.LongestFreeze }),
			ms(func(r slowLinkRun) time.Duration { return r.DelayP50 }),
			ms(func(r slowLinkRun) time.Duration { return r.DelayP95 }))
	}
}
