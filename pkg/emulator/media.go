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
		return s.startTestPattern(ctx, track, keyframeReq)
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

// startTestPattern encodes the test pattern with OpenH264 (Constrained
// Baseline; the OpenH264 encoder cannot produce the device's High profile).
// Every frame carries a timestamp barcode (see BurnedTimestamp) so latency
// harnesses can compare capture time against encode time. Source frame i
// is captured at start + i/fps and its RTP timestamp says so, as on the
// device: a frame that is not sent (the loop fell behind, or the encoder's
// frame rate cap drops it) still advances the RTP clock. With the encoder
// patch, the encoder model sets each frame's size (see encoderModel).
func (s *Server) startTestPattern(ctx context.Context, track *webrtc.TrackLocalStaticSample, keyframeReq <-chan struct{}) error {
	s.mu.Lock() // password changes write the config
	cfg := s.cfg
	s.mu.Unlock()
	params := openh264.NewEncoderParams()
	params.Width = cfg.Width
	params.Height = cfg.Height
	params.BitRate = cfg.Width * cfg.Height * 4
	params.MaxFrameRate = float32(cfg.FPS)
	params.UsageType = openh264.ScreenContentRealTime
	params.EnableFrameSkip = false
	params.IntraPeriod = 0 // the loop decides every keyframe

	encoder, err := openh264.NewEncoder(params)
	if err != nil {
		return err
	}
	var model *encoderModel
	if cfg.EncoderPatch {
		model = newEncoderModel(cfg.Width, cfg.Height)
	}
	var typed func() int64
	if cfg.StillScreen {
		typed = s.typed.Load
	}
	pat := newPattern(cfg, model != nil, typed)
	go func() {
		defer closeEncoder(encoder)
		interval := time.Second / time.Duration(cfg.FPS)
		skip := media.Sample{Duration: interval} // advances the RTP clock, sends nothing
		timer := time.NewTimer(0)
		defer timer.Stop()
		start := time.Now()
		key, change := false, 0.0
		for i := 0; ; i++ {
			at := start.Add(time.Duration(i) * interval)
			timer.Reset(time.Until(at))
		wait:
			for {
				select {
				case <-ctx.Done():
					return
				case <-keyframeReq:
					key = true
				case <-timer.C:
					break wait
				}
			}
			img, c := pat.next(i)
			key, change = key || i%cfg.GOP == 0, max(change, c)
			coded := time.Since(at) < interval
			size := 0
			if coded && model != nil {
				p, target, peak := s.encoderRates()
				if coded = model.codes(at, p.MaxFPS); coded {
					key, size = model.frame(at, p, target, peak, change, key)
				}
			}
			sample := skip
			if coded {
				if key {
					_ = encoder.ForceKeyFrame()
				}
				if typed == nil {
					burnTimestamp(img, time.Now())
				}
				payload, err := encoder.Encode(img)
				if err != nil {
					return
				}
				sample.Data = padAccessUnit(payload, size)
				key, change = false, 0
			}
			if err := track.WriteSample(sample); err != nil {
				return
			}
		}
	}()
	return nil
}

// encoderRates returns the encoder parameters and the bitrate target and
// peak (kbit/s) they mean for the stream.
func (s *Server) encoderRates() (p EncoderParams, target, peak int) {
	s.mu.Lock()
	p, factor := s.state.EncoderParams, s.state.StreamQualityFactor
	s.mu.Unlock()
	target, peak = p.rates(factor, s.cfg.Width, s.cfg.Height)
	return p, target, peak
}

func closeEncoder(encoder *openh264.Encoder) {
	// openh264-go encoder teardown can block indefinitely on Windows in CI.
	// The process is short-lived in tests and the OS will reclaim resources.
	if runtime.GOOS == "windows" {
		return
	}
	_ = encoder.Close()
}

// The test pattern's content (Config.Desktop, Config.Scroll): a box moving
// over a gradient that moves too (everything changes every frame), over a
// still screen of text (desktop), or a screen of text that rests for
// scrollRest and then scrolls for scrollFor at a screen height a second,
// again and again (reading a document; the box moves only while it
// scrolls).
const (
	scrollRest = 4 * time.Second
	scrollFor  = 2 * time.Second
	boxWidth   = 100
	boxHeight  = 60
)

// pattern draws the test pattern's frames.
type pattern struct {
	width, height int
	desktop       bool
	scrollFrames  int // a scroll's length in frames (0: never scrolls)
	period        int // frames from one scroll's start to the next
	scrollStep    int // pixels a frame scrolls
	// text is the screen of text (desktop, scroll); nil draws the moving
	// gradient. plain draws a flat screen instead of either, for the
	// encoder model, whose frames must stay small.
	text  *image.YCbCr
	plain bool
	steps int // changing frames so far: the box and the text move a step each
	// typed (Config.StillScreen): a still light screen that shows this many
	// typed glyphs instead (drawn so far: drawn, on still).
	typed func() int64
	drawn int64
	still *image.YCbCr
}

func newPattern(cfg Config, plain bool, typed func() int64) *pattern {
	p := &pattern{width: cfg.Width, height: cfg.Height, desktop: cfg.Desktop || cfg.Scroll, plain: plain, typed: typed}
	if cfg.Scroll {
		p.scrollFrames = int(scrollFor) * cfg.FPS / int(time.Second)
		p.period = p.scrollFrames + int(scrollRest)*cfg.FPS/int(time.Second)
		p.scrollStep = max(1, cfg.Height/cfg.FPS)
	}
	if p.desktop && !plain {
		p.text = desktopBackground(cfg.Width, cfg.Height)
	}
	return p
}

// next draws source frame i and reports the share of the screen that
// changed since frame i-1.
func (p *pattern) next(i int) (*image.YCbCr, float64) {
	if p.typed != nil {
		return p.nextTyped()
	}
	change := 1.0
	switch {
	case p.scrollFrames > 0 && i%p.period < p.period-p.scrollFrames:
		change = 0
	case p.desktop && p.scrollFrames == 0:
		change = min(1, 2*boxWidth*boxHeight/float64(p.width*p.height))
	}
	if change > 0 {
		p.steps++
	}
	img := image.NewYCbCr(image.Rect(0, 0, p.width, p.height), image.YCbCrSubsampleRatio420)
	switch {
	case p.plain:
		for j := range img.Y {
			img.Y[j] = 128
		}
		for j := range img.Cb {
			img.Cb[j], img.Cr[j] = 128, 128
		}
	case p.text != nil:
		scroll := p.steps * p.scrollStep % p.height
		for y := range p.height {
			src := (y + scroll) % p.height
			copy(img.Y[y*img.YStride:][:p.width], p.text.Y[src*p.text.YStride:][:p.width])
		}
		copy(img.Cb, p.text.Cb)
		copy(img.Cr, p.text.Cr)
	default:
		drawGradient(img, i)
	}
	fillLuma(img, 20+(p.steps*7)%max(1, p.width-120), 20+(p.steps*5)%max(1, p.height-80), boxWidth, boxHeight, 235)
	return img, change
}

// nextTyped draws the glyphs typed since the last frame onto the still
// screen and reports their share of it.
func (p *pattern) nextTyped() (*image.YCbCr, float64) {
	if p.still == nil {
		p.still = image.NewYCbCr(image.Rect(0, 0, p.width, p.height), image.YCbCrSubsampleRatio420)
		for j := range p.still.Y {
			p.still.Y[j] = 235
		}
		for j := range p.still.Cb {
			p.still.Cb[j], p.still.Cr[j] = 128, 128
		}
	}
	n := p.typed()
	added := n - p.drawn
	for ; p.drawn < n; p.drawn++ {
		drawTypedGlyph(p.still, int(p.drawn))
	}
	return p.still, min(1, float64(added*glyphWidth*glyphHeight)/float64(p.width*p.height))
}

// Typed glyphs on the still screen: dark blocks the size of a 1x glyph, in
// lines from the top left, like text typed into an editor.
const (
	glyphWidth   = 8
	glyphHeight  = 16
	glyphAdvance = 10
	glyphLine    = 24
	glyphMargin  = 64
)

func drawTypedGlyph(img *image.YCbCr, index int) {
	perLine := max(1, (img.Rect.Dx()-2*glyphMargin)/glyphAdvance)
	x := glyphMargin + index%perLine*glyphAdvance
	y := glyphMargin + index/perLine*glyphLine
	fillLuma(img, x, y, glyphWidth, glyphHeight, 16)
}

// drawGradient fills img with a diagonal gradient that moves with phase.
func drawGradient(img *image.YCbCr, phase int) {
	phase %= 255
	width, height := img.Rect.Dx(), img.Rect.Dy()
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
