package emulator

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"

	"github.com/lkarlslund/jetkvm-desktop/pkg/client"
	"github.com/lkarlslund/jetkvm-desktop/pkg/protocol/auth"
	"github.com/lkarlslund/jetkvm-desktop/pkg/protocol/hidrpc"
	"github.com/lkarlslund/jetkvm-desktop/pkg/video"
)

// End-to-end checks of the engine against firmware-0.5.9 behaviour.

func startTestServer(t *testing.T, cfg Config) *Server {
	t.Helper()
	cfg.ListenAddr = "127.0.0.1:0"
	if cfg.AuthMode == AuthModeUnset {
		cfg.AuthMode = AuthModeNoPassword
	}
	srv, err := NewServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = srv.ListenAndServe(ctx)
	}()
	t.Cleanup(func() {
		cancel()
		<-done
	})
	deadline := time.Now().Add(2 * time.Second)
	for srv.BaseURL() == "" && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if srv.BaseURL() == "" {
		t.Fatal("emulator did not start")
	}
	return srv
}

func connectClient(t *testing.T, cfg client.Config) *client.Client {
	t.Helper()
	c, err := client.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := c.Connect(ctx); err != nil {
		t.Fatalf("connect: %v", err)
	}
	if err := c.WaitForHID(ctx); err != nil {
		t.Fatalf("hid: %v", err)
	}
	return c
}

func TestVoidRPCsSucceedImmediately(t *testing.T) {
	srv := startTestServer(t, Config{})
	srv.SetActiveExtension("atx-power")
	c := connectClient(t, client.Config{BaseURL: srv.BaseURL(), RPCTimeout: 3 * time.Second})

	start := time.Now()
	if err := c.SetATXPowerAction(context.Background(), "power-short"); err != nil {
		t.Fatalf("void ATX action reported failure: %v", err)
	}
	if err := c.SetDCPowerState(context.Background(), true); err != nil {
		t.Fatalf("void DC action reported failure: %v", err)
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("void RPCs took %s; they must not wait for a result that never comes", elapsed)
	}
}

func TestRPCErrorCarriesDeviceMessage(t *testing.T) {
	srv := startTestServer(t, Config{})
	c := connectClient(t, client.Config{BaseURL: srv.BaseURL()})
	err := c.SetATXPowerAction(context.Background(), "explode")
	var rpcErr *client.RPCError
	if !errors.As(err, &rpcErr) || !strings.Contains(err.Error(), "invalid action") {
		t.Fatalf("expected the device's error text, got %v", err)
	}
}

func TestPacketLossIsRepairedByNACK(t *testing.T) {
	if raceEnabled {
		t.Skip("timing-sensitive: retransmission deadlines are unrealistic under -race")
	}
	// Long GOP: without retransmission a single loss would freeze the picture
	// for the rest of the test.
	srv := startTestServer(t, Config{
		Width: 640, Height: 360, FPS: 30, GOP: 600,
		Netem: NetemConfig{DropSequence: []int{60, 61, 150, 240, 241, 242}, Latency: 15 * time.Millisecond},
	})
	var frames atomic.Int64
	c := connectClient(t, client.Config{
		BaseURL:      srv.BaseURL(),
		OnAccessUnit: func(video.AccessUnit) { frames.Add(1) },
	})

	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if _, dropped := srv.NetemStats(); dropped >= 6 && frames.Load() > 90 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	_, dropped := srv.NetemStats()
	if dropped < 6 {
		t.Fatalf("netem dropped only %d packets; test did not exercise loss", dropped)
	}
	stats := c.Stats()
	if stats.KeyframeWaits != 0 {
		t.Fatalf("losses were not repaired (keyframe waits=%d, dropped frames=%d, frames=%d)", stats.KeyframeWaits, stats.FramesDropped, frames.Load())
	}
	if frames.Load() < 90 {
		sent, dropped := srv.NetemStats()
		t.Fatalf("too few frames after repaired losses: %d (stats %+v, netem sent=%d dropped=%d)", frames.Load(), c.Stats(), sent, dropped)
	}
}

func TestConnectFailsFastWhenDeviceNeverAnswers(t *testing.T) {
	srv := startTestServer(t, Config{Faults: FaultConfig{SignalingSilent: true}})
	c, err := client.New(client.Config{BaseURL: srv.BaseURL(), ConnectTimeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	start := time.Now()
	err = c.Connect(context.Background())
	if err == nil {
		t.Fatal("connect succeeded against a silent device")
	}
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Fatalf("connect took %s, want ≈ ConnectTimeout", elapsed)
	}
}

func TestConnectSurfacesOfferRejection(t *testing.T) {
	srv := startTestServer(t, Config{Faults: FaultConfig{SignalingAnswerError: true}})
	c, err := client.New(client.Config{BaseURL: srv.BaseURL(), ConnectTimeout: 5 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	start := time.Now()
	err = c.Connect(context.Background())
	if !errors.Is(err, client.ErrOfferRejected) {
		t.Fatalf("want ErrOfferRejected, got %v", err)
	}
	if time.Since(start) > 2*time.Second {
		t.Fatal("offer rejection was not reported promptly")
	}
}

func TestReconnectReusesSessionCookie(t *testing.T) {
	srv := startTestServer(t, Config{AuthMode: AuthModePassword, Password: "secret"})
	jar, err := auth.NewClient()
	if err != nil {
		t.Fatal(err)
	}
	cfg := client.Config{BaseURL: srv.BaseURL(), Password: "secret", Auth: jar}
	first := connectClient(t, cfg)
	_ = first.Close()
	_ = connectClient(t, cfg)
	if got := srv.LoginCount(); got != 1 {
		t.Fatalf("logins = %d, want 1 (a reconnect must reuse the cookie)", got)
	}
}

func TestWrongPasswordIsAnAuthError(t *testing.T) {
	srv := startTestServer(t, Config{AuthMode: AuthModePassword, Password: "secret"})
	c, err := client.New(client.Config{BaseURL: srv.BaseURL(), Password: "nope"})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	err = c.Connect(context.Background())
	var authErr *auth.Error
	if !errors.As(err, &authErr) || authErr.StatusCode != 401 {
		t.Fatalf("want 401 auth error, got %v", err)
	}
}

func TestHeldKeySurvivesThanksToKeepAlive(t *testing.T) {
	srv := startTestServer(t, Config{})
	c := connectClient(t, client.Config{BaseURL: srv.BaseURL()})
	if err := c.SendKeypress(4, true); err != nil {
		t.Fatal(err)
	}
	time.Sleep(400 * time.Millisecond) // 4× the device's auto-release delay
	if keys := srv.State().KeysDown; keys[0] != 4 {
		t.Fatalf("held key was auto-released despite keepalives: %v", keys)
	}
	if err := c.SendKeypress(4, false); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	for _, in := range srv.Inputs() {
		if in.Type == "autoRelease" {
			t.Fatalf("unexpected auto-release: %+v", in)
		}
	}
}

func TestDeviceAutoReleasesWithoutKeepAlive(t *testing.T) {
	srv, err := NewServer(Config{})
	if err != nil {
		t.Fatal(err)
	}
	sess := &session{serverRef: srv}
	h := &hidState{sess: sess, autoRelease: map[byte]*time.Timer{}}
	press, _ := hidrpc.Keypress{Key: 4, Press: true}.MarshalBinary()
	if err := h.process(context.Background(), "hidrpc", press); err != nil {
		t.Fatal(err)
	}
	time.Sleep(2 * autoReleaseDelay)
	if keys := srv.State().KeysDown; keys[0] != 0 {
		t.Fatalf("key not auto-released after a stalled link: %v", keys)
	}
}

func TestTypeMacroIsChunkedAndWaitsForCompletion(t *testing.T) {
	srv := startTestServer(t, Config{})
	c := connectClient(t, client.Config{BaseURL: srv.BaseURL()})

	steps := make([]hidrpc.KeyboardMacroStep, 300)
	for i := range steps {
		if i%2 == 0 {
			steps[i].Keys[0] = 4
		}
		steps[i].Delay = 1
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := c.TypeMacro(ctx, steps); err != nil {
		t.Fatalf("TypeMacro: %v", err)
	}
	chunks := 0
	for _, in := range srv.Inputs() {
		if in.Type == "macroDone" {
			chunks++
		}
		if in.Type == "macroCancelled" {
			t.Fatal("a chunk cancelled its predecessor")
		}
	}
	if chunks != 3 {
		t.Fatalf("chunks completed = %d, want 3 (≤128 steps each)", chunks)
	}
}

func TestDefaultOfferNegotiatesH264(t *testing.T) {
	srv := startTestServer(t, Config{})
	_ = connectClient(t, client.Config{BaseURL: srv.BaseURL()})
	if got := srv.NegotiatedCodecs(); len(got) != 1 || got[0] != webrtc.MimeTypeH264 {
		t.Fatalf("negotiated %v, want H.264 (offering H.265 makes the device switch)", got)
	}
}

// makeClip encodes a short clip with access-unit delimiters, or skips the
// test when ffmpeg is unavailable.
func makeClip(t *testing.T, codec string) string {
	t.Helper()
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg not installed")
	}
	path := filepath.Join(t.TempDir(), "clip."+codec)
	args := []string{"-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30", "-t", "1"}
	switch codec {
	case "h264":
		args = append(args, "-c:v", "libx264", "-profile:v", "high", "-bf", "0", "-g", "15", "-bsf:v", "h264_metadata=aud=insert", "-f", "h264")
	case "h265":
		args = append(args, "-c:v", "libx265", "-x265-params", "bframes=0:keyint=15:log-level=error", "-bsf:v", "hevc_metadata=aud=insert", "-f", "hevc")
	}
	args = append(args, "-y", path)
	if out, err := exec.Command(ffmpeg, args...).CombinedOutput(); err != nil {
		t.Skipf("ffmpeg cannot encode %s: %v %s", codec, err, out)
	}
	if info, err := os.Stat(path); err != nil || info.Size() == 0 {
		t.Skip("ffmpeg produced no clip")
	}
	return path
}

func collectUnits(t *testing.T, cfg client.Config, want func([]video.AccessUnit) bool) []video.AccessUnit {
	t.Helper()
	var mu sync.Mutex
	var units []video.AccessUnit
	cfg.OnAccessUnit = func(au video.AccessUnit) {
		mu.Lock()
		units = append(units, au)
		mu.Unlock()
	}
	_ = connectClient(t, cfg)
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		done := want(units)
		mu.Unlock()
		if done {
			break
		}
		time.Sleep(25 * time.Millisecond)
	}
	mu.Lock()
	defer mu.Unlock()
	return append([]video.AccessUnit(nil), units...)
}

func TestH265ReplayReachesAccessUnitConsumer(t *testing.T) {
	clip := makeClip(t, "h265")
	srv := startTestServer(t, Config{FPS: 30, ReplayH265: clip})
	units := collectUnits(t, client.Config{BaseURL: srv.BaseURL(), OfferH265: true}, func(u []video.AccessUnit) bool { return len(u) >= 20 })
	if got := srv.NegotiatedCodecs(); len(got) != 1 || got[0] != webrtc.MimeTypeH265 {
		t.Fatalf("negotiated %v, want H.265", got)
	}
	if len(units) < 20 {
		t.Fatalf("received %d H.265 access units", len(units))
	}
	if units[0].Codec != video.CodecH265 || !units[0].Keyframe {
		t.Fatalf("first unit must be an H.265 keyframe: %+v", units[0].Codec)
	}
}

func TestH264HighProfileReplayDecodes(t *testing.T) {
	clip := makeClip(t, "h264")
	srv := startTestServer(t, Config{FPS: 30, ReplayH264: clip})
	c := connectClient(t, client.Config{BaseURL: srv.BaseURL()})
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if img, _ := c.LatestFrameInfo(); img != nil {
			if b := img.Bounds(); b.Dx() != 320 || b.Dy() != 240 {
				t.Fatalf("decoded %v, want 320x240", b)
			}
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("no High-profile frame decoded")
}

func TestBurnedTimestampRoundTrips(t *testing.T) {
	img := newPatternFrame(640, 360, 7)
	at := time.UnixMilli(1760000000123)
	burnTimestamp(img, at)
	got, ok := BurnedTimestamp(img.Y, img.YStride, 640, 360)
	if !ok || !got.Equal(at) {
		t.Fatalf("barcode decoded %v ok=%v, want %v", got, ok, at)
	}
}
