package video

import (
	"encoding/binary"
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
	// LateRepairs counts keyframe waits that a repair arriving after the
	// deadline cancelled.
	LateRepairs uint64
}

const (
	// maxPendingPackets bounds memory if a stream stalls mid-frame.
	maxPendingPackets = 4096
	// maxGapDeadline caps the wait for NACK repair before asking for a
	// keyframe (reached at a round trip of about 250 ms).
	maxGapDeadline = 600 * time.Millisecond
	// assumedRTT is used until a round-trip measurement exists (ICE stats
	// arrive a moment after connecting). Erring long only costs time when a
	// packet is actually missing; erring short turns a repairable loss into
	// a freeze until the next keyframe.
	assumedRTT                 = 100 * time.Millisecond
	minKeyframeRequestInterval = time.Second
)

// NACKInterval is how often the client's NACK generator asks for missing
// packets, so a missing packet is NACKed within one interval of the gap.
const NACKInterval = 40 * time.Millisecond

// NACKRetryInterval is how long a NACK goes unanswered before the same
// packet is NACKed again: a round trip, a quarter more for queueing, and
// 10 ms. The device resends on every NACK, so repeating sooner only sends
// the packet twice. On a LAN this is below NACKInterval: the repeat goes out
// one interval after the first NACK.
func NACKRetryInterval(rtt time.Duration) time.Duration {
	if rtt <= 0 {
		rtt = assumedRTT
	}
	return rtt*5/4 + 10*time.Millisecond
}

// Assembler turns an RTP packet stream into complete access units.
//
// It emits a frame as soon as all packets from the frame's first packet up to
// the packet carrying the RTP marker bit are present and contiguous, so there
// is no added hold (pion's samplebuilder waits for the next frame's first
// packet). When a sequence gap appears it holds the frames behind it while
// NACKs repair it. A gap whose repair makes no progress for an RTT-derived
// deadline (two NACK rounds) makes it ask the sender for a keyframe, rate
// limited, but it keeps holding: a repair that arrives late still beats
// waiting for the keyframe, and cancels that wait. The hold ends when the
// gap fills or when a complete keyframe is pending behind it, which
// supersedes everything before it. Emitting later P-frames past a lost frame
// would only produce corrupted pictures.
type Assembler struct {
	codec           Codec
	deliver         func(AccessUnit)
	requestKeyframe func()

	// deliverMu serialises Push and Tick from assembly through delivery, so
	// frames reach the decoder in order even though they run on different
	// goroutines.
	deliverMu sync.Mutex
	// seenParams: parameter sets (SPS/PPS, VPS/SPS/PPS) have been delivered,
	// so any later IDR is decodable on its own.
	seenParams bool

	mu              sync.Mutex
	pending         map[uint16]pendingPacket
	synced          bool
	nextSeq         uint16
	gapSince        time.Time
	gapHole         uint16 // the first missing packet at gapSince
	waitingKeyframe bool
	// repairWait: the keyframe wait was entered for the gap at nextSeq, so
	// a late repair of that gap cancels it.
	repairWait bool
	// keySeq is a pending packet of the newest keyframe seen (haveKey).
	keySeq          uint16
	haveKey         bool
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

// gapDeadline is how long the repair of a sequence gap may make no progress
// before a keyframe is requested: two NACK rounds, since the first NACK or
// its retransmission can be lost too. The first NACK goes out within an
// interval, the repeat NACKRetryInterval later (rounded up to the next
// interval), and its answer takes a round trip; 10 ms of slack. On a LAN
// that is about 100 ms.
func (a *Assembler) gapDeadline() time.Duration {
	rtt := a.rtt
	if rtt <= 0 {
		rtt = assumedRTT
	}
	return min(2*NACKInterval+NACKRetryInterval(rtt)+rtt+10*time.Millisecond, maxGapDeadline)
}

// seqLess reports whether a precedes b in RTP sequence space.
func seqLess(a, b uint16) bool { return int16(a-b) < 0 }

// Push adds a packet. now is its arrival time.
func (a *Assembler) Push(pkt *rtp.Packet, now time.Time) {
	a.deliverMu.Lock()
	defer a.deliverMu.Unlock()
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
	if carriesKeyframe(a.codec, pkt.Payload) && (!a.haveKey || seqLess(a.keySeq, seq)) {
		a.keySeq, a.haveKey = seq, true
	}
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
	a.deliverMu.Lock()
	defer a.deliverMu.Unlock()
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
		frame, complete, gap := a.collectFrameLocked(a.nextSeq)
		if !complete {
			if !gap {
				// Packets so far are contiguous; the frame is still arriving.
				a.gapSince = time.Time{}
				break
			}
			if a.skipToKeyframeLocked() {
				continue
			}
			// The deadline runs from when the gap appeared or repair last
			// filled its first missing packet: a large loss (a burst, or a
			// keyframe through a shallow queue) can take several round
			// trips, and a keyframe would only add to the load.
			if hole := a.nextSeq + uint16(len(frame)); a.gapSince.IsZero() || hole != a.gapHole {
				a.gapSince, a.gapHole = now, hole
			}
			if now.Sub(a.gapSince) >= a.gapDeadline() {
				// NACKs did not repair the gap in time. Ask for a keyframe
				// (again every second), but keep the frames.
				if !a.waitingKeyframe {
					a.repairWait = true
				}
				a.enterKeyframeWaitLocked(now)
			}
			break
		}
		a.gapSince = time.Time{}
		if a.repairWait {
			// The gap filled after all: no keyframe needed.
			a.repairWait, a.waitingKeyframe = false, false
			a.stats.LateRepairs++
		}
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
		hasParams := HasParameterSets(a.codec, au.Data)
		if a.waitingKeyframe {
			// Until parameter sets have been seen, an IDR alone (e.g. joined
			// after its SPS/PPS packet) cannot be decoded.
			if !au.Keyframe || (!a.seenParams && !hasParams) {
				a.stats.DroppedFrames++
				a.maybeRequestKeyframeLocked(now)
				continue
			}
			a.waitingKeyframe = false
		}
		if hasParams {
			a.seenParams = true
		}
		a.stats.Frames++
		out = append(out, au)
	}
	return out
}

// collectFrameLocked returns the packets of the frame starting at seq, and
// whether they are all present up to and including a marker packet; an
// incomplete frame's packets end before its first missing one. gap reports a
// missing packet with later packets already pending (i.e. a loss, not just a
// frame still in flight).
func (a *Assembler) collectFrameLocked(seq uint16) (frame []pendingPacket, complete, gap bool) {
	for range maxPendingPackets {
		p, ok := a.pending[seq]
		if !ok {
			return frame, false, len(frame) < len(a.pending)
		}
		frame = append(frame, p)
		if p.pkt.Marker {
			return frame, true, false
		}
		seq++
	}
	return frame, false, true
}

// skipToKeyframeLocked gives up on the gap at nextSeq when a complete
// keyframe is pending behind it, which supersedes every frame before it. It
// reports whether it skipped.
func (a *Assembler) skipToKeyframeLocked() bool {
	if !a.haveKey || !seqLess(a.nextSeq, a.keySeq) {
		return false
	}
	key, ok := a.pending[a.keySeq]
	if !ok || !carriesKeyframe(a.codec, key.pkt.Payload) {
		a.haveKey = false
		return false
	}
	// The keyframe starts at its earliest packet before a gap or another
	// frame.
	start := a.keySeq
	for {
		p, ok := a.pending[start-1]
		if !ok || p.pkt.Timestamp != key.pkt.Timestamp {
			break
		}
		start--
	}
	frame, complete, _ := a.collectFrameLocked(start)
	if !complete {
		return false
	}
	if _, bounded := a.pending[start-1]; !bounded {
		// Its first packet may be missing: skip only if what is here
		// decodes on its own.
		if au, err := a.depacketize(frame); err != nil || !HasParameterSets(a.codec, au.Data) {
			return false
		}
	}
	// Count the frames given up by their timestamps.
	dropped, lastTS := 0, uint32(0)
	for s := a.nextSeq; s != start; s++ {
		if p, ok := a.pending[s]; ok {
			if dropped == 0 || p.pkt.Timestamp != lastTS {
				dropped++
			}
			lastTS = p.pkt.Timestamp
			delete(a.pending, s)
		}
	}
	a.stats.DroppedFrames += uint64(max(dropped, 1))
	a.nextSeq = start
	a.gapSince = time.Time{}
	a.repairWait = false
	return true
}

// dropAndResyncLocked gives up on the frame at nextSeq when the pending
// packets overflow: it discards that frame's packets (identified by RTP
// timestamp) and resumes at the next pending packet that starts a NAL unit
// of a different frame. Without such a packet it waits for the next marker
// to find a boundary.
func (a *Assembler) dropAndResyncLocked() {
	a.stats.DroppedFrames++
	a.gapSince = time.Time{}
	a.repairWait = false
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
		if nalType(codec, payload[0]) == 49 { // fragmentation unit
			return payload[2]&0x80 != 0
		}
		return true
	default:
		if len(payload) < 2 {
			return false
		}
		if t := nalType(codec, payload[0]); t == 28 || t == 29 { // FU-A / FU-B
			return payload[1]&0x80 != 0
		}
		return true
	}
}

// carriesKeyframe reports whether an RTP payload holds an IDR (H.264) or
// IRAP (H.265) slice or a fragment of one, alone or in an aggregation
// packet.
func carriesKeyframe(codec Codec, payload []byte) bool {
	if len(payload) < 3 {
		return false
	}
	t := nalType(codec, payload[0])
	switch {
	case codec == CodecH265 && t == 48: // aggregation packet
		return aggregatesKeyframe(codec, payload[2:])
	case codec == CodecH265 && t == 49: // fragmentation unit
		return isKeyframeNAL(codec, payload[2]&0x3f)
	case codec == CodecH264 && t == 24: // STAP-A
		return aggregatesKeyframe(codec, payload[1:])
	case codec == CodecH264 && (t == 28 || t == 29): // FU-A / FU-B
		return isKeyframeNAL(codec, payload[1]&0x1f)
	}
	return isKeyframeNAL(codec, t)
}

// aggregatesKeyframe walks the NAL units of an aggregation packet, each
// preceded by its 16-bit size.
func aggregatesKeyframe(codec Codec, units []byte) bool {
	for len(units) > 2 {
		size := int(binary.BigEndian.Uint16(units))
		units = units[2:]
		if size == 0 || size > len(units) {
			return false
		}
		if isKeyframeNAL(codec, nalType(codec, units[0])) {
			return true
		}
		units = units[size:]
	}
	return false
}

// nalType reads a NAL unit's type from its first header byte.
func nalType(codec Codec, header byte) byte {
	if codec == CodecH265 {
		return (header >> 1) & 0x3f
	}
	return header & 0x1f
}

// isKeyframeNAL: an IDR slice (H.264) or an IRAP picture (H.265).
func isKeyframeNAL(codec Codec, t byte) bool {
	if codec == CodecH265 {
		return t >= 16 && t <= 21
	}
	return t == 5
}

func (a *Assembler) enterKeyframeWaitLocked(now time.Time) {
	if !a.waitingKeyframe {
		a.waitingKeyframe = true
		a.stats.KeyframeWaits++
	}
	a.maybeRequestKeyframeLocked(now)
}

func (a *Assembler) maybeRequestKeyframeLocked(now time.Time) {
	if a.requestKeyframe == nil || now.Sub(a.lastKeyframeReq) < minKeyframeRequestInterval {
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
		if len(nal) > 0 && isKeyframeNAL(codec, nalType(codec, nal[0])) {
			found = true
			return false
		}
		return true
	})
	return found
}

// HasParameterSets reports whether an access unit carries the parameter sets
// a decoder needs to start: SPS and PPS (H.264) or VPS, SPS and PPS (H.265).
func HasParameterSets(codec Codec, annexB []byte) bool {
	var vps, sps, pps bool
	ForEachNAL(annexB, func(nal []byte) bool {
		if len(nal) == 0 {
			return true
		}
		if codec == CodecH265 {
			switch (nal[0] >> 1) & 0x3f {
			case 32:
				vps = true
			case 33:
				sps = true
			case 34:
				pps = true
			}
		} else {
			switch nal[0] & 0x1f {
			case 7:
				sps = true
			case 8:
				pps = true
			}
		}
		return true
	})
	if codec == CodecH265 {
		return vps && sps && pps
	}
	return sps && pps
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
