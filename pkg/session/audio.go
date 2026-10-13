package session

import (
	"context"

	"github.com/wottpal/blitzkvm/pkg/client"
	"github.com/wottpal/blitzkvm/pkg/logging"
)

// The device's audio. The device attaches it only while answering an offer,
// and only while its audio is on (getAudioConfig), which stock firmware
// leaves off by default: turning it on takes one reconnect.

// audioSink is what the next client forwards audio to, nil without audio.
func (c *Controller) audioSink() func(client.AudioPacket) {
	forward := c.cfg.OnAudioPacket
	if forward == nil || !c.audio.Load() {
		return nil
	}
	return func(p client.AudioPacket) {
		if c.audio.Load() {
			forward(p)
		}
	}
}

// SetAudio turns the device's audio on or off. Off mutes at once; the
// device keeps sending until the next connect leaves audio out of the offer
// (and only while the target plays something). On reconnects if the
// connection did not ask for audio, turning the device's audio on first
// where that is allowed.
func (c *Controller) SetAudio(on bool) {
	if c.audio.Swap(on) == on || !on || c.cfg.OnAudioPacket == nil {
		return
	}
	// A connection still being set up is checked once it is up (audioRestart).
	if cl := c.clientIfConnected(); cl != nil && !cl.AudioOffered() {
		go func() {
			c.turnOnDeviceAudio(context.Background(), cl)
			c.ReconnectNow()
		}()
	}
}

// audioRestart runs once a connection is up and reports whether it must be
// replaced to get audio: the device's audio was just turned on, or audio
// was turned on while the connection was being set up without it.
func (c *Controller) audioRestart(ctx context.Context, cl *client.Client) bool {
	if c.audioSink() == nil {
		return false
	}
	turnedOn := c.turnOnDeviceAudio(ctx, cl)
	return turnedOn || !cl.AudioOffered()
}

// turnOnDeviceAudio turns the device's audio on where it is off and the
// session may change settings (Config.EnableDeviceAudio), at most once per
// controller, and reports whether it did. Firmware without getAudioConfig is
// left alone, and so is a device whose USB audio function is off
// (setAudioConfig keeps audio off there without an error): reconnecting for
// audio never loops.
func (c *Controller) turnOnDeviceAudio(ctx context.Context, cl *client.Client) bool {
	c.mu.Lock()
	allowed := c.cfg.EnableDeviceAudio && !c.audioTurnedOn
	c.mu.Unlock()
	if !allowed {
		return false
	}
	if on, err := cl.GetAudioEnabled(ctx); err != nil || on {
		return false
	}
	c.mu.Lock()
	tried := c.audioTurnedOn
	c.audioTurnedOn = true
	c.mu.Unlock()
	if tried {
		return false
	}
	log := logging.Subsystem("session")
	if err := cl.SetAudioEnabled(ctx, true); err != nil {
		log.Warn().Err(err).Msg("turning the device's audio on")
		return false
	}
	if on, err := cl.GetAudioEnabled(ctx); err != nil || !on {
		log.Error().Msg("the device keeps its audio off: its USB audio function is off")
		return false
	}
	log.Error().Msg("turned the device's audio on; reconnecting so it sends it")
	return true
}
