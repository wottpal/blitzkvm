package video

import (
	"cmp"
	"slices"
	"sync"
	"time"

	"github.com/pion/rtp"
)

// LinkEstimator measures the path from the device from the video's own
// packets, with no probing.
//
// The device stamps each frame with its capture time (RTP, 90 kHz, no
// drift) and sends the frame's packets back to back. A frame's first packet
// therefore arrives its one-way delay after the timestamp, up to a constant
// offset. The lowest delay of the last baselineWindow is the path with empty
// queues; what a frame's first packet takes beyond it is the time it waited
// behind earlier traffic, in the device's send path or the network.
//
// A frame's packets reach the receiver no faster than the slowest hop
// forwards them, so a frame's bytes over the spread of its arrivals is the
// rate the path delivers (packet-train dispersion): the bottleneck's rate,
// or the device's send path where that is slower.
//
// Retransmissions (a sequence number at or behind the newest) are left out
// of both: their timing is the repair's, not the link's. Their share of
// what arrives tells a queue of repairs from one of new frames.
type LinkEstimator struct {
	mu      sync.Mutex
	started bool
	newest  uint16 // highest sequence number seen
	rawTS   uint32 // newest frame's RTP timestamp, to unwrap the next
	ts      int64  // its unwrapped timestamp
	origin  time.Time
	cur     frameArrival
	prev    time.Duration // the previous frame's delay
	// base holds the frames of the last baselineWindow whose delay no later
	// frame undercut, ascending: base[0] is the window's lowest.
	base   []delaySample
	recent []delaySample // frames of the last QueueWindow
	rates  []rateSample
	// arrivals are the packets of the last QueueWindow.
	arrivals []packetArrival
}

const (
	// baselineWindow is how far back the lowest delay counts as the empty
	// path: long enough to always hold a moment without a queue (the quality
	// controller drains one within seconds), short enough to follow a route
	// change. A queue that never drains for that long becomes the baseline.
	baselineWindow = 10 * time.Second
	// QueueWindow is the span of arrivals LinkEstimate.Queue looks at: a
	// frame or two at 15 fps, six at 60. The least delay of several frames
	// filters the link's jitter.
	QueueWindow = 100 * time.Millisecond
	// rateWindow is how far back frame dispersions count for the delivery
	// rate; rateMinPackets the fewest packets a frame needs to count (fewer
	// are too short to time against jitter and Wi-Fi aggregation). Over
	// Tailscale, frames of 4-7 packets measured the same rate as larger ones
	// (3.8 against 3.7-3.9 Mbit/s), and at the lowest levels, which send
	// few larger frames, they are most of the evidence.
	rateWindow     = 10 * time.Second
	rateMinPackets = 4
	// rateWarmup leaves the stream's first frames out of the rate, the
	// session's first keyframe among them: the device sends it while it sets
	// up the session (it spread at 1.4 Mbit/s over a path that then measured
	// 3.8), and as the largest frame it would outweigh the rest. A longer
	// warm-up keeps a new session at its first guess longer: over the
	// emulated DERP relay, 1.5 s left balanced overrunning the relay's queue.
	rateWarmup = 500 * time.Millisecond
	// maxDelayStep is the largest change in delay between two frames that
	// is believed: a larger one (an encoder restart that moved the RTP
	// clock) starts the baseline over. A real queue that grew this much at
	// once drains below the new baseline, which then follows it down.
	maxDelayStep = 2 * time.Second
)

type frameArrival struct {
	open              bool
	first, last       time.Time
	firstBytes, bytes int
	packets           int
}

type delaySample struct {
	at    time.Time
	delay time.Duration
}

type rateSample struct {
	at    time.Time
	bytes int
	bps   float64
}

type packetArrival struct {
	at     time.Time
	bytes  int
	repair bool
}

// LinkEstimate is what the video's arrivals tell about the link.
type LinkEstimate struct {
	// Queue is the least queueing delay of the QueueFrames frames whose
	// first packet arrived within the last QueueWindow: how long every one
	// of them waited behind earlier traffic. QueueGrowth is how much longer
	// the newest of them waited than the oldest: negative while a queue
	// drains, as behind a keyframe, whose frames arrive bunched up and each
	// less late than the one before; zero for a single frame.
	Queue, QueueGrowth time.Duration
	QueueFrames        int
	// Rate is the rate the path delivered frames at (bits per second): the
	// median of the frame dispersions of the last rateWindow, weighted by
	// the frames' bytes, so a keyframe outweighs small frames. RateBytes is
	// the bytes those frames carried and RateFrames their number (the weight
	// of the evidence); all are zero without frames of rateMinPackets or
	// more.
	Rate       float64
	RateBytes  int
	RateFrames int
	// Delivered is the rate packets arrived at over the last QueueWindow
	// (bits per second), retransmissions included. While a queue stands,
	// the link is busy all along and this is its rate now, which Rate,
	// a median over seconds, follows only slowly. RepairShare is the share
	// of those bytes that were retransmissions.
	Delivered, RepairShare float64
}

// NewLinkEstimator returns an estimator with no history.
func NewLinkEstimator() *LinkEstimator { return &LinkEstimator{} }

// Push takes a video packet and its arrival time.
func (e *LinkEstimator) Push(pkt *rtp.Packet, at time.Time) {
	e.mu.Lock()
	defer e.mu.Unlock()
	size := pkt.MarshalSize()
	repair := e.started && int16(pkt.SequenceNumber-e.newest) <= 0
	e.arrivals = append(dropBefore(e.arrivals, at.Add(-QueueWindow)), packetArrival{at, size, repair})
	if repair {
		return
	}
	if !e.started || pkt.Timestamp != e.rawTS {
		e.finishLocked()
		if e.started {
			e.ts += int64(int32(pkt.Timestamp - e.rawTS))
		} else {
			e.origin = at
		}
		e.started, e.rawTS = true, pkt.Timestamp
		e.cur = frameArrival{open: true, first: at, last: at, firstBytes: size, bytes: size, packets: 1}
		// One RTP tick is 100000/9 ns.
		e.addDelayLocked(at, at.Sub(e.origin)-time.Duration(e.ts*100000/9))
	} else if e.cur.open {
		e.cur.last = at
		e.cur.bytes += size
		e.cur.packets++
	}
	e.newest = pkt.SequenceNumber
	if pkt.Marker {
		e.finishLocked()
	}
}

func (e *LinkEstimator) addDelayLocked(at time.Time, delay time.Duration) {
	if len(e.base) > 0 && (delay-e.prev > maxDelayStep || e.prev-delay > maxDelayStep) {
		e.base, e.recent = e.base[:0], e.recent[:0]
	}
	e.prev = delay
	for len(e.base) > 0 && e.base[len(e.base)-1].delay >= delay {
		e.base = e.base[:len(e.base)-1]
	}
	e.base = append(e.base, delaySample{at, delay})
	e.base = dropBefore(e.base, at.Add(-baselineWindow))
	e.recent = append(dropBefore(e.recent, at.Add(-QueueWindow)), delaySample{at, delay})
}

// finishLocked ends the frame being received and keeps its dispersion.
func (e *LinkEstimator) finishLocked() {
	f := e.cur
	e.cur.open = false
	if !f.open || f.packets < rateMinPackets || !f.last.After(f.first) || f.first.Sub(e.origin) < rateWarmup {
		return
	}
	bps := float64(f.bytes-f.firstBytes) * 8 / f.last.Sub(f.first).Seconds()
	e.rates = append(dropBefore(e.rates, f.last.Add(-rateWindow)), rateSample{f.last, f.bytes, bps})
}

// Estimate returns the estimate as of now.
func (e *LinkEstimator) Estimate(now time.Time) LinkEstimate {
	e.mu.Lock()
	defer e.mu.Unlock()
	var est LinkEstimate
	if arrivals := dropBefore(e.arrivals, now.Add(-QueueWindow)); len(arrivals) > 0 {
		total, repaired := 0, 0
		for _, a := range arrivals {
			total += a.bytes
			if a.repair {
				repaired += a.bytes
			}
		}
		est.Delivered = float64(total) * 8 / QueueWindow.Seconds()
		est.RepairShare = float64(repaired) / float64(total)
	}
	if recent := dropBefore(e.recent, now.Add(-QueueWindow)); len(recent) > 0 {
		least := slices.MinFunc(recent, func(a, b delaySample) int { return cmp.Compare(a.delay, b.delay) })
		est.Queue = least.delay - e.base[0].delay
		est.QueueGrowth = recent[len(recent)-1].delay - recent[0].delay
		est.QueueFrames = len(recent)
	}
	rates := dropBefore(slices.Clone(e.rates), now.Add(-rateWindow))
	est.RateFrames = len(rates)
	for _, r := range rates {
		est.RateBytes += r.bytes
	}
	slices.SortFunc(rates, func(a, b rateSample) int { return cmp.Compare(a.bps, b.bps) })
	for half := 0; len(rates) > 0; rates = rates[1:] {
		if half += rates[0].bytes; 2*half >= est.RateBytes {
			est.Rate = rates[0].bps
			break
		}
	}
	return est
}

type timed interface{ time() time.Time }

func (s delaySample) time() time.Time   { return s.at }
func (s rateSample) time() time.Time    { return s.at }
func (s packetArrival) time() time.Time { return s.at }

// dropBefore drops the samples older than cutoff from the front of a list
// in time order.
func dropBefore[E timed](s []E, cutoff time.Time) []E {
	i := 0
	for i < len(s) && s[i].time().Before(cutoff) {
		i++
	}
	return s[i:]
}
