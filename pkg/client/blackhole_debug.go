package client

// Debug aid: BLITZKVM_DEBUG_BLACKHOLE="period:duration" (seconds) drops all of
// the session's UDP traffic (both ways) for the last `duration` seconds of
// every `period`, to reproduce network hiccups. It measured the SCTP stall
// that sctpRTOMax bounds (plan §25). Unset, nothing is wrapped.

import (
	"net"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/pion/transport/v5"
	"github.com/pion/transport/v5/stdnet"
	"github.com/pion/webrtc/v4"
)

var blackholeStart = time.Now()

type blackholeSchedule struct{ period, duration time.Duration }

var blackholeCfg atomic.Pointer[blackholeSchedule]

func blackholeActive() bool {
	s := blackholeCfg.Load()
	if s == nil {
		return false
	}
	return time.Since(blackholeStart)%s.period >= s.period-s.duration
}

func applyDebugBlackhole(se *webrtc.SettingEngine) {
	spec := os.Getenv("BLITZKVM_DEBUG_BLACKHOLE")
	parts := strings.Split(spec, ":")
	if len(parts) != 2 {
		return
	}
	p, err1 := strconv.ParseFloat(parts[0], 64)
	d, err2 := strconv.ParseFloat(parts[1], 64)
	if err1 != nil || err2 != nil || p <= d {
		return
	}
	blackholeCfg.Store(&blackholeSchedule{time.Duration(p * float64(time.Second)), time.Duration(d * float64(time.Second))})
	n, err := stdnet.NewNet()
	if err != nil {
		return
	}
	se.SetNet(blackholeNet{n})
}

type blackholeNet struct{ *stdnet.Net }

func (n blackholeNet) ListenUDP(network string, laddr *net.UDPAddr) (transport.UDPConn, error) {
	c, err := n.Net.ListenUDP(network, laddr)
	if err != nil {
		return nil, err
	}
	return &blackholeConn{c}, nil
}

func (n blackholeNet) ListenPacket(network, address string) (net.PacketConn, error) {
	c, err := n.Net.ListenPacket(network, address)
	if err != nil {
		return nil, err
	}
	if u, ok := c.(transport.UDPConn); ok {
		return &blackholeConn{u}, nil
	}
	return c, nil
}

type blackholeConn struct{ transport.UDPConn }

func (c *blackholeConn) ReadFrom(p []byte) (int, net.Addr, error) {
	for {
		n, a, err := c.UDPConn.ReadFrom(p)
		if err != nil || !blackholeActive() {
			return n, a, err
		}
	}
}

func (c *blackholeConn) ReadFromUDP(p []byte) (int, *net.UDPAddr, error) {
	for {
		n, a, err := c.UDPConn.ReadFromUDP(p)
		if err != nil || !blackholeActive() {
			return n, a, err
		}
	}
}

func (c *blackholeConn) WriteTo(p []byte, a net.Addr) (int, error) {
	if blackholeActive() {
		return len(p), nil
	}
	return c.UDPConn.WriteTo(p, a)
}

func (c *blackholeConn) WriteToUDP(p []byte, a *net.UDPAddr) (int, error) {
	if blackholeActive() {
		return len(p), nil
	}
	return c.UDPConn.WriteToUDP(p, a)
}
