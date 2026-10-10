package client

import (
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

func TestComputeSmoothedRates(t *testing.T) {
	base := time.Unix(1000, 0)
	history := []statsSample{
		{at: base, bytesReceived: 1000, framesDecoded: 10},
		{at: base.Add(1500 * time.Millisecond), bytesReceived: 2500, framesDecoded: 40},
		{at: base.Add(3 * time.Second), bytesReceived: 4000, framesDecoded: 70},
	}

	bitrateKbps, fps := computeSmoothedRates(history)
	if bitrateKbps != 8 {
		t.Fatalf("expected 8 kbps, got %v", bitrateKbps)
	}
	if fps != 20 {
		t.Fatalf("expected 20 fps, got %v", fps)
	}
}

func TestComputeSmoothedRatesHandlesShortHistory(t *testing.T) {
	bitrateKbps, fps := computeSmoothedRates([]statsSample{{at: time.Unix(1000, 0)}})
	if bitrateKbps != 0 || fps != 0 {
		t.Fatalf("expected zero rates, got bitrate=%v fps=%v", bitrateKbps, fps)
	}
}

func TestHandleTransportDisconnectEmitsLifecycleAndCloses(t *testing.T) {
	c, err := New(Config{})
	if err != nil {
		t.Fatal(err)
	}

	c.handleTransportDisconnect(webrtc.PeerConnectionStateDisconnected, "test")

	select {
	case evt := <-c.Lifecycle():
		if evt.Type != "peer_state" {
			t.Fatalf("expected peer_state event, got %q", evt.Type)
		}
		if evt.Connection != webrtc.PeerConnectionStateDisconnected {
			t.Fatalf("expected disconnected state, got %s", evt.Connection)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for lifecycle event")
	}

	select {
	case <-c.closeCh:
	case <-time.After(time.Second):
		t.Fatal("expected client to close after transport disconnect")
	}
}

func TestHandleTransportDisconnectNoopsAfterClose(t *testing.T) {
	c, err := New(Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := c.Close(); err != nil {
		t.Fatal(err)
	}

	c.handleTransportDisconnect(webrtc.PeerConnectionStateDisconnected, "test")

	select {
	case evt, ok := <-c.Lifecycle():
		if ok {
			t.Fatalf("unexpected lifecycle event after close: %+v", evt)
		}
	case <-time.After(100 * time.Millisecond):
	}
}

func TestStatsAfterCloseDoesNotPoll(t *testing.T) {
	c, err := New(Config{})
	if err != nil {
		t.Fatal(err)
	}
	api, err := c.newAPI()
	if err != nil {
		t.Fatal(err)
	}
	pc, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	c.pcMu.Lock()
	c.pc = pc
	c.pcMu.Unlock()
	c.statsMu.Lock()
	c.stats.BytesReceived = 12345 // sentinel: a poll would overwrite it
	c.statsMu.Unlock()
	if err := c.Close(); err != nil {
		t.Fatal(err)
	}
	before := c.Stats()
	c.collectStats(time.Now().Add(time.Minute))
	if after := c.Stats(); !reflect.DeepEqual(before, after) {
		t.Fatalf("stats changed after close: %+v -> %+v", before, after)
	}
	c.statsMu.Lock()
	samples := len(c.statsHistory)
	c.statsMu.Unlock()
	if samples != 0 {
		t.Fatalf("closed client recorded %d stats samples", samples)
	}
}

func offerSDP(t *testing.T, cfg Config) string {
	t.Helper()
	c, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	api, err := c.newAPI()
	if err != nil {
		t.Fatal(err)
	}
	pc, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer pc.Close()
	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo, webrtc.RTPTransceiverInit{
		Direction: webrtc.RTPTransceiverDirectionRecvonly,
	}); err != nil {
		t.Fatal(err)
	}
	offer, err := pc.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	return offer.SDP
}

func TestOfferNegotiatesLossRecoveryAndOmitsH265(t *testing.T) {
	sdp := offerSDP(t, Config{})
	// JetKVM switches to H.265 if the offer mentions it anywhere.
	if strings.Contains(strings.ToUpper(sdp), "H265") {
		t.Fatalf("offer must not mention H265 by default:\n%s", sdp)
	}
	for _, want := range []string{"H264/90000", "packetization-mode=1", "a=rtcp-fb:102 nack", "a=rtcp-fb:102 nack pli", "a=rtcp-fb:102 ccm fir"} {
		if !strings.Contains(sdp, want) {
			t.Fatalf("offer is missing %q:\n%s", want, sdp)
		}
	}
}

func TestOfferH265WhenRequested(t *testing.T) {
	sdp := offerSDP(t, Config{OfferH265: true})
	if !strings.Contains(sdp, "H265/90000") {
		t.Fatalf("expected H265 in offer:\n%s", sdp)
	}
}
