package client

import (
	"net"
	"strings"
	"testing"
	"time"
)

func TestDirectPlan(t *testing.T) {
	ips := func(s ...string) []net.IP {
		var out []net.IP
		for _, a := range s {
			out = append(out, net.ParseIP(a))
		}
		return out
	}
	physical := ips("192.168.1.20")
	cases := []struct {
		name          string
		local, remote []net.IP
		want          bool
	}{
		{"device runs tailscaled", ips("100.64.0.21"), ips("100.64.0.20"), true},
		{"over IPv6", ips("fd7a:115c:a1e0::1"), ips("fd7a:115c:a1e0::2"), true},
		{"LAN", ips("192.168.1.20"), ips("192.168.1.40"), false},
		{"subnet router", ips("100.64.0.21"), ips("192.168.1.40"), false},
		{"subnet router, 4via6", ips("fd7a:115c:a1e0::1"), ips("fd7a:115c:a1e0:b1a:0:1:c0a8:128"), false},
		{"another VPN to a tailnet address", ips("10.8.0.2"), ips("100.64.0.20"), false},
		{"no route", nil, nil, false},
	}
	for _, c := range cases {
		if got := directPlan(c.local, c.remote, physical) != nil; got != c.want {
			t.Errorf("%s: direct = %v, want %v", c.name, got, c.want)
		}
	}
	if directPlan(ips("100.64.0.21"), ips("100.64.0.20"), nil) != nil {
		t.Error("no physical default route: want no direct attempt")
	}
}

// The settings that keep a connection on the tunnel.
func TestDirectPathOff(t *testing.T) {
	local, remote := []net.IP{net.ParseIP("100.64.0.21")}, []net.IP{net.ParseIP("100.64.0.20")}
	for _, cfg := range []Config{{NoDirectPath: true}, {ICELoopbackOnly: true}} {
		c := &Client{cfg: cfg}
		if direct := c.directPath(local, remote); direct != nil || c.directKey != "" {
			t.Errorf("%+v: direct attempt on %v", cfg, direct)
		}
	}
}

// BLITZKVM_STUN_SERVERS replaces the servers with its stun: URLs that pion
// parses; a URL it can't parse would fail the whole connection.
func TestSTUNServersFromTheEnvironment(t *testing.T) {
	t.Setenv("BLITZKVM_STUN_SERVERS", "stun:stun.example.com:3478 stun:host:abc stuns:stun.example.org turn:turn.example.com stun:192.0.2.1")
	if got := stunServers(); strings.Join(got, " ") != "stun:stun.example.com:3478 stun:192.0.2.1" {
		t.Errorf("stunServers = %q", got)
	}
	t.Setenv("BLITZKVM_STUN_SERVERS", "")
	if got := stunServers(); len(got) != 0 {
		t.Errorf("set but empty: %q, want none", got)
	}
}

func TestDefaultRouteIPsArePhysical(t *testing.T) {
	for _, ip := range defaultRouteIPs() {
		if ip.IsLoopback() || inTailnet(ip) || isTunnelInterface(ip) {
			t.Errorf("default route address %s is not a physical interface's", ip)
		}
	}
}

func TestDirectFailuresExpire(t *testing.T) {
	key := directCacheKey("http://mac-mini-jetkvm.example.ts.net", []net.IP{net.ParseIP("192.168.1.20")})
	now := time.Now()
	t.Cleanup(func() { directFailures.Delete(key) })
	noteDirectOutcome(key, PathTailscale, now)
	if !directBlocked(key, now.Add(directRetryAfter-time.Second)) {
		t.Error("an attempt that ended on the tunnel is tried again too soon")
	}
	if directBlocked(key, now.Add(directRetryAfter)) {
		t.Error("an attempt that ended on the tunnel is never tried again")
	}
	noteDirectOutcome(key, PathInternet, now)
	if directBlocked(key, now) {
		t.Error("a direct path that worked blocks the next attempt")
	}
	if other := directCacheKey("http://mac-mini-jetkvm.example.ts.net", []net.IP{net.ParseIP("10.0.0.5")}); other == key {
		t.Error("another network shares the key")
	}
}

func TestDemoteTailnetCandidates(t *testing.T) {
	host := "candidate:1467250027 1 udp 2130706431 100.64.0.20 54321 typ host"
	got := demoteTailnetCandidate(host)
	want := "candidate:1467250027 1 udp 16777215 100.64.0.20 54321 typ host"
	if got != want {
		t.Fatalf("demoted = %q, want %q", got, want)
	}
	// Below every other kind: a server-reflexive candidate's type preference
	// is 100, a peer-reflexive one's 110, a host's 126.
	if tailnetCandidatePriority(1) >= 100<<24 {
		t.Fatalf("tailnet priority %d is not below a server-reflexive candidate's", tailnetCandidatePriority(1))
	}
	for _, keep := range []string{
		"candidate:1 1 udp 2130706431 192.168.1.40 54321 typ host",
		"candidate:2 1 udp 1694498815 203.0.113.7 2562 typ srflx raddr 0.0.0.0 rport 54322",
		"",
		"candidate:4 1 udp",
	} {
		if got := demoteTailnetCandidate(keep); got != keep {
			t.Errorf("demoteTailnetCandidate(%q) = %q, want it unchanged", keep, got)
		}
	}
	v6 := demoteTailnetCandidate("candidate:5 1 udp 2130706431 fd7a:115c:a1e0::20 54321 typ host generation 0")
	if !strings.Contains(v6, " 16777215 fd7a:115c:a1e0::20 54321 typ host generation 0") {
		t.Errorf("tailnet IPv6 candidate not demoted: %q", v6)
	}

	sdp := strings.Join([]string{
		"v=0",
		"a=candidate:1467250027 1 udp 2130706431 100.64.0.20 54321 typ host",
		"a=candidate:1 1 udp 2130706431 192.168.1.40 54321 typ host",
		"a=end-of-candidates",
		"",
	}, "\r\n")
	wantSDP := strings.Replace(sdp, "2130706431 100.64.0.20", "16777215 100.64.0.20", 1)
	if got := demoteTailnetSDP(sdp); got != wantSDP {
		t.Errorf("demoteTailnetSDP = %q, want %q", got, wantSDP)
	}
	// The client's own tailnet candidates stay out of its offer.
	wantOffer := strings.Replace(sdp, "a=candidate:1467250027 1 udp 2130706431 100.64.0.20 54321 typ host\r\n", "", 1)
	if got := withoutTailnetCandidates(sdp); got != wantOffer {
		t.Errorf("withoutTailnetCandidates = %q, want %q", got, wantOffer)
	}
}
