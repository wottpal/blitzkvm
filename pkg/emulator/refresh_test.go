package emulator

import (
	"context"
	"errors"
	"image"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/wottpal/blitzkvm/pkg/client"
	"github.com/wottpal/blitzkvm/pkg/video"
	"github.com/wottpal/blitzkvm/pkg/video/openh264"
)

// Client-driven still refresh (fork firmware D13).

// Before D13 none of it exists, and autoRefresh means nothing.
func TestRefreshRegionsNeedsD13(t *testing.T) {
	srv := startTestServer(t, Config{EncoderPatch: true})
	c := connectClient(t, client.Config{BaseURL: srv.BaseURL()})
	ctx := context.Background()
	for _, method := range []string{"getFirmwareFeatures", "refreshRegions"} {
		var rpcErr *client.RPCError
		if err := c.Call(ctx, method, map[string]any{"rects": []any{}, "qp": 1}, nil); !errors.As(err, &rpcErr) || rpcErr.Code != -32601 {
			t.Fatalf("%s: want method not found, got %v", method, err)
		}
	}
	if c.HasFirmwareFeature(ctx, client.FeatureRefreshRegions) {
		t.Fatal("refreshRegions listed")
	}
	if err := c.Call(ctx, "setVideoEncoderParams", map[string]any{"params": map[string]any{"autoRefresh": false}}, nil); err != nil {
		t.Fatal(err)
	}
	if !srv.State().EncoderParams.AutoRefresh {
		t.Fatal("autoRefresh changed on firmware without it")
	}
}

func TestRefreshRegionsValidatesAndFullRefreshSendsAKeyframe(t *testing.T) {
	srv := startTestServer(t, Config{RefreshRegions: true, Width: 640, Height: 360, FPS: 30, GOP: 1800})
	var keyframes atomic.Int64
	c := connectClient(t, client.Config{BaseURL: srv.BaseURL(), OnAccessUnit: func(au video.AccessUnit) {
		if au.Keyframe {
			keyframes.Add(1)
		}
	}})
	ctx := context.Background()
	if !c.HasFirmwareFeature(ctx, client.FeatureRefreshRegions) || !c.HasFirmwareFeature(ctx, client.FeatureHIDRPCWheel) {
		t.Fatal("D13 features not listed")
	}
	// Partial updates: autoRefresh alone leaves the rest as it is.
	if err := c.Call(ctx, "setVideoEncoderParams", map[string]any{"params": map[string]any{"autoRefresh": false}}, nil); err != nil {
		t.Fatal(err)
	}
	want := DefaultEncoderParams
	want.AutoRefresh = false
	if got := srv.State().EncoderParams; got != want {
		t.Fatalf("params %+v, want %+v", got, want)
	}

	rect := func(x, y, w, h int) map[string]any { return map[string]any{"x": x, "y": y, "w": w, "h": h} }
	if err := c.Call(ctx, "refreshRegions", map[string]any{"rects": []any{rect(0, 0, 16, 16), rect(624, 352, 16, 8)}, "qp": 1}, nil); err != nil {
		t.Fatalf("valid region refresh: %v", err)
	}
	bad := map[string]map[string]any{
		"at most 6 rects":       {"rects": []any{rect(0, 0, 1, 1), rect(0, 0, 1, 1), rect(0, 0, 1, 1), rect(0, 0, 1, 1), rect(0, 0, 1, 1), rect(0, 0, 1, 1), rect(0, 0, 1, 1)}, "qp": 1},
		"qp must be":            {"rects": []any{rect(0, 0, 16, 16)}, "qp": 0},
		"frames must be":        {"rects": []any{rect(0, 0, 16, 16)}, "qp": 1, "frames": 5},
		"outside":               {"rects": []any{rect(632, 0, 16, 16)}, "qp": 1},
		"missing parameter: qp": {"rects": []any{}},
	}
	for want, params := range bad {
		var rpcErr *client.RPCError
		if err := c.Call(ctx, "refreshRegions", params, nil); !errors.As(err, &rpcErr) || !strings.Contains(rpcErr.Data, want) {
			t.Errorf("%v: want an error containing %q, got %v", params, want, err)
		}
	}

	deadline := time.Now().Add(5 * time.Second)
	for keyframes.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	before := keyframes.Load()
	if err := c.Call(ctx, "refreshRegions", map[string]any{"rects": []any{}, "qp": 1, "frames": 2}, nil); err != nil {
		t.Fatalf("full refresh: %v", err)
	}
	deadline = time.Now().Add(time.Second)
	for keyframes.Load() == before && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if keyframes.Load() == before {
		t.Fatal("a full refresh sent no keyframe")
	}

	var logged []string
	for _, in := range srv.Inputs() {
		if in.Type == "rpc.refreshRegions" {
			logged = append(logged, in.Data)
		}
	}
	wantLogged := []string{"rects=[{X:0 Y:0 W:16 H:16} {X:624 Y:352 W:16 H:8}] qp=1 frames=2", "rects=[] qp=1 frames=2"}
	if strings.Join(logged, "|") != strings.Join(wantLogged, "|") {
		t.Fatalf("logged %q, want %q (invalid calls are not logged)", logged, wantLogged)
	}
}

// Encoder overrides belong to the session that set them: another session
// taking over starts from the defaults (fork resetEncoderOverrides).
func TestEncoderOverridesResetOnTakeover(t *testing.T) {
	srv := startTestServer(t, Config{RefreshRegions: true})
	first := connectClient(t, client.Config{BaseURL: srv.BaseURL()})
	if err := first.Call(context.Background(), "setVideoEncoderParams", map[string]any{"params": map[string]any{"autoRefresh": false, "minQp": 10}}, nil); err != nil {
		t.Fatal(err)
	}
	if srv.State().EncoderParams.AutoRefresh {
		t.Fatal("autoRefresh not set")
	}
	_ = connectClient(t, client.Config{BaseURL: srv.BaseURL()})
	if got := srv.State().EncoderParams; got != DefaultEncoderParams {
		t.Fatalf("after a takeover: %+v, want the defaults", got)
	}
}

// The still screen stands still until a key is pressed, which changes only
// the glyph's macroblocks.
func TestStillScreenChangesWhereTyped(t *testing.T) {
	srv := startTestServer(t, Config{StillScreen: true, Width: 320, Height: 240, FPS: 30, GOP: 1800})
	c := connectClient(t, client.Config{BaseURL: srv.BaseURL(), NewVideoSink: openh264.NewSink})
	luma := func() []byte {
		img, _ := c.LatestFrameInfo()
		if y, ok := img.(*image.YCbCr); ok {
			return append([]byte(nil), y.Y...)
		}
		return nil
	}
	// Settled: the encoder refines a new picture for a few frames.
	settle := func() []byte {
		var prev []byte
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			time.Sleep(200 * time.Millisecond)
			cur := luma()
			if cur != nil && string(cur) == string(prev) {
				return cur
			}
			prev = cur
		}
		t.Fatal("the still screen never stood still")
		return nil
	}
	before := settle()
	if err := c.SendKeypress(4, true); err != nil {
		t.Fatal(err)
	}
	_ = c.SendKeypress(4, false)
	after := settle()
	changed := image.Rectangle{}
	for i := range after {
		if after[i] != before[i] {
			p := image.Pt(i%320, i/320)
			changed = changed.Union(image.Rectangle{Min: p, Max: p.Add(image.Pt(1, 1))})
		}
	}
	glyph := image.Rect(glyphMargin, glyphMargin, glyphMargin+glyphWidth, glyphMargin+glyphHeight)
	if changed.Empty() || !changed.In(glyph.Inset(-16)) {
		t.Fatalf("typing changed %v, want within the glyph %v and its macroblocks", changed, glyph)
	}
}
