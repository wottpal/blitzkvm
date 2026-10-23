package session

import (
	"fmt"
	"slices"
	"testing"
	"time"

	"github.com/wottpal/blitzkvm/pkg/client"
	"github.com/wottpal/blitzkvm/pkg/emulator"
	"github.com/wottpal/blitzkvm/pkg/video"
)

// feed runs the governor over n one-second samples produced by next, with
// a link estimate that measures nothing.
func feed(g *qualityGovernor, start time.Time, n int, next func(i int, prev client.StatsSnapshot) client.StatsSnapshot) (changes []int, now time.Time) {
	return feedLink(g, start, n, time.Second, func(i int, prev client.StatsSnapshot) (client.StatsSnapshot, video.LinkEstimate) {
		return next(i, prev), video.LinkEstimate{}
	})
}

// feedLink runs the governor over n samples, every step, produced by next.
func feedLink(g *qualityGovernor, start time.Time, n int, step time.Duration, next func(i int, prev client.StatsSnapshot) (client.StatsSnapshot, video.LinkEstimate)) (changes []int, now time.Time) {
	var s client.StatsSnapshot
	var link video.LinkEstimate
	now = start
	for i := 0; i < n; i++ {
		now = now.Add(step)
		s, link = next(i, s)
		if level, why := g.observe(now, s, link); why != "" {
			changes = append(changes, level)
		}
	}
	return changes, now
}

// measured is a link estimate that has measured rate (bit/s) on enough
// frames, with no queue.
func measured(rate float64) video.LinkEstimate {
	return video.LinkEstimate{Rate: rate, RateBytes: 1_000_000, RateFrames: 60, QueueFrames: 6}
}

// clean: 4 Mbit/s, 2 ms RTT, no loss.
func clean(_ int, prev client.StatsSnapshot) client.StatsSnapshot {
	prev.BytesReceived += 500_000
	prev.RoundTripMs = 2
	return prev
}

func TestQualityStartsHighOnLANAndStaysThereWhenClean(t *testing.T) {
	start := time.Unix(0, 0)
	g := newQualityGovernor(start, 2*time.Millisecond, upAfterClean)
	if g.level != len(qualityLadder)-1 {
		t.Fatalf("LAN start level = %d", g.level)
	}
	if changes, _ := feed(g, start, 120, clean); len(changes) != 0 {
		t.Fatalf("clean link changed level: %v", changes)
	}
}

func TestQualityStepsDownOnLossAndRecoversSlowly(t *testing.T) {
	start := time.Unix(0, 0)
	g := newQualityGovernor(start, 30*time.Millisecond, upAfterClean)
	top := g.level
	// 5% loss for 10 s: two steps down at most every downCooldown.
	lossy := func(_ int, prev client.StatsSnapshot) client.StatsSnapshot {
		prev.BytesReceived += 400_000
		prev.PacketsLost += 18 // ~5% of ~350 packets
		prev.RoundTripMs = 30
		return prev
	}
	changes, now := feed(g, start, 10, lossy)
	if len(changes) < 2 || changes[0] != top-1 {
		t.Fatalf("expected steps down from %d, got %v", top, changes)
	}
	low := g.level
	// Clean again on a link measured to carry every level: no step up
	// before upAfterClean, then one step at a time.
	cleanAt30 := func(i int, prev client.StatsSnapshot) (client.StatsSnapshot, video.LinkEstimate) {
		prev.BytesReceived += 400_000
		prev.RoundTripMs = 30
		return prev, measured(50e6)
	}
	early, now := feedLink(g, now, int(upAfterClean/time.Second)-2, time.Second, cleanAt30)
	if len(early) != 0 {
		t.Fatalf("stepped up too early: %v", early)
	}
	later, _ := feedLink(g, now, 60, time.Second, cleanAt30)
	if len(later) == 0 || later[0] != low+1 {
		t.Fatalf("expected a single step up to %d, got %v", low+1, later)
	}
}

// at1080p is a governor for 1080p video started at rtt.
func at1080p(start time.Time, rtt time.Duration) *qualityGovernor {
	g := newQualityGovernor(start, rtt, upAfterClean)
	g.width, g.height = 1920, 1080
	return g
}

// cleanStats is a clean second of transport statistics at rtt.
func cleanStats(prev client.StatsSnapshot, rtt float64) client.StatsSnapshot {
	prev.SampledAt = prev.SampledAt.Add(time.Second)
	prev.BytesReceived += 400_000
	prev.RoundTripMs = rtt
	return prev
}

// onLinkLAN is a statistics sample's path over Wi-Fi or Ethernet to the
// device's own subnet.
var onLinkLAN = client.StatsSnapshot{Path: client.PathLAN, PathRemote: "192.168.1.40", PathOnLink: true}

// wifi feeds clean samples at the round trips (ms), a second apart.
func wifi(g *qualityGovernor, start time.Time, link video.LinkEstimate, rtts ...float64) time.Time {
	s := client.StatsSnapshot{SampledAt: start}
	now := start
	for i, rtt := range rtts {
		now = start.Add(time.Duration(i+1) * time.Second)
		s = cleanStats(s, rtt)
		g.observe(now, s, link)
	}
	return now
}

// Home Wi-Fi: the round trip swings between 5 and 35 ms, its lowest of a
// minute 6-9 ms. On a LAN path to the device's subnet that is a LAN: the
// session goes to the top even after a first sample that guessed high, and
// the encoder is not capped.
func TestQualityWiFiLANIsALAN(t *testing.T) {
	start := time.Unix(0, 0)
	g := at1080p(start, 34*time.Millisecond)
	if g.level != 3 {
		t.Fatalf("a 34 ms first sample started at %d, want high", g.level)
	}
	g.setPath(onLinkLAN)
	now := wifi(g, start, video.LinkEstimate{}, 24, 9, 15, 11, 16, 25)
	if !g.onLAN() || g.level != len(qualityLadder)-1 {
		t.Fatalf("Wi-Fi LAN (baseline %v): onLAN %v, level %d, want a LAN at maximum", g.baseRTT, g.onLAN(), g.level)
	}
	if g.updatePeak(now, measured(6e6)); g.params().PeakKbps != 0 || g.params().PaceKbps != 0 {
		t.Fatalf("Wi-Fi LAN capped the peak at %d, paced at %d", g.params().PeakKbps, g.params().PaceKbps)
	}

	for _, c := range []struct {
		name string
		path client.StatsSnapshot
		rtts []float64
	}{
		// A private network behind a router (another site, a VLAN) is held
		// to lanRTT, as are the emulator's impaired links over loopback.
		{"a routed private network", client.StatsSnapshot{Path: client.PathLAN, PathRemote: "10.1.2.40"}, []float64{24, 9, 15, 11, 16, 25}},
		{"loopback", client.StatsSnapshot{Path: client.PathLoopback, PathRemote: "127.0.0.1"}, []float64{20, 20}},
		{"a Wi-Fi LAN that never comes below lanPathRTT", onLinkLAN, []float64{34, 31, 40}},
	} {
		g := at1080p(start, 34*time.Millisecond)
		g.setPath(c.path)
		wifi(g, start, video.LinkEstimate{}, c.rtts...)
		if g.onLAN() || g.level != 3 {
			t.Errorf("%s (baseline %v): onLAN %v, level %d, want no LAN, high", c.name, g.baseRTT, g.onLAN(), g.level)
		}
	}
}

// A session that started off a LAN (the rate was measured while the round
// trip still spiked) goes to the top once the LAN shows, as long as it hasn't
// stepped since; a step since, or loss, keeps the ladder's way up.
func TestQualityLANStartOverridesTheStart(t *testing.T) {
	start := time.Unix(0, 0)
	g := at1080p(start, 40*time.Millisecond)
	g.setPath(onLinkLAN)
	if level, why := g.observe(start, cleanStats(client.StatsSnapshot{SampledAt: start}, 40), measured(6e6)); why != "start" || level != 2 {
		t.Fatalf("the start off a LAN went to %d (%s), want balanced", level, why)
	}
	s := cleanStats(client.StatsSnapshot{SampledAt: start.Add(time.Second)}, 9)
	if level, why := g.observe(start.Add(2*time.Second), s, measured(6e6)); why != "start" || level != len(qualityLadder)-1 {
		t.Fatalf("the LAN went to %d (%s), want maximum", level, why)
	}
	if !g.lastUp.IsZero() {
		t.Fatal("the LAN start counts as a step up (flapping)")
	}

	stepped := at1080p(start, 40*time.Millisecond)
	stepped.setPath(onLinkLAN)
	stepped.observe(start, cleanStats(client.StatsSnapshot{SampledAt: start}, 40), measured(6e6))
	stepped.down(start.Add(time.Second), 1, measured(6e6), "loss")
	s = cleanStats(client.StatsSnapshot{SampledAt: start.Add(time.Second)}, 9)
	if level, why := stepped.observe(start.Add(2*time.Second), s, measured(6e6)); why != "" || level != 1 {
		t.Fatalf("after a step down the LAN went to %d (%s), want it to stay", level, why)
	}

	lossy := at1080p(start, 40*time.Millisecond)
	lossy.setPath(onLinkLAN)
	prev := client.StatsSnapshot{SampledAt: start, BytesReceived: 1_000_000}
	lossy.observe(start, prev, video.LinkEstimate{})
	s = cleanStats(prev, 9)
	s.PacketsLost = 50
	if level, why := lossy.observe(start.Add(time.Second), s, video.LinkEstimate{}); why == "start" || level == len(qualityLadder)-1 {
		t.Fatalf("a lossy LAN started at %d (%s)", level, why)
	}
}

// A new path starts its own baseline: the LAN's round trips don't make a
// relay a LAN.
func TestQualityNewPathNewBaseline(t *testing.T) {
	start := time.Unix(0, 0)
	g := at1080p(start, 3*time.Millisecond)
	g.setPath(onLinkLAN)
	if !g.onLAN() {
		t.Fatal("3 ms on a LAN is no LAN")
	}
	g.setPath(onLinkLAN)
	if !g.onLAN() {
		t.Fatal("the same path again lost its baseline")
	}
	g.setPath(client.StatsSnapshot{Path: client.PathInternet, PathRemote: "203.0.113.7"})
	if g.onLAN() || g.baseRTT != 0 {
		t.Fatalf("a relay kept the LAN's baseline %v", g.baseRTT)
	}
}

// On a LAN the top level encodes every captured frame where the encoder
// keeps up (sourceRatePixels) and a frame rate change is free (D18);
// elsewhere, and at other levels, at most 60.
func TestQualitySourceRateAtTheTopOnALAN(t *testing.T) {
	start := time.Unix(0, 0)
	lan := 2 * time.Millisecond
	for _, c := range []struct {
		name          string
		rtt           time.Duration
		width, height int
		fps           float64
		old, tunnel   bool
		want          int
	}{
		{"1456×920 at 90 Hz on a LAN", lan, 1456, 920, 90, false, false, 0},
		{"1280×720 at 120 Hz on a LAN", lan, 1280, 720, 120, false, false, 0},
		{"1920×1080 at 90 Hz on a LAN: over the encoder's rate", lan, 1920, 1080, 90, false, false, 60},
		{"60 Hz on a LAN", lan, 2400, 1012, 60, false, false, 60},
		{"60.5 Hz on a LAN", lan, 1920, 1080, 60.5, false, false, 60},
		{"no video yet", lan, 0, 0, 90, false, false, 60},
		{"no frame rate yet", lan, 1456, 920, 0, false, false, 60},
		{"firmware before D18 (a keyframe a change)", lan, 1456, 920, 90, true, false, 60},
		{"Tailscale on the device", lan, 1456, 920, 90, false, true, 60},
		{"1456×920 at 90 Hz off a LAN", 60 * time.Millisecond, 1456, 920, 90, false, false, 60},
	} {
		g := newQualityGovernor(start, c.rtt, upAfterClean)
		g.width, g.height, g.sourceFPS = c.width, c.height, c.fps
		g.framePacing, g.deviceTunnel = !c.old, c.tunnel
		g.level = len(qualityLadder) - 1
		if got := g.params().MaxFPS; got != c.want {
			t.Errorf("%s: maxFps %d, want %d", c.name, got, c.want)
		}
		g.level--
		if got := g.params().MaxFPS; got != 60 {
			t.Errorf("%s, one level down: maxFps %d, want 60", c.name, got)
		}
	}
}

// The baseline is the lowest round trip of the last minute: a spike after
// the minute doesn't become it, and an old low sample leaves it.
func TestQualityRTTBaselineSlides(t *testing.T) {
	start := time.Unix(0, 0)
	g := at1080p(start, 6*time.Millisecond)
	for i := 1; i <= 59; i++ {
		g.noteRTT(start.Add(time.Duration(i)*time.Second), 9*time.Millisecond)
	}
	g.noteRTT(start.Add(61*time.Second), 150*time.Millisecond)
	if g.baseRTT != 9*time.Millisecond {
		t.Fatalf("baseline %v after a spike, want 9ms", g.baseRTT)
	}
	g.noteRTT(start.Add(125*time.Second), 20*time.Millisecond)
	if g.baseRTT != 20*time.Millisecond {
		t.Fatalf("baseline %v a minute after the last low sample, want 20ms", g.baseRTT)
	}
}

func TestQualityStepsDownAtOnceWhenAQueueGrows(t *testing.T) {
	start := time.Unix(0, 0)
	g := at1080p(start, 30*time.Millisecond) // high
	g.lastChange = start                     // past the start
	// 12 Mbit/s measured: high fits. Then the cell drops to 4 Mbit/s:
	// frames queue up, the wait grows, and the rate median still reads
	// 12. What arrives while the queue stands is the link's rate now: one
	// step straight to low (2.3 Mbit/s). When the queue still grows a
	// second later, at 2 Mbit/s, the next goes to minimal.
	queue := func(i int) video.LinkEstimate {
		link := measured(12e6)
		if i >= 10 {
			link.Queue, link.QueueGrowth, link.Delivered = time.Duration(i-5)*20*time.Millisecond, 20*time.Millisecond, 4e6
		}
		if i >= 15 {
			link.Delivered = 2e6
		}
		return link
	}
	changes, _ := feedLink(g, start, 30, qualityTick, func(i int, prev client.StatsSnapshot) (client.StatsSnapshot, video.LinkEstimate) {
		if i%10 == 0 {
			prev = cleanStats(prev, 30)
		}
		return prev, queue(i)
	})
	if want := []int{1, 0}; !slices.Equal(changes, want) {
		t.Fatalf("changes %v, want %v", changes, want)
	}
}

func TestQualityLeavesADrainingBurstAloneOnALAN(t *testing.T) {
	start := time.Unix(0, 0)
	g := at1080p(start, 2*time.Millisecond) // maximum
	// The rate measured is the device's send path, here below maximum's
	// target, and every 6 s a still refresh drains through it: the frames
	// behind it wait up to 120 ms, less and less.
	changes, _ := feedLink(g, start, 600, qualityTick, func(i int, prev client.StatsSnapshot) (client.StatsSnapshot, video.LinkEstimate) {
		if i%10 == 0 {
			prev = cleanStats(prev, 2)
		}
		link := measured(10e6)
		if i%60 == 1 {
			link.Queue, link.QueueGrowth = 120*time.Millisecond, -110*time.Millisecond
		}
		return prev, link
	})
	if len(changes) != 0 {
		t.Fatalf("a LAN left maximum: %v", changes)
	}
}

func TestQualityLeavesAQueueOfRepairsAlone(t *testing.T) {
	start := time.Unix(0, 0)
	g := at1080p(start, 60*time.Millisecond)
	g.level, g.lastChange = 1, start // low, which 4 Mbit/s carries
	// After an outage, NACK repairs and the keyframe asked for with them
	// queue up for a moment.
	changes, _ := feedLink(g, start, 10, qualityTick, func(i int, prev client.StatsSnapshot) (client.StatsSnapshot, video.LinkEstimate) {
		link := measured(4e6)
		link.Queue, link.QueueGrowth, link.RepairShare = time.Duration(80+20*i)*time.Millisecond, 20*time.Millisecond, 0.6
		return prev, link
	})
	if len(changes) != 0 {
		t.Fatalf("a queue of repairs changed quality: %v", changes)
	}
}

func TestQualityLeavesALevelTheLinkDoesNotCarry(t *testing.T) {
	start := time.Unix(0, 0)
	g := at1080p(start, 60*time.Millisecond) // balanced: 4 Mbit/s
	g.lastChange = start                     // past the start
	changes, _ := feedLink(g, start, 2, qualityTick, func(_ int, prev client.StatsSnapshot) (client.StatsSnapshot, video.LinkEstimate) {
		return cleanStats(prev, 60), measured(3.5e6)
	})
	if want := []int{1}; !slices.Equal(changes, want) {
		t.Fatalf("changes %v, want %v (low)", changes, want)
	}
}

func TestQualityStartsAtTheLevelTheLinkCarries(t *testing.T) {
	for _, c := range []struct {
		rate float64
		want int
	}{{3.5e6, 1}, {4.7e6, 1}, {12e6, 3}, {21e6, 4}} {
		start := time.Unix(0, 0)
		g := at1080p(start, 60*time.Millisecond)
		g.observe(start, cleanStats(client.StatsSnapshot{}, 60), measured(c.rate))
		if g.level != c.want {
			t.Errorf("%.1f Mbit/s: started at %d, want %d", c.rate/1e6, g.level, c.want)
		}
	}
}

func TestQualityStillRefreshFitsTheLink(t *testing.T) {
	for _, c := range []struct {
		rtt         time.Duration
		rate        float64
		level, qp   int
		description string
	}{
		{60 * time.Millisecond, 3.8e6, 1, 21, "4 Mbit/s: low's 161 kB refresh would take 340 ms; none"},
		{60 * time.Millisecond, 12e6, 3, 5, "12 Mbit/s: high's refresh one QP coarser, 298 kB in 200 ms"},
		{60 * time.Millisecond, 50e6, 4, 1, "50 Mbit/s: maximum's as it is"},
		{2 * time.Millisecond, 10e6, 4, 1, "a LAN keeps the ladder's"},
	} {
		start := time.Unix(0, 0)
		g := at1080p(start, c.rtt)
		g.observe(start, cleanStats(client.StatsSnapshot{}, c.rtt.Seconds()*1000), measured(c.rate))
		if p := g.params(); g.level != c.level || p.StillQP != c.qp {
			t.Errorf("%s: level %d still QP %d, want %d and %d", c.description, g.level, p.StillQP, c.level, c.qp)
		}
	}
}

func TestQualityStepsUpOnlyOnEvidence(t *testing.T) {
	start := time.Unix(0, 0)
	g := at1080p(start, 60*time.Millisecond)
	g.level, g.lastChange = 1, start // low, after a step down
	idle := func(_ int, prev client.StatsSnapshot) (client.StatsSnapshot, video.LinkEstimate) {
		return cleanStats(prev, 60), video.LinkEstimate{QueueFrames: 6}
	}
	// Five minutes of a still screen: single-packet frames measure no rate.
	if changes, _ := feedLink(g, start, 300, time.Second, idle); len(changes) != 0 {
		t.Fatalf("stepped up on idle time: %v", changes)
	}
	// Scrolling measures 12 Mbit/s: one step at once (the clean stretch is
	// long past), the next after upAfterClean, and no further than high.
	now := start.Add(300 * time.Second)
	changes, _ := feedLink(g, now, 120, time.Second, func(_ int, prev client.StatsSnapshot) (client.StatsSnapshot, video.LinkEstimate) {
		return cleanStats(prev, 60), measured(12e6)
	})
	if want := []int{2, 3}; !slices.Equal(changes, want) {
		t.Fatalf("changes %v, want %v", changes, want)
	}
}

func TestQualitySevereLossDropsTwoLevels(t *testing.T) {
	start := time.Unix(0, 0)
	g := newQualityGovernor(start, 2*time.Millisecond, upAfterClean)
	top := g.level
	severe := func(_ int, prev client.StatsSnapshot) client.StatsSnapshot {
		prev.BytesReceived += 300_000
		prev.PacketsLost += 60 // ~20%
		prev.RoundTripMs = 2
		return prev
	}
	changes, _ := feed(g, start, 3, severe)
	if len(changes) == 0 || changes[0] != top-2 {
		t.Fatalf("severe loss: want %d, got %v", top-2, changes)
	}
}

func TestQualityIgnoresASingleNoisySample(t *testing.T) {
	start := time.Unix(0, 0)
	g := newQualityGovernor(start, 2*time.Millisecond, upAfterClean)
	blip := func(i int, prev client.StatsSnapshot) client.StatsSnapshot {
		prev.BytesReceived += 500_000
		prev.RoundTripMs = 2
		if i == 5 {
			prev.PacketsLost += 10 // ~2.3%, one sample only
		}
		return prev
	}
	if changes, _ := feed(g, start, 30, blip); len(changes) != 0 {
		t.Fatalf("a single mild loss sample changed quality: %v", changes)
	}
}

func TestQualityIgnoresALossOnAStillScreen(t *testing.T) {
	start := time.Unix(0, 0)
	g := newQualityGovernor(start, 30*time.Millisecond, upAfterClean)
	// A still screen: a handful of packets a second, one of them lost.
	still := func(_ int, prev client.StatsSnapshot) client.StatsSnapshot {
		prev.BytesReceived += 6_000
		prev.PacketsLost++
		prev.RoundTripMs = 30
		return prev
	}
	if changes, _ := feed(g, start, 10, still); len(changes) != 0 {
		t.Fatalf("single losses on a still screen changed quality: %v", changes)
	}
}

func TestFactorKbpsMatchesFirmware(t *testing.T) {
	for _, c := range []struct {
		factor float64
		w, h   int
		want   int
	}{
		{1, 1920, 1080, 4000},
		{0.5, 1920, 1080, 2256},
		{3, 1920, 1080, 10976},
		{1, 1280, 720, 1777},
		{0.1, 640, 480, 200},
	} {
		if got := factorKbps(c.factor, c.w, c.h); got != c.want {
			t.Errorf("factorKbps(%g, %dx%d) = %d, want %d", c.factor, c.w, c.h, got, c.want)
		}
	}
}

func TestQualityIgnoresStartupKeyframeWaitButReactsToRepeatedRepairFailures(t *testing.T) {
	start := time.Unix(0, 0)
	g := newQualityGovernor(start, 2*time.Millisecond, upAfterClean)
	top := g.level
	// Session start: frames dropped until the first keyframe, no loss.
	startup := func(i int, prev client.StatsSnapshot) client.StatsSnapshot {
		prev.BytesReceived += 500_000
		prev.RoundTripMs = 2
		if i < 4 {
			prev.FramesDropped += 60
		}
		return prev
	}
	changes, now := feed(g, start, 10, startup)
	if len(changes) != 0 {
		t.Fatalf("startup keyframe wait changed quality: %v", changes)
	}
	// Two unrepaired losses in a row: step down.
	failing := func(_ int, prev client.StatsSnapshot) client.StatsSnapshot {
		prev.BytesReceived += 500_000
		prev.RoundTripMs = 2
		prev.KeyframeWaits++
		return prev
	}
	changes, _ = feed(g, now, 2, failing)
	if len(changes) != 1 || changes[0] != top-1 {
		t.Fatalf("repeated repair failures: want [%d], got %v", top-1, changes)
	}
}

// Stock firmware (the emulator has no setVideoEncoderParams): a manual level
// sets the device's quality factor once, and turning automatic off keeps the
// level automatic had chosen.
func TestControllerQualityLevelsOnStockFirmware(t *testing.T) {
	srv, ctx, cancel := startEmulator(t)
	defer cancel()
	controller := New(Config{
		BaseURL:         srv.BaseURL(),
		ICELoopbackOnly: true,
		Password:        "secret",
		RPCTimeout:      2 * time.Second,
		Reconnect:       true,
	})
	controller.Start(ctx)
	defer controller.Stop()
	waitForPhase(t, controller, PhaseConnected, 5*time.Second)

	if err := controller.SetQualityLevel(ctx, "low"); err != nil {
		t.Fatalf("SetQualityLevel: %v", err)
	}
	var factor float64
	raw, err := controller.Call(ctx, "getStreamQualityFactor", nil)
	if err == nil {
		_, err = fmt.Sscan(string(raw), &factor)
	}
	if err != nil || factor != 0.5 {
		t.Fatalf("device factor = %v (%v), want 0.5", factor, err)
	}
	if s := controller.Snapshot(); s.QualityLevel != "low" || s.AutoQuality {
		t.Fatalf("snapshot level %q auto %v", s.QualityLevel, s.AutoQuality)
	}
	if err := controller.SetQualityLevel(ctx, "turbo"); err == nil {
		t.Fatal("unknown level accepted")
	}

	// Automatic on, then off: the level it ran at stays configured.
	controller.SetAutoQuality(true)
	deadline := time.Now().Add(5 * time.Second)
	for controller.Snapshot().QualityLevel == "low" && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	chosen := controller.Snapshot().QualityLevel
	if chosen == "low" || chosen == "" {
		t.Fatalf("automatic did not pick a level (still %q)", chosen)
	}
	controller.SetAutoQuality(false)
	controller.mu.RLock()
	kept := controller.cfg.QualityLevel
	controller.mu.RUnlock()
	if kept != chosen {
		t.Fatalf("automatic off kept %q, want %q", kept, chosen)
	}
}

// Firmware with the encoder patch: a level is applied live through
// setVideoEncoderParams, including the still-screen refresh QP.
func TestControllerQualityLevelsOnPatchedFirmware(t *testing.T) {
	srv, ctx, cancel := startEmulatorWith(t, emulator.Config{EncoderPatch: true})
	defer cancel()
	controller := New(Config{
		BaseURL:         srv.BaseURL(),
		ICELoopbackOnly: true,
		Password:        "secret",
		RPCTimeout:      2 * time.Second,
		Reconnect:       true,
	})
	controller.Start(ctx)
	defer controller.Stop()
	waitForPhase(t, controller, PhaseConnected, 5*time.Second)

	for _, name := range []string{"maximum", "minimal"} {
		if err := controller.SetQualityLevel(ctx, name); err != nil {
			t.Fatalf("SetQualityLevel(%s): %v", name, err)
		}
		l := qualityLadder[levelIndex(name)]
		s := controller.Snapshot()
		want := emulator.EncoderParams{MinQP: l.MinQP, MaxQP: emulator.DefaultEncoderParams.MaxQP,
			GOPSeconds: emulator.DefaultEncoderParams.GOPSeconds, MaxFPS: l.MaxFPS, StillQP: l.StillQP,
			BitrateKbps: factorKbps(l.Factor, s.VideoWidth, s.VideoHeight), AutoRefresh: true}
		want.MaxBitrateKbps = want.BitrateKbps * 3 / 2
		if got := srv.State().EncoderParams; got != want {
			t.Fatalf("%s: device params %+v, want %+v", name, got, want)
		}
		if s.QualityLevel != name {
			t.Fatalf("%s: snapshot level %q", name, s.QualityLevel)
		}
	}
	// The stock quality factor is left alone on the live path.
	if f := srv.State().StreamQualityFactor; f != 0.75 {
		t.Fatalf("quality factor changed to %v", f)
	}
}

// Client-driven still refresh: on firmware that offers refreshRegions, a
// client that plans refreshes turns the device's own off with every level,
// also after a reconnect (the device drops overrides with the session).
// Other clients, and firmware without the feature, keep the device's.
func TestControllerClientRefresh(t *testing.T) {
	for _, tc := range []struct {
		name          string
		d13, wantsIt  bool
		clientRefresh bool
	}{
		{name: "client plans, D13", d13: true, wantsIt: true, clientRefresh: true},
		{name: "client does not plan, D13", d13: true},
		{name: "client plans, before D13", wantsIt: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv, ctx, cancel := startEmulatorWith(t, emulator.Config{EncoderPatch: true, RefreshRegions: tc.d13})
			defer cancel()
			controller := New(Config{
				BaseURL:         srv.BaseURL(),
				ICELoopbackOnly: true,
				Password:        "secret",
				RPCTimeout:      2 * time.Second,
				Reconnect:       true,
				ReconnectBase:   50 * time.Millisecond,
				QualityLevel:    "high",
				ClientRefresh:   tc.wantsIt,
			})
			controller.Start(ctx)
			defer controller.Stop()
			l := qualityLadder[levelIndex("high")]
			check := func(when string) {
				t.Helper()
				deadline := time.Now().Add(5 * time.Second)
				for controller.Snapshot().MinQP == 0 && time.Now().Before(deadline) {
					time.Sleep(25 * time.Millisecond)
				}
				s := controller.Snapshot()
				if s.ClientRefresh != tc.clientRefresh || s.MinQP != l.MinQP || s.StillQP != l.StillQP {
					t.Fatalf("%s: snapshot clientRefresh %v minQp %d stillQp %d, want %v %d %d", when, s.ClientRefresh, s.MinQP, s.StillQP, tc.clientRefresh, l.MinQP, l.StillQP)
				}
				if got := srv.State().EncoderParams; got.AutoRefresh == tc.clientRefresh || got.MinQP != l.MinQP {
					t.Fatalf("%s: device params %+v", when, got)
				}
			}
			waitForPhase(t, controller, PhaseConnected, 5*time.Second)
			check("connected")

			srv.DisconnectSession()
			deadline := time.Now().Add(5 * time.Second)
			for srv.SessionCount() < 2 && time.Now().Before(deadline) {
				time.Sleep(25 * time.Millisecond)
			}
			waitForPhase(t, controller, PhaseConnected, 5*time.Second)
			check("reconnected")
		})
	}
}

func TestQualitySkipsARepeatedSample(t *testing.T) {
	start := time.Unix(0, 0)
	g := newQualityGovernor(start, 2*time.Millisecond, upAfterClean)
	s := client.StatsSnapshot{SampledAt: start, RoundTripMs: 2}
	g.observe(start, s, video.LinkEstimate{})
	lossy := func(at time.Time) client.StatsSnapshot {
		s.SampledAt = at
		s.BytesReceived += 400_000
		s.PacketsLost += 20 // ~5%
		return s
	}
	// Two lossy seconds, but the governor's tick reads the first sample
	// twice in between. Read as a clean second, the repeat would reset the
	// congestion count and the step down would never come.
	first := lossy(start.Add(time.Second))
	g.observe(start.Add(time.Second), first, video.LinkEstimate{})
	g.observe(start.Add(1500*time.Millisecond), first, video.LinkEstimate{})
	if _, why := g.observe(start.Add(2*time.Second), lossy(start.Add(2*time.Second)), video.LinkEstimate{}); why == "" {
		t.Fatal("sustained loss did not step down")
	}
}

func TestQualityFlappingBacksOffStepUps(t *testing.T) {
	start := time.Unix(0, 0)
	g := newQualityGovernor(start, 30*time.Millisecond, upAfterClean)
	lossy := func(_ int, prev client.StatsSnapshot) client.StatsSnapshot {
		prev.BytesReceived += 400_000
		prev.PacketsLost += 60
		prev.RoundTripMs = 30
		return prev
	}
	cleanAt30 := func(_ int, prev client.StatsSnapshot) (client.StatsSnapshot, video.LinkEstimate) {
		prev.BytesReceived += 400_000
		prev.RoundTripMs = 30
		return prev, measured(50e6)
	}
	_, now := feed(g, start, 3, lossy)                         // down
	ups, now := feedLink(g, now, 25, time.Second, cleanAt30)   // up after 20 s
	_, now = feed(g, now, 3, lossy)                            // down again within a minute: flapping
	early, now := feedLink(g, now, 30, time.Second, cleanAt30) // 30 s clean: not enough now
	later, _ := feedLink(g, now, 15, time.Second, cleanAt30)   // 45 s: the doubled delay has passed
	if len(ups) != 1 || len(early) != 0 || len(later) != 1 {
		t.Fatalf("ups %v, early %v, later %v", ups, early, later)
	}
}

// Every level encodes at the same frame rate: a lower one delays every
// change, and changing it live costs the device a keyframe.
func TestQualityLevelsKeepTheFrameRate(t *testing.T) {
	for _, l := range qualityLadder {
		if l.MaxFPS != qualityLadder[0].MaxFPS {
			t.Errorf("%s encodes at %d fps, %s at %d", l.Name, l.MaxFPS, qualityLadder[0].Name, qualityLadder[0].MaxFPS)
		}
	}
}

// Off a LAN the encoder's peak follows the measured rate; small changes
// and changes soon after the last wait; a LAN has no cap.
func TestQualityPeakFollowsTheLink(t *testing.T) {
	start := time.Unix(0, 0)
	g := at1080p(start, 60*time.Millisecond)
	if !g.updatePeak(start, measured(4e6)) || g.params().PeakKbps != 3600 {
		t.Fatalf("peak %d kbps at 4 Mbit/s, want 3600", g.params().PeakKbps)
	}
	if g.updatePeak(start.Add(peakHold), measured(4.4e6)) {
		t.Fatalf("a 10%% change moved the peak to %d", g.peakKbps)
	}
	if g.updatePeak(start.Add(time.Second), measured(2e6)) {
		t.Fatalf("the peak moved within peakHold, to %d", g.peakKbps)
	}
	if !g.updatePeak(start.Add(peakHold), measured(2e6)) || g.peakKbps != 1800 {
		t.Fatalf("peak %d kbps at 2 Mbit/s, want 1800", g.peakKbps)
	}
	// Balanced's target (4 Mbit/s) and peak follow the cap.
	if target, peak := g.params().bitrates(1920, 1080); target != 1800 || peak != 1800 {
		t.Fatalf("balanced under an 1800 kbps cap: target %d, peak %d", target, peak)
	}

	lan := at1080p(start, 2*time.Millisecond)
	if lan.updatePeak(start, measured(4e6)) || lan.params().PeakKbps != 0 {
		t.Fatalf("a LAN capped the peak at %d", lan.params().PeakKbps)
	}
	if target, peak := lan.params().bitrates(1920, 1080); target != 10976 || peak != 16464 {
		t.Fatalf("maximum on a LAN: target %d, peak %d", target, peak)
	}
}

// Firmware that paces frames (D18) gets the pacing with the peak cap off a
// LAN, and none on a LAN; firmware without it gets none.
func TestQualityPacingFollowsThePeak(t *testing.T) {
	start := time.Unix(0, 0)
	g := at1080p(start, 60*time.Millisecond)
	g.framePacing = true
	if !g.updatePeak(start, measured(4e6)) || g.params().PaceKbps != int(paceOverPeak*3600) {
		t.Fatalf("pace %d kbps under a 3600 kbps peak, want %d", g.params().PaceKbps, int(paceOverPeak*3600))
	}

	lan := at1080p(start, 2*time.Millisecond)
	lan.framePacing, lan.peakKbps, lan.paceKbps = true, 3600, 3600
	if !lan.updatePeak(start, measured(4e6)) || lan.params().PaceKbps != 0 {
		t.Fatalf("a LAN paced at %d kbps", lan.params().PaceKbps)
	}

	fast := at1080p(start, 60*time.Millisecond)
	fast.framePacing = true
	if fast.updatePeak(start, measured(80e6)); fast.paceKbps != 50_000 {
		t.Fatalf("pace %d kbps at 80 Mbit/s, want the firmware's 50000 at most", fast.paceKbps)
	}

	stock := at1080p(start, 60*time.Millisecond)
	if stock.updatePeak(start, measured(4e6)); stock.params().PaceKbps != 0 {
		t.Fatalf("firmware without frame pacing got a pace of %d kbps", stock.params().PaceKbps)
	}
}

// When the JetKVM runs WireGuard itself, its CPU saturates at about half the
// rate its bursts drain at: such a path starts no higher than balanced and
// its peak stays at deviceTunnelShare of the rate.
func TestQualityDeviceTunnelStaysBelowTheDevicesCeiling(t *testing.T) {
	start := time.Unix(0, 0)
	g := at1080p(start, 30*time.Millisecond)
	if g.level != 3 {
		t.Fatalf("a 30 ms round trip started at %d, want high", g.level)
	}
	// A sample without a selected pair says nothing.
	if g.setPath(client.StatsSnapshot{}) || g.deviceTunnel {
		t.Fatal("an empty path changed the governor")
	}
	if !g.setPath(client.StatsSnapshot{Path: client.PathTailscale, PathRemote: "100.64.0.20"}) || g.level != 2 {
		t.Fatalf("a device tunnel started at %d, want balanced", g.level)
	}
	g.updatePeak(start, measured(3.7e6))
	if g.peakKbps != 2035 {
		t.Fatalf("peak %d kbps at 3.7 Mbit/s, want 2035", g.peakKbps)
	}

	// The device's CPU limits a tailnet path at LAN round trips too.
	lan := at1080p(start, 2*time.Millisecond)
	if !lan.setPath(client.StatsSnapshot{Path: client.PathTailscale, PathRemote: "100.64.0.20"}) || lan.level != 2 {
		t.Fatalf("a device tunnel at 2 ms started at %d, want balanced", lan.level)
	}
	if !lan.updatePeak(start, measured(8e6)) || lan.peakKbps != 4400 {
		t.Fatalf("a device tunnel at 2 ms: peak %d kbps, want 4400", lan.peakKbps)
	}
	// A subnet router: the device's LAN address, no tailscaled on it.
	router := at1080p(start, 30*time.Millisecond)
	if router.setPath(client.StatsSnapshot{Path: client.PathTailscale, PathRemote: "192.168.1.40"}) || router.level != 3 {
		t.Fatalf("a subnet router path started at %d, want high", router.level)
	}
}

// The session's first keyframe measures the device at its busiest: the
// start level waits for a rate measured on several frames.
func TestQualityStartWaitsForMoreThanTheFirstKeyframe(t *testing.T) {
	start := time.Unix(0, 0)
	g := at1080p(start, 60*time.Millisecond)
	first := video.LinkEstimate{Rate: 1.4e6, RateBytes: 120_000, RateFrames: 1, QueueFrames: 1}
	if level, why := g.observe(start, cleanStats(client.StatsSnapshot{}, 60), first); why != "" || level != 2 {
		t.Fatalf("one keyframe moved the start to %d (%s)", level, why)
	}
	if g.updatePeak(start, first) {
		t.Fatalf("one keyframe capped the peak at %d", g.peakKbps)
	}
}

// A client that refreshes regions keeps them on where the device's own
// refresh keyframe would not fit the link: they come at the QP floor.
func TestQualityClientRegionRefreshStaysOnOffALAN(t *testing.T) {
	start := time.Unix(0, 0)
	for _, c := range []struct {
		clientRefresh bool
		level, qp     int
	}{{false, 1, 21}, {true, 1, 20}} {
		g := at1080p(start, 60*time.Millisecond)
		g.clientRefresh = c.clientRefresh
		g.observe(start, cleanStats(client.StatsSnapshot{}, 60), measured(3.8e6))
		if p := g.params(); g.level != c.level || p.StillQP != c.qp {
			t.Errorf("client refresh %v: level %d still QP %d, want %d and %d", c.clientRefresh, g.level, p.StillQP, c.level, c.qp)
		}
	}
	// A LAN path at a longer round trip (mesh Wi-Fi): the client may refresh
	// whole frames there, so the budget's verdict stands.
	lan := at1080p(start, 60*time.Millisecond)
	lan.clientRefresh = true
	lan.setPath(client.StatsSnapshot{Path: client.PathLAN, PathRemote: "192.168.1.40"})
	lan.observe(start, cleanStats(client.StatsSnapshot{}, 60), measured(3.8e6))
	if p := lan.params(); p.StillQP != p.MinQP {
		t.Errorf("a LAN path: still QP %d, want the floor %d (off)", p.StillQP, p.MinQP)
	}
	// The lowest level's refresh stays off.
	g := at1080p(start, 60*time.Millisecond)
	g.clientRefresh = true
	g.observe(start, cleanStats(client.StatsSnapshot{}, 60), measured(0.5e6))
	if p := g.params(); g.level != 0 || p.StillQP != p.MinQP {
		t.Errorf("minimal: level %d still QP %d", g.level, p.StillQP)
	}
}

// Game Mode replaces maximum at the top with the game level: no near-lossless
// still refresh, no pacing on a LAN, and every captured frame where maximum
// would encode it.
func TestGameModeTopIsTheGameLevel(t *testing.T) {
	start := time.Unix(0, 0)
	for _, c := range []struct {
		width, height int
		fps           float64
		wantFPS       int
	}{
		{1280, 720, 120, 0},
		{1920, 1080, 60, 60},
	} {
		g := newQualityGovernor(start, 2*time.Millisecond, upAfterClean)
		g.width, g.height, g.sourceFPS = c.width, c.height, c.fps
		g.framePacing, g.gameMode = true, true
		g.level = len(qualityLadder) - 1
		p := g.params()
		if p.Name != "game" || p.MaxFPS != c.wantFPS || p.MinQP != 22 || p.StillQP < p.MinQP || p.PaceKbps != 0 {
			t.Errorf("%dx%d@%v: params %+v, want game, maxFps %d, minQp 22, no still refresh, no pacing", c.width, c.height, c.fps, p, c.wantFPS)
		}
	}
}

// Game Mode turns the still refresh off at every level, on a LAN and off it,
// and no level drops below 60 fps.
func TestGameModeNoStillRefreshAtAnyLevel(t *testing.T) {
	start := time.Unix(0, 0)
	for _, rtt := range []time.Duration{2 * time.Millisecond, 60 * time.Millisecond} {
		g := newQualityGovernor(start, rtt, upAfterClean)
		g.width, g.height, g.sourceFPS = 1920, 1080, 60
		g.framePacing, g.clientRefresh, g.gameMode = true, true, true
		for i := range qualityLadder {
			g.level = i
			// What the governor would hold off a LAN: a refresh just below the
			// floor (stillQPFor), a peak cap and pacing.
			g.stillQP = qualityLadder[i].MinQP - 1
			if rtt > lanRTT {
				g.peakKbps, g.paceKbps = 3000, 3750
			}
			p := g.params()
			if p.StillQP < p.MinQP {
				t.Errorf("rtt %v, level %d: stillQp %d below minQp %d", rtt, i, p.StillQP, p.MinQP)
			}
			if p.MaxFPS != 0 && p.MaxFPS < 60 {
				t.Errorf("rtt %v, level %d: maxFps %d", rtt, i, p.MaxFPS)
			}
		}
	}
}

// "game" is not a ladder level: turning automatic off keeps maximum, the
// level Game Mode replaced, for reconnects.
func TestGameModeAutoOffKeepsALadderLevel(t *testing.T) {
	controller := New(Config{AutoQuality: true, GameMode: true})
	controller.mu.Lock()
	controller.snapshot.QualityLevel = gameLevel.Name
	controller.mu.Unlock()
	controller.SetAutoQuality(false)
	controller.mu.RLock()
	kept := controller.cfg.QualityLevel
	controller.mu.RUnlock()
	if kept != "maximum" {
		t.Fatalf("automatic off kept %q, want maximum", kept)
	}
}

// gameModeEmulator is firmware with the encoder patch, D13's client refresh
// and D18's frame pacing.
var gameModeEmulator = emulator.Config{EncoderPatch: true, RefreshRegions: true, FramePacing: true}

func newGameModeController(t *testing.T, srv *emulator.Server, cfg Config) *Controller {
	t.Helper()
	cfg.BaseURL = srv.BaseURL()
	cfg.ICELoopbackOnly = true
	cfg.Password = "secret"
	cfg.RPCTimeout = 2 * time.Second
	cfg.Reconnect = true
	return New(cfg)
}

// waitFor polls cond until it holds or 5 s have passed.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(25 * time.Millisecond)
	}
}

func TestControllerGameModeSetsEncoder(t *testing.T) {
	srv, ctx, cancel := startEmulatorWith(t, gameModeEmulator)
	defer cancel()
	controller := newGameModeController(t, srv, Config{ClientRefresh: true})
	controller.Start(ctx)
	defer controller.Stop()
	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
	if got := srv.State().EncoderParams; !got.AutoRefresh {
		t.Fatalf("device refresh off before Game Mode: %+v", got)
	}

	if err := controller.SetGameMode(ctx, true); err != nil {
		t.Fatalf("SetGameMode: %v", err)
	}
	if got := srv.State().EncoderParams; got.AutoRefresh || got.StillQP < got.MinQP || got.MinQP != gameLevel.MinQP {
		t.Fatalf("device params %+v, want autoRefresh off, stillQp >= minQp %d", got, gameLevel.MinQP)
	}
	if s := controller.Snapshot(); !s.GameMode || s.ClientRefresh || s.QualityLevel != "game" {
		t.Fatalf("snapshot gameMode %v clientRefresh %v level %q", s.GameMode, s.ClientRefresh, s.QualityLevel)
	}
}

func TestControllerGameModeRestoresTheLevel(t *testing.T) {
	srv, ctx, cancel := startEmulatorWith(t, gameModeEmulator)
	defer cancel()
	controller := newGameModeController(t, srv, Config{ClientRefresh: true, QualityLevel: "balanced"})
	controller.Start(ctx)
	defer controller.Stop()
	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
	waitFor(t, "balanced", func() bool { return controller.Snapshot().MinQP == 18 })

	if err := controller.SetGameMode(ctx, true); err != nil {
		t.Fatalf("SetGameMode(true): %v", err)
	}
	if got := srv.State().EncoderParams; got.MinQP != gameLevel.MinQP {
		t.Fatalf("game: device params %+v", got)
	}
	if err := controller.SetGameMode(ctx, false); err != nil {
		t.Fatalf("SetGameMode(false): %v", err)
	}
	if got := srv.State().EncoderParams; got.MinQP != 18 || got.StillQP != 8 || got.AutoRefresh {
		t.Fatalf("after game: device params %+v, want balanced with the client's refresh", got)
	}
	if s := controller.Snapshot(); !s.ClientRefresh || s.GameMode || s.QualityLevel != "balanced" {
		t.Fatalf("after game: snapshot clientRefresh %v gameMode %v level %q", s.ClientRefresh, s.GameMode, s.QualityLevel)
	}
}

// With automatic quality, Game Mode changes the running governor's level at
// once (not at its next level change), and turning it off brings the still
// refresh back.
func TestControllerGameModeWithAutoQuality(t *testing.T) {
	srv, ctx, cancel := startEmulatorWith(t, gameModeEmulator)
	defer cancel()
	controller := newGameModeController(t, srv, Config{ClientRefresh: true, AutoQuality: true})
	controller.Start(ctx)
	defer controller.Stop()
	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
	waitFor(t, "a level", func() bool { return controller.Snapshot().MinQP != 0 })

	if err := controller.SetGameMode(ctx, true); err != nil {
		t.Fatalf("SetGameMode(true): %v", err)
	}
	waitFor(t, "Game Mode's level", func() bool {
		s, got := controller.Snapshot(), srv.State().EncoderParams
		return !s.ClientRefresh && s.StillQP >= s.MinQP && !got.AutoRefresh && got.StillQP >= got.MinQP
	})
	if err := controller.SetGameMode(ctx, false); err != nil {
		t.Fatalf("SetGameMode(false): %v", err)
	}
	waitFor(t, "the still refresh again", func() bool {
		s, got := controller.Snapshot(), srv.State().EncoderParams
		return s.ClientRefresh && s.StillQP < s.MinQP && s.QualityLevel != "game" && got.StillQP < got.MinQP
	})
}

// Game Mode looks whether the device's relative mouse is on (FPS games need
// it) and reports when it is off, without changing it.
func TestControllerGameModeReportsRelativeMouseOff(t *testing.T) {
	srv, ctx, cancel := startEmulator(t)
	defer cancel()
	controller := newGameModeController(t, srv, Config{})
	controller.Start(ctx)
	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
	if err := controller.SetGameMode(ctx, true); err != nil {
		t.Fatalf("SetGameMode: %v", err)
	}
	if controller.Snapshot().RelativeMouseOff {
		t.Fatal("relative mouse reported off on the default device")
	}
	_ = controller.SetGameMode(ctx, false)
	devices := `{"devices":{"absolute_mouse":true,"relative_mouse":false,"keyboard":true,"mass_storage":true,"audio":true}}`
	if _, err := controller.Call(ctx, "setUsbDevices", []byte(devices)); err != nil {
		t.Fatalf("setUsbDevices: %v", err)
	}
	if err := controller.SetGameMode(ctx, true); err != nil {
		t.Fatalf("SetGameMode: %v", err)
	}
	if !controller.Snapshot().RelativeMouseOff {
		t.Fatal("relative mouse off not reported")
	}
	if srv.State().USBDevices.RelativeMouse {
		t.Fatal("Game Mode turned the relative mouse on")
	}
	// Game Mode off clears the report.
	if err := controller.SetGameMode(ctx, false); err != nil {
		t.Fatalf("SetGameMode: %v", err)
	}
	if controller.Snapshot().RelativeMouseOff {
		t.Fatal("relative mouse off still reported after Game Mode off")
	}
	// The app turns it on (the user's Turn On), then sets Game Mode again
	// to check: the report clears.
	if err := controller.SetGameMode(ctx, true); err != nil || !controller.Snapshot().RelativeMouseOff {
		t.Fatalf("relative mouse off not reported again: %v", err)
	}
	turnOn := []byte(`{"device":"relativeMouse","enabled":true}`)
	if _, err := controller.Call(ctx, "setUsbDeviceState", turnOn); err != nil {
		t.Fatalf("setUsbDeviceState: %v", err)
	}
	if !srv.State().USBDevices.RelativeMouse {
		t.Fatal("setUsbDeviceState left the relative mouse off")
	}
	if err := controller.SetGameMode(ctx, true); err != nil {
		t.Fatalf("SetGameMode: %v", err)
	}
	if controller.Snapshot().RelativeMouseOff {
		t.Fatal("relative mouse off still reported after it was turned on")
	}
	_ = controller.SetGameMode(ctx, false)
	devicesOff := `{"devices":{"absolute_mouse":true,"relative_mouse":false,"keyboard":true,"mass_storage":true,"audio":true}}`
	if _, err := controller.Call(ctx, "setUsbDevices", []byte(devicesOff)); err != nil {
		t.Fatalf("setUsbDevices: %v", err)
	}
	controller.Stop()

	// Connecting with Game Mode on checks too.
	controller = newGameModeController(t, srv, Config{GameMode: true})
	controller.Start(ctx)
	defer controller.Stop()
	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
	waitFor(t, "relative mouse off on connect", func() bool { return controller.Snapshot().RelativeMouseOff })
	if !controller.Snapshot().GameMode {
		t.Fatal("snapshot without Game Mode")
	}
}

// Stock firmware takes Game Mode as the game level's quality factor, and gets
// its own factor back afterwards.
func TestControllerGameModeOnStockFirmware(t *testing.T) {
	srv, ctx, cancel := startEmulator(t)
	defer cancel()
	controller := newGameModeController(t, srv, Config{})
	controller.Start(ctx)
	defer controller.Stop()
	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
	before := srv.State().StreamQualityFactor

	if err := controller.SetGameMode(ctx, true); err != nil {
		t.Fatalf("SetGameMode(true): %v", err)
	}
	var factor float64
	raw, err := controller.Call(ctx, "getStreamQualityFactor", nil)
	if err == nil {
		_, err = fmt.Sscan(string(raw), &factor)
	}
	if err != nil || factor != gameLevel.Factor {
		t.Fatalf("device factor = %v (%v), want %v", factor, err, gameLevel.Factor)
	}
	if err := controller.SetGameMode(ctx, false); err != nil {
		t.Fatalf("SetGameMode(false): %v", err)
	}
	if got := srv.State().StreamQualityFactor; got != before {
		t.Fatalf("factor after Game Mode %v, want %v", got, before)
	}
}
