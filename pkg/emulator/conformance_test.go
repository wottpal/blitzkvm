package emulator

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
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
	"github.com/lkarlslund/jetkvm-desktop/pkg/video/openh264"
)

// End-to-end checks of the engine against firmware-0.5.9 behaviour.

func startTestServer(t *testing.T, cfg Config) *Server {
	t.Helper()
	cfg.ListenAddr = "127.0.0.1:0"
	cfg.ICELoopbackOnly = true
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
	cfg.ICELoopbackOnly = true
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

// A wait for a keyframe must ask for one: the patched firmware sends them
// only on request (or once a minute).
func TestRequestKeyframeGetsAnIDR(t *testing.T) {
	srv := startTestServer(t, Config{Width: 640, Height: 360, FPS: 30, GOP: 1800, KeyframeOnRequest: true})
	var keyframes atomic.Int64
	c := connectClient(t, client.Config{
		BaseURL: srv.BaseURL(),
		OnAccessUnit: func(au video.AccessUnit) {
			if au.Keyframe {
				keyframes.Add(1)
			}
		},
	})
	waitFor := func(n int64, within time.Duration) bool {
		deadline := time.Now().Add(within)
		for keyframes.Load() < n && time.Now().Before(deadline) {
			time.Sleep(10 * time.Millisecond)
		}
		return keyframes.Load() >= n
	}
	if !waitFor(1, 10*time.Second) {
		t.Fatal("no initial keyframe")
	}
	c.RequestKeyframe()
	if !waitFor(2, time.Second) {
		t.Fatalf("no keyframe within 1 s of a request (keyframes=%d)", keyframes.Load())
	}
}

func TestConnectFailsFastWhenDeviceNeverAnswers(t *testing.T) {
	srv := startTestServer(t, Config{Faults: FaultConfig{SignalingSilent: true}})
	c, err := client.New(client.Config{ICELoopbackOnly: true, BaseURL: srv.BaseURL(), ConnectTimeout: time.Second})
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
	c, err := client.New(client.Config{ICELoopbackOnly: true, BaseURL: srv.BaseURL(), ConnectTimeout: 5 * time.Second})
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
	c, err := client.New(client.Config{ICELoopbackOnly: true, BaseURL: srv.BaseURL(), Password: "nope"})
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

// A second hold after a pause must get fresh keepalive timing: stale
// timestamps from the first hold would make the device ignore keepalives and
// release the key.
func TestSecondHoldSurvivesThanksToKeepAlive(t *testing.T) {
	srv, err := NewServer(Config{})
	if err != nil {
		t.Fatal(err)
	}
	h := &hidState{sess: &session{serverRef: srv}, autoRelease: map[byte]*time.Timer{}}
	key := func(press bool) {
		t.Helper()
		msg, _ := hidrpc.Keypress{Key: 4, Press: press}.MarshalBinary()
		if err := h.process(context.Background(), "hidrpc", msg); err != nil {
			t.Fatal(err)
		}
	}
	key(true)
	h.keepAlive(time.Now())
	key(false)
	time.Sleep(3 * keepAliveMaxStale) // idle between holds

	key(true)
	for range 8 { // 400 ms, 4× the auto-release delay
		time.Sleep(keepAliveRate)
		h.keepAlive(time.Now())
	}
	if keys := srv.State().KeysDown; keys[0] != 4 {
		t.Fatalf("second hold was auto-released despite keepalives: %v", keys)
	}
	key(false)
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
	// The assembler only starts at a keyframe; check that it really is a
	// decodable start and that later keyframes are recognised too.
	if units[0].Codec != video.CodecH265 || !video.HasParameterSets(video.CodecH265, units[0].Data) {
		t.Fatalf("first unit must be an H.265 keyframe with VPS/SPS/PPS: %+v", units[0].Codec)
	}
	keyframes := 0
	for _, au := range units {
		if au.Keyframe {
			keyframes++
		}
	}
	// The clip has a keyframe every 15 frames: not one, and not every unit
	// (which a misclassified NAL type would cause).
	if maxKeyframes := len(units)/15 + 2; keyframes < 2 || keyframes > maxKeyframes {
		t.Fatalf("%d keyframes in %d units, want 2..%d", keyframes, len(units), maxKeyframes)
	}
}

func TestH264HighProfileReplayDecodes(t *testing.T) {
	clip := makeClip(t, "h264")
	srv := startTestServer(t, Config{FPS: 30, ReplayH264: clip})
	c := connectClient(t, client.Config{BaseURL: srv.BaseURL(), NewVideoSink: openh264.NewSink})
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

func TestDeviceInfoNeedsLogin(t *testing.T) {
	srv := startTestServer(t, Config{AuthMode: AuthModePassword, Password: "secret"})
	hc := &http.Client{Transport: &http.Transport{DisableKeepAlives: true}}
	resp, err := hc.Get(srv.BaseURL() + "/device")
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("GET /device without login = %d, want 401 (protected upstream)", resp.StatusCode)
	}
	resp, err = hc.Get(srv.BaseURL() + "/device/status")
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /device/status = %d, want 200 (public)", resp.StatusCode)
	}
}

// With a still-valid cookie (or no password) the identity is checked before
// any login, so the stored password never reaches the wrong device.
func TestConnectRefusesADifferentDeviceBeforeLogin(t *testing.T) {
	srv := startTestServer(t, Config{AuthMode: AuthModePassword, Password: "secret"})
	jar, err := auth.NewClient()
	if err != nil {
		t.Fatal(err)
	}
	first := connectClient(t, client.Config{BaseURL: srv.BaseURL(), Password: "secret", Auth: jar, ExpectedDeviceID: "emu-jetkvm-001"})
	if err := first.VerifyIdentity(context.Background()); err != nil {
		t.Fatalf("right device rejected: %v", err)
	}
	_ = first.Close()

	c, err := client.New(client.Config{ICELoopbackOnly: true, BaseURL: srv.BaseURL(), Password: "secret", Auth: jar, ExpectedDeviceID: "some-other-device"})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if err := c.Connect(context.Background()); !errors.Is(err, client.ErrDeviceMismatch) {
		t.Fatalf("want ErrDeviceMismatch, got %v", err)
	}
	if got := srv.LoginCount(); got != 1 {
		t.Fatalf("logins = %d, want 1: the password was sent to the wrong device", got)
	}
}

// Without a cookie, password-protected firmware answers GET /device only
// after login, so the check happens over RPC before any input.
func TestConnectRefusesADifferentDeviceAfterLogin(t *testing.T) {
	srv := startTestServer(t, Config{AuthMode: AuthModePassword, Password: "secret"})
	c := connectClient(t, client.Config{BaseURL: srv.BaseURL(), Password: "secret", ExpectedDeviceID: "some-other-device"})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.VerifyIdentity(ctx); !errors.Is(err, client.ErrDeviceMismatch) {
		t.Fatalf("want ErrDeviceMismatch, got %v", err)
	}
}

// Every client setter must send the parameter names the firmware binds
// (a wrong name fails on the device with "missing parameter").
func TestClientSendsFirmwareParameterNames(t *testing.T) {
	srv := startTestServer(t, Config{})
	c := connectClient(t, client.Config{BaseURL: srv.BaseURL()})
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	calls := map[string]func() error{
		"SetStreamQualityFactor":  func() error { return c.SetStreamQualityFactor(ctx, 1) },
		"SetKeyboardLayout":       func() error { return c.SetKeyboardLayout(ctx, "en-US") },
		"SetEDID":                 func() error { return c.SetEDID(ctx, "") },
		"SetATXPowerAction":       func() error { return c.SetATXPowerAction(ctx, "power-short") },
		"SetActiveExtension":      func() error { return c.SetActiveExtension(ctx, "") },
		"SetDCPowerState":         func() error { return c.SetDCPowerState(ctx, false) },
		"SetDCRestoreState":       func() error { return c.SetDCRestoreState(ctx, 0) },
		"SetSerialSettings":       func() error { return c.SetSerialSettings(ctx, client.SerialSettings{}) },
		"SetSerialCommandHistory": func() error { return c.SetSerialCommandHistory(ctx, nil) },
		"SendCustomCommand":       func() error { return c.SendCustomCommand(ctx, "") },
		"SetVideoCodecPreference": func() error { return c.SetVideoCodecPreference(ctx, "auto") },
		"GetPublicIPAddresses":    func() error { _, err := c.GetPublicIPAddresses(ctx, false); return err },
		"SetBacklightSettings":    func() error { return c.SetBacklightSettings(ctx, client.BacklightSettings{}) },
		"SetVideoSleepMode":       func() error { return c.SetVideoSleepMode(ctx, 0) },
		"SetMQTTSettings":         func() error { return c.SetMQTTSettings(ctx, client.MQTTSettings{}) },
		"TestMQTTConnection":      func() error { _, err := c.TestMQTTConnection(ctx, client.MQTTSettings{}); return err },
		"SetAutoUpdateState":      func() error { return c.SetAutoUpdateState(ctx, false) },
		"SetNetworkSettings":      func() error { return c.SetNetworkSettings(ctx, client.NetworkSettings{}) },
		"SetTLSState":             func() error { return c.SetTLSState(ctx, client.TLSState{}) },
		"SetUSBDevices":           func() error { return c.SetUSBDevices(ctx, client.USBDevices{Keyboard: true, AbsoluteMouse: true}) },
		"SetDisplayRotation":      func() error { return c.SetDisplayRotation(ctx, "270") },
		"SetDevChannelState":      func() error { return c.SetDevChannelState(ctx, false) },
		"SetLocalLoopbackOnly":    func() error { return c.SetLocalLoopbackOnly(ctx, false) },
		"SetSSHKeyState":          func() error { return c.SetSSHKeyState(ctx, "") },
		"SetKeyboardMacros":       func() error { return c.SetKeyboardMacros(ctx, nil) },
		"SetDeveloperModeState":   func() error { return c.SetDeveloperModeState(ctx, false) },
		"SetJigglerState":         func() error { return c.SetJigglerState(ctx, false) },
		"SetJigglerConfig":        func() error { return c.SetJigglerConfig(ctx, client.JigglerConfig{}) },
		"MountMediaURL":           func() error { return c.MountMediaURL(ctx, "http://127.0.0.1:1/x.iso", "CDROM") },
		"UnmountMedia":            func() error { return c.UnmountMedia(ctx) },
		"DeleteStorageFile":       func() error { return c.DeleteStorageFile(ctx, "none.iso") },
		"MountStorageFile":        func() error { return c.MountStorageFile(ctx, "none.iso", "CDROM") },
		"StartStorageFileUpload":  func() error { _, err := c.StartStorageFileUpload(ctx, "x.iso", 1); return err },
		// Last: it may switch USB emulation off.
	}
	defer func() {
		if err := c.SetUSBEmulationState(ctx, true); err != nil && strings.Contains(err.Error(), "missing parameter") {
			t.Errorf("SetUSBEmulationState: %v", err)
		}
	}()
	// Reboot is not called (it takes the emulator offline); check its
	// request shape directly.
	if raw, _ := json.Marshal(client.RebootRequest{}); !strings.Contains(string(raw), `"force"`) {
		t.Errorf("reboot request %s lacks \"force\"", raw)
	}
	for name, call := range calls {
		if err := call(); err != nil && strings.Contains(err.Error(), "missing parameter") {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestMissingRPCParameterIsAnInternalError(t *testing.T) {
	srv := startTestServer(t, Config{})
	c := connectClient(t, client.Config{BaseURL: srv.BaseURL()})
	err := c.Call(context.Background(), "setStreamQualityFactor", map[string]any{"quality": 0.5}, nil)
	var rpcErr *client.RPCError
	if !errors.As(err, &rpcErr) || rpcErr.Code != -32603 || rpcErr.Data != "missing parameter: factor" {
		t.Fatalf("want -32603 missing parameter: factor, got %v", err)
	}
}

func TestSeventhKeyRollsOver(t *testing.T) {
	srv, err := NewServer(Config{})
	if err != nil {
		t.Fatal(err)
	}
	for key := byte(4); key < 11; key++ {
		srv.applyKeypress(key, true)
	}
	if keys := srv.State().KeysDown; !bytes.Equal(keys, make([]byte, 6)) {
		t.Fatalf("7 keys down = %v, want ErrorRollOver then all released", keys)
	}
	rolled := false
	for _, in := range srv.Inputs() {
		rolled = rolled || in.Type == "rollover"
	}
	if !rolled {
		t.Fatal("rollover not recorded")
	}
}

func TestKeysDownStateUsesFirmwareJSON(t *testing.T) {
	srv := startTestServer(t, Config{})
	c := connectClient(t, client.Config{BaseURL: srv.BaseURL()})
	var raw json.RawMessage
	if err := c.Call(context.Background(), "getKeyDownState", nil, &raw); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"keys":[0,0,0,0,0,0]`) {
		t.Fatalf("getKeyDownState = %s, want keys as a number array (as firmware)", raw)
	}
	if _, err := c.GetKeyDownState(context.Background()); err != nil {
		t.Fatalf("client cannot decode the firmware shape: %v", err)
	}
}

// A pinned device's password must not go to a host that answers 401 but is
// not a JetKVM (the address now belongs to a router, a camera, ...).
func TestPasswordNotSentToANonJetKVM(t *testing.T) {
	var logins atomic.Int32
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/auth/login-local" {
			logins.Add(1)
		}
		http.Error(w, "unauthorized", http.StatusUnauthorized)
	}))
	defer other.Close()
	c, err := client.New(client.Config{ICELoopbackOnly: true, BaseURL: other.URL, Password: "secret", ExpectedDeviceID: "emu-jetkvm-001"})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	err = c.Connect(context.Background())
	if !errors.Is(err, client.ErrDeviceMismatch) {
		t.Fatalf("want ErrDeviceMismatch, got %v", err)
	}
	if logins.Load() != 0 {
		t.Fatal("the password was sent to a host that is not a JetKVM")
	}
}
