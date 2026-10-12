// Package netimpair models a slow, lossy network path (a cellular link,
// hotel Wi-Fi, a Tailscale DERP relay) for tests and benchmarks. Each
// direction is a Link: a bottleneck of fixed rate or following a Mahimahi
// delivery trace, a queue limited in bytes or packets, propagation delay with
// jitter that never reorders, Gilbert–Elliott burst loss, and outages shared
// by both directions.
//
// The model is pure: every call takes the current time, so tests drive it
// with a fake clock, and nothing runs on its own. It is not safe for
// concurrent use.
package netimpair

import (
	"fmt"
	"math/rand/v2"
	"sort"
	"time"
)

// MTU is what one delivery opportunity of a trace carries, as in Mahimahi.
const MTU = 1500

// Config describes one path. Both directions use the same settings.
type Config struct {
	// Rate is the bottleneck in bits per second (0: unlimited).
	Rate float64
	// Trace replaces Rate with a Mahimahi delivery trace: each entry is a
	// moment (an offset from the start, ascending) at which the link can
	// deliver MTU bytes. The trace repeats after its last entry.
	Trace []time.Duration
	// QueueBytes and QueuePackets limit the packets waiting for the
	// bottleneck (0: unlimited).
	QueueBytes, QueuePackets int
	// DropHead makes a full queue drop its oldest packets to make room
	// instead of the arriving one.
	DropHead bool
	// Delay is the one-way propagation delay. Jitter varies it uniformly by
	// up to ±Jitter; a packet never overtakes an earlier one.
	Delay, Jitter time.Duration
	// Loss is the mean loss rate (0 ≤ Loss < 1) of a Gilbert–Elliott channel
	// whose bad state loses every packet and whose good state loses none.
	// LossBurst is the mean length of a loss burst in packets; at 1 or less,
	// losses are independent.
	Loss, LossBurst float64
	// OutageEvery is the mean time between outages (a Poisson process; 0:
	// none). An outage lasts between OutageMin and OutageMax (uniform) and
	// loses every packet that leaves the bottleneck during it, both ways.
	OutageEvery, OutageMin, OutageMax time.Duration
	// Seed makes all random decisions reproducible (0: random).
	Seed uint64
}

// Stats counts what a Link did. Delays run from Send to delivery.
type Stats struct {
	Packets, Bytes                     int
	Delivered                          int
	QueueDrops, LossDrops, OutageDrops int
	TotalDelay, MaxDelay               time.Duration
}

// Dropped is the number of packets the link lost for any reason.
func (s Stats) Dropped() int { return s.QueueDrops + s.LossDrops + s.OutageDrops }

func (s Stats) String() string {
	lost, mean := 0.0, time.Duration(0)
	if s.Packets > 0 {
		lost = 100 * float64(s.Dropped()) / float64(s.Packets)
	}
	if s.Delivered > 0 {
		mean = s.TotalDelay / time.Duration(s.Delivered)
	}
	return fmt.Sprintf("%d packets, %.2f%% lost (queue %d, loss %d, outage %d), delay mean %s max %s",
		s.Packets, lost, s.QueueDrops, s.LossDrops, s.OutageDrops, mean.Round(time.Millisecond), s.MaxDelay.Round(time.Millisecond))
}

// Link is one direction of a path. Packets wait in its queue for the
// bottleneck, are lost or sent, and arrive after the propagation delay.
type Link[T any] struct {
	// Dropped, if set, is called with every packet the link loses, from
	// within the Send or Receive call that decides it.
	Dropped func(T)

	cfg     Config
	rng     *rand.Rand
	outages *outages
	// lossEnter and lossStay are the Gilbert–Elliott transition
	// probabilities (good→bad, bad→bad); bad is the current state.
	lossEnter, lossStay float64
	bad                 bool

	origin time.Time // first Send: the trace's time base
	queue  []packet[T]
	queued int       // bytes in queue
	busy   time.Time // the bottleneck sends until then
	// nextOpp is the next unused delivery opportunity of the trace (an
	// index over its repetitions); credit is what is left of the one that
	// ended at busy.
	nextOpp, credit int

	flight  []packet[T] // sent, due times ascending
	lastDue time.Time
	stats   Stats
}

type packet[T any] struct {
	v    T
	size int
	sent time.Time
	due  time.Time
}

// NewPath returns the two directions of one path. They share its outages;
// everything else is independent.
func NewPath[T any](cfg Config) (up, down *Link[T]) {
	seed := cfg.Seed
	if seed == 0 {
		seed = rand.Uint64()
	}
	o := &outages{cfg: cfg, rng: rand.New(rand.NewPCG(seed, 3))}
	return newLink[T](cfg, rand.New(rand.NewPCG(seed, 1)), o), newLink[T](cfg, rand.New(rand.NewPCG(seed, 2)), o)
}

func newLink[T any](cfg Config, rng *rand.Rand, o *outages) *Link[T] {
	l := &Link[T]{cfg: cfg, rng: rng, outages: o}
	if p := cfg.Loss; p > 0 {
		leave := 1 - p // independent losses
		if cfg.LossBurst > 1 {
			leave = 1 / cfg.LossBurst
		}
		// Stationary loss p = enter / (enter + leave).
		l.lossEnter, l.lossStay = p*leave/(1-p), 1-leave
	}
	return l
}

// Stats returns the counters so far.
func (l *Link[T]) Stats() Stats { return l.stats }

// Send offers a packet of size bytes (as on the wire) to the link at now.
func (l *Link[T]) Send(now time.Time, size int, v T) {
	if l.origin.IsZero() {
		l.origin = now
	}
	l.advance(now)
	l.stats.Packets++
	l.stats.Bytes += size
	for l.full(size) {
		if !l.cfg.DropHead || len(l.queue) == 0 {
			l.stats.QueueDrops++
			l.drop(v)
			return
		}
		l.queued -= l.queue[0].size
		l.stats.QueueDrops++
		l.drop(l.queue[0].v)
		l.queue = pop(l.queue)
	}
	l.queue = append(l.queue, packet[T]{v: v, size: size, sent: now})
	l.queued += size
}

func (l *Link[T]) drop(v T) {
	if l.Dropped != nil {
		l.Dropped(v)
	}
}

func (l *Link[T]) full(size int) bool {
	return (l.cfg.QueueBytes > 0 && l.queued+size > l.cfg.QueueBytes) ||
		(l.cfg.QueuePackets > 0 && len(l.queue) >= l.cfg.QueuePackets)
}

// Receive returns the next packet that has arrived by now.
func (l *Link[T]) Receive(now time.Time) (T, bool) {
	l.advance(now)
	if len(l.flight) == 0 || l.flight[0].due.After(now) {
		var zero T
		return zero, false
	}
	p := l.flight[0]
	l.flight = pop(l.flight)
	delay := p.due.Sub(p.sent)
	l.stats.Delivered++
	l.stats.TotalDelay += delay
	l.stats.MaxDelay = max(l.stats.MaxDelay, delay)
	return p.v, true
}

// Next is the earliest time Receive may return a packet.
func (l *Link[T]) Next() (time.Time, bool) {
	switch {
	case len(l.flight) > 0:
		return l.flight[0].due, true
	case len(l.queue) > 0:
		return later(l.queue[0].sent, l.busy), true
	}
	return time.Time{}, false
}

// advance sends every queued packet whose turn at the bottleneck has come by
// now. Its loss, delay and arrival are decided as it starts, which is exact:
// a FIFO link's schedule depends only on what was sent before.
func (l *Link[T]) advance(now time.Time) {
	for len(l.queue) > 0 {
		p := l.queue[0]
		start := later(p.sent, l.busy)
		if start.After(now) {
			return
		}
		l.queue = pop(l.queue)
		l.queued -= p.size
		l.busy = l.transmit(start, p.size)
		if l.lost(l.busy) {
			l.drop(p.v)
			continue
		}
		delay := l.cfg.Delay
		if l.cfg.Jitter > 0 {
			delay += time.Duration((2*l.rng.Float64() - 1) * float64(l.cfg.Jitter))
		}
		p.due = later(l.busy.Add(max(delay, 0)), l.lastDue)
		l.lastDue = p.due
		l.flight = append(l.flight, p)
	}
}

// transmit returns when a packet of size bytes that starts at start has
// left the bottleneck.
func (l *Link[T]) transmit(start time.Time, size int) time.Time {
	switch {
	case len(l.cfg.Trace) > 0:
		return l.traceTransmit(start, size)
	case l.cfg.Rate > 0:
		return start.Add(time.Duration(float64(size) * 8 / l.cfg.Rate * float64(time.Second)))
	}
	return start
}

// traceTransmit follows Mahimahi: each opportunity carries MTU bytes, a
// packet may span several, and what an opportunity has left serves the
// packets already waiting. Opportunities that pass while the queue is empty
// are lost.
func (l *Link[T]) traceTransmit(start time.Time, size int) time.Time {
	need := size
	at := start
	if start.Equal(l.busy) && l.credit > 0 {
		use := min(l.credit, need)
		l.credit -= use
		need -= use
	}
	l.nextOpp = max(l.nextOpp, l.firstOpportunity(start))
	for need > 0 {
		at = l.opportunity(l.nextOpp)
		l.nextOpp++
		use := min(MTU, need)
		need -= use
		l.credit = MTU - use
	}
	return at
}

func (l *Link[T]) period() time.Duration { return l.cfg.Trace[len(l.cfg.Trace)-1] }

func (l *Link[T]) opportunity(i int) time.Time {
	n := len(l.cfg.Trace)
	return l.origin.Add(time.Duration(i/n)*l.period() + l.cfg.Trace[i%n])
}

// firstOpportunity is the index of the first opportunity at or after t.
func (l *Link[T]) firstOpportunity(t time.Time) int {
	n := len(l.cfg.Trace)
	offset := t.Sub(l.origin)
	cycle := int(offset / l.period())
	within := offset - time.Duration(cycle)*l.period()
	return cycle*n + sort.Search(n, func(i int) bool { return l.cfg.Trace[i] >= within })
}

// lost decides the fate of a packet leaving the bottleneck at t. The loss
// channel advances on every packet, so an outage does not shift its
// pattern.
func (l *Link[T]) lost(t time.Time) bool {
	if l.lossEnter > 0 {
		p := l.lossEnter
		if l.bad {
			p = l.lossStay
		}
		l.bad = l.rng.Float64() < p
	}
	switch {
	case l.outages.active(t):
		l.stats.OutageDrops++
	case l.bad:
		l.stats.LossDrops++
	default:
		return false
	}
	return true
}

// outages is a path's outage schedule, generated as time goes on.
type outages struct {
	cfg   Config
	rng   *rand.Rand
	spans []span // ascending, not overlapping
	next  time.Time
}

type span struct{ start, end time.Time }

func (o *outages) active(t time.Time) bool {
	if o.cfg.OutageEvery <= 0 {
		return false
	}
	if o.next.IsZero() {
		o.next = t.Add(o.gap())
	}
	for !o.next.After(t) {
		d := o.cfg.OutageMin
		if o.cfg.OutageMax > d {
			d += time.Duration(o.rng.Float64() * float64(o.cfg.OutageMax-d))
		}
		s := span{o.next, o.next.Add(d)}
		o.spans = append(o.spans, s)
		o.next = s.end.Add(o.gap())
	}
	i := sort.Search(len(o.spans), func(i int) bool { return o.spans[i].end.After(t) })
	return i < len(o.spans) && !o.spans[i].start.After(t)
}

func (o *outages) gap() time.Duration {
	return time.Duration(o.rng.ExpFloat64() * float64(o.cfg.OutageEvery))
}

func later(a, b time.Time) time.Time {
	if a.After(b) {
		return a
	}
	return b
}

// pop removes the first element, clearing it so its value can be collected.
func pop[E any](s []E) []E {
	var zero E
	s[0] = zero
	return s[1:]
}
