package session

import (
	"context"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/wottpal/blitzkvm/pkg/client"
	"github.com/wottpal/blitzkvm/pkg/emulator"
)

// audioController connects to srv with audio as configured and counts the
// audio packets it forwards.
func audioController(t *testing.T, srv *emulator.Server, ctx context.Context, cfg Config) (*Controller, *atomic.Int64) {
	t.Helper()
	var packets atomic.Int64
	cfg.BaseURL, cfg.ICELoopbackOnly, cfg.Password, cfg.RPCTimeout = srv.BaseURL(), true, "secret", 2*time.Second
	cfg.Reconnect, cfg.ReconnectBase, cfg.ReconnectMax = true, 100*time.Millisecond, 300*time.Millisecond
	cfg.OnAudioPacket = func(client.AudioPacket) { packets.Add(1) }
	controller := New(cfg)
	controller.Start(ctx)
	t.Cleanup(controller.Stop)
	waitForPhase(t, controller, PhaseConnected, 5*time.Second)
	return controller, &packets
}

func waitForAudio(t *testing.T, packets *atomic.Int64, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for packets.Load() == 0 {
		if time.Now().After(deadline) {
			t.Fatal("no audio arrived")
		}
		time.Sleep(25 * time.Millisecond)
	}
}

func audioConfigCalls(srv *emulator.Server) []string {
	var calls []string
	for _, in := range srv.Inputs() {
		if in.Type == "rpc.setAudioConfig" {
			calls = append(calls, in.Data)
		}
	}
	return calls
}

// The device's audio is off (the firmware default): the session turns it
// on and reconnects once, since the device attaches audio only to an answer.
func TestControllerTurnsDeviceAudioOnOnce(t *testing.T) {
	srv, ctx, cancel := startEmulatorWith(t, emulator.Config{AudioTone: true, OpusAudio: true})
	defer cancel()
	_, packets := audioController(t, srv, ctx, Config{Audio: true, EnableDeviceAudio: true})
	waitForAudio(t, packets, 10*time.Second)
	if calls := audioConfigCalls(srv); len(calls) != 1 || calls[0] != "enabled=true" {
		t.Fatalf("setAudioConfig calls: %v", calls)
	}
	if n := srv.SessionCount(); n != 2 {
		t.Fatalf("%d sessions, want 2 (one reconnect for audio)", n)
	}
}

// Where the USB audio function is off, setAudioConfig keeps audio off
// without an error: one try, no reconnect, no loop.
func TestControllerLeavesAudioOffWithoutUSBAudio(t *testing.T) {
	srv, ctx, cancel := startEmulatorWith(t, emulator.Config{AudioTone: true})
	defer cancel()
	setup, _ := audioController(t, srv, ctx, Config{})
	if err := setup.SetUSBDevices(USBDevices{Keyboard: true, AbsoluteMouse: true, RelativeMouse: true}); err != nil {
		t.Fatal(err)
	}
	setup.Stop()
	sessions := srv.SessionCount()

	_, packets := audioController(t, srv, ctx, Config{Audio: true, EnableDeviceAudio: true})
	time.Sleep(2500 * time.Millisecond)
	if calls := audioConfigCalls(srv); len(calls) != 1 || calls[0] != "enabled=false" {
		t.Fatalf("setAudioConfig calls: %v", calls)
	}
	if n := srv.SessionCount() - sessions; n != 1 || packets.Load() != 0 {
		t.Fatalf("%d sessions and %d packets, want 1 and none", n, packets.Load())
	}
}

// A view-only session plays the device's audio but never turns it on.
func TestControllerViewOnlyLeavesDeviceAudio(t *testing.T) {
	for _, on := range []bool{false, true} {
		srv, ctx, cancel := startEmulatorWith(t, emulator.Config{AudioTone: true, AudioEnabled: on})
		_, packets := audioController(t, srv, ctx, Config{Audio: true})
		time.Sleep(2500 * time.Millisecond)
		if calls := audioConfigCalls(srv); len(calls) != 0 {
			t.Fatalf("device audio %v: setAudioConfig calls: %v", on, calls)
		}
		if got := packets.Load() > 0; got != on || srv.SessionCount() != 1 {
			t.Fatalf("device audio %v: audio %v, %d sessions", on, got, srv.SessionCount())
		}
		cancel()
	}
}

// Audio turned on during a session without it reconnects, turning the
// device's audio on first; off mutes at once.
func TestControllerSetAudio(t *testing.T) {
	srv, ctx, cancel := startEmulatorWith(t, emulator.Config{AudioTone: true})
	defer cancel()
	controller, packets := audioController(t, srv, ctx, Config{EnableDeviceAudio: true})
	controller.SetAudio(true)
	waitForAudio(t, packets, 10*time.Second)
	if n := srv.SessionCount(); n != 2 {
		t.Fatalf("%d sessions, want 2", n)
	}
	if stats := controller.Stats(); stats.AudioCodec != "pcmu" || stats.AudioPackets == 0 {
		t.Fatalf("stats: codec %q, %d packets", stats.AudioCodec, stats.AudioPackets)
	}
	controller.SetAudio(false)
	muted := packets.Load()
	time.Sleep(2500 * time.Millisecond)
	if packets.Load() != muted || srv.SessionCount() != 2 {
		t.Fatalf("muted audio still forwarded (%d packets) or reconnected", packets.Load()-muted)
	}
	if !strings.Contains(controller.Snapshot().Status, "connected") {
		t.Fatalf("status %q", controller.Snapshot().Status)
	}
}
