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
//     and refreshes are not held to it). Firmware with frame pacing (D18)
//     also paces the frames to paceOverPeak of that peak, so a keyframe or a
//     run of large frames thins out instead of queueing in front of the next
//     change.
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
// deliver it. On a LAN (onLAN: a round trip under lanRTT, or a Wi-Fi or
// Ethernet one to the device's subnet) the measured rate is the device's
// send path, not a limit, so only a real queue or loss leaves maximum, and
// maximum encodes every captured frame (sourceRatePixels).
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
	MaxFPS int     // encode frame rate cap; 0 = the source rate (patched firmware)
	MinQP  int     // QP floor (patched firmware); lower = sharper, larger keyframes
	// StillQP is the QP of the keyframe the patched firmware sends once the
	// screen has been still for half a second; >= MinQP turns it off.
	StillQP int
	// PeakKbps caps the encoder's bitrate (patched firmware) below the
	// level's own peak, 1.5× its target; 0 = no cap.
	PeakKbps int
	// PaceKbps paces the frames (firmware D18): a captured frame is left out
	// while the encoded bytes run more than 40 ms ahead of it; 0 = off.
	PaceKbps int
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
//   - Every level encodes up to 60 fps (maximum on a LAN every captured
//     frame, params). A lower rate gives each moving frame more bits
//     (+1.5-2 dB while scrolling at low and minimal), but every change, a
//     key's echo or the pointer, waits for the next encoded frame: over
//     Tailscale with scrolling, a key took 117 ms at 15 fps and 89-93 ms at
//     60 or more (median). And a live frame rate change cost a keyframe
//     before firmware D18, so levels that differ only in bitrate and QP
//     change for free on any firmware.
var qualityLadder = []QualityLevel{
	{Name: "minimal", Factor: 0.25, MaxFPS: 60, MinQP: 26, StillQP: 26},
	{Name: "low", Factor: 0.5, MaxFPS: 60, MinQP: 21, StillQP: 17},
	{Name: "balanced", Factor: 1, MaxFPS: 60, MinQP: 18, StillQP: 8},
	{Name: "high", Factor: 2, MaxFPS: 60, MinQP: 14, StillQP: 4},
	{Name: "maximum", Factor: 3, MaxFPS: 60, MinQP: 10, StillQP: 1},
}

// gameLevel replaces maximum at the top of the ladder in Game Mode, and a
// manual level: maximum's bitrate with a coarser QP floor, which keeps
// keyframes and large changes smaller (about half maximum's keyframe,
// keyframeBytesQP10 and qpStep) and so shorter in the send path, and no
// still refresh (StillQP at the floor), whose keyframe would hold back the
// frames behind it. MinQP and Factor are starting values.
var gameLevel = QualityLevel{Name: "game", Factor: 3, MaxFPS: 60, MinQP: 22, StillQP: 22}

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
	// paceOverPeak sets the frame pacing (firmware D18) relative to the
	// peak cap off a LAN: above the measured rate, so pacing only thins out
	// what would queue. At 1.25 the emulator's scrolling over LTE had half
	// the p99 delay (153 → 81 ms) and no link froze longer; at 1.0, a rate
	// measured low held the frames after a keyframe longer than the link
	// did (desktop over hotel Wi-Fi: a 1.4 s freeze, none at 1.25).
	paceOverPeak = 1.25
	// peakChange is the least relative change of the peak cap that is
	// applied, and peakHold the least time between two changes: each one
	// restarts the encoder's rate control (firmware D07).
	peakChange = 0.25
	peakHold   = 5 * time.Second
	// lanRTT is the round trip below which the link is a LAN. A LAN path to
	// the device's own subnet (client.StatsSnapshot.PathOnLink) is one too
	// while its lowest round trip stays below lanPathRTT: Wi-Fi's power save
	// and retries keep it above lanRTT (5-35 ms at home, its lowest of a
	// minute 6-9 ms) though the device's send path is still what limits it.
	lanRTT     = 8 * time.Millisecond
	lanPathRTT = 30 * time.Millisecond
	// sourceRatePixels bounds the pixel rate at which the top level encodes
	// every captured frame on a LAN, on firmware where a frame rate change
	// costs no keyframe (D18, with frame pacing): the encoder's own, 1080p60;
	// the ladder caps the rest at 60 fps. At 1456×920, 90 Hz over Wi-Fi,
	// keys showed 3 ms sooner (median; 8 ms at p75) and pointer moves 4-6 ms
	// at p75-p90, moving frames lost 0.1-0.2 dB and the device kept 56-59 %
	// idle.
	sourceRatePixels = 1920 * 1080 * 60
	// baseWindow is how far back the round trip's baseline (its lowest)
	// looks.
	baseWindow = time.Minute
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
	paceKbps      int // the frame pacing on this link, 0 = none
	peakAt        time.Time
	framePacing   bool   // the firmware paces frames (client.FeatureFramePacing)
	deviceTunnel  bool   // the JetKVM runs WireGuard itself (setPath)
	lanPath       bool   // the path is a LAN (setPath): the client may refresh whole frames
	onLink        bool   // the path is a LAN to the device's subnet (setPath, lanPathRTT)
	path          string // the path's kind and remote address (setPath)
	pathRemote    string
	clientRefresh bool    // the client plans still refreshes (Config.ClientRefresh, D13)
	gameMode      bool    // Config.GameMode: gameLevel at the top, no still refresh
	width, height int     // the video's, for the levels' bitrates and keyframes
	sourceFPS     float64 // the video's frame rate
	lastChange    time.Time
	started       time.Time // the start level's lastChange: no step since (observe)
	lastUp        time.Time
	lastDown      time.Time
	baseUp        time.Duration
	upDelay       time.Duration
	cleanSince    time.Time
	baseRTT       time.Duration // the lowest of rtts
	rtts          []rttSample   // the round trips of the last baseWindow
	congestedN    int
	prev          client.StatsSnapshot
	havePrev      bool
}

type rttSample struct {
	at  time.Time
	rtt time.Duration
}

func newQualityGovernor(now time.Time, rtt, baseUp time.Duration) *qualityGovernor {
	// No change yet: the first step down may come at once.
	g := &qualityGovernor{cleanSince: now, baseUp: baseUp, upDelay: baseUp}
	g.noteRTT(now, rtt)
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

// params is the current level as applied: the ladder's (gameLevel at the
// top in Game Mode), with the still refresh QP and the peak cap for the
// link.
func (g *qualityGovernor) params() QualityLevel {
	top := g.level == len(qualityLadder)-1
	l := qualityLadder[g.level]
	if g.gameMode && top {
		l = gameLevel
	}
	l.StillQP, l.PeakKbps, l.PaceKbps = g.stillQP, g.peakKbps, g.paceKbps
	if top && g.onLAN() && !g.deviceTunnel && g.framePacing &&
		g.width > 0 && g.height > 0 && g.sourceFPS > float64(l.MaxFPS)+1 &&
		float64(g.width*g.height)*g.sourceFPS <= sourceRatePixels {
		l.MaxFPS = 0 // the source rate (sourceRatePixels)
	}
	if g.gameMode {
		// No still refresh at any level. Pacing stays off on a LAN
		// (updatePeak) and stays where Tailscale on the device or a slow
		// link needs it.
		l.StillQP = l.MinQP
	}
	return l
}

// setPath records the path a statistics sample names (Path, PathRemote and
// PathOnLink; a sample without a selected pair changes nothing), and reports
// whether that lowered the level: with Tailscale on the JetKVM, a session
// that hasn't changed level yet starts no higher than balanced, since the
// device can't send high's bitrate through tailscaled.
func (g *qualityGovernor) setPath(s client.StatsSnapshot) bool {
	if s.PathRemote == "" {
		return false
	}
	if g.pathRemote != "" && (s.Path != g.path || s.PathRemote != g.pathRemote) {
		// Another path: the old one's round trips say nothing about it.
		g.rtts, g.baseRTT = nil, 0
	}
	g.path, g.pathRemote = s.Path, s.PathRemote
	g.deviceTunnel = client.InTailnet(s.PathRemote)
	g.lanPath = s.Path == client.PathLAN || s.Path == client.PathLoopback
	g.onLink = s.Path == client.PathLAN && s.PathOnLink
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
		cleared := g.peakKbps > 0 || g.paceKbps > 0
		g.peakKbps, g.paceKbps = 0, 0
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
	if g.framePacing {
		// The firmware takes 100-50,000 kbps.
		g.paceKbps = min(max(int(paceOverPeak*float64(kbps)), 100), 50_000)
	}
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
	case lan && !lossy && !g.deviceTunnel && g.lastChange.Equal(g.started) && g.level < len(qualityLadder)-1:
		// A LAN found after the start (the first round trips were a Wi-Fi
		// spike) starts at the top too, as a LAN does.
		top := len(qualityLadder) - 1
		g.level, g.stillQP = top, g.stillQPFor(top, link)
		g.lastChange, g.started = now, now
		return g.level, "start"
	case measured && !lan && g.lastChange.IsZero():
		// The session starts at the level the link carries, instead of the
		// round trip's guess, with the still refresh it carries.
		g.started = now
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
	g.noteRTT(now, time.Duration(s.RoundTripMs*float64(time.Millisecond)))
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

// noteRTT adds a round trip sample to the baseline: the lowest of the last
// baseWindow, which queues and Wi-Fi spikes don't move.
func (g *qualityGovernor) noteRTT(now time.Time, rtt time.Duration) {
	if rtt <= 0 {
		return
	}
	g.rtts = append(g.rtts, rttSample{now, rtt})
	keep := g.rtts[:0]
	g.baseRTT = 0
	for _, s := range g.rtts {
		if now.Sub(s.at) > baseWindow {
			continue
		}
		keep = append(keep, s)
		if g.baseRTT == 0 || s.rtt < g.baseRTT {
			g.baseRTT = s.rtt
		}
	}
	g.rtts = keep
}

// onLAN reports a LAN (lanRTT, lanPathRTT): the measured rate is then the
// device's send path, not a limit to keep below.
func (g *qualityGovernor) onLAN() bool {
	return g.baseRTT > 0 && (g.baseRTT < lanRTT || g.onLink && g.baseRTT < lanPathRTT)
}

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
	wasAuto := c.cfg.AutoQuality
	c.cfg.AutoQuality = on
	if !on && wasAuto && c.snapshot.QualityLevel != "" {
		// Keep what automatic had chosen, also for reconnects; the game
		// level stands in for maximum.
		level := c.snapshot.QualityLevel
		if level == gameLevel.Name {
			level = qualityLadder[len(qualityLadder)-1].Name
		}
		c.cfg.QualityLevel = level
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
	return c.applyManual(ctx, cl)
}

// SetGameMode turns Game Mode on or off for this session (and its
// reconnects). Automatic quality's governor takes it up within a
// qualityTick; a manual level is applied here: the game level in Game Mode,
// the configured one again after it.
func (c *Controller) SetGameMode(ctx context.Context, on bool) error {
	c.mu.Lock()
	c.cfg.GameMode = on
	c.snapshot.GameMode = on
	auto := c.cfg.AutoQuality
	c.mu.Unlock()
	cl := c.clientIfConnected()
	if cl == nil {
		return nil // applied on connect
	}
	if on {
		c.checkRelativeMouse(ctx, cl)
	}
	if auto {
		return nil
	}
	return c.applyManual(ctx, cl)
}

// checkRelativeMouse reports whether the device's relative mouse, which
// games read, is off. It never changes the device's USB functions.
func (c *Controller) checkRelativeMouse(ctx context.Context, cl *client.Client) {
	devices, err := cl.GetUSBDevices(ctx)
	if err != nil {
		log := logging.Subsystem("quality")
		log.Debug().Err(err).Msg("get USB devices")
		return
	}
	c.setStateFor(cl, func(s *Snapshot) { s.RelativeMouseOff = !devices.RelativeMouse })
}

// gameSavedState is what Game Mode replaced on the device while no level was
// configured (Controller.gameSaved).
type gameSavedState struct {
	saved  bool
	live   bool
	factor float64         // stock firmware's quality factor
	params json.RawMessage // getVideoEncoderParams
}

// applyManual applies the configured level when automatic quality is off:
// the game level in Game Mode, otherwise the configured level, or, with none,
// what Game Mode replaced.
func (c *Controller) applyManual(ctx context.Context, cl *client.Client) error {
	c.mu.RLock()
	game, level := c.cfg.GameMode, levelIndex(c.cfg.QualityLevel)
	c.mu.RUnlock()
	if game {
		if level < 0 {
			if err := c.saveForGame(ctx, cl); err != nil {
				return err
			}
		}
		return c.applyLevel(ctx, cl, gameLevel)
	}
	c.mu.Lock()
	saved := c.gameSaved
	c.gameSaved = gameSavedState{}
	c.mu.Unlock()
	if level >= 0 {
		return c.applyLevel(ctx, cl, qualityLadder[level])
	}
	return c.restoreFromGame(ctx, cl, saved)
}

// saveForGame keeps the device's own quality before Game Mode first changes
// it, once: the stock quality factor is a device setting that outlives the
// session, and live parameters are what the device ran with.
func (c *Controller) saveForGame(ctx context.Context, cl *client.Client) error {
	c.mu.RLock()
	saved := c.gameSaved.saved
	c.mu.RUnlock()
	if saved {
		return nil
	}
	live, err := c.encoderParams(ctx, cl)
	if err != nil {
		return err
	}
	state := gameSavedState{saved: true, live: live}
	if live {
		err = cl.Call(ctx, "getVideoEncoderParams", nil, &state.params)
	} else {
		state.factor, err = cl.GetStreamQualityFactor(ctx)
	}
	if err != nil {
		return err
	}
	c.mu.Lock()
	c.gameSaved = state
	c.mu.Unlock()
	return nil
}

// restoreFromGame puts back what saveForGame kept.
func (c *Controller) restoreFromGame(ctx context.Context, cl *client.Client, saved gameSavedState) error {
	if !saved.saved {
		return nil
	}
	if saved.live {
		if err := cl.Call(ctx, "setVideoEncoderParams", map[string]any{"params": saved.params}, nil); err != nil {
			return err
		}
		// No level of ours applies, as at a new session.
		c.setStateFor(cl, func(s *Snapshot) { s.QualityLevel, s.ClientRefresh, s.MinQP, s.StillQP = "", false, 0, 0 })
		return nil
	}
	current, err := cl.GetStreamQualityFactor(ctx)
	if err != nil {
		return err
	}
	if current != saved.factor {
		if err := cl.SetStreamQualityFactor(ctx, saved.factor); err != nil {
			return err
		}
	}
	c.setStateFor(cl, func(s *Snapshot) { s.QualityLevel, s.Quality = "", saved.factor })
	return nil
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
		game := c.cfg.GameMode
		c.mu.RUnlock()
		// Game Mode has no still refresh, the device's or the client's.
		clientRefresh = !game && clientRefresh && cl.HasFirmwareFeature(ctx, client.FeatureRefreshRegions)
		target, peak := l.bitrates(w, h)
		// Firmware from before the still refresh ignores stillQp.
		update := map[string]any{
			"minQp": l.MinQP, "maxFps": l.MaxFPS, "bitrateKbps": target, "maxBitrateKbps": peak,
			"stillQp": l.StillQP,
		}
		if clientRefresh || game {
			update["autoRefresh"] = false
		}
		// Sent with every level, so a manual level turns pacing off again.
		if cl.HasFirmwareFeature(ctx, client.FeatureFramePacing) {
			update["paceKbps"] = l.PaceKbps
		}
		if err := cl.Call(ctx, "setVideoEncoderParams", map[string]any{"params": update}, nil); err != nil {
			log.Warn().Err(err).Msg("set encoder params")
			return err
		}
		c.setStateFor(cl, func(s *Snapshot) { s.ClientRefresh, s.MinQP, s.StillQP = clientRefresh, l.MinQP, l.StillQP })
		log.Info().Str("level", l.Name).Int("kbps", target).Int("peakKbps", peak).Int("paceKbps", l.PaceKbps).Int("maxFps", l.MaxFPS).Int("minQp", l.MinQP).Int("stillQp", l.StillQP).
			Bool("clientRefresh", clientRefresh).Bool("gameMode", game).Msg("stream quality (live)")
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
	auto, game := c.cfg.AutoQuality, c.cfg.GameMode
	if game {
		go c.checkRelativeMouse(ctx, cl)
	}
	if !auto {
		c.mu.Unlock()
		_ = c.applyManual(ctx, cl)
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
	clientRefresh, game := c.cfg.ClientRefresh, c.cfg.GameMode
	c.mu.RUnlock()
	clientRefresh = clientRefresh && live && cl.HasFirmwareFeature(ctx, client.FeatureRefreshRegions)
	// The bitrate follows the resolution (the firmware's formula), the
	// source rate the frame rate.
	type videoMode struct {
		width, height int
		fps           float64
	}
	currentMode := func() videoMode {
		c.mu.RLock()
		defer c.mu.RUnlock()
		return videoMode{c.snapshot.VideoWidth, c.snapshot.VideoHeight, c.snapshot.VideoFPS}
	}
	stats := cl.Stats()
	gov := newQualityGovernor(time.Now(), time.Duration(stats.RoundTripMs*float64(time.Millisecond)), baseUp)
	mode := currentMode()
	gov.width, gov.height, gov.sourceFPS = mode.width, mode.height, mode.fps
	gov.clientRefresh, gov.gameMode = clientRefresh, game
	gov.framePacing = live && cl.HasFirmwareFeature(ctx, client.FeatureFramePacing)
	gov.setPath(stats)
	// The rate may be measured by now (the stream's first frames are not
	// counted); otherwise the round trip's guess stands until it is.
	link := cl.LinkEstimate()
	gov.observe(time.Now(), cl.Stats(), link)
	gov.updatePeak(time.Now(), link)
	applied := gov.params()
	_ = c.applyLevel(ctx, cl, applied)

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
			game := c.cfg.GameMode
			c.mu.RUnlock()
			if !on {
				return
			}
			changed := false
			if game != gov.gameMode {
				// SetGameMode: the current level again, with or without it.
				gov.gameMode, changed = game, true
			}
			if m := currentMode(); m != mode {
				mode, changed = m, true
				gov.width, gov.height, gov.sourceFPS = m.width, m.height, m.fps
			}
			link := cl.LinkEstimate()
			stats := cl.Stats()
			if gov.setPath(stats) {
				changed = true
			}
			level, why := gov.observe(now, stats, link)
			if why != "" {
				log.Info().Str("why", why).Str("level", qualityLadder[level].Name).Dur("queue", link.Queue).
					Float64("rateMbps", link.Rate/1e6).Msg("stream quality changes")
				changed = true
			}
			if gov.updatePeak(now, link) {
				log.Info().Int("peakKbps", gov.peakKbps).Int("paceKbps", gov.paceKbps).Float64("rateMbps", link.Rate/1e6).Bool("deviceTunnel", gov.deviceTunnel).
					Msg("stream peak follows the link")
				changed = true
			}
			// The link turning LAN or not changes the parameters too.
			if p := gov.params(); changed || p != applied {
				applied = p
				_ = c.applyLevel(ctx, cl, p)
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
