package session

import (
	"fmt"
	"testing"
	"time"

	"github.com/lkarlslund/jetkvm-desktop/pkg/client"
	"github.com/lkarlslund/jetkvm-desktop/pkg/emulator"
)

// feed runs the governor over n one-second samples produced by next.
func feed(g *qualityGovernor, start time.Time, n int, next func(i int, prev client.StatsSnapshot) client.StatsSnapshot) (changes []int, now time.Time) {
	var s client.StatsSnapshot
	now = start
	for i := 0; i < n; i++ {
		now = now.Add(time.Second)
		s = next(i, s)
		if level, changed := g.observe(now, s); changed {
			changes = append(changes, level)
		}
	}
	return changes, now
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
	// Clean again: no step up before upAfterClean, then one step at a time.
	cleanAt30 := func(i int, prev client.StatsSnapshot) client.StatsSnapshot {
		prev.BytesReceived += 400_000
		prev.RoundTripMs = 30
		return prev
	}
	early, now := feed(g, now, int(upAfterClean/time.Second)-2, cleanAt30)
	if len(early) != 0 {
		t.Fatalf("stepped up too early: %v", early)
	}
	later, _ := feed(g, now, 60, cleanAt30)
	if len(later) == 0 || later[0] != low+1 {
		t.Fatalf("expected a single step up to %d, got %v", low+1, later)
	}
}

func TestQualityStepsDownOnQueueingDelay(t *testing.T) {
	start := time.Unix(0, 0)
	g := newQualityGovernor(start, 10*time.Millisecond, upAfterClean)
	before := g.level
	// Baseline 10 ms, then the queue builds to 120 ms without loss.
	i := 0
	bloated := func(_ int, prev client.StatsSnapshot) client.StatsSnapshot {
		i++
		prev.BytesReceived += 400_000
		prev.RoundTripMs = 10
		if i > 3 {
			prev.RoundTripMs = 120
		}
		return prev
	}
	changes, _ := feed(g, start, 8, bloated)
	if len(changes) == 0 || changes[0] != before-1 {
		t.Fatalf("queueing delay did not lower quality: %v", changes)
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
			BitrateKbps: factorKbps(l.Factor, s.VideoWidth, s.VideoHeight)}
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

func TestQualitySkipsARepeatedSample(t *testing.T) {
	start := time.Unix(0, 0)
	g := newQualityGovernor(start, 2*time.Millisecond, upAfterClean)
	s := client.StatsSnapshot{SampledAt: start, RoundTripMs: 2}
	g.observe(start, s)
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
	g.observe(start.Add(time.Second), first)
	g.observe(start.Add(1500*time.Millisecond), first)
	if _, changed := g.observe(start.Add(2*time.Second), lossy(start.Add(2*time.Second))); !changed {
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
	cleanAt30 := func(_ int, prev client.StatsSnapshot) client.StatsSnapshot {
		prev.BytesReceived += 400_000
		prev.RoundTripMs = 30
		return prev
	}
	_, now := feed(g, start, 3, lossy)        // down
	ups, now := feed(g, now, 25, cleanAt30)   // up after 20 s
	_, now = feed(g, now, 3, lossy)           // down again within a minute: flapping
	early, now := feed(g, now, 30, cleanAt30) // 30 s clean: not enough now
	later, _ := feed(g, now, 15, cleanAt30)   // 45 s: the doubled delay has passed
	if len(ups) != 1 || len(early) != 0 || len(later) != 1 {
		t.Fatalf("ups %v, early %v, later %v", ups, early, later)
	}
}
