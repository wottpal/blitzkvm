package client

import (
	"errors"
	"net"
	"os"
	"testing"
	"time"
)

func listenLoopback(t *testing.T) *net.UDPConn {
	t.Helper()
	u, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = u.Close() })
	return u
}

func TestImpairedConnDelaysBothWays(t *testing.T) {
	im, err := newImpairment("delay=40ms,seed=1")
	if err != nil {
		t.Fatal(err)
	}
	defer im.stop()
	conn, peer := im.wrap(listenLoopback(t)), listenLoopback(t)
	buf := make([]byte, 64)

	start := time.Now()
	if _, err := peer.WriteTo([]byte("down"), conn.LocalAddr()); err != nil {
		t.Fatal(err)
	}
	n, from, err := conn.ReadFrom(buf)
	if err != nil || string(buf[:n]) != "down" || from.String() != peer.LocalAddr().String() {
		t.Fatalf("read %q from %v: %v", buf[:n], from, err)
	}
	if took := time.Since(start); took < 40*time.Millisecond {
		t.Fatalf("down took %s, want ≥ 40 ms", took)
	}

	start = time.Now()
	if _, err := conn.WriteTo([]byte("up"), peer.LocalAddr()); err != nil {
		t.Fatal(err)
	}
	if took := time.Since(start); took > 10*time.Millisecond {
		t.Fatalf("a write blocked for %s", took)
	}
	n, _, err = peer.ReadFrom(buf)
	if err != nil || string(buf[:n]) != "up" {
		t.Fatalf("peer read %q: %v", buf[:n], err)
	}
	if took := time.Since(start); took < 40*time.Millisecond {
		t.Fatalf("up took %s, want ≥ 40 ms", took)
	}
}

func TestImpairedConnHonoursDeadlinesAndClose(t *testing.T) {
	im, err := newImpairment("rate=1mbit")
	if err != nil {
		t.Fatal(err)
	}
	defer im.stop()
	conn := im.wrap(listenLoopback(t))
	buf := make([]byte, 64)

	_ = conn.SetReadDeadline(time.Now().Add(30 * time.Millisecond))
	if _, _, err := conn.ReadFrom(buf); !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("read past its deadline: %v", err)
	}
	_ = conn.SetDeadline(time.Now().Add(-time.Second))
	if _, err := conn.WriteTo(buf, conn.LocalAddr()); !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("write past its deadline: %v", err)
	}
	_ = conn.SetDeadline(time.Time{})

	read := make(chan error, 1)
	go func() {
		_, _, err := conn.ReadFrom(buf)
		read <- err
	}()
	time.Sleep(20 * time.Millisecond)
	_ = conn.Close()
	select {
	case err := <-read:
		if !errors.Is(err, net.ErrClosed) {
			t.Fatalf("blocked read ended with %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Close did not unblock a read")
	}
	if _, err := conn.WriteTo(buf, conn.LocalAddr()); !errors.Is(err, net.ErrClosed) {
		t.Fatalf("write after Close: %v", err)
	}
}

func TestVideoBytesTellRetransmissions(t *testing.T) {
	v := videoBytes{newest: map[uint32]uint16{}}
	rtp := func(seq uint16) []byte {
		return []byte{0x80, 96, byte(seq >> 8), byte(seq), 0, 0, 0, 0, 0, 0, 0, 1, 0xaa}
	}
	for _, seq := range []uint16{65534, 65535, 0, 1, 65535, 2} {
		v.offer(rtp(seq))
	}
	v.offer([]byte{0x80, 200, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1}) // RTCP sender report
	v.offer([]byte{22, 254, 253})                            // DTLS
	v.lose(rtp(3))
	v.lose([]byte{22, 254, 253})
	if v.resent != 13 || v.lost != 13 {
		t.Fatalf("resent %d lost %d bytes, want 13 each", v.resent, v.lost)
	}
}
