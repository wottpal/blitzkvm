package video

import (
	"sync"
	"testing"
	"time"

	"github.com/pion/rtp"
)

// frame builds the RTP packets of one H.264 access unit. Keyframes start
// with a STAP-A carrying SPS and PPS, as real encoders send them. A frame of
// n packets uses FU-A fragmentation for its slice.
func frame(seq uint16, ts uint32, idr bool, n int) []*rtp.Packet {
	var pkts []*rtp.Packet
	add := func(payload []byte) {
		pkts = append(pkts, &rtp.Packet{Header: rtp.Header{SequenceNumber: seq + uint16(len(pkts)), Timestamp: ts}, Payload: payload})
	}
	nalType := byte(1)
	if idr {
		nalType = 5
		sps, pps := []byte{0x67, 0x64, 0x00, 0x1f}, []byte{0x68, 0xee, 0x3c}
		stap := []byte{24, 0, byte(len(sps))}
		stap = append(stap, sps...)
		stap = append(stap, 0, byte(len(pps)))
		stap = append(stap, pps...)
		if n == 1 {
			stap = append(stap, 0, 3, 0x60|nalType, 0xaa, 0xbb)
			add(stap)
			pkts[0].Marker = true
			return pkts
		}
		add(stap)
		n--
	}
	if n == 1 {
		add([]byte{0x60 | nalType, 0xaa, 0xbb})
	} else {
		for i := 0; i < n; i++ {
			fuHeader := nalType
			if i == 0 {
				fuHeader |= 0x80 // start
			}
			if i == n-1 {
				fuHeader |= 0x40 // end
			}
			add([]byte{0x60 | 28, fuHeader, byte(i), 0xcc})
		}
	}
	pkts[len(pkts)-1].Marker = true
	return pkts
}

type sink struct {
	mu        sync.Mutex
	units     []AccessUnit
	keyframes int
}

func (s *sink) deliver(au AccessUnit) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.units = append(s.units, au)
}

func (s *sink) request() {
	s.mu.Lock()
	s.keyframes++
	s.mu.Unlock()
}

func (s *sink) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.units)
}

func TestAssemblerEmitsOnMarkerWithoutWaitingForNextFrame(t *testing.T) {
	var out sink
	a := NewAssembler(CodecH264, out.deliver, out.request)
	now := time.Unix(0, 0)
	for _, p := range frame(100, 9000, true, 3) {
		a.Push(p, now)
	}
	if out.count() != 1 {
		t.Fatalf("keyframe not emitted on its marker packet: got %d units", out.count())
	}
	if !out.units[0].Keyframe || out.units[0].Codec != CodecH264 {
		t.Fatalf("unexpected unit: %+v", out.units[0])
	}
	for _, p := range frame(103, 12000, false, 1) {
		a.Push(p, now)
	}
	if out.count() != 2 {
		t.Fatalf("P-frame not emitted immediately: got %d units", out.count())
	}
}

func TestAssemblerDiscardsUntilFirstKeyframe(t *testing.T) {
	var out sink
	a := NewAssembler(CodecH264, out.deliver, out.request)
	now := time.Unix(0, 0)
	for _, p := range frame(1, 3000, false, 1) {
		a.Push(p, now)
	}
	if out.count() != 0 {
		t.Fatal("emitted a P-frame before any keyframe")
	}
	for _, p := range frame(2, 6000, true, 2) {
		a.Push(p, now)
	}
	if out.count() != 1 {
		t.Fatalf("keyframe not emitted: %d", out.count())
	}
}

func TestAssemblerWaitsForRetransmission(t *testing.T) {
	var out sink
	a := NewAssembler(CodecH264, out.deliver, out.request)
	now := time.Unix(0, 0)
	for _, p := range frame(10, 1000, true, 1) {
		a.Push(p, now)
	}
	pkts := frame(11, 2000, false, 3)
	a.Push(pkts[0], now)
	a.Push(pkts[2], now) // pkts[1] lost for now
	a.Tick(now.Add(20 * time.Millisecond))
	if out.count() != 1 {
		t.Fatalf("emitted an incomplete frame: %d", out.count())
	}
	a.Push(pkts[1], now.Add(25*time.Millisecond)) // NACK retransmission
	if out.count() != 2 {
		t.Fatalf("frame not completed by retransmission: %d", out.count())
	}
	if st := a.Stats(); st.DroppedFrames != 0 || st.KeyframeWaits != 0 {
		t.Fatalf("unexpected drops after recovered loss: %+v", st)
	}
}

func (s *sink) requests() int {
	time.Sleep(10 * time.Millisecond) // keyframe requests run on their own goroutine
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.keyframes
}

// brokenStream delivers a keyframe, then a P-frame missing its middle packet
// (seq 12) and a P-frame that depends on it, all at now.
func brokenStream(a *Assembler, now time.Time) (missing *rtp.Packet) {
	for _, p := range frame(10, 1000, true, 1) {
		a.Push(p, now)
	}
	broken := frame(11, 2000, false, 3)
	a.Push(broken[0], now)
	a.Push(broken[2], now)
	for _, p := range frame(14, 3000, false, 1) {
		a.Push(p, now)
	}
	return broken[1]
}

func TestAssemblerAsksForKeyframeAfterDeadlineAndResumesAtIt(t *testing.T) {
	var out sink
	a := NewAssembler(CodecH264, out.deliver, out.request)
	now := time.Unix(0, 0)
	brokenStream(a, now)
	a.Tick(now.Add(a.gapDeadline() - time.Millisecond))
	if st := a.Stats(); st.KeyframeWaits != 0 || out.requests() != 0 {
		t.Fatalf("asked for a keyframe before the deadline: %+v", st)
	}
	a.Tick(now.Add(a.gapDeadline()))
	if out.count() != 1 {
		t.Fatalf("emitted frames that depend on a lost frame: %d", out.count())
	}
	if st := a.Stats(); st.KeyframeWaits != 1 || out.requests() != 1 {
		t.Fatalf("expected a keyframe wait and request, got %+v", st)
	}
	for _, p := range frame(15, 4000, true, 2) {
		a.Push(p, now.Add(500*time.Millisecond))
	}
	if out.count() != 2 || !out.units[1].Keyframe {
		t.Fatalf("did not resume at the keyframe: %d units", out.count())
	}
	if st := a.Stats(); st.DroppedFrames != 2 || st.LateRepairs != 0 {
		t.Fatalf("want the two frames before the keyframe dropped: %+v", st)
	}
	for _, p := range frame(17, 5000, false, 1) {
		a.Push(p, now.Add(510*time.Millisecond))
	}
	if out.count() != 3 {
		t.Fatalf("frame after the keyframe not emitted: %d", out.count())
	}
}

func TestAssemblerLateRepairCancelsKeyframeWait(t *testing.T) {
	var out sink
	a := NewAssembler(CodecH264, out.deliver, out.request)
	now := time.Unix(0, 0)
	missing := brokenStream(a, now)
	a.Tick(now.Add(time.Second))
	if st := a.Stats(); st.KeyframeWaits != 1 {
		t.Fatalf("no keyframe wait after the deadline: %+v", st)
	}
	a.Push(missing, now.Add(time.Second+time.Millisecond)) // the repair, late
	if out.count() != 3 {
		t.Fatalf("held frames not emitted after the late repair: %d", out.count())
	}
	for _, p := range frame(15, 4000, false, 1) {
		a.Push(p, now.Add(time.Second+2*time.Millisecond))
	}
	if out.count() != 4 {
		t.Fatalf("still waiting for a keyframe after the repair: %d", out.count())
	}
	if st := a.Stats(); st.LateRepairs != 1 || st.DroppedFrames != 0 {
		t.Fatalf("stats %+v", st)
	}
}

func TestAssemblerDeadlineRunsFromLastRepair(t *testing.T) {
	var out sink
	a := NewAssembler(CodecH264, out.deliver, out.request)
	now := time.Unix(0, 0)
	for _, p := range frame(10, 1000, true, 1) {
		a.Push(p, now)
	}
	// A keyframe-sized loss: 20 packets, repaired one by one.
	big := frame(11, 2000, false, 22)
	a.Push(big[0], now)
	a.Push(big[21], now)
	step := a.gapDeadline() / 2
	for i := 1; i < 21; i++ {
		at := now.Add(time.Duration(i) * step)
		a.Tick(at)
		a.Push(big[i], at)
	}
	if st := a.Stats(); st.KeyframeWaits != 0 || out.count() != 2 {
		t.Fatalf("a repair under way timed out: %+v, %d units", st, out.count())
	}
}

func TestAssemblerTakesKeyframeBehindGapAtOnce(t *testing.T) {
	var out sink
	a := NewAssembler(CodecH264, out.deliver, out.request)
	now := time.Unix(0, 0)
	brokenStream(a, now)
	// A keyframe (another client asked for one) arrives within the deadline.
	for _, p := range frame(15, 4000, true, 3) {
		a.Push(p, now.Add(10*time.Millisecond))
	}
	if out.count() != 2 || !out.units[1].Keyframe {
		t.Fatalf("keyframe behind the gap not emitted: %d units", out.count())
	}
	if st := a.Stats(); st.KeyframeWaits != 0 || st.DroppedFrames != 2 || out.requests() != 0 {
		t.Fatalf("stats %+v, %d requests", st, out.requests())
	}
}

func TestAssemblerGapDeadlineScalesWithRTT(t *testing.T) {
	a := NewAssembler(CodecH264, func(AccessUnit) {}, nil)
	for _, tc := range []struct{ rtt, want time.Duration }{
		{time.Millisecond, 102250 * time.Microsecond}, // as before on a LAN
		{100 * time.Millisecond, 325 * time.Millisecond},
		{200 * time.Millisecond, 550 * time.Millisecond},
		{time.Second, maxGapDeadline},
	} {
		a.SetRTT(tc.rtt)
		if got := a.gapDeadline(); got != tc.want {
			t.Errorf("RTT %s: deadline %s, want %s", tc.rtt, got, tc.want)
		}
	}
}

func TestCarriesKeyframe(t *testing.T) {
	for _, tc := range []struct {
		codec   Codec
		payload []byte
		want    bool
	}{
		{CodecH264, []byte{0x65, 0x88, 0x80}, true},                                // IDR slice
		{CodecH264, []byte{0x7c, 0x85, 0x01}, true},                                // FU-A of an IDR
		{CodecH264, []byte{0x7c, 0x81, 0x01}, false},                               // FU-A of a P slice
		{CodecH264, []byte{0x78, 0, 2, 0x67, 0x42, 0, 2, 0x65, 0x88}, true},        // STAP-A: SPS, IDR
		{CodecH264, []byte{0x78, 0, 2, 0x67, 0x42, 0, 2, 0x68, 0xce}, false},       // STAP-A: SPS, PPS
		{CodecH265, []byte{0x62, 0x01, 0x93, 0xaf}, true},                          // FU of IDR_W_RADL
		{CodecH265, []byte{0x62, 0x01, 0x81, 0xaf}, false},                         // FU of TRAIL_R
		{CodecH265, []byte{0x60, 0x01, 0, 2, 0x40, 0x01, 0, 2, 0x28, 0x01}, true},  // AP: VPS, IDR_N_LP
		{CodecH265, []byte{0x60, 0x01, 0, 2, 0x40, 0x01, 0, 2, 0x02, 0x01}, false}, // AP: VPS, TRAIL_R
	} {
		if got := carriesKeyframe(tc.codec, tc.payload); got != tc.want {
			t.Errorf("%s % x: got %v", tc.codec, tc.payload, got)
		}
	}
}

func TestAssemblerHandlesSequenceWraparound(t *testing.T) {
	var out sink
	a := NewAssembler(CodecH264, out.deliver, out.request)
	now := time.Unix(0, 0)
	for _, p := range frame(65534, 1000, true, 3) { // 65534, 65535, 0
		a.Push(p, now)
	}
	for _, p := range frame(1, 2000, false, 1) {
		a.Push(p, now)
	}
	if out.count() != 2 {
		t.Fatalf("lost frames across sequence wraparound: %d", out.count())
	}
}

func TestAssemblerIgnoresDuplicates(t *testing.T) {
	var out sink
	a := NewAssembler(CodecH264, out.deliver, out.request)
	now := time.Unix(0, 0)
	pkts := frame(10, 1000, true, 2)
	a.Push(pkts[0], now)
	a.Push(pkts[0], now)
	a.Push(pkts[1], now)
	a.Push(pkts[1], now) // late duplicate of an emitted packet
	if out.count() != 1 {
		t.Fatalf("duplicates produced extra frames: %d", out.count())
	}
}

func TestIsKeyframe(t *testing.T) {
	h264IDR := []byte{0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x65, 2}
	h264P := []byte{0, 0, 0, 1, 0x41, 2}
	if !IsKeyframe(CodecH264, h264IDR) || IsKeyframe(CodecH264, h264P) {
		t.Fatal("H.264 keyframe detection wrong")
	}
	h265IDR := []byte{0, 0, 0, 1, 0x40, 1, 0, 0, 1, 0x26, 1, 0xaf} // VPS, IDR_W_RADL (19)
	h265P := []byte{0, 0, 1, 0x02, 1, 0xd0}                        // TRAIL_R (1)
	if !IsKeyframe(CodecH265, h265IDR) || IsKeyframe(CodecH265, h265P) {
		t.Fatal("H.265 keyframe detection wrong")
	}
}

func TestAssemblerNeedsParameterSetsBeforeFirstKeyframe(t *testing.T) {
	var out sink
	a := NewAssembler(CodecH264, out.deliver, out.request)
	now := time.Unix(0, 0)
	// A lone IDR slice (its SPS/PPS were sent before we joined).
	a.Push(&rtp.Packet{Header: rtp.Header{SequenceNumber: 1, Timestamp: 1000, Marker: true}, Payload: []byte{0x65, 0x88}}, now)
	if out.count() != 0 {
		t.Fatal("emitted an IDR without parameter sets as the first keyframe")
	}
	for _, p := range frame(2, 2000, true, 2) {
		a.Push(p, now)
	}
	if out.count() != 1 || !HasParameterSets(CodecH264, out.units[0].Data) {
		t.Fatalf("complete keyframe not emitted: %d", out.count())
	}
	// Once parameter sets were seen, a later lone IDR is fine.
	a.Push(&rtp.Packet{Header: rtp.Header{SequenceNumber: 4, Timestamp: 3000, Marker: true}, Payload: []byte{0x65, 0x99}}, now)
	if out.count() != 2 {
		t.Fatalf("later IDR rejected: %d", out.count())
	}
}

func TestAssemblerDeliversInOrderUnderConcurrentTick(t *testing.T) {
	var mu sync.Mutex
	var order []uint32
	a := NewAssembler(CodecH264, func(au AccessUnit) {
		time.Sleep(time.Millisecond) // a slow consumer widens any race window
		mu.Lock()
		order = append(order, au.RTPTimestamp)
		mu.Unlock()
	}, nil)
	stop := make(chan struct{})
	go func() {
		for {
			select {
			case <-stop:
				return
			default:
				a.Tick(time.Now())
			}
		}
	}()
	seq := uint16(0)
	for i := 0; i < 200; i++ {
		pkts := frame(seq, uint32(i*3000), i%30 == 0, 2)
		for _, p := range pkts {
			a.Push(p, time.Now())
		}
		seq += uint16(len(pkts))
	}
	close(stop)
	mu.Lock()
	defer mu.Unlock()
	for i := 1; i < len(order); i++ {
		if order[i] <= order[i-1] {
			t.Fatalf("out of order at %d: %v", i, order[max(0, i-3):i+1])
		}
	}
	if len(order) != 200 {
		t.Fatalf("delivered %d of 200 frames", len(order))
	}
}
