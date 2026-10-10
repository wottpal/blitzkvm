package video

import (
	"sync"
	"testing"
	"time"

	"github.com/pion/rtp"
)

// frame builds the RTP packets of one H.264 access unit: a single-NAL packet
// (IDR or non-IDR slice) or an FU-A fragmented NAL split into n packets.
func frame(seq uint16, ts uint32, idr bool, n int) []*rtp.Packet {
	nalType := byte(1)
	if idr {
		nalType = 5
	}
	if n == 1 {
		return []*rtp.Packet{{Header: rtp.Header{SequenceNumber: seq, Timestamp: ts, Marker: true}, Payload: []byte{0x60 | nalType, 0xaa, 0xbb}}}
	}
	pkts := make([]*rtp.Packet, 0, n)
	for i := 0; i < n; i++ {
		fuHeader := nalType
		if i == 0 {
			fuHeader |= 0x80 // start
		}
		if i == n-1 {
			fuHeader |= 0x40 // end
		}
		pkts = append(pkts, &rtp.Packet{
			Header:  rtp.Header{SequenceNumber: seq + uint16(i), Timestamp: ts, Marker: i == n-1},
			Payload: []byte{0x60 | 28, fuHeader, byte(i), 0xcc},
		})
	}
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

func TestAssemblerDropsAndWaitsForKeyframeAfterDeadline(t *testing.T) {
	var out sink
	a := NewAssembler(CodecH264, out.deliver, out.request)
	now := time.Unix(0, 0)
	for _, p := range frame(10, 1000, true, 1) {
		a.Push(p, now)
	}
	broken := frame(11, 2000, false, 3)
	a.Push(broken[0], now)
	a.Push(broken[2], now)
	// The next P-frame arrives complete but depends on the broken one.
	for _, p := range frame(14, 3000, false, 1) {
		a.Push(p, now)
	}
	a.Tick(now.Add(maxGapDeadline + time.Millisecond))
	if out.count() != 1 {
		t.Fatalf("emitted frames that depend on a lost frame: %d", out.count())
	}
	st := a.Stats()
	if st.KeyframeWaits != 1 || st.DroppedFrames < 1 {
		t.Fatalf("expected a keyframe wait, got %+v", st)
	}
	for _, p := range frame(15, 4000, true, 2) {
		a.Push(p, now.Add(300*time.Millisecond))
	}
	if out.count() != 2 || !out.units[1].Keyframe {
		t.Fatalf("did not recover at the next keyframe: %d units", out.count())
	}
	time.Sleep(10 * time.Millisecond) // keyframe request runs on its own goroutine
	out.mu.Lock()
	requested := out.keyframes
	out.mu.Unlock()
	if requested == 0 {
		t.Fatal("no keyframe was requested after the loss")
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
