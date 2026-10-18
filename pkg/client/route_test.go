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

func TestOnLink(t *testing.T) {
	ip := net.ParseIP
	cases := []struct {
		local, remote string
		want          bool
	}{
		// The loopback interface's subnet is 127.0.0.0/8.
		{"127.0.0.1", "127.0.0.2", true},
		{"127.0.0.1", "203.0.113.7", false},
		// No interface has the local address: routed, unless link-local.
		{"192.0.2.1", "192.0.2.2", false},
		{"192.0.2.1", "fe80::2", true},
	}
	for _, c := range cases {
		if got := onLink(ip(c.local), ip(c.remote)); got != c.want {
			t.Errorf("onLink(%s, %s) = %v, want %v", c.local, c.remote, got, c.want)
		}
	}
}

func TestRouteIPs(t *testing.T) {
	local, remote := routeIPs(context.Background(), "http://127.0.0.1:8080")
	if len(local) != 1 || !local[0].IsLoopback() || len(remote) != 1 || !remote[0].IsLoopback() {
		t.Fatalf("routeIPs(127.0.0.1) = %v, %v, want the loopback address twice", local, remote)
	}
	if local, remote := routeIPs(context.Background(), "http://"); local != nil || remote != nil {
		t.Fatalf("routeIPs without a host = %v, %v, want none", local, remote)
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
