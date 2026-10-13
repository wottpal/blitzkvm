package emulator

import (
	"cmp"
	"context"
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
	"github.com/wottpal/blitzkvm/pkg/logging"
	appsession "github.com/wottpal/blitzkvm/pkg/session"
	"github.com/wottpal/blitzkvm/pkg/video"
)

// Slow links: the client's traffic runs through the BLITZKVM_IMPAIR link
// model (both ways) while the emulator streams with the fork's keyframe
// policy, so a loss that NACKs do not repair stalls the picture until a
// requested keyframe arrives.

// slowLink is one run: a link (a BLITZKVM_IMPAIR spec, "" for none), what
// the screen shows ("motion", "desktop" or "scroll", see Config), and for
// how long.
type slowLink struct {
	spec, content string
	d             time.Duration
	// auto runs the app's session, with automatic quality, against
	// firmware with the encoder patch at 1080p60, whose frames follow the
	// quality levels (encoderModel). Otherwise a bare client watches the
	// unpatched pattern at 960×540, 30 fps.
	auto bool
}

// deviceSendRate is how fast the device's send path puts RTP out: about
// 0.45 ms of CPU for each 1.2 kB packet, so a 300 kB keyframe takes
// 110-140 ms to leave it even on a LAN.
const deviceSendRate = 21e6

// freezeGap is the longest wait between two frames that is not a freeze, as
// in the app's self-tests.
const freezeGap = 250 * time.Millisecond

type slowLinkRun struct {
	Frames        int
	DroppedFrames uint64
	KeyframeWaits uint64
	LateRepairs   uint64
	PLIs          int64 // keyframe requests the device received
	// VideoLost and VideoResent are bytes of RTP the link lost, and the
	// device sent again in answer to NACKs (bare client only).
	VideoLost, VideoResent int
	// Freezes are waits of more than freezeGap between two frames.
	LongestFreeze, TotalFreeze time.Duration
	// Frame delay above the run's fastest frame, from capture (the RTP
	// timestamp) to delivery.
	DelayP50, DelayP95, DelayP99 time.Duration
	Kbps                         float64
	// Levels is the seconds spent at each quality level, LevelChanges how
	// often it changed (automatic quality only).
	Levels       map[string]float64
	LevelChanges int
}

func runSlowLink(t *testing.T, l slowLink) slowLinkRun {
	t.Helper()
	t.Setenv("BLITZKVM_IMPAIR", l.spec)
	cfg := Config{Width: 960, Height: 540, FPS: 30, GOP: 3600, KeyframeOnRequest: true}
	if l.auto {
		cfg = Config{Width: 1920, Height: 1080, FPS: 60, GOP: 3600, KeyframeOnRequest: true, EncoderPatch: true,
			Netem: NetemConfig{Rate: deviceSendRate}}
	}
	switch l.content {
	case "desktop":
		// A keyframe every 10 s: the device's keyframes on request and
		// still refreshes, which a box that never rests would not get.
		cfg.Desktop, cfg.GOP = true, 10*cfg.FPS
	case "scroll":
		cfg.Scroll = true
	}
	srv := startTestServer(t, cfg)
	type arrival struct {
		rtp   uint32
		at    time.Time
		bytes int
	}
	var mu sync.Mutex
	var units []arrival
	record := func(au video.AccessUnit) {
		mu.Lock()
		units = append(units, arrival{au.RTPTimestamp, time.Now(), len(au.Data)})
		mu.Unlock()
	}
	var run slowLinkRun
	if l.auto {
		ctrl := appsession.New(appsession.Config{BaseURL: srv.BaseURL(), ICELoopbackOnly: true, AutoQuality: true, OnAccessUnit: record})
		ctx, cancel := context.WithCancel(context.Background())
		ctrl.Start(ctx)
		run.Levels = map[string]float64{}
		level, last := "", time.Now()
		for end := last.Add(l.d); time.Now().Before(end); time.Sleep(20 * time.Millisecond) {
			now := time.Now()
			run.Levels[level] += now.Sub(last).Seconds()
			if s := ctrl.Snapshot().QualityLevel; s != level {
				if level != "" {
					run.LevelChanges++
				}
				level = s
			}
			last = now
		}
		delete(run.Levels, "")
		stats := ctrl.Stats()
		run.DroppedFrames, run.KeyframeWaits, run.LateRepairs = stats.FramesDropped, stats.KeyframeWaits, stats.LateRepairs
		ctrl.Stop()
		cancel()
	} else {
		c := connectClient(t, client.Config{BaseURL: srv.BaseURL(), OnAccessUnit: record})
		time.Sleep(l.d)
		stats := c.Stats()
		link, _ := c.Impairment()
		_ = c.Close()
		run.DroppedFrames, run.KeyframeWaits, run.LateRepairs = stats.FramesDropped, stats.KeyframeWaits, stats.LateRepairs
		run.VideoLost, run.VideoResent = link.VideoLost, link.VideoResent
	}
	run.PLIs = srv.KeyframeRequests()

	mu.Lock()
	defer mu.Unlock()
	run.Frames = len(units)
	if len(units) < 2 {
		run.LongestFreeze, run.TotalFreeze = l.d, l.d // the picture never started
		return run
	}
	delays := make([]time.Duration, len(units))
	bytes := 0
	for i, u := range units {
		captured := time.Duration(int32(u.rtp-units[0].rtp)) * time.Second / 90000
		delays[i] = u.at.Sub(units[0].at) - captured
		bytes += u.bytes
		if i > 0 {
			if gap := u.at.Sub(units[i-1].at); gap > freezeGap {
				run.LongestFreeze = max(run.LongestFreeze, gap)
				run.TotalFreeze += gap
			}
		}
	}
	run.Kbps = float64(bytes) * 8 / l.d.Seconds() / 1000
	fastest := slices.Min(delays)
	for i := range delays {
		delays[i] -= fastest
	}
	slices.Sort(delays)
	run.DelayP50, run.DelayP95, run.DelayP99 = delays[len(delays)/2], delays[len(delays)*95/100], delays[len(delays)*99/100]
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
		run := runSlowLink(t, slowLink{spec: "delay=150ms,loss=2%,seed=1", content: "motion", d: 5 * time.Second})
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
		run := runSlowLink(t, slowLink{spec: "delay=350ms,loss=1%,seed=1", content: "motion", d: 6 * time.Second})
		t.Logf("%+v", run)
		if run.LateRepairs == 0 || 2*run.LateRepairs < run.KeyframeWaits {
			t.Errorf("only %d of %d keyframe waits ended by a late repair", run.LateRepairs, run.KeyframeWaits)
		}
	})
}

// TestSlowLinkBenchmark runs the app's session with automatic quality
// through each profile and prints the median of the runs as a table row.
// BLITZKVM_BENCH=60s runs it; BLITZKVM_BENCH_RUNS (default 1),
// BLITZKVM_BENCH_SEED (of the first run, default 1),
// BLITZKVM_BENCH_PROFILES (space-separated profiles or link specs such as
// "trace=var.trace,queue=1s,delay=30ms"; default: none and every profile) and
// BLITZKVM_BENCH_CONTENT (desktop, scroll or motion; default desktop)
// adjust it. Equal seeds give two builds the same random losses. Each run
// also logs a "BENCH <profile> <json>" line; BLITZKVM_LOG_LEVEL=info adds
// the quality governor's decisions.
func TestSlowLinkBenchmark(t *testing.T) {
	d, err := time.ParseDuration(os.Getenv("BLITZKVM_BENCH"))
	if err != nil {
		t.Skip("set BLITZKVM_BENCH=<duration> to run")
	}
	if raceEnabled {
		t.Skip("timing-sensitive")
	}
	if err := logging.Configure(""); err != nil {
		t.Fatal(err)
	}
	runs, _ := strconv.Atoi(os.Getenv("BLITZKVM_BENCH_RUNS"))
	seed, _ := strconv.Atoi(os.Getenv("BLITZKVM_BENCH_SEED"))
	content := cmp.Or(os.Getenv("BLITZKVM_BENCH_CONTENT"), "desktop")
	profiles := []string{"none", "lte", "lte-congested", "wifi-hotel", "derp"}
	if p := os.Getenv("BLITZKVM_BENCH_PROFILES"); p != "" {
		profiles = strings.Fields(p)
	}
	fmt.Println("| profile | frames | keyframe waits (late repairs) | PLIs | longest / total freeze | delay excess p50 / p95 / p99 | Mbit/s | level changes |")
	fmt.Println("|---|---|---|---|---|---|---|---|")
	for _, profile := range profiles {
		var all []slowLinkRun
		for i := range max(runs, 1) {
			spec := ""
			if profile != "none" {
				spec = fmt.Sprintf("%s,seed=%d", profile, max(seed, 1)+i)
			}
			run := runSlowLink(t, slowLink{spec: spec, content: content, d: d, auto: true})
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
		fmt.Printf("| %s | %.0f | %.1f (%.1f) | %.1f | %.0f / %.0f ms | %.0f / %.0f / %.0f ms | %.2f | %.1f |\n", profile,
			median(func(r slowLinkRun) float64 { return float64(r.Frames) }),
			median(func(r slowLinkRun) float64 { return float64(r.KeyframeWaits) }),
			median(func(r slowLinkRun) float64 { return float64(r.LateRepairs) }),
			median(func(r slowLinkRun) float64 { return float64(r.PLIs) }),
			ms(func(r slowLinkRun) time.Duration { return r.LongestFreeze }),
			ms(func(r slowLinkRun) time.Duration { return r.TotalFreeze }),
			ms(func(r slowLinkRun) time.Duration { return r.DelayP50 }),
			ms(func(r slowLinkRun) time.Duration { return r.DelayP95 }),
			ms(func(r slowLinkRun) time.Duration { return r.DelayP99 }),
			median(func(r slowLinkRun) float64 { return r.Kbps / 1000 }),
			median(func(r slowLinkRun) float64 { return float64(r.LevelChanges) }))
	}
}
