package client

// Test aid: BLITZKVM_IMPAIR=<profile>[,key=value...] (see netimpair.Parse,
// e.g. "lte-congested" or "rate=4mbit,queue=1s,delay=40ms,loss=1%") runs the
// session's UDP traffic through a model of a slow link, both ways: device →
// Mac (video, RTCP, data channels) and Mac → device (input, RTCP, STUN).
// Each socket is drained into the model the moment a packet arrives, so the
// kernel's receive buffer adds no queue of its own. When the session ends,
// one log line says what the link did. Unset, nothing is wrapped.

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"sync"
	"time"

	"github.com/pion/transport/v5"
	"github.com/pion/transport/v5/deadline"
	"github.com/pion/transport/v5/stdnet"

	"github.com/wottpal/blitzkvm/pkg/logging"
	"github.com/wottpal/blitzkvm/pkg/netimpair"
)

const (
	envImpair = "BLITZKVM_IMPAIR"
	// ipUDPOverhead is what IPv4 and UDP add to each datagram on the link.
	ipUDPOverhead = 28
	// impairInbox bounds delivered datagrams a socket's reader has not
	// taken yet; more are dropped, like a full socket buffer.
	impairInbox = 1024
)

// testNet is the network pion uses when BLITZKVM_DEBUG_BLACKHOLE or
// BLITZKVM_IMPAIR is set; nil otherwise, so pion uses the system's own.
func (c *Client) testNet() (transport.Net, error) {
	blackhole := blackholeFromEnv()
	spec := os.Getenv(envImpair)
	if !blackhole && spec == "" {
		return nil, nil
	}
	base, err := stdnet.NewNet()
	if err != nil {
		return nil, err
	}
	var n transport.Net = base
	if blackhole {
		n = wrapNet{n, func(u transport.UDPConn) transport.UDPConn { return &blackholeConn{u} }}
	}
	if spec != "" {
		im, err := newImpairment(spec)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", envImpair, err)
		}
		c.impair.Store(im)
		n = wrapNet{n, im.wrap}
	}
	return n, nil
}

// wrapNet wraps every UDP socket pion opens.
type wrapNet struct {
	transport.Net
	wrap func(transport.UDPConn) transport.UDPConn
}

func (n wrapNet) ListenUDP(network string, laddr *net.UDPAddr) (transport.UDPConn, error) {
	u, err := n.Net.ListenUDP(network, laddr)
	if err != nil {
		return nil, err
	}
	return n.wrap(u), nil
}

func (n wrapNet) ListenPacket(network, address string) (net.PacketConn, error) {
	c, err := n.Net.ListenPacket(network, address)
	if u, ok := c.(transport.UDPConn); ok && err == nil {
		return n.wrap(u), nil
	}
	return c, err
}

// impairment is one session's link model: both directions, shared by all
// of its sockets, and the goroutine that delivers what the model releases.
type impairment struct {
	spec     string
	mu       sync.Mutex
	up, down *netimpair.Link[datagram]
	video    videoBytes
	wake     chan struct{}
	done     chan struct{}
	stopOnce sync.Once
}

type datagram struct {
	conn *impairedConn
	addr net.Addr
	data []byte
}

func newImpairment(spec string) (*impairment, error) {
	cfg, err := netimpair.Parse(spec)
	if err != nil {
		return nil, err
	}
	im := &impairment{spec: spec, wake: make(chan struct{}, 1), done: make(chan struct{})}
	im.up, im.down = netimpair.NewPath[datagram](cfg)
	im.down.Dropped = func(d datagram) { im.video.lose(d.data) }
	im.video.newest = map[uint32]uint16{}
	log := logging.Subsystem("client")
	log.Error().Str("link", spec).Msg("network impaired for testing (" + envImpair + ")")
	go im.run()
	return im, nil
}

func (im *impairment) wrap(u transport.UDPConn) transport.UDPConn {
	c := &impairedConn{UDPConn: u, im: im, inbox: make(chan datagram, impairInbox), closed: make(chan struct{}),
		readDeadline: deadline.New(), writeDeadline: deadline.New()}
	go c.drain()
	return c
}

func (im *impairment) send(link *netimpair.Link[datagram], d datagram) {
	im.mu.Lock()
	if link == im.down {
		im.video.offer(d.data)
	}
	link.Send(time.Now(), len(d.data)+ipUDPOverhead, d)
	im.mu.Unlock()
	select {
	case im.wake <- struct{}{}:
	default:
	}
}

// run hands each datagram on when the model releases it: up to the real
// socket, down to the reading side of its socket.
func (im *impairment) run() {
	timer := time.NewTimer(time.Hour)
	defer timer.Stop()
	var up []datagram
	for {
		im.mu.Lock()
		now := time.Now()
		for d, ok := im.up.Receive(now); ok; d, ok = im.up.Receive(now) {
			up = append(up, d)
		}
		for d, ok := im.down.Receive(now); ok; d, ok = im.down.Receive(now) {
			select {
			case d.conn.inbox <- d:
			default:
			}
		}
		next, pending := im.up.Next()
		if t, ok := im.down.Next(); ok && (!pending || t.Before(next)) {
			next, pending = t, true
		}
		im.mu.Unlock()
		for i, d := range up {
			d.conn.writeOut(d)
			up[i] = datagram{}
		}
		up = up[:0]
		wait := time.Hour
		if pending {
			wait = time.Until(next)
		}
		timer.Reset(wait)
		select {
		case <-timer.C:
		case <-im.wake:
		case <-im.done:
			return
		}
	}
}

// stop ends delivery and logs what the link did.
func (im *impairment) stop() {
	im.stopOnce.Do(func() {
		close(im.done)
		log := logging.Subsystem("client")
		log.Error().Str("link", im.spec).Msg("impaired link: " + im.stats().String())
	})
}

// ImpairmentStats is what the BLITZKVM_IMPAIR link model did.
type ImpairmentStats struct {
	Up, Down netimpair.Stats
	// VideoLost is the bytes of the device's RTP that the link lost;
	// VideoResent the RTP bytes offered to it with a sequence number
	// already seen, i.e. NACK repair.
	VideoLost, VideoResent int
}

func (s ImpairmentStats) String() string {
	return fmt.Sprintf("down %s; up %s; video RTP %d kB lost, %d kB resent (%.2f×)",
		s.Down, s.Up, s.VideoLost/1000, s.VideoResent/1000, float64(s.VideoResent)/float64(max(s.VideoLost, 1)))
}

// Impairment reports what the BLITZKVM_IMPAIR link model did so far; ok is
// false without one.
func (c *Client) Impairment() (stats ImpairmentStats, ok bool) {
	im := c.impair.Load()
	if im == nil {
		return ImpairmentStats{}, false
	}
	return im.stats(), true
}

func (im *impairment) stats() ImpairmentStats {
	im.mu.Lock()
	defer im.mu.Unlock()
	return ImpairmentStats{Up: im.up.Stats(), Down: im.down.Stats(),
		VideoLost: im.video.lost, VideoResent: im.video.resent}
}

// videoBytes tells NACK repair from new video in the device's RTP: a
// packet whose sequence number was already seen is a retransmission.
type videoBytes struct {
	newest       map[uint32]uint16 // per SSRC
	resent, lost int
}

// rtpSeq parses an RTP header, telling RTP from RTCP, DTLS and STUN as
// RFC 7983 does.
func rtpSeq(b []byte) (ssrc uint32, seq uint16, ok bool) {
	if len(b) < 12 || b[0] < 128 || b[0] > 191 || (b[1] >= 192 && b[1] <= 223) {
		return 0, 0, false
	}
	return binary.BigEndian.Uint32(b[8:12]), binary.BigEndian.Uint16(b[2:4]), true
}

func (v *videoBytes) offer(b []byte) {
	ssrc, seq, ok := rtpSeq(b)
	if !ok {
		return
	}
	if newest, seen := v.newest[ssrc]; seen && int16(seq-newest) <= 0 {
		v.resent += len(b)
		return
	}
	v.newest[ssrc] = seq
}

func (v *videoBytes) lose(b []byte) {
	if _, _, ok := rtpSeq(b); ok {
		v.lost += len(b)
	}
}

// impairedConn is a socket whose traffic passes through the link model.
// Reads and writes never touch the real socket directly: drain feeds the
// model from it, and run writes to it.
type impairedConn struct {
	transport.UDPConn
	im                          *impairment
	inbox                       chan datagram
	closed                      chan struct{}
	closeOnce                   sync.Once
	readDeadline, writeDeadline *deadline.Deadline
}

func (c *impairedConn) drain() {
	buf := make([]byte, 64<<10)
	for {
		n, addr, err := c.UDPConn.ReadFrom(buf)
		if err != nil {
			c.shut()
			return
		}
		c.im.send(c.im.down, datagram{c, addr, bytes.Clone(buf[:n])})
	}
}

func (c *impairedConn) writeOut(d datagram) {
	if d.addr == nil {
		_, _ = c.UDPConn.Write(d.data)
		return
	}
	_, _ = c.UDPConn.WriteTo(d.data, d.addr)
}

func (c *impairedConn) shut() { c.closeOnce.Do(func() { close(c.closed) }) }

func (c *impairedConn) Close() error {
	c.shut()
	return c.UDPConn.Close()
}

func (c *impairedConn) ReadFrom(p []byte) (int, net.Addr, error) {
	select {
	case d := <-c.inbox:
		return copy(p, d.data), d.addr, nil
	case <-c.closed:
		return 0, nil, net.ErrClosed
	case <-c.readDeadline.Done():
		return 0, nil, os.ErrDeadlineExceeded
	}
}

func (c *impairedConn) ReadFromUDP(p []byte) (int, *net.UDPAddr, error) {
	n, addr, err := c.ReadFrom(p)
	udp, _ := addr.(*net.UDPAddr)
	return n, udp, err
}

func (c *impairedConn) ReadMsgUDP(p, _ []byte) (n, oobn, flags int, addr *net.UDPAddr, err error) {
	n, addr, err = c.ReadFromUDP(p)
	return n, 0, 0, addr, err
}

func (c *impairedConn) Read(p []byte) (int, error) {
	n, _, err := c.ReadFrom(p)
	return n, err
}

func (c *impairedConn) WriteTo(p []byte, addr net.Addr) (int, error) {
	select {
	case <-c.closed:
		return 0, net.ErrClosed
	case <-c.writeDeadline.Done():
		return 0, os.ErrDeadlineExceeded
	default:
	}
	c.im.send(c.im.up, datagram{c, addr, bytes.Clone(p)})
	return len(p), nil
}

func (c *impairedConn) WriteToUDP(p []byte, addr *net.UDPAddr) (int, error) {
	if addr == nil {
		return c.WriteTo(p, nil)
	}
	return c.WriteTo(p, addr)
}

func (c *impairedConn) WriteMsgUDP(p, _ []byte, addr *net.UDPAddr) (n, oobn int, err error) {
	n, err = c.WriteToUDP(p, addr)
	return n, 0, err
}

func (c *impairedConn) Write(p []byte) (int, error) { return c.WriteTo(p, nil) }

func (c *impairedConn) SetDeadline(t time.Time) error {
	c.readDeadline.Set(t)
	c.writeDeadline.Set(t)
	return nil
}

func (c *impairedConn) SetReadDeadline(t time.Time) error {
	c.readDeadline.Set(t)
	return nil
}

func (c *impairedConn) SetWriteDeadline(t time.Time) error {
	c.writeDeadline.Set(t)
	return nil
}
