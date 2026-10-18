package emulator

import (
	"bytes"
	"context"
	"math"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/wottpal/blitzkvm/pkg/client"
	"github.com/wottpal/blitzkvm/pkg/video"
)

// modelRun codes seconds of 1080p60 under p, with change the share of the
// screen each source frame changes, and returns the bitrate of the frames
// between keyframes (Mbit/s) and the keyframes' sizes.
func modelRun(p EncoderParams, seconds float64, change func(i int) float64) (mbps float64, keyframes []int) {
	m := newEncoderModel(1920, 1080)
	target, peak := p.rates(1, 1920, 1080)
	start := time.Unix(0, 0)
	total := 0
	for i := range int(seconds * 60) {
		at := start.Add(time.Duration(i) * time.Second / 60)
		if !m.codes(at, p.MaxFPS) {
			continue
		}
		key, size := m.frame(at, p, target, peak, change(i), i == 0)
		if key {
			keyframes = append(keyframes, size)
		} else {
			total += size
		}
	}
	return float64(total) * 8 / seconds / 1e6, keyframes
}

func near(got, want, tolerance float64) bool { return math.Abs(got-want) <= tolerance*want }

func TestEncoderModelMatchesTheDevice(t *testing.T) {
	scrolling := func(int) float64 { return 1 }
	// Maximum (plan §21): scrolling 8.1 Mbit/s, keyframes 231 kB at QP 10.
	maxLevel := EncoderParams{MinQP: 10, MaxQP: 42, StillQP: 1, BitrateKbps: 10976, MaxBitrateKbps: 16464}
	mbps, keys := modelRun(maxLevel, 10, scrolling)
	if !near(mbps, 8.1, 0.05) || len(keys) != 1 || !near(float64(keys[0]), 231_000, 0.01) {
		t.Errorf("maximum: %.2f Mbit/s, keyframes %v", mbps, keys)
	}
	// QP 24: the sweep measured 123 kB keyframes and 3.7 Mbit/s scrolling.
	qp24 := EncoderParams{MinQP: 24, MaxQP: 42, StillQP: 24, BitrateKbps: 10976}
	if mbps, keys := modelRun(qp24, 10, scrolling); !near(mbps, 3.7, 0.1) || !near(float64(keys[0]), 123_000, 0.1) {
		t.Errorf("QP 24: %.2f Mbit/s, keyframes %v", mbps, keys)
	}
	// Balanced: the 4 Mbit/s target (peak 6) holds sustained motion that
	// would cost 5.4 Mbit/s, after a burst at up to the peak (the first
	// keyframe spends some of its credit).
	balanced := EncoderParams{MinQP: 18, MaxQP: 42, StillQP: 8, BitrateKbps: 4000, MaxBitrateKbps: 6000}
	if mbps, keys := modelRun(balanced, 30, scrolling); !near(mbps, 4.0+(2.0-float64(keys[0])*8/1e6)/30, 0.01) {
		t.Errorf("balanced: %.2f Mbit/s over 30 s", mbps)
	}
	// Minimal: 15 fps, QP 26.
	minimal := EncoderParams{MinQP: 26, MaxQP: 42, StillQP: 26, MaxFPS: 15, BitrateKbps: 1384}
	if mbps, _ := modelRun(minimal, 10, scrolling); !near(mbps, 8.1/4*math.Pow(qpStep, 16), 0.05) {
		t.Errorf("minimal: %.2f Mbit/s", mbps)
	}
}

// With its peak at its target, the encoder codes at the target (CBR), not at
// its coarsest: on the device, balanced with both at 2 Mbit/s scrolled at
// about 2 Mbit/s (plan §32).
func TestEncoderModelPeakAtTheTarget(t *testing.T) {
	scrolling := func(int) float64 { return 1 }
	capped := EncoderParams{MinQP: 18, MaxQP: 42, StillQP: 8, BitrateKbps: 2000, MaxBitrateKbps: 2000}
	if mbps, keys := modelRun(capped, 30, scrolling); !near(mbps, 2.0-float64(keys[0])*8/1e6/30, 0.02) {
		t.Errorf("peak at the target: %.2f Mbit/s, want 2", mbps)
	}
}

func TestEncoderModelStillRefresh(t *testing.T) {
	// One second of scrolling, then a still screen: one keyframe at the
	// still QP half a second later (QP 1 at maximum: about 350 kB).
	scrollThenStill := func(i int) float64 {
		if i < 60 {
			return 1
		}
		return 0
	}
	maxLevel := EncoderParams{MinQP: 10, MaxQP: 42, StillQP: 1, BitrateKbps: 10976}
	if _, keys := modelRun(maxLevel, 5, scrollThenStill); len(keys) != 2 || !near(float64(keys[1]), 350_000, 0.05) {
		t.Errorf("maximum: keyframes %v, want the first and a still refresh of about 350 kB", keys)
	}
	// stillQp >= minQp turns it off.
	minimal := EncoderParams{MinQP: 26, MaxQP: 42, StillQP: 26, BitrateKbps: 1384}
	if _, keys := modelRun(minimal, 5, scrollThenStill); len(keys) != 1 {
		t.Errorf("minimal: keyframes %v, want only the first", keys)
	}
}

func TestPadAccessUnit(t *testing.T) {
	sps, pps, idr := []byte{0x67, 0x42, 0xc0, 0x1f}, []byte{0x68, 0xce, 0x3c, 0x80}, []byte{0x65, 0x88, 0x84, 0x21}
	var au []byte
	for _, nal := range [][]byte{sps, pps, idr} {
		au = append(au, 0, 0, 0, 1)
		au = append(au, nal...)
	}
	for _, size := range []int{len(au), len(au) + 30, 300, 1000, 255*3 + 40, 100_000} {
		padded := padAccessUnit(bytes.Clone(au), size)
		if size-len(au) < 40 && len(padded) != len(au) {
			t.Errorf("size %d: padded to %d, want unchanged", size, len(padded))
			continue
		}
		if size-len(au) >= 40 && (len(padded) > size || len(padded) < size-1) {
			t.Errorf("size %d: padded to %d", size, len(padded))
		}
		var types []byte
		video.ForEachNAL(padded, func(nal []byte) bool {
			types = append(types, nal[0]&0x1f)
			return true
		})
		want := []byte{7, 8, 5}
		if len(padded) > len(au) {
			want = []byte{7, 8, 6, 5}
		}
		if !bytes.Equal(types, want) || !video.IsKeyframe(video.CodecH264, padded) || !video.HasParameterSets(video.CodecH264, padded) {
			t.Errorf("size %d: NAL types %v, want %v", size, types, want)
		}
	}
}

// The stream follows setVideoEncoderParams: at minimal (15 fps, QP 26) a
// moving screen sends half the frames of maximum (60 fps here capped at
// the 30 fps source, QP 10), each about 0.95^16 the size.
func TestEncoderModelFollowsTheParameters(t *testing.T) {
	srv := startTestServer(t, Config{Width: 640, Height: 360, FPS: 30, GOP: 3600, EncoderPatch: true})
	var mu sync.Mutex
	var sizes []int
	c := connectClient(t, client.Config{BaseURL: srv.BaseURL(), OnAccessUnit: func(au video.AccessUnit) {
		mu.Lock()
		if !au.Keyframe {
			sizes = append(sizes, len(au.Data))
		}
		mu.Unlock()
	}})
	measure := func(params map[string]any) (frames, median int) {
		if err := c.Call(context.Background(), "setVideoEncoderParams", map[string]any{"params": params}, nil); err != nil {
			t.Fatal(err)
		}
		time.Sleep(200 * time.Millisecond)
		mu.Lock()
		sizes = sizes[:0]
		mu.Unlock()
		time.Sleep(time.Second)
		mu.Lock()
		defer mu.Unlock()
		if len(sizes) == 0 {
			t.Fatal("no frames")
		}
		sorted := slices.Sorted(slices.Values(sizes))
		return len(sizes), sorted[len(sorted)/2]
	}
	maxFrames, maxSize := measure(map[string]any{"minQp": 10, "maxFps": 60, "bitrateKbps": 10976, "stillQp": 1})
	minFrames, minSize := measure(map[string]any{"minQp": 26, "maxFps": 15, "bitrateKbps": 1384, "stillQp": 26})
	t.Logf("maximum: %d frames of %d B; minimal: %d frames of %d B", maxFrames, maxSize, minFrames, minSize)
	if ratio := float64(minFrames) / float64(maxFrames); math.Abs(ratio-0.5) > 0.1 {
		t.Errorf("minimal sent %d frames to maximum's %d, want half", minFrames, maxFrames)
	}
	want := float64(motionBytesQP10) * 640 * 360 / (1920 * 1080)
	if !near(float64(maxSize), want, 0.05) || !near(float64(minSize), want*math.Pow(qpStep, 16), 0.05) {
		t.Errorf("frames of %d and %d B, want %.0f and %.0f", maxSize, minSize, want, want*math.Pow(qpStep, 16))
	}
}
