package client

import (
	"context"
	"net"
	"net/netip"
	"net/url"
	"strings"
	"sync"

	"github.com/pion/webrtc/v4"
)

// Video takes the route of the address the app connected to: the LAN at
// home, a VPN such as Tailscale away. Left to itself, ICE may pick any pair
// that answers, for example the Tailscale pair at home, which sends the
// whole stream through WireGuard on the JetKVM's single core. A device
// reached over its own Tailscale also gets a direct path tried (direct.go).

// routeIPs resolves baseURL's host and returns the addresses that have a
// route (remote) and the local addresses the system sends to them from, one
// per local address. Empty when the host doesn't resolve or has no route.
func routeIPs(ctx context.Context, baseURL string) (local, remote []net.IP) {
	u, err := url.Parse(baseURL)
	if err != nil || u.Hostname() == "" {
		return nil, nil
	}
	addrs, err := net.DefaultResolver.LookupIPAddr(ctx, u.Hostname())
	if err != nil {
		return nil, nil
	}
	for _, addr := range addrs {
		ip := routeSource(&net.UDPAddr{IP: addr.IP, Port: 9, Zone: addr.Zone})
		if ip == nil {
			continue
		}
		remote = append(remote, addr.IP)
		if !containsIP(local, ip) {
			local = append(local, ip)
		}
	}
	return local, remote
}

// routeSource is the local address the system sends to dst from, nil when
// it has no route there. Connecting a UDP socket picks a route and a source
// address; it sends nothing.
func routeSource(dst *net.UDPAddr) net.IP {
	conn, err := net.DialUDP("udp", nil, dst)
	if err != nil {
		return nil
	}
	defer conn.Close()
	return conn.LocalAddr().(*net.UDPAddr).IP
}

// pinICE limits candidate gathering to the given local addresses.
func pinICE(se *webrtc.SettingEngine, local []net.IP) {
	for _, ip := range local {
		if !ip.IsLoopback() {
			se.SetIPFilter(func(candidate net.IP) bool { return containsIP(local, candidate) })
			return
		}
	}
	restrictICEToLoopback(se)
}

func containsIP(ips []net.IP, ip net.IP) bool {
	for _, have := range ips {
		if have.Equal(ip) {
			return true
		}
	}
	return false
}

// Path kinds, as reported in StatsSnapshot.Path.
const (
	PathLAN       = "lan"
	PathTailscale = "tailscale"
	PathVPN       = "vpn"
	PathInternet  = "internet"
	PathLoopback  = "loopback"
)

var (
	tailscale4 = netip.MustParsePrefix("100.64.0.0/10")
	tailscale6 = netip.MustParsePrefix("fd7a:115c:a1e0::/48")
	// tailscale4via6 maps a subnet router's IPv4 subnets into tailscale6.
	tailscale4via6 = netip.MustParsePrefix("fd7a:115c:a1e0:b1a::/64")
)

// pathKind names the network a candidate pair runs over. Tailscale is
// recognised by its address ranges on either end (a subnet router reaches a
// LAN address from a tailnet one); another VPN by its tunnel interface.
func pathKind(local, remote net.IP) string {
	switch {
	case remote.IsLoopback():
		return PathLoopback
	case inTailnet(local) || inTailnet(remote):
		return PathTailscale
	case isTunnelInterface(local):
		return PathVPN
	case remote.IsPrivate() || remote.IsLinkLocalUnicast():
		return PathLAN
	default:
		return PathInternet
	}
}

// InTailnet reports whether addr, an IP address such as
// StatsSnapshot.PathRemote, is a Tailscale node's own address: as the path's
// remote end, the JetKVM itself runs tailscaled. A subnet router's 4via6
// addresses reach a device behind it. (A device whose LAN sits in the
// carrier-grade NAT range would read as one too.)
func InTailnet(addr string) bool {
	ip, err := netip.ParseAddr(addr)
	if err != nil {
		return false
	}
	ip = ip.Unmap()
	return tailscale4.Contains(ip) || (tailscale6.Contains(ip) && !tailscale4via6.Contains(ip))
}

func inTailnet(ip net.IP) bool {
	addr, ok := netip.AddrFromSlice(ip)
	if !ok {
		return false
	}
	addr = addr.Unmap()
	return tailscale4.Contains(addr) || tailscale6.Contains(addr)
}

var tunnelInterfaces sync.Map // local IP string -> bool

// isTunnelInterface reports whether ip belongs to a tunnel interface (utun,
// tun, wg, ipsec, ppp), cached per address.
func isTunnelInterface(ip net.IP) bool {
	key := ip.String()
	if v, ok := tunnelInterfaces.Load(key); ok {
		return v.(bool)
	}
	tunnel := false
	if ifaces, err := net.Interfaces(); err == nil {
		for _, iface := range ifaces {
			addrs, err := iface.Addrs()
			if err != nil {
				continue
			}
			for _, a := range addrs {
				if n, ok := a.(*net.IPNet); ok && n.IP.Equal(ip) {
					name := iface.Name
					tunnel = iface.Flags&net.FlagPointToPoint != 0 ||
						strings.HasPrefix(name, "utun") || strings.HasPrefix(name, "tun") ||
						strings.HasPrefix(name, "wg") || strings.HasPrefix(name, "ipsec") || strings.HasPrefix(name, "ppp")
				}
			}
		}
	}
	tunnelInterfaces.Store(key, tunnel)
	return tunnel
}
