package emulator

import (
	"errors"
	"math/rand/v2"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtp"
)

// NetemConfig impairs the emulator's outgoing RTP the way a lossy WAN/VPN
// link would. It acts below pion's NACK responder (closest to the wire), so a
// dropped packet is still in the responder's history and can be retransmitted
// when the client NACKs it, exactly as on a real device.
type NetemConfig struct {
	// LossRate is the probability (0..1) that an outgoing RTP packet is dropped.
	LossRate float64
	// DropSequence drops the packets whose 0-based outgoing index is listed,
	// deterministically (first transmission only; retransmissions pass).
	DropSequence []int
	// Latency delays every outgoing RTP packet by this one-way duration.
	Latency time.Duration
	// HoldEvery and HoldFor stall the link without losing anything: for
	// HoldFor out of every HoldEvery, outgoing RTP is held back and then
	// released at once, like a Wi-Fi hiccup (scan, AWDL, power save). The
	// client receives the frames of the stall in one burst.
	HoldEvery, HoldFor time.Duration
	// Rate paces outgoing RTP to this many bits per second (0: unlimited),
	// so a released hold drains at link speed rather than all at once.
	Rate float64
	// Seed makes LossRate decisions reproducible when non-zero.
	Seed uint64
}

func (c NetemConfig) enabled() bool {
	return c.LossRate > 0 || c.Latency > 0 || len(c.DropSequence) > 0 || c.holds() || c.Rate > 0
}

func (c NetemConfig) holds() bool { return c.HoldEvery > 0 && c.HoldFor > 0 && c.HoldFor < c.HoldEvery }

type netemFactory struct {
	cfg   NetemConfig
	stats *NetemStats
}

// NetemStats counts what the impairment did, for test assertions.
type NetemStats struct {
	Sent    atomic.Int64
	Dropped atomic.Int64
}

func (f *netemFactory) NewInterceptor(string) (interceptor.Interceptor, error) {
	seed := f.cfg.Seed
	if seed == 0 {
		seed = uint64(time.Now().UnixNano())
	}
	drops := make(map[int]bool, len(f.cfg.DropSequence))
	for _, idx := range f.cfg.DropSequence {
		drops[idx] = true
	}
	return &netemInterceptor{
		cfg:   f.cfg,
		stats: f.stats,
		rng:   rand.New(rand.NewPCG(seed, seed^0x9e3779b97f4a7c15)),
		drops: drops,
		start: time.Now(),
	}, nil
}

type netemInterceptor struct {
	interceptor.NoOp
	cfg   NetemConfig
	stats *NetemStats

	mu    sync.Mutex
	rng   *rand.Rand
	index int
	drops map[int]bool
	// highest is the newest sequence number sent (one video stream), so
	// deterministic drops only affect first transmissions and NACK
	// retransmissions get through, across sequence-number wrap.
	started bool
	highest uint16
	queues  map[uint32]chan delayedPacket
	start   time.Time
}

// due is when a packet sent now leaves: after Latency, or at the end of the
// current hold.
func (n *netemInterceptor) due(now time.Time) time.Time {
	due := now.Add(n.cfg.Latency)
	if n.cfg.holds() {
		phase := now.Sub(n.start) % n.cfg.HoldEvery
		if hold := n.cfg.HoldEvery - n.cfg.HoldFor; phase >= hold {
			due = due.Add(n.cfg.HoldEvery - phase)
		}
	}
	return due
}

func (n *netemInterceptor) BindLocalStream(info *interceptor.StreamInfo, writer interceptor.RTPWriter) interceptor.RTPWriter {
	var queue chan delayedPacket
	if n.cfg.Latency > 0 || n.cfg.holds() || n.cfg.Rate > 0 {
		queue = make(chan delayedPacket, 4096)
		n.mu.Lock()
		if n.queues == nil {
			n.queues = map[uint32]chan delayedPacket{}
		}
		n.queues[info.SSRC] = queue
		n.mu.Unlock()
		go func() {
			var next time.Time // when the link is free (Rate)
			for p := range queue {
				if wait := time.Until(p.due); wait > 0 {
					time.Sleep(wait)
				}
				if n.cfg.Rate > 0 {
					// Sleep only once a millisecond of sending has queued up:
					// shorter sleeps overshoot.
					now := time.Now()
					if wait := next.Sub(now); wait > time.Millisecond {
						time.Sleep(wait)
					}
					next = maxTime(next, now).Add(time.Duration(float64(len(p.payload)*8) / n.cfg.Rate * float64(time.Second)))
				}
				_, _ = writer.Write(&p.header, p.payload, p.attrs)
			}
		}()
	}
	return interceptor.RTPWriterFunc(func(header *rtp.Header, payload []byte, attrs interceptor.Attributes) (int, error) {
		if n.shouldDrop(header.SequenceNumber) {
			n.stats.Dropped.Add(1)
			return len(payload), nil
		}
		n.stats.Sent.Add(1)
		if queue == nil {
			return writer.Write(header, payload, attrs)
		}
		p := delayedPacket{header: header.Clone(), payload: append([]byte(nil), payload...), attrs: attrs, due: n.due(time.Now())}
		n.mu.Lock()
		defer n.mu.Unlock()
		if n.queues[info.SSRC] != queue {
			return 0, errNetemClosed
		}
		select {
		case queue <- p:
		default:
			// Queue overflow behaves like a congested link: drop.
			n.stats.Dropped.Add(1)
		}
		return len(payload), nil
	})
}

func (n *netemInterceptor) UnbindLocalStream(info *interceptor.StreamInfo) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if queue, ok := n.queues[info.SSRC]; ok {
		close(queue)
		delete(n.queues, info.SSRC)
	}
}

func (n *netemInterceptor) Close() error {
	n.mu.Lock()
	defer n.mu.Unlock()
	for ssrc, queue := range n.queues {
		close(queue)
		delete(n.queues, ssrc)
	}
	return nil
}

func (n *netemInterceptor) shouldDrop(seq uint16) bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.started && int16(seq-n.highest) <= 0 {
		// At or behind the newest packet (modulo wrap): a retransmission
		// (NACK response). Only random loss applies.
		return n.cfg.LossRate > 0 && n.rng.Float64() < n.cfg.LossRate
	}
	n.started, n.highest = true, seq
	idx := n.index
	n.index++
	if n.drops[idx] {
		return true
	}
	return n.cfg.LossRate > 0 && n.rng.Float64() < n.cfg.LossRate
}

var errNetemClosed = errors.New("netem stream closed")

func maxTime(a, b time.Time) time.Time {
	if a.After(b) {
		return a
	}
	return b
}

type delayedPacket struct {
	header  rtp.Header
	payload []byte
	attrs   interceptor.Attributes
	due     time.Time
}
