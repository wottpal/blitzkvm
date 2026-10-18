package client

import (
	"context"
	"net"
	"testing"
)

func TestPathKind(t *testing.T) {
	ip := net.ParseIP
	cases := []struct {
		local, remote string
		want          string
	}{
		{"127.0.0.1", "127.0.0.1", PathLoopback},
		{"192.168.1.20", "192.168.1.40", PathLAN},
		{"fe80::1", "fe80::2", PathLAN},
		{"100.64.0.21", "100.64.0.20", PathTailscale},
		{"fd7a:115c:a1e0::1", "fd7a:115c:a1e0::2", PathTailscale},
		// A subnet router: a tailnet address reaches a LAN one.
		{"100.64.0.21", "192.168.1.40", PathTailscale},
		{"192.168.1.20", "203.0.113.7", PathInternet},
	}
	for _, c := range cases {
		if got := pathKind(ip(c.local), ip(c.remote)); got != c.want {
			t.Errorf("pathKind(%s, %s) = %s, want %s", c.local, c.remote, got, c.want)
		}
	}
}

func TestRouteLocalIPs(t *testing.T) {
	local := routeLocalIPs(context.Background(), "http://127.0.0.1:8080")
	if len(local) != 1 || !local[0].IsLoopback() {
		t.Fatalf("routeLocalIPs(127.0.0.1) = %v, want the loopback address", local)
	}
	if got := routeLocalIPs(context.Background(), "http://"); got != nil {
		t.Fatalf("routeLocalIPs without a host = %v, want none", got)
	}
}

func TestInTailnetIsATailscaleNodesOwnAddress(t *testing.T) {
	for addr, want := range map[string]bool{
		"100.64.0.20":                  true,
		"fd7a:115c:a1e0::20":           true,
		"fd7a:115c:a1e0:b1a::c0a8:128": false, // 4via6: a subnet router's
		"192.168.1.40":                 false,
		"":                             false,
	} {
		if got := InTailnet(addr); got != want {
			t.Errorf("InTailnet(%q) = %v, want %v", addr, got, want)
		}
	}
}
