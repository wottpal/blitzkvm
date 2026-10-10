package engine_test

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/lkarlslund/jetkvm-desktop/pkg/emulator"
	"github.com/lkarlslund/jetkvm-desktop/pkg/engine"
	"github.com/lkarlslund/jetkvm-desktop/pkg/engineipc"
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
	srv, err := emulator.NewServer(emulator.Config{ListenAddr: "127.0.0.1:0", AuthMode: emulator.AuthModePassword, Password: "pw"})
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
