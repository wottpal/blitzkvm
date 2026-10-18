package session

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"time"

	"github.com/wottpal/blitzkvm/pkg/client"
	"github.com/wottpal/blitzkvm/pkg/logging"
	"github.com/wottpal/blitzkvm/pkg/video"
)

// Automatic stream quality.
//
// JetKVM has no congestion control: it sends whatever its VBR encoder
// produces. On a link slower than the stream's peaks, packets queue up and
// get lost, and the picture lags, then stalls while NACKs and keyframes
// repair it. The governor walks a quality ladder from what the receive side
// sees (video.LinkEstimator, the client's statistics):
//
//   - A queue: when every frame of the last video.QueueWindow waited more
//     than queueHigh behind earlier traffic and the wait is not shrinking,
//     the stream outruns the link. It steps down at once, to the level the
//     link carries at the rate it delivers while the queue stands. A wait
//     that shrinks is a burst draining (a keyframe or still refresh,
//     110-140 ms through the device's own send path on a LAN), and a queue
//     of NACK repairs (after an outage) drains once they are through: both
//     are left alone.
//   - The delivery rate (frame dispersion): a level whose bitrate target
//     exceeds what the link delivers is left before scrolling overruns it,
//     and a step up needs a measured rate that carries the next level with
//     room to spare. A still screen sends single-packet frames, which
//     measure nothing, so idle time never earns a step up. Off a LAN the
//     encoder's peak bitrate is also held below the rate (peakShare), so
//     scrolling at any level stays below what the link delivers (keyframes
//     and refreshes are not held to it).
//   - Loss (more than 2 %, or a loss NACKs could not repair) remains as a
//     backstop, on the client's once-a-second statistics. The round trip
//     no longer counts: it shows a queue seconds after the one-way delay
//     does, and a queue on the way to the device is not the video's.
//
// When the JetKVM itself is the Tailscale peer (the path's remote end is a
// tailnet address), every packet also passes tailscaled's WireGuard on the
// device's single core: about 1.1 ms of CPU a packet against 0.45 ms for
// the rest of the send path, so the device saturates at about half the rate
// its bursts drain at, and saturated, it stalls the stream for hundreds of
// milliseconds (plan §32). Such a path starts no higher than balanced and
// its peaks stay below deviceTunnelShare of the rate, whatever the round
// trip.
//
// Steps up come one at a time after a stretch without congestion, which
// doubles when the link flaps between two levels. Off a LAN, the still
// refresh (the largest burst the device sends) is coded coarser, or not
// sent, when the measured rate would take longer than refreshBudget to
// deliver it. On a LAN (a round trip under lanRTT) the measured rate is the
// device's send path, not a limit, so only a real queue or loss leaves
// maximum.
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
	// PeakKbps caps the encoder's bitrate (patched firmware) below the
	// level's own peak, 1.5× its target; 0 = no cap.
	PeakKbps int
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
//   - Every level encodes up to 60 fps. A lower rate gives each moving frame
//     more bits (+1.5-2 dB while scrolling at low and minimal), but every
//     change, a key's echo or the pointer, waits for the next encoded frame:
//     over Tailscale with scrolling, a key took 117 ms at 15 fps and 89-93
//     ms at 60 or more (median). And a live frame rate change costs a keyframe (firmware
//     D06), so levels that differ only in bitrate and QP change for free.
var qualityLadder = []QualityLevel{
	{Name: "minimal", Factor: 0.25, MaxFPS: 60, MinQP: 26, StillQP: 26},
	{Name: "low", Factor: 0.5, MaxFPS: 60, MinQP: 21, StillQP: 17},
	{Name: "balanced", Factor: 1, MaxFPS: 60, MinQP: 18, StillQP: 8},
	{Name: "high", Factor: 2, MaxFPS: 60, MinQP: 14, StillQP: 4},
	{Name: "maximum", Factor: 3, MaxFPS: 60, MinQP: 10, StillQP: 1},
}

const (
	// qualityTick is how often the governor looks: often enough to answer a
	// queue within 100-200 ms. The transport statistics behind the loss
	// checks refresh once a second.
	qualityTick = 100 * time.Millisecond
	// queueHigh is the wait behind earlier traffic that steps down when all
	// frames of a video.QueueWindow exceed it and it does not shrink. It is
	// above a cellular link's jitter (10-30 ms) and the device's encode time
	// variation, and well below the 150-300 ms where lag starts to show. In
	// the harness, scrolling at maximum (8 Mbit/s) over 4 Mbit/s crosses it
	// 200 ms into the scroll.
	queueHigh = 60 * time.Millisecond
	// queueCooldown separates two steps down for a queue, so what queued
	// before the first can start to drain.
	queueCooldown = time.Second
	// repairShareHigh is the share of retransmissions in what arrives that
	// makes a queue the repair's (in the harness 60-100 % after an outage,
	// against a few percent from random loss).
	repairShareHigh = 0.25
	// linkUse is the share of the measured delivery rate a level's bitrate
	// target may take for a step up to it: the encoder's peaks run at 1.5×
	// the target, and on a jittery link small frames measure the rate up to
	// 20 % low. A level is left once its target exceeds the whole rate.
	linkUse = 0.8
	// rateEvidence is the fewest bytes of multi-packet frames the delivery
	// rate must rest on, and rateMinFrames the fewest frames: about a second
	// of scrolling, even at the lowest level. One keyframe alone is not
	// enough.
	rateEvidence  = 40_000
	rateMinFrames = 5
	// peakShare is the share of the measured rate the encoder's peak may
	// take off a LAN; deviceTunnelShare replaces it when the JetKVM runs
	// WireGuard itself. Over Tailscale to the device (1456×920 at 90 Hz,
	// balanced's QP floor), peaks of 2, 2.5 and 3.9 Mbit/s against a rate
	// of 3.7 left the device's core saturated in 20, 31 and over 40 % of
	// scrolling, and a key's echo took 138, 195 and 258 ms (p90).
	peakShare         = 0.9
	deviceTunnelShare = 0.55
	// peakChange is the least relative change of the peak cap that is
	// applied, and peakHold the least time between two changes: each one
	// restarts the encoder's rate control (firmware D07).
	peakChange = 0.25
	peakHold   = 5 * time.Second
	// lanRTT is the round trip below which the link is a LAN.
	lanRTT = 8 * time.Millisecond
	// refreshBudget is the longest the still refresh may hold the link off
	// a LAN: the frames behind it (the echo of the next keystroke) wait as
	// long. On a LAN the device's own send path takes 110-140 ms for it.
	// keyframeBytesQP10 and qpStep model its size: 231 kB for a 1080p
	// keyframe at QP 10, 5 % less for each QP step (fits the device's
	// 123-350 kB at QP 24-1 within 10 %; plan §21, §23).
	refreshBudget     = 200 * time.Millisecond
	keyframeBytesQP10 = 231_000
	qpStep            = 0.95
	// downCooldown is the least time between two steps down for loss.
	downCooldown = 4 * time.Second
	// upAfterClean is the time without congestion before a step up. A step
	// down soon after a step up (a link between two rungs) doubles it, up to
	// maxUpDelay; a long stretch without steps down restores it. Stock
	// firmware restarts its encoder on every change, so it waits longer.
	upAfterClean        = 20 * time.Second
	upAfterCleanStock   = time.Minute
	maxUpDelay          = 5 * time.Minute
	flapWindow          = time.Minute
	lossThreshold       = 0.02 // fraction of packets lost in a sample
	severeLossThreshold = 0.10
	// minLossSample is the fewest packets a sample's loss rate needs: a
	// still screen sends a handful a second, where one loss would read as
	// a severe 15 %.
	minLossSample     = 100
	approxPacketBytes = 1150 // RTP payloads are ~1200 bytes
)

// qualityGovernor decides level changes from transport samples and link
// estimates. It holds no locks and does no I/O, so it is unit-testable with
// synthetic data.
type qualityGovernor struct {
	level         int
	stillQP       int // the level's still refresh QP on this link
	peakKbps      int // the encoder's peak cap on this link, 0 = none
	peakAt        time.Time
	deviceTunnel  bool // the JetKVM runs WireGuard itself (setPath)
	lanPath       bool // the path is a LAN (setPath): the client may refresh whole frames
	clientRefresh bool // the client plans still refreshes (Config.ClientRefresh, D13)
	width, height int  // the video's, for the levels' bitrates and keyframes
	lastChange    time.Time
	lastUp        time.Time
	lastDown      time.Time
	baseUp        time.Duration
	upDelay       time.Duration
	cleanSince    time.Time
	baseRTT       time.Duration
	baseAt        time.Time
	congestedN    int
	prev          client.StatsSnapshot
	havePrev      bool
}

func newQualityGovernor(now time.Time, rtt, baseUp time.Duration) *qualityGovernor {
	// No change yet: the first step down may come at once.
	g := &qualityGovernor{cleanSince: now, baseUp: baseUp, upDelay: baseUp, baseRTT: rtt, baseAt: now}
	// Until the link's rate is measured: maximum on a LAN, high on a short
	// round trip, balanced elsewhere.
	switch {
	case rtt > 0 && rtt < lanRTT:
		g.level = len(qualityLadder) - 1
	case rtt > 0 && rtt < 40*time.Millisecond:
		g.level = len(qualityLadder) - 2
	default:
		g.level = 2
	}
	g.stillQP = qualityLadder[g.level].StillQP
	return g
}

// params is the current level as applied: the ladder's, with the still
// refresh QP and the peak cap for the link.
func (g *qualityGovernor) params() QualityLevel {
	l := qualityLadder[g.level]
	l.StillQP, l.PeakKbps = g.stillQP, g.peakKbps
	return l
}

// setPath records the path a statistics sample names (client.StatsSnapshot
// Path and PathRemote; a sample without a selected pair changes nothing),
// and reports whether that lowered the level: with Tailscale on the JetKVM,
// a session that hasn't changed level yet starts no higher than balanced,
// since the device can't send high's bitrate through tailscaled.
func (g *qualityGovernor) setPath(kind, remote string) bool {
	if remote == "" {
		return false
	}
	g.deviceTunnel = client.InTailnet(remote)
	g.lanPath = kind == client.PathLAN || kind == client.PathLoopback
	if g.deviceTunnel && g.lastChange.IsZero() && g.level > 2 {
		g.level, g.stillQP = 2, qualityLadder[2].StillQP
		return true
	}
	return false
}

// rated reports a delivery rate measured on enough frames to act on.
func rated(link video.LinkEstimate) bool {
	return link.RateBytes >= rateEvidence && link.RateFrames >= rateMinFrames
}

// updatePeak sets the encoder's peak cap off a LAN to the share of the
// measured rate the path takes, and reports whether it changed. Small
// changes, and changes within peakHold of the last, wait. Tailscale on the
// JetKVM costs its CPU per packet, however short the round trip, so such a
// path keeps its cap on a LAN too.
func (g *qualityGovernor) updatePeak(now time.Time, link video.LinkEstimate) bool {
	if g.onLAN() && !g.deviceTunnel {
		// A LAN's rate is the device's send path, not a limit.
		cleared := g.peakKbps > 0
		g.peakKbps = 0
		return cleared
	}
	if !rated(link) {
		return false
	}
	share := peakShare
	if g.deviceTunnel {
		share = deviceTunnelShare
	}
	kbps := int(share * link.Rate / 1000)
	if g.peakKbps > 0 && (now.Sub(g.peakAt) < peakHold ||
		math.Abs(float64(kbps-g.peakKbps)) < peakChange*float64(g.peakKbps)) {
		return false
	}
	g.peakKbps, g.peakAt = kbps, now
	return true
}

// observe takes the latest transport sample and link estimate and returns
// the level, and why it changed ("" if it did not).
func (g *qualityGovernor) observe(now time.Time, s client.StatsSnapshot, link video.LinkEstimate) (int, string) {
	lossy, severe := g.transport(now, s)
	queued := link.QueueFrames >= 2 && link.Queue > queueHigh && link.QueueGrowth >= 0 && link.RepairShare < repairShareHigh
	if lossy || queued {
		g.cleanSince = now
	}
	measured := rated(link)
	carried := g.carried(link.Rate)
	lan := g.onLAN()
	switch {
	case queued:
		if now.Sub(g.lastChange) < queueCooldown {
			break
		}
		// The link was busy for the whole window: what it delivered is its
		// rate now.
		to := g.level - 1
		if link.Delivered > 0 {
			to = min(to, g.carried(link.Delivered))
		}
		return g.down(now, to, link, "queue")
	case measured && !lan && g.lastChange.IsZero():
		// The session starts at the level the link carries, instead of the
		// round trip's guess, with the still refresh it carries.
		if carried > g.level {
			return g.up(now, carried, link, "start")
		}
		g.level, g.lastChange = carried, now
		g.stillQP = g.stillQPFor(carried, link)
		return g.level, "start"
	case measured && !lan && g.target(g.level) > link.Rate:
		return g.down(now, carried, link, "rate")
	case lossy && (severe || g.congestedN >= 2):
		if now.Sub(g.lastChange) < downCooldown {
			break
		}
		step := 1
		if severe && g.level >= 2 {
			step = 2
		}
		return g.down(now, g.level-step, link, "loss")
	case !lossy && measured && carried > g.level && link.Queue < queueHigh/2 &&
		now.Sub(g.cleanSince) >= g.upDelay && now.Sub(g.lastChange) >= g.upDelay:
		if now.Sub(g.lastDown) >= maxUpDelay {
			g.upDelay = g.baseUp
		}
		return g.up(now, g.level+1, link, "rate")
	}
	return g.level, ""
}

// transport reads a new statistics sample (the client takes one a second):
// the loss since the previous one, and the round trip's baseline.
func (g *qualityGovernor) transport(now time.Time, s client.StatsSnapshot) (congested, severe bool) {
	if !g.havePrev {
		g.prev, g.havePrev = s, true
		return false, false
	}
	// Statistics refresh on their own timer: the same sample read twice
	// would look like a perfectly clean second.
	if !s.SampledAt.IsZero() && !s.SampledAt.After(g.prev.SampledAt) {
		return false, false
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
	if lost+received >= minLossSample {
		lossRate = lost / (lost + received)
	}
	// A new keyframe wait means a loss NACKs could not repair. Frames the
	// assembler drops while waiting (also before the first keyframe of a
	// session) are not counted again.
	unrepaired := s.KeyframeWaits > prev.KeyframeWaits
	congested = lossRate > lossThreshold || unrepaired
	if congested {
		g.congestedN++
	} else {
		g.congestedN = 0
	}
	return congested, congested && lossRate > severeLossThreshold
}

// onLAN reports a round trip below lanRTT: the measured rate is then the
// device's send path, not a limit to keep below.
func (g *qualityGovernor) onLAN() bool { return g.baseRTT > 0 && g.baseRTT < lanRTT }

// target is a level's bitrate target in bit/s at the video's size.
func (g *qualityGovernor) target(level int) float64 {
	return 1000 * float64(factorKbps(qualityLadder[level].Factor, g.width, g.height))
}

// carried is the highest level whose bitrate target fits a link of rate
// (bit/s) with room to spare (linkUse), or the lowest.
func (g *qualityGovernor) carried(rate float64) int {
	level := len(qualityLadder) - 1
	for level > 0 && g.target(level) > linkUse*rate {
		level--
	}
	return level
}

func (g *qualityGovernor) down(now time.Time, to int, link video.LinkEstimate, why string) (int, string) {
	to = max(to, 0)
	if to >= g.level {
		return g.level, ""
	}
	if !g.lastUp.IsZero() && now.Sub(g.lastUp) < flapWindow {
		g.upDelay = min(2*g.upDelay, maxUpDelay)
	}
	g.level, g.stillQP = to, g.stillQPFor(to, link)
	g.lastChange, g.lastDown = now, now
	return g.level, why
}

func (g *qualityGovernor) up(now time.Time, to int, link video.LinkEstimate, why string) (int, string) {
	g.level, g.stillQP = to, g.stillQPFor(to, link)
	g.lastChange, g.lastUp, g.cleanSince = now, now, now
	return g.level, why
}

// stillQPFor is a level's still refresh QP on the link: the ladder's, or
// coarser until the refresh keyframe takes no longer than refreshBudget at
// the measured rate. At the level's QP floor there is no refresh. A LAN, or
// a rate not yet measured, keeps the ladder's.
func (g *qualityGovernor) stillQPFor(level int, link video.LinkEstimate) int {
	l := qualityLadder[level]
	if !rated(link) || g.onLAN() {
		return l.StillQP
	}
	width, height := cmp.Or(g.width, 1920), cmp.Or(g.height, 1080)
	budget := link.Rate / 8 * refreshBudget.Seconds() // bytes
	qp := l.StillQP
	for ; qp < l.MinQP; qp++ {
		if keyframeBytesQP10*float64(width*height)/(1920*1080)*math.Pow(qpStep, float64(qp-10)) <= budget {
			break
		}
	}
	// A client that plans refreshes sends only region refreshes off a LAN
	// path (RefreshPlanner.isLANLike), which the device codes at the QP
	// floor whatever stillQp is, but which stillQp at the floor turns off. Under a peak cap, moving content is
	// coded far above the floor: on balanced over Tailscale, a still picture
	// after scrolling stayed at 44 dB, against 50 refreshed. One step below
	// the floor keeps them, and other keyframes nearly at the floor's size.
	if g.clientRefresh && !g.lanPath && qp >= l.MinQP && l.StillQP < l.MinQP {
		qp = l.MinQP - 1
	}
	return qp
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
	return c.applyLevel(ctx, cl, qualityLadder[level])
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

// applyLevel sets a level on the device: live on firmware with the encoder
// patch, through the quality factor (an encoder restart) otherwise.
func (c *Controller) applyLevel(ctx context.Context, cl *client.Client, l QualityLevel) error {
	log := logging.Subsystem("quality")
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
		target, peak := l.bitrates(w, h)
		// Firmware from before the still refresh ignores stillQp.
		update := map[string]any{
			"minQp": l.MinQP, "maxFps": l.MaxFPS, "bitrateKbps": target, "maxBitrateKbps": peak,
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
		log.Info().Str("level", l.Name).Int("kbps", target).Int("peakKbps", peak).Int("maxFps", l.MaxFPS).Int("minQp", l.MinQP).Int("stillQp", l.StillQP).
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
			_ = c.applyLevel(ctx, cl, qualityLadder[level])
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
	live, err := c.encoderParams(ctx, cl)
	if err == nil && live {
		baseUp = upAfterClean
	}
	c.mu.RLock()
	clientRefresh := c.cfg.ClientRefresh
	c.mu.RUnlock()
	clientRefresh = clientRefresh && live && cl.HasFirmwareFeature(ctx, client.FeatureRefreshRegions)
	videoSize := func() [2]int {
		c.mu.RLock()
		defer c.mu.RUnlock()
		return [2]int{c.snapshot.VideoWidth, c.snapshot.VideoHeight}
	}
	size := videoSize()
	stats := cl.Stats()
	gov := newQualityGovernor(time.Now(), time.Duration(stats.RoundTripMs*float64(time.Millisecond)), baseUp)
	gov.width, gov.height = size[0], size[1]
	gov.clientRefresh = clientRefresh
	gov.setPath(stats.Path, stats.PathRemote)
	// The rate may be measured by now (the stream's first frames are not
	// counted); otherwise the round trip's guess stands until it is.
	link := cl.LinkEstimate()
	gov.observe(time.Now(), cl.Stats(), link)
	gov.updatePeak(time.Now(), link)
	_ = c.applyLevel(ctx, cl, gov.params())

	log := logging.Subsystem("quality")
	ticker := time.NewTicker(qualityTick)
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
			// The bitrate follows the resolution (the firmware's formula).
			changed := false
			if s := videoSize(); s != size {
				size, changed = s, true
				gov.width, gov.height = s[0], s[1]
			}
			link := cl.LinkEstimate()
			stats := cl.Stats()
			if gov.setPath(stats.Path, stats.PathRemote) {
				changed = true
			}
			level, why := gov.observe(now, stats, link)
			if why != "" {
				log.Info().Str("why", why).Str("level", qualityLadder[level].Name).Dur("queue", link.Queue).
					Float64("rateMbps", link.Rate/1e6).Msg("stream quality changes")
				changed = true
			}
			if gov.updatePeak(now, link) {
				log.Info().Int("peakKbps", gov.peakKbps).Float64("rateMbps", link.Rate/1e6).Bool("deviceTunnel", gov.deviceTunnel).
					Msg("stream peak follows the link")
				changed = true
			}
			if changed {
				_ = c.applyLevel(ctx, cl, gov.params())
			}
		}
	}
}

// bitrates are a live level's bitrate target and peak in kbps at the video's
// size: the factor's, with the peak at 1.5× the target. A lower PeakKbps
// replaces the peak, and the target where it is lower still (the firmware
// takes at least 100 kbps).
func (l QualityLevel) bitrates(width, height int) (target, peak int) {
	target = factorKbps(l.Factor, width, height)
	peak = target * 3 / 2
	if l.PeakKbps > 0 && l.PeakKbps < peak {
		peak = max(l.PeakKbps, 100)
		target = min(target, peak)
	}
	return target, peak
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
