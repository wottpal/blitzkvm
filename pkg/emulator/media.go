package emulator

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"math/rand/v2"
	"os"
	"runtime"
	"strings"
	"time"

	openh264 "github.com/Azunyan1111/openh264-go"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
)

// resolveCodec mirrors upstream webrtc.go: with preference "auto" (default) the
// device streams H.265 whenever "H265" appears anywhere in the offer.
func resolveCodec(offerSDP, preference string) string {
	offersH265 := strings.Contains(strings.ToUpper(offerSDP), "H265")
	switch preference {
	case "h265":
		if offersH265 {
			return webrtc.MimeTypeH265
		}
		return webrtc.MimeTypeH264
	case "h264":
		return webrtc.MimeTypeH264
	default:
		if offersH265 {
			return webrtc.MimeTypeH265
		}
		return webrtc.MimeTypeH264
	}
}

// startVideo feeds track with the configured source for mimeType until ctx ends.
// H.264 defaults to a live OpenH264 test pattern; H.264 High profile and H.265
// come from Annex-B replay files (see Config.ReplayH264 / ReplayH265).
// keyframeReq carries PLI/FIR requests (see Config.KeyframeOnRequest).
func (s *Server) startVideo(ctx context.Context, mimeType string, track *webrtc.TrackLocalStaticSample, keyframeReq <-chan struct{}) error {
	switch mimeType {
	case webrtc.MimeTypeH264:
		if s.cfg.ReplayH264 != "" {
			return startReplay(ctx, s.cfg.ReplayH264, h264AUD, s.cfg.FPS, track)
		}
		return startTestPattern(ctx, s.cfg.Width, s.cfg.Height, s.cfg.FPS, s.cfg.GOP, s.cfg.Desktop, track, keyframeReq)
	case webrtc.MimeTypeH265:
		if s.cfg.ReplayH265 != "" {
			return startReplay(ctx, s.cfg.ReplayH265, h265AUD, s.cfg.FPS, track)
		}
		// A real device would stream H.265 here. Without a replay clip the
		// emulator sends no video, which is what a client that cannot decode
		// H.265 would effectively see.
		return nil
	default:
		return fmt.Errorf("unsupported codec %s", mimeType)
	}
}

// startTestPattern encodes a moving pattern with OpenH264 (Constrained
// Baseline; the OpenH264 encoder cannot produce the device's High profile).
// Every frame carries a timestamp barcode (see BurnedTimestamp) so latency
// harnesses can compare capture time against encode time.
func startTestPattern(ctx context.Context, width, height, fps, gop int, desktop bool, track *webrtc.TrackLocalStaticSample, keyframeReq <-chan struct{}) error {
	var background *image.YCbCr
	if desktop {
		background = desktopBackground(width, height)
	}
	params := openh264.NewEncoderParams()
	params.Width = width
	params.Height = height
	params.BitRate = width * height * 4
	params.MaxFrameRate = float32(fps)
	params.UsageType = openh264.ScreenContentRealTime
	params.EnableFrameSkip = false
	params.IntraPeriod = uint(gop)

	encoder, err := openh264.NewEncoder(params)
	if err != nil {
		return err
	}

	ticker := time.NewTicker(time.Second / time.Duration(fps))
	go func() {
		defer ticker.Stop()
		defer closeEncoder(encoder)

		frameIndex := 0
		for {
			select {
			case <-ctx.Done():
				return
			case <-keyframeReq:
				_ = encoder.ForceKeyFrame()
			case <-ticker.C:
				if frameIndex%gop == 0 {
					_ = encoder.ForceKeyFrame()
				}
				img := newPatternFrame(width, height, frameIndex, background)
				burnTimestamp(img, time.Now())
				payload, err := encoder.Encode(img)
				if err != nil {
					return
				}
				frameIndex++
				if len(payload) == 0 {
					continue
				}
				if err := track.WriteSample(media.Sample{Data: payload, Duration: time.Second / time.Duration(fps)}); err != nil {
					return
				}
			}
		}
	}()
	return nil
}

func closeEncoder(encoder *openh264.Encoder) {
	// openh264-go encoder teardown can block indefinitely on Windows in CI.
	// The process is short-lived in tests and the OS will reclaim resources.
	if runtime.GOOS == "windows" {
		return
	}
	_ = encoder.Close()
}

// newPatternFrame draws frame frameIndex: a moving box over a moving
// gradient, or over a copy of background if set.
func newPatternFrame(width, height, frameIndex int, background *image.YCbCr) *image.YCbCr {
	img := image.NewYCbCr(image.Rect(0, 0, width, height), image.YCbCrSubsampleRatio420)
	phase := frameIndex % 255
	if background != nil {
		copy(img.Y, background.Y)
		copy(img.Cb, background.Cb)
		copy(img.Cr, background.Cr)
	} else {
		for y := 0; y < height; y++ {
			row := img.Y[y*img.YStride:]
			for x := 0; x < width; x++ {
				row[x] = uint8((x + y + phase) % 256)
			}
		}
		for y := 0; y < height/2; y++ {
			for x := 0; x < width/2; x++ {
				img.Cb[y*img.CStride+x] = uint8((x*2 + phase*3) % 256)
				img.Cr[y*img.CStride+x] = uint8((y*2 + phase*5) % 256)
			}
		}
	}
	fillLuma(img, 20+(frameIndex*7)%max(1, width-120), 20+(frameIndex*5)%max(1, height-80), 100, 60, 235)
	return img
}

// desktopBackground is a still screen full of text: rows of 5×7 glyphs,
// dark on light. Like a real desktop it costs much to code once (a
// keyframe) and nothing while it stays.
func desktopBackground(width, height int) *image.YCbCr {
	img := image.NewYCbCr(image.Rect(0, 0, width, height), image.YCbCrSubsampleRatio420)
	for i := range img.Y {
		img.Y[i] = 235
	}
	for i := range img.Cb {
		img.Cb[i], img.Cr[i] = 128, 128
	}
	rng := rand.New(rand.NewPCG(1, 2))
	var glyphs [64]uint64
	for i := range glyphs {
		for bit := range 35 {
			if rng.Float64() < 0.3 {
				glyphs[i] |= 1 << bit
			}
		}
	}
	for y := 4; y+7 <= height; y += 12 {
		for x := 4; x+5 <= width; x += 6 {
			glyph := glyphs[rng.IntN(len(glyphs))]
			for bit := range 35 {
				if glyph&(1<<bit) != 0 {
					img.Y[(y+bit/5)*img.YStride+x+bit%5] = 16
				}
			}
		}
	}
	return img
}

// Timestamp barcode: 48 bits of Unix milliseconds, MSB first, drawn as
// barcodeCell×barcodeCell luma blocks (black = 0, white = 1) in the top-left
// corner, preceded by a white/black start marker.
const (
	barcodeCell = 8
	barcodeBits = 48
)

func burnTimestamp(img *image.YCbCr, at time.Time) {
	needed := (barcodeBits + 2) * barcodeCell
	if img.Rect.Dx() < needed || img.Rect.Dy() < barcodeCell {
		return
	}
	ms := uint64(at.UnixMilli())
	fillLuma(img, 0, 0, barcodeCell, barcodeCell, 235)
	fillLuma(img, barcodeCell, 0, barcodeCell, barcodeCell, 16)
	for i := 0; i < barcodeBits; i++ {
		v := uint8(16)
		if ms&(1<<(barcodeBits-1-i)) != 0 {
			v = 235
		}
		fillLuma(img, (i+2)*barcodeCell, 0, barcodeCell, barcodeCell, v)
	}
}

// BurnedTimestamp decodes the barcode written by the test pattern from a
// decoded frame's luma plane. ok is false when no barcode is present.
func BurnedTimestamp(luma []byte, stride, width, height int) (time.Time, bool) {
	needed := (barcodeBits + 2) * barcodeCell
	if width < needed || height < barcodeCell {
		return time.Time{}, false
	}
	sample := func(cell int) uint8 {
		x := cell*barcodeCell + barcodeCell/2
		y := barcodeCell / 2
		return luma[y*stride+x]
	}
	if sample(0) < 128 || sample(1) >= 128 {
		return time.Time{}, false
	}
	var ms uint64
	for i := 0; i < barcodeBits; i++ {
		ms <<= 1
		if sample(i+2) >= 128 {
			ms |= 1
		}
	}
	return time.UnixMilli(int64(ms)), true
}

func fillLuma(img *image.YCbCr, x0, y0, w, h int, luma uint8) {
	for y := max(0, y0); y < min(img.Rect.Dy(), y0+h); y++ {
		for x := max(0, x0); x < min(img.Rect.Dx(), x0+w); x++ {
			img.Y[y*img.YStride+x] = luma
			img.Cb[(y/2)*img.CStride+(x/2)] = 128
			img.Cr[(y/2)*img.CStride+(x/2)] = 128
		}
	}
}

// Access-unit delimiter NAL types, used to split replay clips into frames.
// Generate clips with `-bsf:v h264_metadata=aud=insert` (or hevc_metadata).
type audKind int

const (
	h264AUD audKind = iota
	h265AUD
)

func isAUD(nal []byte, kind audKind) bool {
	if len(nal) == 0 {
		return false
	}
	if kind == h264AUD {
		return nal[0]&0x1f == 9
	}
	return (nal[0]>>1)&0x3f == 35
}

// splitAccessUnits splits an Annex-B elementary stream at access-unit
// delimiters. Each returned unit keeps its start codes.
func splitAccessUnits(stream []byte, kind audKind) [][]byte {
	var units [][]byte
	start := -1
	i := 0
	for i+3 <= len(stream) {
		scLen := 0
		if stream[i] == 0 && stream[i+1] == 0 && stream[i+2] == 1 {
			scLen = 3
		} else if i+4 <= len(stream) && stream[i] == 0 && stream[i+1] == 0 && stream[i+2] == 0 && stream[i+3] == 1 {
			scLen = 4
		}
		if scLen == 0 {
			i++
			continue
		}
		if isAUD(stream[i+scLen:], kind) {
			if start >= 0 {
				units = append(units, stream[start:i])
			}
			start = i
		}
		i += scLen
	}
	if start >= 0 {
		units = append(units, stream[start:])
	}
	return units
}

func startReplay(ctx context.Context, path string, kind audKind, fps int, track *webrtc.TrackLocalStaticSample) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	units := splitAccessUnits(data, kind)
	if len(units) == 0 {
		return fmt.Errorf("replay %s: no access-unit delimiters found", path)
	}
	go func() {
		ticker := time.NewTicker(time.Second / time.Duration(fps))
		defer ticker.Stop()
		for i := 0; ; i++ {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				unit := bytes.Clone(units[i%len(units)])
				if err := track.WriteSample(media.Sample{Data: unit, Duration: time.Second / time.Duration(fps)}); err != nil {
					return
				}
			}
		}
	}()
	return nil
}
