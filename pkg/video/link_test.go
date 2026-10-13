package video

import (
	"math"
	"testing"
	"time"

	"github.com/pion/rtp"
)

// path is a synthetic timeline: the device sends each frame's packets
// sendGap apart (its send path), they queue for a bottleneck of bps, and
// arrive delay later. Packets are 1200 bytes on the wire.
type path struct {
	t       *testing.T
	est     *LinkEstimator
	bps     float64
	delay   time.Duration
	sendGap time.Duration
	start   time.Time
	free    time.Time // when the bottleneck has sent everything so far
	seq     uint16
	rtp     uint32 // RTP timestamp of capture time 0
	arrived time.Time
}

func newPath(t *testing.T, bps float64) *path {
	start := time.Unix(1000, 0)
	return &path{t: t, est: NewLinkEstimator(), bps: bps, delay: 20 * time.Millisecond, start: start, free: start}
}

// send sends a frame of n packets captured at capture (from the start) and
// returns the arrival of its first packet.
func (p *path) send(capture time.Duration, n int) time.Time {
	var first time.Time
	for i := range n {
		sent := p.start.Add(capture + time.Duration(i)*p.sendGap)
		if sent.After(p.free) {
			p.free = sent
		}
		p.free = p.free.Add(time.Duration(1200 * 8 / p.bps * float64(time.Second)))
		pkt := &rtp.Packet{
			Header:  rtp.Header{SequenceNumber: p.seq, Timestamp: p.rtp + uint32(capture*9/100000), Marker: i == n-1},
			Payload: make([]byte, 1188),
		}
		p.seq++
		p.arrived = p.free.Add(p.delay)
		p.est.Push(pkt, p.arrived)
		if i == 0 {
			first = p.arrived
		}
	}
	return first
}

// frames sends a frame of n packets every interval from capture from to to.
func (p *path) frames(from, to, interval time.Duration, n int) {
	for c := from; c < to; c += interval {
		p.send(c, n)
	}
}

func (p *path) estimate() LinkEstimate { return p.est.Estimate(p.arrived) }

const frame60 = time.Second / 60

func TestLinkEstimatorIdleLinkHasNoQueueAndNoRate(t *testing.T) {
	p := newPath(t, 4e6)
	p.frames(0, 2*time.Second, frame60, 1)
	if est := p.estimate(); est.Queue > time.Millisecond || est.QueueFrames < 6 || est.Rate != 0 {
		t.Fatalf("idle link: %+v", est)
	}
}

func TestLinkEstimatorDeliveryRateIsTheSlowestHop(t *testing.T) {
	for _, c := range []struct {
		name    string
		bps     float64
		sendGap time.Duration
		want    float64
	}{
		{"cellular", 4e6, 450 * time.Microsecond, 4e6},
		// A LAN is faster than the device's send path (0.45 ms a packet).
		{"lan", 1e9, 450 * time.Microsecond, 1200 * 8 / 450e-6},
	} {
		p := newPath(t, c.bps)
		p.sendGap = c.sendGap
		p.send(0, 200) // a 240 kB keyframe
		p.frames(time.Second, 2*time.Second, frame60, 1)
		if est := p.estimate(); math.Abs(est.Rate-c.want) > 0.01*c.want || est.RateBytes != 240_000 {
			t.Errorf("%s: rate %.2f Mbit/s from %d bytes, want %.2f", c.name, est.Rate/1e6, est.RateBytes, c.want/1e6)
		}
	}
}

func TestLinkEstimatorRateIgnoresBurstsDeliveredAtOnce(t *testing.T) {
	// A keyframe at 4 Mbit/s, then small frames whose packets arrive
	// together (Wi-Fi aggregation): the byte-weighted median keeps the
	// keyframe's rate.
	p := newPath(t, 4e6)
	p.send(0, 150)
	p.bps = 1e10
	p.frames(time.Second, 2*time.Second, 100*time.Millisecond, 8)
	if est := p.estimate(); math.Abs(est.Rate-4e6) > 0.01*4e6 {
		t.Fatalf("rate %.2f Mbit/s, want 4", est.Rate/1e6)
	}
}

func TestLinkEstimatorTellsADrainingBurstFromAGrowingQueue(t *testing.T) {
	// A 240 kB keyframe on 4 Mbit/s takes 480 ms; the frames behind it wait
	// less and less.
	p := newPath(t, 4e6)
	p.frames(0, time.Second, frame60, 1)
	p.send(time.Second, 200)
	p.frames(time.Second+frame60, time.Second+300*time.Millisecond, frame60, 1)
	burst := p.estimate()
	if burst.Queue < 100*time.Millisecond || burst.QueueGrowth >= 0 || burst.QueueFrames < 2 {
		t.Errorf("draining keyframe: %+v, want a queue that shrinks", burst)
	}

	// 8 Mbit/s of scrolling into the same link: the queue grows.
	p = newPath(t, 4e6)
	p.frames(0, time.Second, frame60, 1)
	p.frames(time.Second, time.Second+300*time.Millisecond, frame60, 14)
	growing := p.estimate()
	if growing.Queue < 100*time.Millisecond || growing.QueueGrowth <= 0 || growing.QueueFrames < 2 {
		t.Errorf("overload: %+v, want a queue that grows", growing)
	}
	if math.Abs(growing.Rate-4e6) > 0.02*4e6 || math.Abs(growing.Delivered-4e6) > 0.05*4e6 {
		t.Errorf("overload: rate %.2f and delivered %.2f Mbit/s, want the link's 4", growing.Rate/1e6, growing.Delivered/1e6)
	}
}

func TestLinkEstimatorIgnoresRetransmissions(t *testing.T) {
	p := newPath(t, 4e6)
	p.send(0, 150)
	p.frames(time.Second, 2*time.Second, frame60, 1)
	now := p.arrived.Add(time.Millisecond)
	before := p.est.Estimate(now)
	// NACK repairs of old packets arrive late: they count only as repairs.
	for _, seq := range []uint16{p.seq - 30, 50} {
		p.est.Push(&rtp.Packet{Header: rtp.Header{SequenceNumber: seq, Timestamp: p.rtp + 9000}, Payload: make([]byte, 1188)}, now)
	}
	after := p.est.Estimate(now)
	if share := after.RepairShare; math.Abs(share-2.0/8) > 0.01 {
		t.Errorf("repair share %.2f, want 2 of 8 packets", share)
	}
	after.RepairShare, after.Delivered = before.RepairShare, before.Delivered
	if after != before {
		t.Fatalf("a retransmission changed the estimate: %+v, was %+v", after, before)
	}
}

func TestLinkEstimatorBaselineFollowsThePath(t *testing.T) {
	// The path gets 50 ms longer for good (a new route): a queue at first,
	// part of the baseline once the faster frames are baselineWindow old.
	p := newPath(t, 4e6)
	p.frames(0, time.Second, frame60, 1)
	p.delay += 50 * time.Millisecond
	p.frames(time.Second, 2*time.Second, frame60, 1)
	if est := p.estimate(); math.Abs(float64(est.Queue-50*time.Millisecond)) > float64(time.Millisecond) {
		t.Errorf("longer path: queue %v, want 50 ms", est.Queue)
	}
	p.frames(2*time.Second, 12*time.Second, frame60, 1)
	if est := p.estimate(); est.Queue > time.Millisecond {
		t.Errorf("after the baseline window: queue %v, want none", est.Queue)
	}
	// The RTP clock jumps (the encoder restarted): the baseline starts over
	// instead of reading a queue of seconds.
	p.rtp -= 5 * 90000
	p.frames(12*time.Second, 13*time.Second, frame60, 1)
	if est := p.estimate(); est.Queue > time.Millisecond {
		t.Errorf("after an RTP clock jump: queue %v, want none", est.Queue)
	}
}

func TestLinkEstimatorUnwrapsTheRTPClock(t *testing.T) {
	p := newPath(t, 4e6)
	p.rtp = math.MaxUint32 - 90000/2 // wraps after half a second
	p.frames(0, 2*time.Second, frame60, 1)
	if est := p.estimate(); est.Queue > time.Millisecond {
		t.Fatalf("queue %v across the wrap, want none", est.Queue)
	}
}
