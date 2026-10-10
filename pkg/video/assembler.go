package video

import (
	"sort"
	"sync"
	"time"

	"github.com/pion/rtp"
	"github.com/pion/rtp/codecs"
)

// Codec identifies the video codec of an access unit.
type Codec uint8

const (
	CodecH264 Codec = iota + 1
	CodecH265
)

func (c Codec) String() string {
	switch c {
	case CodecH264:
		return "h264"
	case CodecH265:
		return "h265"
	default:
		return "unknown"
	}
}

// AccessUnit is one complete coded picture in Annex-B format.
type AccessUnit struct {
	Codec        Codec
	Data         []byte
	Keyframe     bool
	RTPTimestamp uint32
	// FirstPacketAt / CompletedAt bracket the arrival of the unit's packets.
	FirstPacketAt time.Time
	CompletedAt   time.Time
}

// AssemblerStats counts assembler decisions since creation.
type AssemblerStats struct {
	Frames          uint64
	DroppedFrames   uint64
	KeyframeWaits   uint64
	KeyframeRequest uint64
	Retransmitted   uint64
}

const (
	// maxPendingPackets bounds memory if a stream stalls mid-frame.
	maxPendingPackets = 4096
	minGapDeadline    = 60 * time.Millisecond
	maxGapDeadline    = 300 * time.Millisecond
	// assumedRTT is used until a round-trip measurement exists (ICE stats
	// arrive a moment after connecting). Erring long only costs time when a
	// packet is actually missing; erring short turns a repairable loss into
	// a freeze until the next keyframe.
	assumedRTT = 100 * time.Millisecond
	// nackInterval matches the NACK generator interval configured by the client.
	nackInterval       = 20 * time.Millisecond
	minKeyframeRequest = time.Second
)

// Assembler turns an RTP packet stream into complete access units.
//
// It emits a frame as soon as all packets from the frame's first packet up to
// the packet carrying the RTP marker bit are present and contiguous, so there
// is no added hold (pion's samplebuilder waits for the next frame's first
// packet). When a sequence gap appears it waits up to an RTT-derived deadline
// for NACK retransmissions; if the gap does not fill, the broken frame is
// dropped, the assembler resynchronises at the next frame boundary and
// discards everything until a keyframe, asking the sender for one (rate
// limited). Emitting later P-frames after a lost frame would only produce
// corrupted pictures.
type Assembler struct {
	codec           Codec
	deliver         func(AccessUnit)
	requestKeyframe func()

	mu              sync.Mutex
	pending         map[uint16]pendingPacket
	synced          bool
	nextSeq         uint16
	gapSince        time.Time
	waitingKeyframe bool
	rtt             time.Duration
	lastKeyframeReq time.Time
	stats           AssemblerStats
}

type pendingPacket struct {
	pkt *rtp.Packet
	at  time.Time
}

// NewAssembler creates an assembler. deliver is called synchronously from
// Push/Tick with each complete access unit; requestKeyframe (optional) is
// called when the assembler needs a keyframe to recover.
func NewAssembler(codec Codec, deliver func(AccessUnit), requestKeyframe func()) *Assembler {
	return &Assembler{
		codec:           codec,
		deliver:         deliver,
		requestKeyframe: requestKeyframe,
		pending:         make(map[uint16]pendingPacket),
		waitingKeyframe: true,
	}
}

// SetRTT updates the round-trip estimate used for the retransmission deadline.
func (a *Assembler) SetRTT(rtt time.Duration) {
	a.mu.Lock()
	a.rtt = rtt
	a.mu.Unlock()
}

// Stats returns a copy of the counters.
func (a *Assembler) Stats() AssemblerStats {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.stats
}

// gapDeadline is how long a sequence gap may stay open: two NACK rounds
// (the first NACK or its retransmission can be lost too) plus slack.
func (a *Assembler) gapDeadline() time.Duration {
	rtt := a.rtt
	if rtt <= 0 {
		rtt = assumedRTT
	}
	d := 2*nackInterval + 2*rtt + 20*time.Millisecond
	return min(max(d, minGapDeadline), maxGapDeadline)
}

// seqLess reports whether a precedes b in RTP sequence space.
func seqLess(a, b uint16) bool { return int16(a-b) < 0 }

// Push adds a packet. now is its arrival time.
func (a *Assembler) Push(pkt *rtp.Packet, now time.Time) {
	var out []AccessUnit
	a.mu.Lock()
	seq := pkt.SequenceNumber
	if a.synced && seqLess(seq, a.nextSeq) {
		// Late duplicate or retransmission of an already emitted/dropped packet.
		a.mu.Unlock()
		return
	}
	if _, dup := a.pending[seq]; dup {
		a.stats.Retransmitted++
		a.mu.Unlock()
		return
	}
	a.pending[seq] = pendingPacket{pkt: pkt, at: now}
	if !a.synced {
		a.trySyncLocked()
	}
	if len(a.pending) > maxPendingPackets {
		a.dropAndResyncLocked()
	}
	out = a.drainLocked(now)
	a.mu.Unlock()
	a.emit(out)
}

// Tick enforces the retransmission deadline when no packets arrive.
func (a *Assembler) Tick(now time.Time) {
	a.mu.Lock()
	out := a.drainLocked(now)
	a.mu.Unlock()
	a.emit(out)
}

func (a *Assembler) emit(units []AccessUnit) {
	for _, au := range units {
		a.deliver(au)
	}
}

// trySyncLocked picks where the first frame starts: at the earliest packet
// if it begins a NAL unit, otherwise right after the next marker packet (the
// end of the frame we joined midway). Waiting for a keyframe makes a wrong
// guess harmless.
func (a *Assembler) trySyncLocked() {
	seqs := a.sortedSeqsLocked()
	if len(seqs) == 0 {
		return
	}
	if startsNAL(a.codec, a.pending[seqs[0]].pkt.Payload) {
		a.nextSeq = seqs[0]
		a.synced = true
		a.gapSince = time.Time{}
		return
	}
	for _, s := range seqs {
		if a.pending[s].pkt.Marker {
			for _, t := range seqs {
				if !seqLess(s, t) {
					delete(a.pending, t)
				}
			}
			a.nextSeq = s + 1
			a.synced = true
			a.gapSince = time.Time{}
			return
		}
	}
}

func (a *Assembler) sortedSeqsLocked() []uint16 {
	seqs := make([]uint16, 0, len(a.pending))
	for s := range a.pending {
		seqs = append(seqs, s)
	}
	if len(seqs) == 0 {
		return seqs
	}
	// Order relative to an arbitrary pending element; valid as long as the
	// window spans less than half the sequence space.
	ref := seqs[0]
	sort.Slice(seqs, func(i, j int) bool {
		return int16(seqs[i]-ref) < int16(seqs[j]-ref)
	})
	return seqs
}

func (a *Assembler) drainLocked(now time.Time) []AccessUnit {
	var out []AccessUnit
	for a.synced {
		frame, complete, gap := a.collectFrameLocked()
		if !complete {
			if !gap {
				// Packets so far are contiguous; the frame is still arriving.
				a.gapSince = time.Time{}
				break
			}
			if a.gapSince.IsZero() {
				a.gapSince = now
			}
			if now.Sub(a.gapSince) < a.gapDeadline() {
				break
			}
			a.dropAndResyncLocked()
			continue
		}
		a.gapSince = time.Time{}
		au, err := a.depacketize(frame)
		a.nextSeq = frame[len(frame)-1].pkt.SequenceNumber + 1
		for _, p := range frame {
			delete(a.pending, p.pkt.SequenceNumber)
		}
		if err != nil || len(au.Data) == 0 {
			a.stats.DroppedFrames++
			a.enterKeyframeWaitLocked(now)
			continue
		}
		if a.waitingKeyframe {
			if !au.Keyframe {
				a.stats.DroppedFrames++
				a.maybeRequestKeyframeLocked(now)
				continue
			}
			a.waitingKeyframe = false
		}
		a.stats.Frames++
		out = append(out, au)
	}
	return out
}

// collectFrameLocked returns the packets of the frame starting at nextSeq if
// they are all present up to and including a marker packet. gap reports a
// missing packet with later packets already pending (i.e. a loss, not just a
// frame still in flight).
func (a *Assembler) collectFrameLocked() (frame []pendingPacket, complete, gap bool) {
	seq := a.nextSeq
	for range maxPendingPackets {
		p, ok := a.pending[seq]
		if !ok {
			return nil, false, len(frame) < len(a.pending)
		}
		frame = append(frame, p)
		if p.pkt.Marker {
			return frame, true, false
		}
		seq++
	}
	return nil, false, true
}

// dropAndResyncLocked gives up on the frame at nextSeq: it discards that
// frame's packets (identified by RTP timestamp) and resumes at the next
// pending packet that starts a NAL unit of a different frame. Without such a
// packet it waits for the next marker to find a boundary.
func (a *Assembler) dropAndResyncLocked() {
	a.stats.DroppedFrames++
	a.gapSince = time.Time{}
	defer a.enterKeyframeWaitLocked(time.Now())

	seqs := a.sortedSeqsLocked()
	if len(seqs) == 0 {
		a.synced = false
		return
	}
	first := a.pending[seqs[0]].pkt
	brokenTS, haveBroken := uint32(0), false
	if p, ok := a.pending[a.nextSeq]; ok {
		brokenTS, haveBroken = p.pkt.Timestamp, true
	} else if !startsNAL(a.codec, first.Payload) {
		// Earliest packet continues a fragmented NAL: it belongs to the
		// broken frame.
		brokenTS, haveBroken = first.Timestamp, true
	} else {
		// The broken frame vanished entirely; the earliest packet starts the
		// next one.
		a.nextSeq = seqs[0]
		return
	}
	for _, s := range seqs {
		p := a.pending[s].pkt
		if haveBroken && p.Timestamp == brokenTS {
			delete(a.pending, s)
			continue
		}
		if startsNAL(a.codec, p.Payload) {
			a.nextSeq = s
			return
		}
		delete(a.pending, s)
	}
	clear(a.pending)
	a.synced = false
}

// startsNAL reports whether an RTP payload begins a NAL unit (single NAL,
// aggregation packet, or the first fragment of a fragmented NAL). A frame's
// first packet always does.
func startsNAL(codec Codec, payload []byte) bool {
	switch codec {
	case CodecH265:
		if len(payload) < 3 {
			return false
		}
		t := (payload[0] >> 1) & 0x3f
		if t == 49 { // fragmentation unit
			return payload[2]&0x80 != 0
		}
		return true
	default:
		if len(payload) < 2 {
			return false
		}
		t := payload[0] & 0x1f
		if t == 28 || t == 29 { // FU-A / FU-B
			return payload[1]&0x80 != 0
		}
		return true
	}
}

func (a *Assembler) enterKeyframeWaitLocked(now time.Time) {
	if !a.waitingKeyframe {
		a.waitingKeyframe = true
		a.stats.KeyframeWaits++
	}
	a.maybeRequestKeyframeLocked(now)
}

func (a *Assembler) maybeRequestKeyframeLocked(now time.Time) {
	if a.requestKeyframe == nil || now.Sub(a.lastKeyframeReq) < minKeyframeRequest {
		return
	}
	a.lastKeyframeReq = now
	a.stats.KeyframeRequest++
	go a.requestKeyframe()
}

type depacketizer interface {
	Unmarshal(payload []byte) ([]byte, error)
}

func (a *Assembler) depacketize(frame []pendingPacket) (AccessUnit, error) {
	var d depacketizer
	switch a.codec {
	case CodecH265:
		d = &codecs.H265Depacketizer{}
	default:
		d = &codecs.H264Packet{}
	}
	au := AccessUnit{
		Codec:         a.codec,
		RTPTimestamp:  frame[0].pkt.Timestamp,
		FirstPacketAt: frame[0].at,
		CompletedAt:   frame[len(frame)-1].at,
	}
	for _, p := range frame {
		out, err := d.Unmarshal(p.pkt.Payload)
		if err != nil {
			return au, err
		}
		au.Data = append(au.Data, out...)
	}
	au.Keyframe = IsKeyframe(a.codec, au.Data)
	return au, nil
}

// IsKeyframe reports whether an Annex-B access unit contains a random access
// point: an IDR slice (H.264) or an IRAP picture (H.265).
func IsKeyframe(codec Codec, annexB []byte) bool {
	found := false
	ForEachNAL(annexB, func(nal []byte) bool {
		if len(nal) == 0 {
			return true
		}
		switch codec {
		case CodecH265:
			t := (nal[0] >> 1) & 0x3f
			if t >= 16 && t <= 21 {
				found = true
				return false
			}
		default:
			if nal[0]&0x1f == 5 {
				found = true
				return false
			}
		}
		return true
	})
	return found
}

// ForEachNAL calls fn with each NAL unit (without start code) of an Annex-B
// buffer until fn returns false.
func ForEachNAL(annexB []byte, fn func(nal []byte) bool) {
	start := -1
	i := 0
	for i+3 <= len(annexB) {
		if annexB[i] == 0 && annexB[i+1] == 0 && annexB[i+2] == 1 {
			if start >= 0 {
				end := i
				if end > start && annexB[end-1] == 0 {
					end--
				}
				if !fn(annexB[start:end]) {
					return
				}
			}
			i += 3
			start = i
			continue
		}
		i++
	}
	if start >= 0 && start < len(annexB) {
		fn(annexB[start:])
	}
}
