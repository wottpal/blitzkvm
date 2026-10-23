package engine_test

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/wottpal/blitzkvm/pkg/emulator"
	"github.com/wottpal/blitzkvm/pkg/engine"
	"github.com/wottpal/blitzkvm/pkg/engineipc"
	"github.com/wottpal/blitzkvm/pkg/protocol/tlspin"
)

type harness struct {
	t      *testing.T
	w      *engineipc.Writer
	frames chan frame
	done   chan error
	// firstUnit keeps the first access unit, whenever it arrives (waitFor
	// skips frames it is not looking for).
	firstUnit chan frame
}

type frame struct {
	typ     byte
	payload []byte
}

func startEngine(t *testing.T) *harness {
	t.Helper()
	appToEngineR, appToEngineW := io.Pipe()
	engineToAppR, engineToAppW := io.Pipe()
	h := &harness{t: t, w: engineipc.NewWriter(appToEngineW), frames: make(chan frame, 256), done: make(chan error, 1), firstUnit: make(chan frame, 1)}
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		h.done <- engine.Run(ctx, appToEngineR, engineToAppW)
		_ = engineToAppW.Close()
	}()
	go func() {
		r := engineipc.NewReader(engineToAppR)
		for {
			typ, payload, err := r.ReadFrame()
			if err != nil {
				close(h.frames)
				return
			}
			if typ == engineipc.TypeAccessUnit {
				select {
				case h.firstUnit <- frame{typ, payload}:
				default:
				}
			}
			select {
			case h.frames <- frame{typ, payload}:
			default: // test is not interested in a backlog of video
			}
		}
	}()
	t.Cleanup(func() {
		_ = appToEngineW.Close() // EOF ends the engine
		select {
		case err := <-h.done:
			if err != nil {
				t.Errorf("engine: %v", err)
			}
		case <-time.After(5 * time.Second):
			t.Error("engine did not stop on EOF")
		}
		cancel()
	})
	return h
}

func (h *harness) send(cmd engineipc.Command) {
	h.t.Helper()
	if err := h.w.WriteJSON(engineipc.TypeCommand, cmd); err != nil {
		h.t.Fatal(err)
	}
}

// waitFor returns the first frame accepted by match within timeout.
func (h *harness) waitFor(timeout time.Duration, what string, match func(frame) bool) frame {
	h.t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case f, ok := <-h.frames:
			if !ok {
				h.t.Fatalf("engine closed while waiting for %s", what)
			}
			if match(f) {
				return f
			}
		case <-deadline:
			h.t.Fatalf("timed out waiting for %s", what)
		}
	}
}

func startEmulator(t *testing.T) *emulator.Server {
	t.Helper()
	return startEmulatorWith(t, emulator.Config{})
}

func startEmulatorWith(t *testing.T, cfg emulator.Config) *emulator.Server {
	t.Helper()
	cfg.ListenAddr, cfg.AuthMode, cfg.Password, cfg.ICELoopbackOnly = "127.0.0.1:0", emulator.AuthModePassword, "pw", true
	srv, err := emulator.NewServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	go func() { _ = srv.ListenAndServe(ctx) }()
	t.Cleanup(cancel)
	for i := 0; i < 200 && srv.BaseURL() == ""; i++ {
		time.Sleep(5 * time.Millisecond)
	}
	return srv
}

func TestEngineEndToEnd(t *testing.T) {
	srv := startEmulator(t)
	h := startEngine(t)

	h.send(engineipc.Command{ID: 1, Cmd: "connect", BaseURL: strings.TrimPrefix(srv.BaseURL(), "http://"), Password: "pw"})
	h.waitFor(5*time.Second, "connect ack", func(f frame) bool {
		var res engineipc.CommandResult
		return f.typ == engineipc.TypeCommandDone && json.Unmarshal(f.payload, &res) == nil && res.ID == 1 && res.Error == ""
	})
	h.waitFor(10*time.Second, "connected snapshot", func(f frame) bool {
		var evt engineipc.Event
		if f.typ != engineipc.TypeEvent || json.Unmarshal(f.payload, &evt) != nil || evt.Type != "snapshot" {
			return false
		}
		var snap struct{ Phase string }
		return json.Unmarshal(evt.Snapshot, &snap) == nil && snap.Phase == "connected"
	})

	var au frame
	select {
	case au = <-h.firstUnit:
	case <-time.After(10 * time.Second):
		t.Fatal("no access unit received")
	}
	hdr, data, err := engineipc.ParseAccessUnit(au.payload)
	if err != nil {
		t.Fatal(err)
	}
	if hdr.Flags&engineipc.FlagKeyframe == 0 || hdr.Codec != 1 || len(data) == 0 {
		t.Fatalf("first unit must be an H.264 keyframe: %+v (%d bytes)", hdr, len(data))
	}

	h.send(engineipc.Command{ID: 2, Cmd: "rpc", Method: "ping"})
	res := h.waitFor(5*time.Second, "rpc result", func(f frame) bool { return f.typ == engineipc.TypeRPCResult })
	var rpc engineipc.RPCResult
	if err := json.Unmarshal(res.payload, &rpc); err != nil || rpc.ID != 2 || string(rpc.Result) != `"pong"` {
		t.Fatalf("unexpected rpc result %s (%v)", res.payload, err)
	}

	if err := h.w.WriteFrame(engineipc.TypeKey, []byte{4, 1}); err != nil {
		t.Fatal(err)
	}
	pointer := binary.BigEndian.AppendUint32(nil, 16000)
	pointer = binary.BigEndian.AppendUint32(pointer, 8000)
	if err := h.w.WriteFrame(engineipc.TypeAbsPointer, append(pointer, 1)); err != nil {
		t.Fatal(err)
	}
	if err := h.w.WriteFrame(engineipc.TypeKey, []byte{4, 0}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	var sawKey, sawPointer bool
	for time.Now().Before(deadline) && !(sawKey && sawPointer) {
		for _, in := range srv.Inputs() {
			sawKey = sawKey || in.Type == "hidrpc.Keypress"
			sawPointer = sawPointer || (in.Type == "hidrpc.Pointer" && strings.Contains(in.Data, "X:16000"))
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !sawKey || !sawPointer {
		t.Fatalf("input did not reach the device (key=%v pointer=%v)", sawKey, sawPointer)
	}

	h.send(engineipc.Command{ID: 3, Cmd: "paste", Text: "hi", Delay: 1})
	h.waitFor(5*time.Second, "paste done", func(f frame) bool {
		var res engineipc.CommandResult
		return f.typ == engineipc.TypeCommandDone && json.Unmarshal(f.payload, &res) == nil && res.ID == 3 && res.Error == ""
	})
}

// A paused engine (the app's window is hidden) sends no video and asks for
// no keyframes; resumed, it sends video again from a keyframe.
func TestEngineVideoPause(t *testing.T) {
	srv := startEmulator(t)
	h := startEngine(t)
	h.send(engineipc.Command{ID: 1, Cmd: "connect", BaseURL: strings.TrimPrefix(srv.BaseURL(), "http://"), Password: "pw"})
	select {
	case <-h.firstUnit:
	case <-time.After(10 * time.Second):
		t.Fatal("no access unit received")
	}
	done := func(id int64) func(frame) bool {
		return func(f frame) bool {
			var res engineipc.CommandResult
			return f.typ == engineipc.TypeCommandDone && json.Unmarshal(f.payload, &res) == nil && res.ID == id && res.Error == ""
		}
	}
	h.send(engineipc.Command{ID: 2, Cmd: "setVideoPaused", Paused: true})
	h.waitFor(5*time.Second, "pause ack", done(2))
	time.Sleep(100 * time.Millisecond) // units already queued
	for len(h.frames) > 0 {
		<-h.frames
	}
	deadline := time.After(600 * time.Millisecond)
	for paused := true; paused; {
		select {
		case f := <-h.frames:
			if f.typ == engineipc.TypeAccessUnit {
				t.Fatal("video sent while paused")
			}
		case <-deadline:
			paused = false
		}
	}

	h.send(engineipc.Command{ID: 3, Cmd: "setVideoPaused"})
	au := h.waitFor(5*time.Second, "video after resuming", func(f frame) bool { return f.typ == engineipc.TypeAccessUnit })
	hdr, _, err := engineipc.ParseAccessUnit(au.payload)
	if err != nil {
		t.Fatal(err)
	}
	if hdr.Flags&engineipc.FlagKeyframe == 0 {
		t.Fatal("video must resume at a keyframe")
	}
}

func TestEngineGameMode(t *testing.T) {
	srv := startEmulator(t)
	h := startEngine(t)
	h.send(engineipc.Command{ID: 1, Cmd: "connect", BaseURL: strings.TrimPrefix(srv.BaseURL(), "http://"), Password: "pw"})
	h.waitForSnapshot(10*time.Second, "connected", func(snap map[string]any) bool { return snap["Phase"] == "connected" })
	h.send(engineipc.Command{ID: 2, Cmd: "setGameMode", GameMode: true})
	h.waitFor(5*time.Second, "setGameMode ack", func(f frame) bool {
		var res engineipc.CommandResult
		return f.typ == engineipc.TypeCommandDone && json.Unmarshal(f.payload, &res) == nil && res.ID == 2 && res.Error == ""
	})
	h.waitForSnapshot(5*time.Second, "GameMode snapshot", func(snap map[string]any) bool { return snap["GameMode"] == true })
}

// createPassword sets a password-less device's first password; the device
// then asks for it, and the engine reconnects with it.
func TestEngineCreatePassword(t *testing.T) {
	srv, err := emulator.NewServer(emulator.Config{ListenAddr: "127.0.0.1:0", AuthMode: emulator.AuthModeNoPassword, ICELoopbackOnly: true})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go func() { _ = srv.ListenAndServe(ctx) }()
	for i := 0; i < 200 && srv.BaseURL() == ""; i++ {
		time.Sleep(5 * time.Millisecond)
	}
	h := startEngine(t)
	h.send(engineipc.Command{ID: 1, Cmd: "connect", BaseURL: srv.BaseURL()})
	h.waitForSnapshot(10*time.Second, "connected", func(snap map[string]any) bool { return snap["Phase"] == "connected" })

	h.send(engineipc.Command{ID: 2, Cmd: "createPassword", Password: "correct horse"})
	if res := h.waitDone(5*time.Second, 2); res.Error != "" {
		t.Fatalf("createPassword: %s", res.Error)
	}
	resp, err := http.Get(srv.BaseURL() + "/device")
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("GET /device after createPassword = %d, want 401", resp.StatusCode)
	}
	h.send(engineipc.Command{ID: 3, Cmd: "reconnect"})
	if res := h.waitDone(10*time.Second, 3); res.Error != "" {
		t.Fatalf("reconnect with the new password: %s", res.Error)
	}
	h.waitConnectedAgain()
}

// changePassword needs the current password; the engine then reconnects
// with the new one.
func TestEngineChangePassword(t *testing.T) {
	srv := startEmulator(t)
	h := startEngine(t)
	h.connect(srv.BaseURL(), engineipc.Command{})

	h.send(engineipc.Command{ID: 2, Cmd: "changePassword", OldPassword: "wrong one", Password: "correct horse"})
	if res := h.waitDone(5*time.Second, 2); res.Error == "" {
		t.Fatal("changePassword with a wrong current password succeeded")
	}
	h.send(engineipc.Command{ID: 3, Cmd: "changePassword", OldPassword: "pw", Password: "correct horse"})
	if res := h.waitDone(5*time.Second, 3); res.Error != "" {
		t.Fatalf("changePassword: %s", res.Error)
	}
	h.send(engineipc.Command{ID: 4, Cmd: "reconnect"})
	if res := h.waitDone(10*time.Second, 4); res.Error != "" {
		t.Fatalf("reconnect with the new password: %s", res.Error)
	}
	h.waitConnectedAgain()
}

// removePassword needs the current password; the device then asks for none,
// and the engine reconnects without one.
func TestEngineRemovePassword(t *testing.T) {
	srv := startEmulator(t)
	h := startEngine(t)
	h.connect(srv.BaseURL(), engineipc.Command{})

	h.send(engineipc.Command{ID: 2, Cmd: "removePassword", Password: "wrong one"})
	if res := h.waitDone(5*time.Second, 2); res.Error == "" {
		t.Fatal("removePassword with a wrong password succeeded")
	}
	h.send(engineipc.Command{ID: 3, Cmd: "removePassword", Password: "pw"})
	if res := h.waitDone(5*time.Second, 3); res.Error != "" {
		t.Fatalf("removePassword: %s", res.Error)
	}
	resp, err := http.Get(srv.BaseURL() + "/device")
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /device after removePassword = %d, want 200", resp.StatusCode)
	}
	h.send(engineipc.Command{ID: 4, Cmd: "reconnect"})
	if res := h.waitDone(10*time.Second, 4); res.Error != "" {
		t.Fatalf("reconnect without a password: %s", res.Error)
	}
	h.waitConnectedAgain()
}

// reboot restarts the device; the session goes through rebooting and comes
// back by itself.
func TestEngineReboot(t *testing.T) {
	srv := startEmulatorWith(t, emulator.Config{RebootDowntime: 500 * time.Millisecond})
	h := startEngine(t)
	h.connect(srv.BaseURL(), engineipc.Command{})
	h.send(engineipc.Command{ID: 2, Cmd: "reboot"})
	// The reply and the rebooting snapshot come in either order.
	var done, rebooting bool
	h.waitFor(10*time.Second, "reboot reply and rebooting snapshot", func(f frame) bool {
		var res engineipc.CommandResult
		var evt engineipc.Event
		var snap map[string]any
		switch {
		case f.typ == engineipc.TypeCommandDone && json.Unmarshal(f.payload, &res) == nil && res.ID == 2:
			if res.Error != "" {
				t.Fatalf("reboot: %s", res.Error)
			}
			done = true
		case f.typ == engineipc.TypeEvent && json.Unmarshal(f.payload, &evt) == nil && evt.Type == "snapshot" &&
			json.Unmarshal(evt.Snapshot, &snap) == nil && snap["Phase"] == "rebooting":
			rebooting = true
		}
		return done && rebooting
	})
	h.waitConnectedAgain()
}

// waitConnectedAgain waits until the session answers RPC after a
// reconnect (its "connected" snapshot may have gone by already).
func (h *harness) waitConnectedAgain() {
	h.t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for id := int64(100); time.Now().Before(deadline); id++ {
		h.send(engineipc.Command{ID: id, Cmd: "rpc", Method: "getLocalVersion"})
		var rpc engineipc.RPCResult
		h.waitFor(5*time.Second, "rpc result", func(f frame) bool {
			return f.typ == engineipc.TypeRPCResult && json.Unmarshal(f.payload, &rpc) == nil && rpc.ID == id
		})
		if rpc.Error == "" {
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
	h.t.Fatal("the session didn't answer after reconnecting")
}

func TestNormalizeBaseURL(t *testing.T) {
	for in, want := range map[string]string{
		"jetkvm.local":              "http://jetkvm.local",
		"192.168.1.5":               "http://192.168.1.5",
		"https://kvm.example:8443/": "https://kvm.example:8443",
		" http://10.0.0.2/x?y ":     "http://10.0.0.2",
	} {
		got, err := engine.NormalizeBaseURL(in)
		if err != nil || got != want {
			t.Fatalf("NormalizeBaseURL(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, bad := range []string{"", "ftp://x", "http://"} {
		if _, err := engine.NormalizeBaseURL(bad); err == nil {
			t.Fatalf("NormalizeBaseURL(%q) accepted", bad)
		}
	}
}

func (h *harness) connect(baseURL string, cmd engineipc.Command) {
	h.t.Helper()
	cmd.ID, cmd.Cmd, cmd.BaseURL, cmd.Password = 1, "connect", baseURL, "pw"
	h.send(cmd)
	h.waitForSnapshot(10*time.Second, "connected", func(snap map[string]any) bool { return snap["Phase"] == "connected" })
}

func (h *harness) waitForSnapshot(timeout time.Duration, what string, match func(map[string]any) bool) map[string]any {
	h.t.Helper()
	var snap map[string]any
	h.waitFor(timeout, what+" snapshot", func(f frame) bool {
		var evt engineipc.Event
		if f.typ != engineipc.TypeEvent || json.Unmarshal(f.payload, &evt) != nil || evt.Type != "snapshot" {
			return false
		}
		return json.Unmarshal(evt.Snapshot, &snap) == nil && match(snap)
	})
	return snap
}

func (h *harness) waitDone(timeout time.Duration, id int64) engineipc.CommandResult {
	h.t.Helper()
	var res engineipc.CommandResult
	h.waitFor(timeout, fmt.Sprintf("command %d", id), func(f frame) bool {
		return f.typ == engineipc.TypeCommandDone && json.Unmarshal(f.payload, &res) == nil && res.ID == id
	})
	return res
}

func (h *harness) storageFiles(id int64) map[string]float64 {
	h.t.Helper()
	h.send(engineipc.Command{ID: id, Cmd: "rpc", Method: "listStorageFiles"})
	var rpc engineipc.RPCResult
	h.waitFor(5*time.Second, "listStorageFiles", func(f frame) bool {
		return f.typ == engineipc.TypeRPCResult && json.Unmarshal(f.payload, &rpc) == nil && rpc.ID == id
	})
	var payload struct {
		Files []struct {
			Filename string
			Size     float64
		}
	}
	if err := json.Unmarshal(rpc.Result, &payload); err != nil {
		h.t.Fatalf("listStorageFiles: %s (%v)", rpc.Result, err)
	}
	files := map[string]float64{}
	for _, f := range payload.Files {
		files[f.Filename] = f.Size
	}
	return files
}

// An upload over a slow link can be cancelled and later resumes where it
// stopped, as on the device.
func TestEngineUploadCancelAndResume(t *testing.T) {
	srv := startEmulatorWith(t, emulator.Config{Faults: emulator.FaultConfig{UploadBytesPerSecond: 1 << 20}})
	h := startEngine(t)
	h.connect(srv.BaseURL(), engineipc.Command{})

	// Big enough that socket buffers cannot absorb it: progress below the
	// total means the transfer is still running when it is cancelled.
	const size = 16 << 20
	path := filepath.Join(t.TempDir(), "installer.img")
	if err := os.WriteFile(path, bytes.Repeat([]byte("x"), size), 0o600); err != nil {
		t.Fatal(err)
	}
	h.send(engineipc.Command{ID: 20, Cmd: "upload", Path: path})
	h.waitFor(5*time.Second, "upload progress", func(f frame) bool {
		var evt engineipc.Event
		return f.typ == engineipc.TypeEvent && json.Unmarshal(f.payload, &evt) == nil && evt.Type == "uploadProgress" &&
			evt.Upload.ID == 20 && evt.Upload.Sent > 0 && evt.Upload.Sent < size && evt.Upload.Total == size
	})
	h.send(engineipc.Command{ID: 21, Cmd: "cancelUpload", Target: 20})
	if res := h.waitDone(5*time.Second, 20); res.Error != "upload cancelled" {
		t.Fatalf("cancelled upload ended with %q", res.Error)
	}
	partial := h.storageFiles(22)["installer.img.incomplete"]
	if partial <= 0 || partial >= size {
		t.Fatalf("partial upload has %v bytes", partial)
	}

	srv.SetUploadBytesPerSecond(0)
	h.send(engineipc.Command{ID: 23, Cmd: "upload", Path: path})
	var firstSent int64 = -1
	h.waitFor(10*time.Second, "resumed upload done", func(f frame) bool {
		var evt engineipc.Event
		if f.typ == engineipc.TypeEvent && json.Unmarshal(f.payload, &evt) == nil && evt.Type == "uploadProgress" && evt.Upload.ID == 23 && firstSent < 0 {
			firstSent = evt.Upload.Sent
		}
		var res engineipc.CommandResult
		return f.typ == engineipc.TypeCommandDone && json.Unmarshal(f.payload, &res) == nil && res.ID == 23 && res.Error == ""
	})
	if firstSent < int64(partial) {
		t.Fatalf("resumed upload started at %d, before the %v bytes already on the device", firstSent, partial)
	}
	files := h.storageFiles(24)
	if files["installer.img"] != size {
		t.Fatalf("storage after resume: %v", files)
	}
	if _, left := files["installer.img.incomplete"]; left {
		t.Fatalf("partial file left behind: %v", files)
	}
}

func TestEngineSerialConsole(t *testing.T) {
	srv := startEmulator(t)
	h := startEngine(t)
	h.connect(srv.BaseURL(), engineipc.Command{})

	h.send(engineipc.Command{ID: 30, Cmd: "setExtension", Text: "serial-console"})
	if res := h.waitDone(10*time.Second, 30); res.Error != "" {
		t.Fatalf("setExtension: %s", res.Error)
	}
	serialText := func(want string) {
		t.Helper()
		var got strings.Builder
		h.waitFor(5*time.Second, "serial "+want, func(f frame) bool {
			var evt engineipc.Event
			if f.typ == engineipc.TypeEvent && json.Unmarshal(f.payload, &evt) == nil && evt.Type == "serial" {
				got.WriteString(evt.Text)
			}
			return strings.Contains(got.String(), want)
		})
	}
	h.send(engineipc.Command{ID: 31, Cmd: "serialSend", Text: "uname -a\r"})
	if res := h.waitDone(5*time.Second, 31); res.Error != "" {
		t.Fatalf("serialSend: %s", res.Error)
	}
	serialText("uname -a") // the emulated target echoes
	if err := srv.WriteSerial("Linux target 6.1\r\n"); err != nil {
		t.Fatal(err)
	}
	serialText("Linux target")
	found := false
	for _, in := range srv.Inputs() {
		found = found || (in.Type == "serial.tx" && in.Data == "uname -a\r")
	}
	if !found {
		t.Fatal("serial input did not reach the device")
	}
	// The scrollback is not repeated in every snapshot.
	snap := h.waitForSnapshot(2*time.Second, "any", func(map[string]any) bool { return true })
	if buffer, _ := snap["SerialConsoleBuffer"].(string); buffer != "" {
		t.Fatalf("snapshot carries the serial scrollback (%d bytes)", len(buffer))
	}
}

func TestEngineTLSPin(t *testing.T) {
	srv := startEmulatorWith(t, emulator.Config{TLS: true})
	h := startEngine(t)
	h.send(engineipc.Command{ID: 1, Cmd: "connect", BaseURL: srv.BaseURL(), Password: "pw", CertSHA256: strings.Repeat("00", 32)})
	h.waitForSnapshot(10*time.Second, "fatal", func(snap map[string]any) bool { return snap["Phase"] == "fatal_error" })

	h.send(engineipc.Command{ID: 2, Cmd: "connect", BaseURL: srv.BaseURL(), Password: "pw"})
	snap := h.waitForSnapshot(10*time.Second, "connected", func(snap map[string]any) bool { return snap["Phase"] == "connected" })
	if want := tlspin.Fingerprint(srv.CertificateAuthority()); snap["CertSHA256"] != want {
		t.Fatalf("pinned %v, want %s", snap["CertSHA256"], want)
	}
}

// A partial upload bigger than the file now uploaded under that name cannot
// be resumed: it is replaced, and the result is checked on the device.
func TestEngineUploadReplacesABiggerPartialUpload(t *testing.T) {
	srv := startEmulatorWith(t, emulator.Config{Faults: emulator.FaultConfig{UploadBytesPerSecond: 1 << 20}})
	h := startEngine(t)
	h.connect(srv.BaseURL(), engineipc.Command{})
	dir := t.TempDir()
	big := filepath.Join(dir, "big", "disk.img")
	small := filepath.Join(dir, "small", "disk.img")
	for path, size := range map[string]int{big: 16 << 20, small: 100 << 10} {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, bytes.Repeat([]byte("y"), size), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	h.send(engineipc.Command{ID: 40, Cmd: "upload", Path: big})
	h.waitFor(5*time.Second, "upload progress", func(f frame) bool {
		var evt engineipc.Event
		return f.typ == engineipc.TypeEvent && json.Unmarshal(f.payload, &evt) == nil && evt.Type == "uploadProgress" &&
			evt.Upload.ID == 40 && evt.Upload.Sent > 200<<10 && evt.Upload.Sent < evt.Upload.Total
	})
	h.send(engineipc.Command{ID: 41, Cmd: "cancelUpload", Target: 40})
	h.waitDone(5*time.Second, 40)
	deadline := time.Now().Add(5 * time.Second)
	for h.storageFiles(42)["disk.img.incomplete"] <= 100<<10 && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}

	srv.SetUploadBytesPerSecond(0)
	h.send(engineipc.Command{ID: 43, Cmd: "upload", Path: small})
	if res := h.waitDone(10*time.Second, 43); res.Error != "" {
		t.Fatalf("upload: %s", res.Error)
	}
	files := h.storageFiles(44)
	if files["disk.img"] != 100<<10 {
		t.Fatalf("storage: %v", files)
	}
}

// connect's clientRefresh reaches the session: on firmware that offers
// refreshRegions the snapshot reports the level's QPs with the device's own
// refresh off, and the app's refreshRegions calls pass through.
func TestEngineClientRefresh(t *testing.T) {
	srv := startEmulatorWith(t, emulator.Config{RefreshRegions: true})
	h := startEngine(t)
	// The level may already be in the first connected snapshot.
	h.send(engineipc.Command{ID: 1, Cmd: "connect", BaseURL: srv.BaseURL(), Password: "pw", QualityLevel: "maximum", ClientRefresh: true})
	h.waitForSnapshot(10*time.Second, "client refresh", func(snap map[string]any) bool {
		return snap["Phase"] == "connected" && snap["ClientRefresh"] == true && snap["MinQP"] == float64(10) && snap["StillQP"] == float64(1)
	})
	if srv.State().EncoderParams.AutoRefresh {
		t.Fatal("the device still refreshes on its own")
	}
	h.send(engineipc.Command{ID: 2, Cmd: "rpc", Method: "refreshRegions", Params: json.RawMessage(`{"rects":[{"x":0,"y":0,"w":16,"h":16}],"qp":1,"frames":2}`)})
	var rpc engineipc.RPCResult
	h.waitFor(5*time.Second, "refreshRegions result", func(f frame) bool {
		return f.typ == engineipc.TypeRPCResult && json.Unmarshal(f.payload, &rpc) == nil && rpc.ID == 2
	})
	if rpc.Error != "" {
		t.Fatalf("refreshRegions: %s", rpc.Error)
	}
}

// Audio goes to the app as TypeAudio frames, one per RTP packet.
func TestEngineForwardsAudio(t *testing.T) {
	srv := startEmulatorWith(t, emulator.Config{AudioEnabled: true, AudioTone: true, OpusAudio: true})
	h := startEngine(t)
	h.send(engineipc.Command{ID: 1, Cmd: "connect", BaseURL: strings.TrimPrefix(srv.BaseURL(), "http://"), Password: "pw", Audio: true})
	f := h.waitFor(10*time.Second, "audio", func(f frame) bool { return f.typ == engineipc.TypeAudio })
	hdr, payload, err := engineipc.ParseAudio(f.payload)
	if err != nil {
		t.Fatal(err)
	}
	if age := time.Since(time.Unix(0, hdr.ReceivedUnixNano)); hdr.Codec != 1 || hdr.Flags&engineipc.FlagMarker == 0 || len(payload) < 100 || age < 0 || age > 5*time.Second {
		t.Fatalf("first audio packet: %+v, %d bytes, received %s ago", hdr, len(payload), age)
	}
	h.waitFor(5*time.Second, "audio stats", func(f frame) bool {
		var evt engineipc.Event
		var stats struct {
			Stats        struct{ AudioCodec string }
			DroppedAudio *uint64 `json:"engineDroppedAudio"`
		}
		return f.typ == engineipc.TypeEvent && json.Unmarshal(f.payload, &evt) == nil && evt.Type == "stats" &&
			json.Unmarshal(evt.Stats, &stats) == nil && stats.Stats.AudioCodec == "opus" && stats.DroppedAudio != nil && *stats.DroppedAudio == 0
	})
}
