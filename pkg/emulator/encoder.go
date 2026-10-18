package emulator

import (
	"bytes"
	"fmt"
	"math"
	"time"
)

// EncoderParams mirrors the encoder patch's VideoEncoderParams.
type EncoderParams struct {
	MinQP          int     `json:"minQp"`
	MaxQP          int     `json:"maxQp"`
	GOPSeconds     float64 `json:"gopSeconds"`
	AQ             bool    `json:"aq"`
	MaxFPS         int     `json:"maxFps"`
	BitrateKbps    int     `json:"bitrateKbps"`
	MaxBitrateKbps int     `json:"maxBitrateKbps"`
	StillQP        int     `json:"stillQp"`
	// AutoRefresh: the device refreshes a still screen on its own (fork
	// D13; earlier builds always do). Off, the client asks for refreshes
	// (refreshRegions).
	AutoRefresh bool `json:"autoRefresh"`
}

// DefaultEncoderParams are the encoder patch's compiled defaults.
var DefaultEncoderParams = EncoderParams{MinQP: 18, MaxQP: 42, GOPSeconds: 60, StillQP: 8, AutoRefresh: true}

// Refresh limits of the refreshRegions RPC (fork D13).
const (
	maxRefreshRects      = 6
	maxRefreshFrames     = 4
	defaultRefreshFrames = 2
)

// RefreshRect is one region of a refreshRegions call, in frame pixels.
type RefreshRect struct {
	X int `json:"x"`
	Y int `json:"y"`
	W int `json:"w"`
	H int `json:"h"`
}

// RefreshRequest is refreshRegions' parameters: 1-6 rects are re-encoded as
// intra blocks at qp (clamped to minQp) for frames P-frames, no keyframe; no
// rects refresh the whole frame at once (a keyframe at qp).
type RefreshRequest struct {
	Rects  []RefreshRect `json:"rects"`
	QP     int           `json:"qp"`
	Frames int           `json:"frames"`
}

// validate checks a request against a width x height stream, filling in the
// default frame count.
func (r *RefreshRequest) validate(width, height int) error {
	if r.Frames == 0 {
		r.Frames = defaultRefreshFrames
	}
	switch {
	case len(r.Rects) > maxRefreshRects:
		return fmt.Errorf("at most %d rects, got %d", maxRefreshRects, len(r.Rects))
	case r.QP < 1 || r.QP > 51:
		return fmt.Errorf("qp must be 1-51, got %d", r.QP)
	case r.Frames < 1 || r.Frames > maxRefreshFrames:
		return fmt.Errorf("frames must be 1-%d, got %d", maxRefreshFrames, r.Frames)
	}
	for _, rect := range r.Rects {
		if rect.X < 0 || rect.Y < 0 || rect.W < 1 || rect.H < 1 || rect.X+rect.W > width || rect.Y+rect.H > height {
			return fmt.Errorf("rect %+v outside the %dx%d frame", rect, width, height)
		}
	}
	return nil
}

func (p EncoderParams) validate() error {
	switch {
	case p.MinQP < 8 || p.MinQP > 40:
		return fmt.Errorf("minQp must be 8-40, got %d", p.MinQP)
	case p.MaxQP < p.MinQP || p.MaxQP > 51:
		return fmt.Errorf("maxQp must be %d-51 (minQp-51), got %d", p.MinQP, p.MaxQP)
	case !(p.GOPSeconds >= 0.5 && p.GOPSeconds <= 300):
		return fmt.Errorf("gopSeconds must be 0.5-300, got %g", p.GOPSeconds)
	case p.MaxFPS < 0 || p.MaxFPS > 120:
		return fmt.Errorf("maxFps must be 1-120, or 0 for the source rate, got %d", p.MaxFPS)
	case p.BitrateKbps != 0 && (p.BitrateKbps < 100 || p.BitrateKbps > 50000):
		return fmt.Errorf("bitrateKbps must be 100-50000, or 0 for the quality factor, got %d", p.BitrateKbps)
	case p.MaxBitrateKbps != 0 && (p.MaxBitrateKbps < 100 || p.MaxBitrateKbps > 50000):
		return fmt.Errorf("maxBitrateKbps must be 100-50000, or 0 for 1.5x the target, got %d", p.MaxBitrateKbps)
	case p.StillQP < 1 || p.StillQP > 51:
		return fmt.Errorf("stillQp must be 1-51, got %d", p.StillQP)
	}
	return nil
}

// The encoder model. With the encoder patch the stream follows
// setVideoEncoderParams the way the device's encoder does, so a quality
// controller can be measured against it. The numbers come from the patched
// device (plan §21 and §23: H.265, 1080p), scaled by pixel count:
//
//   - A keyframe costs keyframeBytesQP10 at QP 10: the QP floor for keyframes
//     at the GOP or on request, the still QP for the still refresh.
//   - A frame that changes the whole screen (scrolling) costs
//     motionBytesQP10 at QP 10; a smaller change costs its share of the
//     screen.
//   - Each QP step makes a frame qpStep smaller. One factor fits both the
//     keyframes (123-231 kB at QP 24-10) and scrolling (3.7-8.1 Mbit/s at
//     60 fps) within 10 %, and gives the 250-350 kB still refresh at QP 1.
//   - The bitrate limits the frames between keyframes (VBR): credit accrues
//     at bitrateKbps and holds what maxBitrateKbps may add to it over
//     vbrWindow, so motion runs at the peak for a while and then at the
//     target. A frame that would overdraw the credit is coded coarser, down
//     to maxQp. Keyframes spend credit but are not limited by it: on the
//     device their size followed the QP floor, not the quality factor.
//   - maxFps drops source frames; each coded frame then covers more motion,
//     but costs the same (the device measured slightly less).
//   - stillRefreshAfter the screen last changed (or the stream started),
//     one keyframe at stillQp, unless stillQp >= minQp.
//
// A frame's size on the wire is the model's, or what OpenH264 coded if that
// is more. The model draws a plain picture so its frames stay small, and pads
// each access unit with an SEI that decoders skip (padAccessUnit).
const (
	keyframeBytesQP10 = 231_000
	motionBytesQP10   = 8_100_000 / 8 / 60
	qpStep            = 0.95
	vbrWindow         = time.Second
	stillRefreshAfter = 500 * time.Millisecond
)

// encoderModel is the rate control state of one stream.
type encoderModel struct {
	scale     float64 // frame area relative to 1080p
	credit    float64 // bits the rate control may still spend
	last      time.Time
	changedAt time.Time
	refreshed bool // the still refresh for changedAt went out
}

func newEncoderModel(width, height int) *encoderModel {
	return &encoderModel{scale: float64(width*height) / (1920 * 1080)}
}

// codes reports whether the source frame captured at t is coded under the
// frame rate cap (0: the source rate).
func (m *encoderModel) codes(t time.Time, maxFPS int) bool {
	return maxFPS <= 0 || m.last.IsZero() || t.Sub(m.last) > time.Second/time.Duration(maxFPS)-time.Millisecond
}

// frame plans the coded frame captured at t: target and peak are the
// bitrates (kbit/s), change the share of the screen that changed since the
// previous coded frame, and key a keyframe the GOP or a request asks for.
// It returns whether the frame is a keyframe (key, or the still refresh)
// and its size in bytes.
func (m *encoderModel) frame(t time.Time, p EncoderParams, target, peak int, change float64, key bool) (keyframe bool, size int) {
	if change > 0 || m.changedAt.IsZero() {
		m.changedAt, m.refreshed = t, false
	}
	qp := p.MinQP
	if !m.refreshed && p.StillQP < p.MinQP && t.Sub(m.changedAt) >= stillRefreshAfter {
		key, qp, m.refreshed = true, p.StillQP, true
	}
	rate, depth := float64(target)*1000, float64(max(peak-target, 0))*1000*vbrWindow.Seconds()
	// The bank holds at most depth; what accrued since the last frame comes
	// on top, so with the peak at the target the encoder still spends the
	// target (CBR) instead of nothing.
	if m.last.IsZero() {
		m.credit = depth
	} else {
		m.credit = min(m.credit, depth) + rate*t.Sub(m.last).Seconds()
	}
	m.last = t
	scale := m.scale * math.Pow(qpStep, float64(qp-10))
	var bits float64
	if key {
		bits = 8 * keyframeBytesQP10 * scale
	} else {
		demand := 8 * motionBytesQP10 * scale * change
		coarsest := demand * math.Pow(qpStep, float64(p.MaxQP-qp))
		bits = min(demand, max(m.credit, coarsest))
	}
	m.credit -= bits
	return key, int(bits / 8)
}

// rates returns the encoder's bitrate target and peak in kbit/s: the
// parameters' if set, else the firmware's formula for the quality factor
// (calculate_bitrate, scaled by resolution) and 1.5 times the target.
func (p EncoderParams) rates(factor float64, width, height int) (target, peak int) {
	target = p.BitrateKbps
	if target == 0 {
		target = max(int(512+3488*factor)*width*height/(1920*1080), 200)
	}
	peak = p.MaxBitrateKbps
	if peak == 0 {
		peak = target * 3 / 2
	}
	return target, peak
}

// paddingUUID marks the SEI that pads an access unit (user data
// unregistered: 16 bytes of UUID, then the data).
var paddingUUID = []byte("blitzkvm-padding")

// padAccessUnit grows an H.264 access unit (Annex-B) to size bytes with an
// SEI message before its first slice, where the standard puts SEI. pion's
// payloader drops filler data NAL units, so filler cannot do it.
func padAccessUnit(au []byte, size int) []byte {
	const overhead = 4 + 1 + 1 + 1 // start code, NAL header, payload type, trailing bits
	pad := size - len(au) - overhead - len(paddingUUID)
	if pad < 8 {
		return au
	}
	// The payload size is coded in as many bytes as it needs (255 each but
	// the last); they come out of the padding.
	data := pad - 1
	for data+len(paddingUUID) >= 255*(pad-data) {
		data--
	}
	sei := make([]byte, 0, size-len(au))
	sei = append(sei, 0, 0, 0, 1, 0x06, 0x05) // SEI, user_data_unregistered
	n := data + len(paddingUUID)
	for ; n >= 255; n -= 255 {
		sei = append(sei, 0xff)
	}
	sei = append(sei, byte(n))
	sei = append(sei, paddingUUID...)
	sei = append(sei, bytes.Repeat([]byte{0xff}, data)...)
	sei = append(sei, 0x80)
	at := firstSlice(au)
	return append(au[:at:at], append(sei, au[at:]...)...)
}

// firstSlice is the offset of the start code of an access unit's first
// slice (NAL type 1 or 5), or its length if it has none.
func firstSlice(au []byte) int {
	for i := 0; i+3 < len(au); i++ {
		if au[i] != 0 || au[i+1] != 0 || au[i+2] != 1 {
			continue
		}
		if t := au[i+3] & 0x1f; t == 1 || t == 5 {
			if i > 0 && au[i-1] == 0 {
				return i - 1
			}
			return i
		}
	}
	return len(au)
}
