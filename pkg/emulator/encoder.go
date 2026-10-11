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
}

// DefaultEncoderParams are the encoder patch's compiled defaults.
var DefaultEncoderParams = EncoderParams{MinQP: 18, MaxQP: 42, GOPSeconds: 60, StillQP: 8}

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
