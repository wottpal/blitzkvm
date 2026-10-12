package session

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/wottpal/blitzkvm/pkg/client"
	"github.com/wottpal/blitzkvm/pkg/emulator"
	"github.com/wottpal/blitzkvm/pkg/protocol/auth"
	"github.com/wottpal/blitzkvm/pkg/protocol/tlspin"
	"github.com/wottpal/blitzkvm/pkg/video/openh264"
	"github.com/wottpal/blitzkvm/pkg/virtualmedia"
)

func TestControllerConnects(t *testing.T) {
	srv, ctx, cancel := startEmulator(t)
	defer cancel()

	controller := New(Config{
		BaseURL:         srv.BaseURL(),
		ICELoopbackOnly: true,
		Password:        "secret",
		RPCTimeout:      2 * time.Second,
		Reconnect:       true,
	})
	controller.Start(ctx)
	defer controller.Stop()

	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
	snapshot := controller.Snapshot()
	if snapshot.DeviceID == "" {
		t.Fatal("expected device ID after bootstrap")
	}
	if !snapshot.HIDReady {
		t.Fatal("expected HID to be ready")
	}
	if snapshot.SignalingMode != client.SignalingModeWebSocket {
		t.Fatalf("expected websocket signaling mode, got %v", snapshot.SignalingMode)
	}
}

// Without ICELoopbackOnly, ICE follows the route to the device's address
// (here loopback) and reports the path it took.
func TestControllerPinsICEToRoute(t *testing.T) {
	srv, ctx, cancel := startEmulator(t)
	defer cancel()

	controller := New(Config{BaseURL: srv.BaseURL(), Password: "secret", RPCTimeout: 2 * time.Second})
	controller.Start(ctx)
	defer controller.Stop()

	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
	deadline := time.Now().Add(5 * time.Second)
	for controller.Stats().Path == "" && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	if stats := controller.Stats(); stats.Path != client.PathLoopback || stats.PathRemote != "127.0.0.1" {
		t.Fatalf("path = %q via %q, want loopback via 127.0.0.1", stats.Path, stats.PathRemote)
	}
}

func TestControllerReconnectsAfterDisconnect(t *testing.T) {
	srv, ctx, cancel := startEmulator(t)
	defer cancel()

	controller := New(Config{
		BaseURL:         srv.BaseURL(),
		ICELoopbackOnly: true,
		Password:        "secret",
		RPCTimeout:      2 * time.Second,
		Reconnect:       true,
		ReconnectBase:   100 * time.Millisecond,
		ReconnectMax:    300 * time.Millisecond,
	})
	controller.Start(ctx)
	defer controller.Stop()

	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
	sessions := srv.SessionCount()
	srv.DisconnectSession()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) && (srv.SessionCount() <= sessions || controller.Snapshot().Phase != PhaseConnected) {
		time.Sleep(25 * time.Millisecond)
	}
	if srv.SessionCount() <= sessions {
		t.Fatalf("controller did not reconnect after the device dropped the session: %+v", controller.Snapshot())
	}
	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
}

func TestControllerTransitionsToOtherSession(t *testing.T) {
	srv, ctx, cancel := startEmulator(t)
	defer cancel()

	first := New(Config{
		BaseURL:         srv.BaseURL(),
		ICELoopbackOnly: true,
		Password:        "secret",
		RPCTimeout:      2 * time.Second,
		Reconnect:       true,
	})
	second := New(Config{
		BaseURL:         srv.BaseURL(),
		ICELoopbackOnly: true,
		Password:        "secret",
		RPCTimeout:      2 * time.Second,
		Reconnect:       true,
	})
	first.Start(ctx)
	defer first.Stop()
	waitForPhase(t, first, PhaseConnected, 5*time.Second)

	second.Start(ctx)
	defer second.Stop()
	waitForPhase(t, second, PhaseConnected, 5*time.Second)
	waitForPhase(t, first, PhaseOtherSession, 5*time.Second)

	first.ReconnectNow()
	waitForPhase(t, first, PhaseConnected, 5*time.Second)
}

func TestControllerReceivesVideoAndForwardsInput(t *testing.T) {
	srv, ctx, cancel := startEmulator(t)
	defer cancel()

	controller := New(Config{
		BaseURL:         srv.BaseURL(),
		ICELoopbackOnly: true,
		Password:        "secret",
		RPCTimeout:      2 * time.Second,
		Reconnect:       true,
		NewVideoSink:    openh264.NewSink,
	})
	controller.Start(ctx)
	defer controller.Stop()

	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
	waitForFrame(t, controller, 5*time.Second)

	if err := controller.SendKeypress(4, true); err != nil {
		t.Fatal(err)
	}
	if err := controller.SendAbsPointer(1200, 3400, 1); err != nil {
		t.Fatal(err)
	}
	if err := controller.SendRelMouse(5, -3, 1); err != nil {
		t.Fatal(err)
	}
	if err := controller.SendWheel(-1, 0); err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		inputs := srv.Inputs()
		if len(inputs) < 4 {
			time.Sleep(25 * time.Millisecond)
			continue
		}
		foundKeypress := false
		foundPointer := false
		foundMouse := false
		foundWheel := false
		for _, input := range inputs {
			switch {
			case strings.Contains(input.Type, "Keypress"):
				foundKeypress = true
			case strings.Contains(input.Type, "Pointer"):
				foundPointer = true
			case strings.Contains(input.Type, "Mouse"):
				foundMouse = true
			case input.Type == "rpc.wheelReport" && strings.Contains(input.Data, "wheelY=-1") && strings.Contains(input.Data, "wheelX=0"):
				foundWheel = true
			}
		}
		if foundKeypress && foundPointer && foundMouse && foundWheel {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("expected keypress, pointer, mouse, and wheel inputs, got %+v", srv.Inputs())
}

func TestSerialScrollbackTrimsOldContent(t *testing.T) {
	var log serialScrollback
	var text string
	var truncated bool
	for i := 0; i < serialScrollbackMaxLines+10; i++ {
		text, truncated = log.Append(fmt.Sprintf("line-%d\n", i))
	}
	if !truncated {
		t.Fatal("expected scrollback to report truncation")
	}
	if strings.Contains(text, "line-0\n") {
		t.Fatal("expected oldest lines to be dropped from scrollback")
	}
	if !strings.Contains(text, fmt.Sprintf("line-%d\n", serialScrollbackMaxLines+9)) {
		t.Fatal("expected newest lines to remain in scrollback")
	}
}

func TestControllerSetQualitySucceedsWhenWriteAckIsDropped(t *testing.T) {
	srv, ctx, cancel := startFaultedEmulator(t, emulator.FaultConfig{
		ApplyButDropRPCMethod: "setStreamQualityFactor",
	})
	defer cancel()

	controller := New(Config{
		BaseURL:         srv.BaseURL(),
		ICELoopbackOnly: true,
		Password:        "secret",
		RPCTimeout:      300 * time.Millisecond,
		MutationTimeout: 2 * time.Second,
		Reconnect:       true,
	})
	controller.Start(ctx)
	defer controller.Stop()

	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
	if err := controller.SetQuality(0.5); err != nil {
		t.Fatalf("SetQuality returned error: %v", err)
	}
	if got := controller.Snapshot().Quality; got != 0.5 {
		t.Fatalf("snapshot quality = %v, want 0.5", got)
	}
}

func TestControllerSetKeyboardLayoutSucceedsWhenWriteAckIsDropped(t *testing.T) {
	srv, ctx, cancel := startFaultedEmulator(t, emulator.FaultConfig{
		ApplyButDropRPCMethod: "setKeyboardLayout",
	})
	defer cancel()

	controller := New(Config{
		BaseURL:         srv.BaseURL(),
		ICELoopbackOnly: true,
		Password:        "secret",
		RPCTimeout:      300 * time.Millisecond,
		MutationTimeout: 2 * time.Second,
		Reconnect:       true,
	})
	controller.Start(ctx)
	defer controller.Stop()

	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
	if err := controller.SetKeyboardLayout("da-DK"); err != nil {
		t.Fatalf("SetKeyboardLayout returned error: %v", err)
	}
	if got := controller.Snapshot().KeyboardLayout; got != "da-DK" {
		t.Fatalf("snapshot keyboard layout = %q, want da-DK", got)
	}
}

func TestControllerSetUSBDevicesSucceedsWhenWriteAckIsDropped(t *testing.T) {
	srv, ctx, cancel := startFaultedEmulator(t, emulator.FaultConfig{
		ApplyButDropRPCMethod: "setUsbDevices",
	})
	defer cancel()

	controller := New(Config{
		BaseURL:         srv.BaseURL(),
		ICELoopbackOnly: true,
		Password:        "secret",
		RPCTimeout:      300 * time.Millisecond,
		MutationTimeout: 2 * time.Second,
		Reconnect:       true,
	})
	controller.Start(ctx)
	defer controller.Stop()

	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
	want := USBDevices{
		Keyboard:      true,
		AbsoluteMouse: false,
		RelativeMouse: false,
		MassStorage:   false,
		SerialConsole: true,
		Network:       false,
	}
	if err := controller.SetUSBDevices(want); err != nil {
		t.Fatalf("SetUSBDevices returned error: %v", err)
	}
	got, err := controller.GetUSBDevices(context.Background())
	if err != nil {
		t.Fatalf("GetUSBDevices returned error: %v", err)
	}
	if got != want {
		t.Fatalf("usb devices = %+v, want %+v", got, want)
	}
}

func TestControllerATXStateAndActions(t *testing.T) {
	srv, ctx, cancel := startEmulator(t)
	defer cancel()
	srv.SetActiveExtension("atx-power")
	srv.SetATXState(true, false)

	controller := New(Config{
		BaseURL:         srv.BaseURL(),
		ICELoopbackOnly: true,
		Password:        "secret",
		RPCTimeout:      2 * time.Second,
		Reconnect:       true,
	})
	controller.Start(ctx)
	defer controller.Stop()

	waitForPhase(t, controller, PhaseConnected, 5*time.Second)

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		snap := controller.Snapshot()
		if snap.ActiveExtension == "atx-power" && snap.ATXState != nil && snap.ATXState.Power && !snap.ATXState.HDD {
			break
		}
		time.Sleep(25 * time.Millisecond)
	}
	snap := controller.Snapshot()
	if snap.ActiveExtension != "atx-power" {
		t.Fatalf("active extension = %q, want atx-power", snap.ActiveExtension)
	}
	if snap.ATXState == nil || !snap.ATXState.Power || snap.ATXState.HDD {
		t.Fatalf("ATX state = %+v, want power=true hdd=false", snap.ATXState)
	}

	gotState, err := controller.GetATXState(context.Background())
	if err != nil {
		t.Fatalf("GetATXState returned error: %v", err)
	}
	if gotState == nil || !gotState.Power || gotState.HDD {
		t.Fatalf("GetATXState = %+v, want power=true hdd=false", gotState)
	}

	if err := controller.SetATXPowerAction(ATXPowerActionReset); err != nil {
		t.Fatalf("SetATXPowerAction returned error: %v", err)
	}

	deadline = time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		for _, input := range srv.Inputs() {
			if input.Type == "rpc.setATXPowerAction" && input.Data == "reset" {
				return
			}
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("expected reset ATX action in inputs, got %+v", srv.Inputs())
}

func TestControllerSetActiveExtension(t *testing.T) {
	srv, ctx, cancel := startEmulator(t)
	defer cancel()

	controller := New(Config{
		BaseURL:         srv.BaseURL(),
		ICELoopbackOnly: true,
		Password:        "secret",
		RPCTimeout:      2 * time.Second,
		Reconnect:       true,
	})
	controller.Start(ctx)
	defer controller.Stop()

	waitForPhase(t, controller, PhaseConnected, 5*time.Second)

	if err := controller.SetActiveExtension("dc-power"); err != nil {
		t.Fatalf("SetActiveExtension returned error: %v", err)
	}
	got, err := controller.GetActiveExtension(context.Background())
	if err != nil {
		t.Fatalf("GetActiveExtension returned error: %v", err)
	}
	if got != "dc-power" {
		t.Fatalf("active extension = %q, want dc-power", got)
	}
}

func TestControllerDCAndSerialExtensionRPCs(t *testing.T) {
	srv, ctx, cancel := startEmulator(t)
	defer cancel()

	controller := New(Config{
		BaseURL:         srv.BaseURL(),
		ICELoopbackOnly: true,
		Password:        "secret",
		RPCTimeout:      2 * time.Second,
		Reconnect:       true,
	})
	controller.Start(ctx)
	defer controller.Stop()

	waitForPhase(t, controller, PhaseConnected, 5*time.Second)

	dcState, err := controller.GetDCPowerState(context.Background())
	if err != nil {
		t.Fatalf("GetDCPowerState returned error: %v", err)
	}
	if dcState == nil {
		t.Fatal("expected DC state")
	}
	if err := controller.SetDCPowerState(true); err != nil {
		t.Fatalf("SetDCPowerState returned error: %v", err)
	}
	if err := controller.SetDCRestoreState(1); err != nil {
		t.Fatalf("SetDCRestoreState returned error: %v", err)
	}

	serialSettings, err := controller.GetSerialSettings(context.Background())
	if err != nil {
		t.Fatalf("GetSerialSettings returned error: %v", err)
	}
	if serialSettings == nil || serialSettings.BaudRate == 0 {
		t.Fatalf("unexpected serial settings: %+v", serialSettings)
	}
	if err := controller.SendCustomCommand("help\n"); err != nil {
		t.Fatalf("SendCustomCommand returned error: %v", err)
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		foundDC := false
		foundRestore := false
		foundSerial := false
		for _, input := range srv.Inputs() {
			switch {
			case input.Type == "rpc.setDCPowerState" && strings.Contains(input.Data, "enabled=true"):
				foundDC = true
			case input.Type == "rpc.setDCRestoreState" && strings.Contains(input.Data, "state=1"):
				foundRestore = true
			case input.Type == "rpc.sendCustomCommand" && input.Data == "help\n":
				foundSerial = true
			}
		}
		if foundDC && foundRestore && foundSerial {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("expected dc/serial inputs, got %+v", srv.Inputs())
}

func TestControllerVirtualMediaURLMountAndUnmount(t *testing.T) {
	srv, ctx, cancel := startEmulator(t)
	defer cancel()

	controller := New(Config{
		BaseURL:         srv.BaseURL(),
		ICELoopbackOnly: true,
		Password:        "secret",
		RPCTimeout:      2 * time.Second,
		Reconnect:       true,
	})
	controller.Start(ctx)
	defer controller.Stop()

	waitForPhase(t, controller, PhaseConnected, 5*time.Second)

	// The device reads the image on demand, so it needs byte ranges.
	image := strings.Repeat("I", 4096)
	ranged := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "debian.iso", time.Time{}, strings.NewReader(image))
	}))
	defer ranged.Close()
	plain := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(image))
	}))
	defer plain.Close()

	if err := controller.MountMediaURL(plain.URL+"/debian.iso", virtualmedia.ModeCDROM); err == nil || !strings.Contains(err.Error(), "byte-range") {
		t.Fatalf("a server without byte ranges must be refused with a reason, got %v", err)
	}
	imageURL := ranged.URL + "/debian.iso"
	if err := controller.MountMediaURL(imageURL, virtualmedia.ModeCDROM); err != nil {
		t.Fatalf("MountMediaURL returned error: %v", err)
	}
	state, err := controller.GetVirtualMediaState(context.Background())
	if err != nil {
		t.Fatalf("GetVirtualMediaState returned error: %v", err)
	}
	if state == nil || state.Source != virtualmedia.SourceHTTP || state.URL != imageURL || state.Size != int64(len(image)) {
		t.Fatalf("unexpected media state: %+v", state)
	}

	if err := controller.UnmountMedia(); err != nil {
		t.Fatalf("UnmountMedia returned error: %v", err)
	}
	state, err = controller.GetVirtualMediaState(context.Background())
	if err != nil {
		t.Fatalf("GetVirtualMediaState after unmount returned error: %v", err)
	}
	if state != nil {
		t.Fatalf("expected media to be unmounted, got %+v", state)
	}
}

func TestControllerLocalPasswordLifecycle(t *testing.T) {
	srv, err := emulator.NewServer(emulator.Config{
		ListenAddr: "127.0.0.1:0",
		AuthMode:   emulator.AuthModeNoPassword,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	errCh := make(chan error, 1)
	go func() {
		errCh <- srv.ListenAndServe(ctx)
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case err := <-errCh:
			if err != nil && ctx.Err() == nil {
				t.Errorf("server: %v", err)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("server did not shut down")
		}
	})
	deadline := time.Now().Add(2 * time.Second)
	for srv.BaseURL() == "" && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if srv.BaseURL() == "" {
		t.Fatal("server did not start")
	}

	controller := New(Config{
		BaseURL:         srv.BaseURL(),
		ICELoopbackOnly: true,
		RPCTimeout:      2 * time.Second,
		Reconnect:       true,
	})
	controller.Start(ctx)
	defer controller.Stop()

	waitForPhase(t, controller, PhaseConnected, 5*time.Second)

	mode, _, err := controller.GetLocalAccessState(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if mode != LocalAuthModeNoPassword {
		t.Fatalf("initial auth mode = %v, want noPassword", mode)
	}

	if err := controller.CreateLocalPassword("password123"); err != nil {
		t.Fatal(err)
	}
	mode, _, err = controller.GetLocalAccessState(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if mode != LocalAuthModePassword {
		t.Fatalf("auth mode after create = %v, want password", mode)
	}

	if err := controller.UpdateLocalPassword("password123", "password456"); err != nil {
		t.Fatal(err)
	}
	controller.SetPassword("password456")
	if err := controller.DeleteLocalPassword("password456"); err != nil {
		t.Fatal(err)
	}
	mode, _, err = controller.GetLocalAccessState(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if mode != LocalAuthModeNoPassword {
		t.Fatalf("auth mode after delete = %v, want noPassword", mode)
	}
}

func TestControllerUploadAndMountStorageFile(t *testing.T) {
	srv, ctx, cancel := startEmulator(t)
	defer cancel()

	controller := New(Config{
		BaseURL:         srv.BaseURL(),
		ICELoopbackOnly: true,
		Password:        "secret",
		RPCTimeout:      2 * time.Second,
		Reconnect:       true,
	})
	controller.Start(ctx)
	defer controller.Stop()

	waitForPhase(t, controller, PhaseConnected, 5*time.Second)

	tempDir := t.TempDir()
	imagePath := filepath.Join(tempDir, "test.iso")
	if err := os.WriteFile(imagePath, []byte("virtual-media-test-image"), 0o644); err != nil {
		t.Fatal(err)
	}
	progressCalls := 0
	if err := controller.UploadStorageFile(imagePath, func(progress virtualmedia.UploadProgress) {
		progressCalls++
		if progress.Total <= 0 {
			t.Fatalf("expected upload total to be positive, got %+v", progress)
		}
	}); err != nil {
		t.Fatalf("UploadStorageFile returned error: %v", err)
	}
	if progressCalls == 0 {
		t.Fatal("expected upload progress callback to run")
	}

	files, err := controller.ListStorageFiles(context.Background())
	if err != nil {
		t.Fatalf("ListStorageFiles returned error: %v", err)
	}
	found := false
	for _, file := range files {
		if file.Filename == "test.iso" {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected uploaded file in storage list, got %+v", files)
	}

	if err := controller.MountStorageFile("test.iso", virtualmedia.ModeCDROM); err != nil {
		t.Fatalf("MountStorageFile returned error: %v", err)
	}
	state, err := controller.GetVirtualMediaState(context.Background())
	if err != nil {
		t.Fatalf("GetVirtualMediaState returned error: %v", err)
	}
	if state == nil || state.Source != virtualmedia.SourceStorage || state.Filename != "test.iso" {
		t.Fatalf("unexpected mounted storage state: %+v", state)
	}
}

func TestIsAuthErrorMatchesDeviceMessages(t *testing.T) {
	tests := []error{
		&auth.Error{StatusCode: 401, Message: "Invalid password"},
		&auth.Error{StatusCode: 403, Message: "Forbidden"},
		&auth.Error{StatusCode: 429, Message: "Too many failed attempts"},
		errors.New("authentication failed"),
	}
	for _, err := range tests {
		if !isAuthError(err) {
			t.Fatalf("expected %v to be treated as auth error", err)
		}
	}
	if isAuthError(errors.New("connection reset by peer")) {
		t.Fatal("expected transport error to not be treated as auth error")
	}
}

func startEmulator(t *testing.T) (*emulator.Server, context.Context, context.CancelFunc) {
	t.Helper()
	return startFaultedEmulator(t, emulator.FaultConfig{})
}

func startFaultedEmulator(t *testing.T, faults emulator.FaultConfig) (*emulator.Server, context.Context, context.CancelFunc) {
	t.Helper()
	return startEmulatorWith(t, emulator.Config{Faults: faults})
}

// startEmulatorWith starts a password-protected, loopback-only emulator.
func startEmulatorWith(t *testing.T, cfg emulator.Config) (*emulator.Server, context.Context, context.CancelFunc) {
	t.Helper()
	cfg.ListenAddr = "127.0.0.1:0"
	cfg.AuthMode = emulator.AuthModePassword
	cfg.Password = "secret"
	cfg.ICELoopbackOnly = true
	srv, err := emulator.NewServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	errCh := make(chan error, 1)
	t.Cleanup(func() {
		cancel()
		select {
		case err := <-errCh:
			if err != nil && ctx.Err() == nil {
				t.Errorf("server: %v", err)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("server did not shut down")
		}
	})
	go func() {
		errCh <- srv.ListenAndServe(ctx)
	}()
	deadline := time.Now().Add(2 * time.Second)
	for srv.BaseURL() == "" && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if srv.BaseURL() == "" {
		t.Fatal("server did not start")
	}
	return srv, ctx, cancel
}

func waitForPhase(t *testing.T, controller *Controller, phase Phase, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if controller.Snapshot().Phase == phase {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for phase %v, got %+v", phase, controller.Snapshot())
}

func waitForFrame(t *testing.T, controller *Controller, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if controller.LatestFrame() != nil {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("timed out waiting for first video frame")
}

func TestBackoffNeverOverflowsAndStaysBounded(t *testing.T) {
	base, maxDelay := 500*time.Millisecond, 10*time.Second
	for attempt := 0; attempt < 200; attempt++ {
		d := backoff(attempt, base, maxDelay)
		if d < 0 || d > maxDelay {
			t.Fatalf("attempt %d: backoff %s outside [0, %s]", attempt, d, maxDelay)
		}
		if attempt >= 5 && d < maxDelay/2 {
			t.Fatalf("attempt %d: backoff %s collapsed below max/2", attempt, d)
		}
	}
	if d := backoff(0, base, maxDelay); d < base/2 || d > base {
		t.Fatalf("first backoff %s not within jitter range of %s", d, base)
	}
}

func TestControllerReportsNoSignal(t *testing.T) {
	srv, ctx, cancel := startEmulator(t)
	defer cancel()
	controller := New(Config{BaseURL: srv.BaseURL(), ICELoopbackOnly: true, Password: "secret", RPCTimeout: 2 * time.Second, Reconnect: true})
	controller.Start(ctx)
	defer controller.Stop()
	waitForPhase(t, controller, PhaseConnected, 5*time.Second)

	srv.SetVideoState("no_signal")
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) && controller.Snapshot().VideoSignal != "no_signal" {
		time.Sleep(20 * time.Millisecond)
	}
	snap := controller.Snapshot()
	if snap.VideoSignal != "no_signal" || !strings.Contains(snap.Status, "no signal") {
		t.Fatalf("no-signal state not surfaced: signal=%q status=%q", snap.VideoSignal, snap.Status)
	}
}

func TestControllerFollowsRebootRedirect(t *testing.T) {
	srv, ctx, cancel := startEmulator(t)
	defer cancel()
	controller := New(Config{
		BaseURL:         srv.BaseURL(),
		ICELoopbackOnly: true, Password: "secret", RPCTimeout: 2 * time.Second, Reconnect: true,
		ReconnectBase: time.Second, ReconnectMax: 2 * time.Second,
	})
	controller.Start(ctx)
	defer controller.Stop()
	waitForPhase(t, controller, PhaseConnected, 5*time.Second)

	srv.SendWillReboot("//192.0.2.60")
	waitForPhase(t, controller, PhaseRebooting, 3*time.Second)
	if got := controller.Snapshot().BaseURL; got != "http://192.0.2.60" {
		t.Fatalf("base URL after redirect = %q", got)
	}
}

func TestConnectedBeforeSlowBootstrapFinishes(t *testing.T) {
	srv, ctx, cancel := startFaultedEmulator(t, emulator.FaultConfig{DropRPCMethod: "getEDID"})
	defer cancel()
	controller := New(Config{BaseURL: srv.BaseURL(), ICELoopbackOnly: true, Password: "secret", RPCTimeout: 3 * time.Second, Reconnect: true})
	controller.Start(ctx)
	defer controller.Stop()
	// getEDID never answers (as on a device without HDMI signal); input must
	// still be available long before its RPC timeout.
	start := time.Now()
	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("connected only after %s; a stalled bootstrap RPC blocked input", elapsed)
	}
	if err := controller.SendKeypress(4, true); err != nil {
		t.Fatalf("input not accepted while bootstrap is pending: %v", err)
	}
	_ = controller.SendKeypress(4, false)
}

func TestReleaseAllInputClearsRemoteState(t *testing.T) {
	srv, ctx, cancel := startEmulator(t)
	defer cancel()
	controller := New(Config{BaseURL: srv.BaseURL(), ICELoopbackOnly: true, Password: "secret", RPCTimeout: 2 * time.Second, Reconnect: true})
	controller.Start(ctx)
	defer controller.Stop()
	waitForPhase(t, controller, PhaseConnected, 5*time.Second)

	_ = controller.SendKeypress(225, true)
	_ = controller.SendKeypress(4, true)
	_ = controller.SendAbsPointer(100, 100, 1)
	time.Sleep(50 * time.Millisecond)
	if err := controller.ReleaseAllInput(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		st := srv.State()
		if st.KeyboardModifiers == 0 && st.KeysDown[0] == 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if st := srv.State(); st.KeyboardModifiers != 0 || st.KeysDown[0] != 0 {
		t.Fatalf("keys still held after ReleaseAllInput: %+v %v", st.KeyboardModifiers, st.KeysDown)
	}
	released := false
	for _, in := range srv.Inputs() {
		if in.Type == "hidrpc.Pointer" && strings.Contains(in.Data, "Buttons:0") && in.Channel == "hidrpc" {
			released = true
		}
	}
	if !released {
		t.Fatal("pointer button release was not sent reliably")
	}
}

func TestControllerRefusesADifferentDevice(t *testing.T) {
	// Slow RPCs widen any window in which input would be open before the
	// identity check completes.
	srv, ctx, cancel := startFaultedEmulator(t, emulator.FaultConfig{RPCDelay: 300 * time.Millisecond})
	defer cancel()
	controller := New(Config{BaseURL: srv.BaseURL(), ICELoopbackOnly: true, Password: "secret", RPCTimeout: 2 * time.Second, Reconnect: true, ExpectedDeviceID: "some-other-device"})
	controller.Start(ctx)
	defer controller.Stop()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		snap := controller.Snapshot()
		if snap.Phase == PhaseConnected {
			t.Fatal("connected (input enabled) to the wrong device")
		}
		if snap.Phase == PhaseFatal {
			if !strings.Contains(snap.LastError, "different device") {
				t.Fatalf("unexpected error %q", snap.LastError)
			}
			if err := controller.SendKeypress(4, true); err == nil {
				t.Fatal("input accepted for the wrong device")
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("no fatal phase; last snapshot %+v", controller.Snapshot().Phase)
}

// An identity learned on the first connect pins later reconnects.
func TestControllerPinsTheDeviceItFirstReached(t *testing.T) {
	srv, ctx, cancel := startEmulator(t)
	defer cancel()
	controller := New(Config{
		BaseURL: srv.BaseURL(), ICELoopbackOnly: true, Password: "secret", RPCTimeout: 2 * time.Second, Reconnect: true,
		ReconnectBase: 200 * time.Millisecond, ReconnectMax: 400 * time.Millisecond,
	})
	controller.Start(ctx)
	defer controller.Stop()
	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
	deadline := time.Now().Add(3 * time.Second)
	for controller.Snapshot().DeviceID == "" && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}

	srv.SetDeviceID("another-jetkvm")
	srv.DisconnectSession()
	waitForPhase(t, controller, PhaseFatal, 5*time.Second)
	if err := controller.SendKeypress(4, true); err == nil {
		t.Fatal("input accepted for a different device")
	}
}

func TestControllerAcceptsTheExpectedDevice(t *testing.T) {
	srv, ctx, cancel := startEmulator(t)
	defer cancel()
	controller := New(Config{BaseURL: srv.BaseURL(), ICELoopbackOnly: true, Password: "secret", RPCTimeout: 2 * time.Second, Reconnect: true, ExpectedDeviceID: "emu-jetkvm-001"})
	controller.Start(ctx)
	defer controller.Stop()
	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
}

// A reboot takes the device away for a while; the controller must ride it
// out and reconnect on its own.
func TestControllerReconnectsAfterReboot(t *testing.T) {
	srv, ctx, cancel := startEmulatorWith(t, emulator.Config{RebootDowntime: 2 * time.Second})
	defer cancel()
	controller := New(Config{
		BaseURL: srv.BaseURL(), ICELoopbackOnly: true, Password: "secret", RPCTimeout: 3 * time.Second, Reconnect: true,
		ReconnectBase: 500 * time.Millisecond, ReconnectMax: time.Second,
	})
	controller.Start(ctx)
	defer controller.Stop()
	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
	sessions := srv.SessionCount()

	start := time.Now()
	if err := controller.Reboot(); err != nil {
		t.Fatalf("reboot: %v", err)
	}
	// Firmware waits 1 s before going down, then is away for the downtime;
	// a session caught in that second must not count as back.
	deadline := time.Now().Add(15 * time.Second)
	for time.Since(start) < 3*time.Second || controller.Snapshot().Phase != PhaseConnected {
		if time.Since(start) < 1500*time.Millisecond && controller.Snapshot().Phase == PhaseConnected {
			t.Fatal("connected again before the device went down")
		}
		if time.Now().After(deadline) {
			t.Fatalf("not reconnected after the reboot: %+v", controller.Snapshot().Status)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if srv.SessionCount() <= sessions {
		t.Fatal("no new session after the reboot")
	}
}

func TestControllerPinsTheTLSCertificateOnFirstUse(t *testing.T) {
	srv, ctx, cancel := startEmulatorWith(t, emulator.Config{TLS: true})
	defer cancel()
	if !strings.HasPrefix(srv.BaseURL(), "https://") {
		t.Fatalf("emulator not on https: %s", srv.BaseURL())
	}
	controller := New(Config{
		BaseURL: srv.BaseURL(), ICELoopbackOnly: true, Password: "secret", RPCTimeout: 2 * time.Second, Reconnect: true,
		ReconnectBase: 200 * time.Millisecond, ReconnectMax: 400 * time.Millisecond,
	})
	controller.Start(ctx)
	defer controller.Stop()
	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
	want := tlspin.Fingerprint(srv.CertificateAuthority())
	if got := controller.Snapshot().CertSHA256; got != want {
		t.Fatalf("pinned %q, want the device CA %q", got, want)
	}

	// Another CA at the same address: the reconnect must refuse it.
	if err := srv.RotateCertificate(); err != nil {
		t.Fatal(err)
	}
	srv.DisconnectSession()
	waitForPhase(t, controller, PhaseFatal, 5*time.Second)
	if status := controller.Snapshot().Status; !strings.Contains(status, "certificate changed") {
		t.Fatalf("status %q", status)
	}
}

func TestControllerChecksAGivenTLSPin(t *testing.T) {
	srv, ctx, cancel := startEmulatorWith(t, emulator.Config{TLS: true})
	defer cancel()
	good := New(Config{BaseURL: srv.BaseURL(), ICELoopbackOnly: true, Password: "secret", RPCTimeout: 2 * time.Second, CertSHA256: tlspin.Fingerprint(srv.CertificateAuthority())})
	good.Start(ctx)
	waitForPhase(t, good, PhaseConnected, 5*time.Second)
	good.Stop()

	logins := srv.LoginCount()
	bad := New(Config{BaseURL: srv.BaseURL(), ICELoopbackOnly: true, Password: "secret", RPCTimeout: 2 * time.Second, Reconnect: true, CertSHA256: strings.Repeat("ab", 32)})
	bad.Start(ctx)
	defer bad.Stop()
	waitForPhase(t, bad, PhaseFatal, 5*time.Second)
	if srv.LoginCount() != logins {
		t.Fatal("the password was sent over a connection with the wrong certificate")
	}
}
