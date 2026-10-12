package netimpair

import (
	"math"
	"slices"
	"strings"
	"testing"
	"time"
)

var t0 = time.Unix(1000, 0)

func ms(n float64) time.Duration { return time.Duration(n * float64(time.Millisecond)) }

// arrival is when a packet came out of a link, by its send index.
type arrival struct {
	id int
	at time.Time
}

// drain steps a fake clock in 100 µs ticks until both links are empty.
func drain(l *Link[int], from time.Time) []arrival {
	var out []arrival
	for now := from; ; now = now.Add(100 * time.Microsecond) {
		for {
			id, ok := l.Receive(now)
			if !ok {
				break
			}
			out = append(out, arrival{id, now})
		}
		if _, pending := l.Next(); !pending {
			return out
		}
	}
}

func link(cfg Config) *Link[int] {
	cfg.Seed = 1
	_, down := NewPath[int](cfg)
	return down
}

func TestRateSpacesABurst(t *testing.T) {
	l := link(Config{Rate: 1e6}) // 1000 bytes take 8 ms
	for i := range 10 {
		l.Send(t0, 1000, i)
	}
	got := drain(l, t0)
	if len(got) != 10 {
		t.Fatalf("delivered %d of 10", len(got))
	}
	for i, a := range got {
		if want := t0.Add(ms(8 * float64(i+1))); a.id != i || a.at.Sub(want).Abs() > 100*time.Microsecond {
			t.Errorf("packet %d arrived at %s, want #%d at %s", a.id, a.at.Sub(t0), i, want.Sub(t0))
		}
	}
}

func TestDelayWithoutRate(t *testing.T) {
	l := link(Config{Delay: 50 * time.Millisecond})
	l.Send(t0, 1200, 7)
	if _, ok := l.Receive(t0.Add(ms(49.9))); ok {
		t.Fatal("arrived before the propagation delay")
	}
	if id, ok := l.Receive(t0.Add(ms(50))); !ok || id != 7 {
		t.Fatalf("not delivered after the delay (ok=%v id=%d)", ok, id)
	}
}

func TestQueueDropsTail(t *testing.T) {
	// The first packet goes on the wire at once; ten more fit the queue.
	l := link(Config{Rate: 1e6, QueuePackets: 10})
	for i := range 20 {
		l.Send(t0, 1000, i)
	}
	got := drain(l, t0)
	if len(got) != 11 || got[10].id != 10 {
		t.Fatalf("delivered %v, want packets 0-10", got)
	}
	if s := l.Stats(); s.QueueDrops != 9 || s.Delivered != 11 {
		t.Fatalf("stats %+v", s)
	}
}

func TestQueueDropsHead(t *testing.T) {
	l := link(Config{Rate: 1e6, QueueBytes: 10_000, DropHead: true})
	var dropped []int
	l.Dropped = func(id int) { dropped = append(dropped, id) }
	for i := range 20 {
		l.Send(t0, 1000, i)
	}
	got := drain(l, t0)
	// Packet 0 was already on the wire; the queue keeps the newest ten.
	if len(got) != 11 || got[0].id != 0 || got[1].id != 10 || got[10].id != 19 {
		t.Fatalf("delivered %v, want 0 and 10-19", got)
	}
	if !slices.Equal(dropped, []int{1, 2, 3, 4, 5, 6, 7, 8, 9}) {
		t.Fatalf("dropped %v, want 1-9", dropped)
	}
}

func TestQueueDrainsAtLinkRate(t *testing.T) {
	// A queue limit in time: 100 ms at 1 Mbit/s holds 12.5 kB.
	cfg, err := Parse("rate=1mbit,queue=100ms")
	if err != nil {
		t.Fatal(err)
	}
	l := link(cfg)
	for i := range 40 {
		l.Send(t0, 1000, i)
	}
	if got := len(drain(l, t0)); got != 13 { // 1 on the wire + 12 queued
		t.Fatalf("delivered %d, want 13", got)
	}
}

func TestJitterNeverReorders(t *testing.T) {
	l := link(Config{Delay: 30 * time.Millisecond, Jitter: 10 * time.Millisecond})
	for i := range 2000 {
		l.Send(t0.Add(time.Duration(i)*time.Millisecond), 200, i)
	}
	got := drain(l, t0)
	if len(got) != 2000 {
		t.Fatalf("delivered %d of 2000", len(got))
	}
	var lo, hi time.Duration = time.Hour, 0
	for i, a := range got {
		if a.id != i {
			t.Fatalf("packet %d arrived as #%d", a.id, i)
		}
		delay := a.at.Sub(t0.Add(time.Duration(i) * time.Millisecond))
		lo, hi = min(lo, delay), max(hi, delay)
	}
	// Uniform ±10 ms around 30 ms; waiting behind an earlier packet stays
	// within that range too (and narrows it at this packet rate).
	if lo < ms(20) || hi > ms(40.1) || hi-lo < ms(10) {
		t.Fatalf("delays %s-%s, want spread over 20-40 ms", lo, hi)
	}
}

func TestGilbertElliottLoss(t *testing.T) {
	for _, tc := range []struct {
		loss, burst, wantBurst float64
	}{
		{0.01, 4, 4},
		{0.05, 0, 1 / 0.95}, // independent losses
	} {
		l := link(Config{Loss: tc.loss, LossBurst: tc.burst})
		const n = 400_000
		lost, bursts, prevLost := 0, 0, false
		for i := range n {
			l.Send(t0, 100, i)
			_, ok := l.Receive(t0)
			if !ok {
				lost++
				if !prevLost {
					bursts++
				}
			}
			prevLost = !ok
		}
		rate, burst := float64(lost)/n, float64(lost)/float64(bursts)
		if math.Abs(rate-tc.loss) > tc.loss*0.1 || math.Abs(burst-tc.wantBurst) > tc.wantBurst*0.1 {
			t.Errorf("loss %.2f%% burst %.2f: got %.3f%% in bursts of %.2f", 100*tc.loss, tc.burst, 100*rate, burst)
		}
		if s := l.Stats(); s.LossDrops != lost {
			t.Errorf("stats count %d losses, saw %d", s.LossDrops, lost)
		}
	}
}

func TestOutagesHitBothDirections(t *testing.T) {
	up, down := NewPath[int](Config{Seed: 3, OutageEvery: time.Second, OutageMin: 100 * time.Millisecond, OutageMax: 200 * time.Millisecond})
	const n = 200_000 // 200 s, one packet each way per millisecond
	lost := 0
	for i := range n {
		at := t0.Add(time.Duration(i) * time.Millisecond)
		up.Send(at, 100, i)
		down.Send(at, 100, i)
		_, okUp := up.Receive(at)
		_, okDown := down.Receive(at)
		if okUp != okDown {
			t.Fatalf("at %s one direction was out and the other not", at.Sub(t0))
		}
		if !okUp {
			lost++
		}
	}
	// Mean outage 150 ms per 1.15 s cycle.
	if frac := float64(lost) / n; math.Abs(frac-0.15/1.15) > 0.03 {
		t.Fatalf("out %.1f%% of the time, want ≈ %.1f%%", 100*frac, 100*0.15/1.15)
	}
	if s := down.Stats(); s.OutageDrops != lost || s.LossDrops != 0 {
		t.Fatalf("stats %+v, want %d outage drops", s, lost)
	}
}

func TestTraceDeliversMTUPerOpportunity(t *testing.T) {
	trace, err := ParseTrace(strings.NewReader("1\n2\n2\n4\n"))
	if err != nil {
		t.Fatal(err)
	}
	l := link(Config{Trace: trace})
	// Opportunities at 1, 2, 2, 4 ms, then 5, 6, 6, 8 ms, ...
	l.Send(t0, 500, 0)
	l.Send(t0, 500, 1)  // shares the opportunity at 1 ms
	l.Send(t0, 1000, 2) // the last 500 bytes of it, then half of one at 2 ms
	l.Send(t0, 3000, 3) // rest at 2 ms, the second at 2 ms and the one at 4 ms
	l.Send(t0.Add(ms(4.5)), 100, 4)
	want := []time.Duration{ms(1), ms(1), ms(2), ms(4), ms(5)}
	got := drain(l, t0)
	if len(got) != len(want) {
		t.Fatalf("delivered %v", got)
	}
	for i, a := range got {
		if a.at.Sub(t0) != want[i] {
			t.Errorf("packet %d arrived at %s, want %s", a.id, a.at.Sub(t0), want[i])
		}
	}
	// Idle opportunities are lost: a packet sent at 9.5 ms waits for 10 ms.
	l.Send(t0.Add(ms(9.5)), 100, 5)
	if got := drain(l, t0.Add(ms(9.5))); len(got) != 1 || got[0].at.Sub(t0) != ms(10) {
		t.Fatalf("after idling: %v", got)
	}
}

func TestParseProfilesAndOverrides(t *testing.T) {
	for name := range Profiles {
		if _, err := Parse(name); err != nil {
			t.Errorf("profile %s: %v", name, err)
		}
	}
	cfg, err := Parse("lte-congested,loss=1%,rate=2mbit,seed=9")
	if err != nil {
		t.Fatal(err)
	}
	// The queue stays 1.5 s at the overridden rate.
	if cfg.Rate != 2e6 || cfg.Loss != 0.01 || cfg.LossBurst != 3 || cfg.QueueBytes != 375_000 ||
		cfg.OutageMin != 200*time.Millisecond || cfg.OutageMax != 800*time.Millisecond || cfg.Seed != 9 {
		t.Fatalf("parsed %+v", cfg)
	}
	derp, _ := Parse("derp")
	if derp.QueuePackets != 32 || !derp.DropHead || derp.QueueBytes != 0 {
		t.Fatalf("derp %+v", derp)
	}
	for _, bad := range []string{"", "lte5g", "rate=fast", "loss=100%", "queue=1s", "lte,lte", "colour=blue"} {
		if _, err := Parse(bad); err == nil {
			t.Errorf("Parse(%q) accepted", bad)
		}
	}
}
