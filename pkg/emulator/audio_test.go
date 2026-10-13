package emulator

import (
	"context"
	"math"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/wottpal/blitzkvm/pkg/client"
)

// ulawToLinear is the G.711 µ-law decoder (the app's table, in Go).
func ulawToLinear(u byte) int {
	u = ^u
	magnitude := ((int(u&0x0f) << 3) + 0x84) << ((u >> 4) & 7)
	if u&0x80 != 0 {
		return 0x84 - magnitude
	}
	return magnitude - 0x84
}

func TestLinearToULaw(t *testing.T) {
	for _, tc := range []struct {
		in   int16
		want byte
	}{{0, 0xff}, {32767, 0x80}, {-32768, 0x00}, {-1, 0x7f}} {
		if got := linearToULaw(tc.in); got != tc.want {
			t.Errorf("linearToULaw(%d) = %#x, want %#x", tc.in, got, tc.want)
		}
	}
	// µ-law keeps about 3 % of a sample's magnitude (plus the bias).
	for s := -32768; s <= 32767; s += 7 {
		got := ulawToLinear(linearToULaw(int16(s)))
		if diff := math.Abs(float64(got - s)); diff > 0.035*math.Abs(float64(s))+132 {
			t.Fatalf("%d -> %d", s, got)
		}
	}
}

func TestToneFixtureIsOpus(t *testing.T) {
	packets, err := oggPackets(toneOpus)
	if err != nil {
		t.Fatal(err)
	}
	if string(packets[0][:8]) != "OpusHead" || packets[0][9] != 2 {
		t.Fatalf("first packet %q is not a stereo OpusHead", packets[0][:10])
	}
	// A second of 20 ms frames (the last one carries the encoder's delay).
	if frames := len(packets) - 2; frames != 51 {
		t.Fatalf("%d frames", frames)
	}
	for _, p := range packets[2:] {
		if config := p[0] >> 3; config != 31 { // CELT fullband, 20 ms
			t.Fatalf("TOC config %d, want 20 ms CELT fullband", config)
		}
	}
}

// receiveAudio connects a client that offers audio and returns what it
// received within d.
func receiveAudio(t *testing.T, cfg Config, d time.Duration) []client.AudioPacket {
	t.Helper()
	cfg.ListenAddr, cfg.ICELoopbackOnly, cfg.AuthMode = "127.0.0.1:0", true, AuthModeNoPassword
	srv, err := NewServer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = srv.ListenAndServe(ctx) }()
	waitForBaseURL(t, srv)

	var mu sync.Mutex
	var got []client.AudioPacket
	c, err := client.New(client.Config{
		BaseURL: srv.BaseURL(), ICELoopbackOnly: true, RPCTimeout: 2 * time.Second,
		OnAudioPacket: func(p client.AudioPacket) {
			mu.Lock()
			got = append(got, p)
			mu.Unlock()
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if err := c.Connect(ctx); err != nil {
		t.Fatal(err)
	}
	time.Sleep(d)
	mu.Lock()
	defer mu.Unlock()
	if stats := c.Stats(); stats.AudioPackets < uint64(len(got)) {
		t.Errorf("stats count %d packets, received %d", stats.AudioPackets, len(got))
	}
	return slices.Clone(got)
}

func TestAudioIsOffByDefault(t *testing.T) {
	if got := receiveAudio(t, Config{AudioTone: true}, time.Second); len(got) != 0 {
		t.Fatalf("received %d audio packets from a device whose audio is off", len(got))
	}
}

func TestSilentTargetSendsNoAudio(t *testing.T) {
	if got := receiveAudio(t, Config{AudioEnabled: true}, time.Second); len(got) != 0 {
		t.Fatalf("received %d audio packets while the target plays nothing", len(got))
	}
}

// Stock firmware: PCMU from pion's sample packetizer, which marks every
// packet and keeps the timestamp running only while it sends.
func TestStockAudioIsPCMU(t *testing.T) {
	got := receiveAudio(t, Config{AudioEnabled: true, AudioTone: true}, 2500*time.Millisecond)
	if len(got) < 60 {
		t.Fatalf("received %d packets", len(got))
	}
	for i, p := range got {
		if p.Codec != client.AudioCodecPCMU || len(p.Payload) != 160 || !p.Marker {
			t.Fatalf("packet %d: %v, %d bytes, marker %v", i, p.Codec, len(p.Payload), p.Marker)
		}
		if i > 0 && (p.SequenceNumber != got[i-1].SequenceNumber+1 || p.Timestamp != got[i-1].Timestamp+160) {
			t.Fatalf("packet %d: seq %d ts %d after seq %d ts %d", i, p.SequenceNumber, p.Timestamp, got[i-1].SequenceNumber, got[i-1].Timestamp)
		}
	}
}

// Fork firmware D14: Opus; the marker bit starts each tone, sequence
// numbers run on, and the timestamp jumps across the silence.
func TestForkAudioIsOpus(t *testing.T) {
	got := receiveAudio(t, Config{AudioEnabled: true, AudioTone: true, OpusAudio: true}, 2500*time.Millisecond)
	if len(got) < 60 {
		t.Fatalf("received %d packets", len(got))
	}
	starts := 0
	for i, p := range got {
		if p.Codec != client.AudioCodecOpus {
			t.Fatalf("packet %d: %v", i, p.Codec)
		}
		if i == 0 {
			continue
		}
		prev := got[i-1]
		if p.SequenceNumber != prev.SequenceNumber+1 {
			t.Fatalf("packet %d: seq %d after %d", i, p.SequenceNumber, prev.SequenceNumber)
		}
		gap := p.Timestamp - prev.Timestamp
		if p.Marker {
			starts++
			if gap < 960*40 {
				t.Fatalf("packet %d starts a tone %d samples after the last", i, gap)
			}
		} else if gap%960 != 0 || gap > 960*3 {
			t.Fatalf("packet %d: timestamp +%d within a tone", i, gap)
		}
	}
	if starts != 1 {
		t.Fatalf("%d tone starts after the first in 2.5 s, want 1", starts)
	}
}
