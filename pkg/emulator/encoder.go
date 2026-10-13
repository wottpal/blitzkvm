package emulator

import "fmt"

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
