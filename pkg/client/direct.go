package client

import (
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/pion/stun/v4"
)

// A direct path past the device's own Tailscale. With tailscaled on the
// JetKVM, its single ARMv7 core encrypts every packet of the stream (about
// 1.1 ms of CPU each, a cap near 2.5 Mbit/s), and Tailscale may relay the
// packets through DERP besides. When the app reaches the device that way,
// the session request names public STUN servers: fork firmware with
// FeatureSTUNServers then gathers its public address as well (D19). The
// client gathers on its physical default route too, so ICE can find a UDP
// path through both NATs, or the LAN when both ends are at home. The device's
// tailnet candidates are demoted below every other kind, and host pairs wait
// directHostWait before they may be nominated, so a direct pair that answers
// in time wins; otherwise the tunnel pair is nominated as before.
//
// The client keeps its own tailnet candidates to itself: a check from the
// device that arrived before the device's trickled candidate would make that
// candidate peer-reflexive at the device's own priority, which pion keeps
// when the demoted one arrives, and the tunnel would win. The device learns
// the client's tunnel address from the client's checks instead.
//
// A device and network where the tunnel won anyway are not tried again for
// directRetryAfter (per engine process: a device window).

// directSTUNServers are asked for both ends' public addresses. They see
// those addresses and nothing else; the stream never passes them.
var directSTUNServers = []string{"stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"}

// stunServers returns the stun: URLs of BLITZKVM_STUN_SERVERS (space
// separated) where it is set, for STUN servers of one's own (or an
// unreachable one, to test the fallback), else directSTUNServers. A URL pion
// can't parse would fail the whole connection, so it is left out.
func stunServers() []string {
	raw, ok := os.LookupEnv("BLITZKVM_STUN_SERVERS")
	if !ok {
		return directSTUNServers
	}
	var urls []string
	for _, u := range strings.Fields(raw) {
		if uri, err := stun.ParseURI(u); err == nil && uri.Scheme == stun.SchemeTypeSTUN {
			urls = append(urls, u)
		}
	}
	return urls
}

const (
	// directHostWait holds back host pairs (the tunnel's among them) so
	// server-reflexive ones, a STUN round trip later, can answer first; those
	// wait for nothing. Measured over the internet to the device: a session
	// connected in 1.4-1.6 s on the direct path, as on the tunnel, and in
	// 2.8 s where no direct path worked.
	directHostWait   = 1500 * time.Millisecond
	directRetryAfter = 30 * time.Minute
)

// directFailures maps directCacheKey to when a direct attempt ended on the
// tunnel.
var directFailures sync.Map

// directPlan returns the client's physical default-route addresses when a
// connection over local should try a direct path to remote: local is a
// tailnet address and remote a Tailscale node itself (a device behind a
// subnet router does not run tailscaled, so the tunnel costs it nothing).
// Nil when it should not, or when there is no physical default route.
func directPlan(local, remote, physical []net.IP) []net.IP {
	if len(physical) == 0 {
		return nil
	}
	for _, ip := range local {
		if !inTailnet(ip) {
			return nil
		}
	}
	for _, ip := range remote {
		if InTailnet(ip.String()) {
			return physical
		}
	}
	return nil
}

// defaultRouteIPs returns the local addresses of the IPv4 and IPv6 default
// routes that run over a physical interface: not over Tailscale (an exit
// node) or another tunnel (a full VPN).
func defaultRouteIPs() []net.IP {
	var out []net.IP
	for _, probe := range []string{"1.1.1.1", "2606:4700:4700::1111"} {
		ip := routeSource(&net.UDPAddr{IP: net.ParseIP(probe), Port: 9})
		if ip != nil && !ip.IsLoopback() && !ip.IsLinkLocalUnicast() && !inTailnet(ip) && !isTunnelInterface(ip) {
			out = append(out, ip)
		}
	}
	return out
}

// directCacheKey names a device reached from a network (its physical
// addresses).
func directCacheKey(baseURL string, physical []net.IP) string {
	var b strings.Builder
	b.WriteString(baseURL)
	for _, ip := range physical {
		b.WriteByte(' ')
		b.WriteString(ip.String())
	}
	return b.String()
}

// directBlocked reports whether a direct attempt at key ended on the tunnel
// less than directRetryAfter ago.
func directBlocked(key string, now time.Time) bool {
	v, ok := directFailures.Load(key)
	return ok && now.Sub(v.(time.Time)) < directRetryAfter
}

// noteDirectOutcome records which path a direct attempt at key ended on.
func noteDirectOutcome(key, path string, now time.Time) {
	if path == PathTailscale {
		directFailures.Store(key, now)
	} else {
		directFailures.Delete(key)
	}
}

// tailnetCandidatePriority is a relay's type preference (0) with the highest
// local preference: below every host, server- or peer-reflexive candidate.
func tailnetCandidatePriority(component int) uint32 {
	return 65535<<8 | uint32(256-component)
}

// tailnetCandidate splits an ICE candidate attribute value
// ("candidate:<foundation> <component> <transport> <priority> <address>
// <port> typ <type> ...") whose address is on a tailnet; nil for any other.
func tailnetCandidate(candidate string) []string {
	f := strings.Fields(candidate)
	if len(f) < 8 || !strings.HasPrefix(f[0], "candidate:") {
		return nil
	}
	if ip := net.ParseIP(f[4]); ip == nil || !inTailnet(ip) {
		return nil
	}
	return f
}

// demoteTailnetCandidate gives a candidate on a tailnet address
// tailnetCandidatePriority; anything else comes back unchanged.
func demoteTailnetCandidate(candidate string) string {
	f := tailnetCandidate(candidate)
	if f == nil {
		return candidate
	}
	component, err := strconv.Atoi(f[1])
	if err != nil || component < 1 || component > 256 {
		return candidate
	}
	f[3] = strconv.FormatUint(uint64(tailnetCandidatePriority(component)), 10)
	return strings.Join(f, " ")
}

// demoteTailnetSDP applies demoteTailnetCandidate to an SDP's candidates.
func demoteTailnetSDP(sdp string) string { return mapSDPCandidates(sdp, demoteTailnetCandidate) }

// withoutTailnetCandidates drops an SDP's candidates on tailnet addresses.
func withoutTailnetCandidates(sdp string) string {
	return mapSDPCandidates(sdp, func(candidate string) string {
		if tailnetCandidate(candidate) != nil {
			return ""
		}
		return candidate
	})
}

// mapSDPCandidates replaces each a=candidate line's value with f's result,
// or drops the line where f returns "".
func mapSDPCandidates(sdp string, f func(string) string) string {
	lines := strings.Split(sdp, "\r\n")
	out := lines[:0]
	for _, line := range lines {
		if candidate, ok := strings.CutPrefix(line, "a="); ok && strings.HasPrefix(candidate, "candidate:") {
			if candidate = f(candidate); candidate == "" {
				continue
			}
			line = "a=" + candidate
		}
		out = append(out, line)
	}
	return strings.Join(out, "\r\n")
}
