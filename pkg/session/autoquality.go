package session

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/wottpal/blitzkvm/pkg/client"
	"github.com/wottpal/blitzkvm/pkg/logging"
)

// Automatic stream quality.
//
// JetKVM has no congestion control: it sends whatever its VBR encoder
// produces. On a link slower than the stream's peaks, packets queue up and
// get lost, and the picture stalls while NACKs and keyframes repair it. The
// governor watches the receive side (packet loss, round-trip time growing
// over the link's baseline, frames the assembler had to drop) and walks a
// quality ladder: down at once when the link struggles, up one step at a
// time after a long clean stretch.
//
// On firmware with the desktop encoder patch (setVideoEncoderParams) a level
// is applied live, without restarting the encoder: bitrate, QP floor, encode
// frame rate and the still-screen refresh QP. Stock firmware only takes the
// stream quality factor, which restarts its video pipeline (a short stall),
// so levels change rarely.
//
// Each live level also says who refreshes still pictures: with
// Config.ClientRefresh, on firmware that offers refreshRegions, the device's
// own refresh is off (autoRefresh false) and the client asks for refreshes.
// The device merges partial updates, but drops every override when the
// stream stops or another session takes over; sending it with every level
// keeps both together, and a reconnect applies both again.

// QualityLevel is one rung of the ladder.
type QualityLevel struct {
	Name   string
	Factor float64 // setStreamQualityFactor: 1 = the web UI's "High" (4 Mbit/s target at 1080p)
	MaxFPS int     // encode frame rate cap; 0 = source rate (patched firmware)
	MinQP  int     // QP floor (patched firmware); lower = sharper, larger keyframes
	// StillQP is the QP of the keyframe the patched firmware sends once the
	// screen has been still for half a second; >= MinQP turns it off.
	StillQP int
}

// qualityLadder is ordered from lowest to highest. The values come from the
// ground-truth sweep (plan §21 and §23, tools/quality-bench) on a live device
// with the encoder patch, H.265, 1080p:
//   - A still screen gets a near-lossless keyframe at StillQP: text PSNR
//     60 dB at maximum (QP 1), 56 dB at balanced (QP 8), against 53 and
//     42 dB without it and 32.5 on stock firmware. With the 60 s GOP a still
//     screen then costs 0.04-0.08 Mbit/s. The refresh keyframe (0.2-0.4 MB)
//     is a burst a slow link would turn into loss, so the lowest level
//     skips it.
//   - The QP floor sets the sharpness of moving and freshly changed content.
//   - The bitrate sets quality while the screen moves: scrolling 1080 px/s
//     gives 49.8 dB at ~8 Mbit/s (factor 3, QP 10) and 46.9 dB at 4.2 Mbit/s
//     (factor 1, QP 16).
//   - Below ~3 Mbit/s, 30 fps keeps each frame sharper than 60 fps at a
//     lower bitrate (46.3 dB at 2.3 Mbit/s vs 44.1 at 2.9), so frame rate
//     goes down before the bitrate does.
var qualityLadder = []QualityLevel{
	{Name: "minimal", Factor: 0.25, MaxFPS: 15, MinQP: 26, StillQP: 26},
	{Name: "low", Factor: 0.5, MaxFPS: 30, MinQP: 21, StillQP: 17},
	{Name: "balanced", Factor: 1, MaxFPS: 60, MinQP: 18, StillQP: 8},
	{Name: "high", Factor: 2, MaxFPS: 60, MinQP: 14, StillQP: 4},
	{Name: "maximum", Factor: 3, MaxFPS: 60, MinQP: 10, StillQP: 1},
}

const (
	qualitySample = time.Second
	downCooldown  = 4 * time.Second // between two steps down
	// upAfterClean is the clean time before a step up. A step down soon
	// after a step up (a link between two rungs) doubles it, up to
	// maxUpDelay; a long stretch without steps down restores it. Stock
	// firmware restarts its encoder on every change, so it waits longer.
	upAfterClean        = 20 * time.Second
	upAfterCleanStock   = time.Minute
	maxUpDelay          = 5 * time.Minute
	flapWindow          = time.Minute
	lossThreshold       = 0.02 // fraction of packets lost in a sample
	severeLossThreshold = 0.10
	rttSlack            = 40 * time.Millisecond
	approxPacketBytes   = 1150 // RTP payloads are ~1200 bytes
)

// qualityGovernor decides level changes from periodic transport samples. It
// holds no locks and does no I/O, so it is unit-testable with synthetic data.
type qualityGovernor struct {
	level      int
	lastChange time.Time
	lastUp     time.Time
	lastDown   time.Time
	baseUp     time.Duration
	upDelay    time.Duration
	cleanSince time.Time
	baseRTT    time.Duration
	baseAt     time.Time
	congestedN int
	prev       client.StatsSnapshot
	havePrev   bool
}

func newQualityGovernor(now time.Time, rtt, baseUp time.Duration) *qualityGovernor {
	// No change yet: the first step down may come at once.
	g := &qualityGovernor{cleanSince: now, baseUp: baseUp, upDelay: baseUp}
	// Start high on a LAN, balanced elsewhere; the ladder corrects quickly.
	switch {
	case rtt > 0 && rtt < 8*time.Millisecond:
		g.level = len(qualityLadder) - 1
	case rtt > 0 && rtt < 40*time.Millisecond:
		g.level = len(qualityLadder) - 2
	default:
		g.level = 2
	}
	return g
}

// observe takes one transport sample and returns the new level when it
// should change.
func (g *qualityGovernor) observe(now time.Time, s client.StatsSnapshot) (int, bool) {
	if !g.havePrev {
		g.prev, g.havePrev = s, true
		return g.level, false
	}
	// Statistics refresh on their own timer: the same sample read twice
	// would look like a perfectly clean second.
	if !s.SampledAt.IsZero() && !s.SampledAt.After(g.prev.SampledAt) {
		return g.level, false
	}
	prev := g.prev
	g.prev = s
	rtt := time.Duration(s.RoundTripMs * float64(time.Millisecond))
	// The baseline is the lowest RTT of the last minute (queues inflate it).
	if rtt > 0 && (g.baseRTT == 0 || rtt < g.baseRTT || now.Sub(g.baseAt) > time.Minute) {
		g.baseRTT, g.baseAt = rtt, now
	}
	lost := float64(max(int64(s.PacketsLost)-int64(prev.PacketsLost), 0))
	received := float64(s.BytesReceived-min(prev.BytesReceived, s.BytesReceived)) / approxPacketBytes
	lossRate := 0.0
	if lost+received > 0 {
		lossRate = lost / (lost + received)
	}
	// A new keyframe wait means a loss NACKs could not repair. Frames the
	// assembler drops while waiting (also before the first keyframe of a
	// session) are not counted again.
	unrepaired := s.KeyframeWaits > prev.KeyframeWaits
	queued := g.baseRTT > 0 && rtt > 2*g.baseRTT+rttSlack

	congested := lossRate > lossThreshold || unrepaired || queued
	if congested {
		g.congestedN++
	} else {
		g.congestedN = 0
	}
	switch {
	case congested && (lossRate > severeLossThreshold || g.congestedN >= 2):
		g.cleanSince = now
		if g.level == 0 || now.Sub(g.lastChange) < downCooldown {
			return g.level, false
		}
		step := 1
		if lossRate > severeLossThreshold && g.level >= 2 {
			step = 2
		}
		if !g.lastUp.IsZero() && now.Sub(g.lastUp) < flapWindow {
			g.upDelay = min(2*g.upDelay, maxUpDelay)
		}
		g.level -= step
		g.lastChange, g.lastDown = now, now
		return g.level, true
	case congested:
		g.cleanSince = now
	case g.level < len(qualityLadder)-1 && now.Sub(g.cleanSince) >= g.upDelay && now.Sub(g.lastChange) >= g.upDelay:
		if now.Sub(g.lastDown) >= maxUpDelay {
			g.upDelay = g.baseUp
		}
		g.level++
		g.lastChange, g.lastUp = now, now
		g.cleanSince = now
		return g.level, true
	}
	return g.level, false
}

// SetAutoQuality turns automatic quality on or off for this session (and
// its reconnects). Turning it off keeps the current level.
func (c *Controller) SetAutoQuality(on bool) {
	c.mu.Lock()
	c.cfg.AutoQuality = on
	if !on && c.snapshot.QualityLevel != "" {
		// Keep what automatic had chosen, also for reconnects.
		c.cfg.QualityLevel = c.snapshot.QualityLevel
	}
	current := c.current
	connected := c.snapshot.Phase == PhaseConnected
	c.snapshot.AutoQuality = on
	parent := c.runParent
	c.mu.Unlock()
	if on && connected && current != nil && parent != nil {
		go c.autoQuality(parent, current)
	}
}

// SetQualityLevel picks a ladder level by name and turns automatic quality
// off; the level also applies to later reconnects.
func (c *Controller) SetQualityLevel(ctx context.Context, name string) error {
	level := levelIndex(name)
	if level < 0 {
		return fmt.Errorf("unknown quality level %q", name)
	}
	c.mu.Lock()
	c.cfg.AutoQuality = false
	c.cfg.QualityLevel = name
	c.snapshot.AutoQuality = false
	c.mu.Unlock()
	cl := c.clientIfConnected()
	if cl == nil {
		return nil // applied on connect
	}
	return c.applyLevel(ctx, cl, level)
}

func levelIndex(name string) int {
	for i, l := range qualityLadder {
		if l.Name == name {
			return i
		}
	}
	return -1
}

// encoderParams reports whether the device takes live encoder parameters
// (firmware with the desktop encoder patch). The answer is cached per
// client; a transient failure is not cached.
func (c *Controller) encoderParams(ctx context.Context, cl *client.Client) (bool, error) {
	c.mu.RLock()
	if c.encoderParamsClient == cl {
		ok := c.encoderParamsOK
		c.mu.RUnlock()
		return ok, nil
	}
	c.mu.RUnlock()
	var probe json.RawMessage
	err := cl.Call(ctx, "getVideoEncoderParams", nil, &probe)
	var rpcErr *client.RPCError
	switch {
	case err == nil:
	case errors.As(err, &rpcErr) && rpcErr.Code == -32601: // method not found: stock firmware
	default:
		return false, err
	}
	c.mu.Lock()
	c.encoderParamsClient, c.encoderParamsOK = cl, err == nil
	c.mu.Unlock()
	return err == nil, nil
}

// applyLevel sets a ladder level on the device: live on firmware with the
// encoder patch, through the quality factor (an encoder restart) otherwise.
func (c *Controller) applyLevel(ctx context.Context, cl *client.Client, level int) error {
	log := logging.Subsystem("quality")
	l := qualityLadder[level]
	live, err := c.encoderParams(ctx, cl)
	if err != nil {
		return err
	}
	c.setStateFor(cl, func(s *Snapshot) { s.QualityLevel = l.Name })
	if live {
		c.mu.RLock()
		w, h := c.snapshot.VideoWidth, c.snapshot.VideoHeight
		clientRefresh := c.cfg.ClientRefresh
		c.mu.RUnlock()
		clientRefresh = clientRefresh && cl.HasFirmwareFeature(ctx, client.FeatureRefreshRegions)
		target := factorKbps(l.Factor, w, h)
		// Firmware from before the still refresh ignores stillQp.
		update := map[string]any{
			"minQp": l.MinQP, "maxFps": l.MaxFPS, "bitrateKbps": target, "maxBitrateKbps": target * 3 / 2,
			"stillQp": l.StillQP,
		}
		if clientRefresh {
			update["autoRefresh"] = false
		}
		if err := cl.Call(ctx, "setVideoEncoderParams", map[string]any{"params": update}, nil); err != nil {
			log.Warn().Err(err).Msg("set encoder params")
			return err
		}
		c.setStateFor(cl, func(s *Snapshot) { s.ClientRefresh, s.MinQP, s.StillQP = clientRefresh, l.MinQP, l.StillQP })
		log.Info().Str("level", l.Name).Int("kbps", target).Int("maxFps", l.MaxFPS).Int("minQp", l.MinQP).Int("stillQp", l.StillQP).
			Bool("clientRefresh", clientRefresh).Msg("stream quality (live)")
		return nil
	}
	// Stock firmware: only the factor, and only when it changes (each change
	// restarts the device's video pipeline). Ask the device: the snapshot
	// may not have loaded it yet right after connecting.
	current, err := cl.GetStreamQualityFactor(ctx)
	if err != nil {
		return err
	}
	if current == l.Factor {
		c.setStateFor(cl, func(s *Snapshot) { s.Quality = current })
		return nil
	}
	if err := cl.SetStreamQualityFactor(ctx, l.Factor); err != nil {
		log.Warn().Err(err).Msg("set quality factor")
		return err
	}
	c.setStateFor(cl, func(s *Snapshot) { s.Quality = l.Factor })
	log.Info().Str("level", l.Name).Float64("factor", l.Factor).Msg("stream quality")
	return nil
}

// autoQuality runs after each connect: it applies a manually chosen level,
// or runs the governor until the client closes or automatic quality is
// turned off.
func (c *Controller) autoQuality(ctx context.Context, cl *client.Client) {
	c.mu.Lock()
	auto, manual := c.cfg.AutoQuality, c.cfg.QualityLevel
	if !auto {
		c.mu.Unlock()
		if level := levelIndex(manual); level >= 0 {
			_ = c.applyLevel(ctx, cl, level)
		}
		return
	}
	if c.autoRunning[cl] {
		c.mu.Unlock()
		return
	}
	if c.autoRunning == nil {
		c.autoRunning = map[*client.Client]bool{}
	}
	c.autoRunning[cl] = true
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		delete(c.autoRunning, cl)
		c.mu.Unlock()
	}()

	// Let ICE report a round trip before picking the start level.
	timer := time.NewTimer(2 * time.Second)
	select {
	case <-ctx.Done():
		timer.Stop()
		return
	case <-cl.Done():
		timer.Stop()
		return
	case <-timer.C:
	}
	baseUp := upAfterCleanStock
	if live, err := c.encoderParams(ctx, cl); err == nil && live {
		baseUp = upAfterClean
	}
	gov := newQualityGovernor(time.Now(), time.Duration(cl.Stats().RoundTripMs*float64(time.Millisecond)), baseUp)
	_ = c.applyLevel(ctx, cl, gov.level)
	videoSize := func() [2]int {
		c.mu.RLock()
		defer c.mu.RUnlock()
		return [2]int{c.snapshot.VideoWidth, c.snapshot.VideoHeight}
	}
	size := videoSize()

	ticker := time.NewTicker(qualitySample)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-cl.Done():
			return
		case now := <-ticker.C:
			c.mu.RLock()
			on := c.cfg.AutoQuality && c.current == cl
			c.mu.RUnlock()
			if !on {
				return
			}
			level, changed := gov.observe(now, cl.Stats())
			// The bitrate follows the resolution (the firmware's formula).
			if s := videoSize(); s != size {
				size, changed = s, true
			}
			if changed {
				_ = c.applyLevel(ctx, cl, level)
			}
		}
	}
}

// factorKbps mirrors the firmware's bitrate for a quality factor
// (internal/native/cgo/video.c calculate_bitrate), scaled by resolution.
func factorKbps(factor float64, width, height int) int {
	base := 512 + int((4000-512)*factor)
	if width <= 0 || height <= 0 {
		return base
	}
	return max(base*width*height/(1920*1080), 200)
}
