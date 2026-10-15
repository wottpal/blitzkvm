package client

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"sync"
	"time"

	"github.com/pion/webrtc/v4"
)

// FeatureHostLink: the firmware's USB network link to the computer, and the
// hostlink-ssh data channel to the computer's SSH server (D17).
const FeatureHostLink = "hostLink"

// hostLinkSSHLabel is the data channel the firmware connects to the
// computer's SSH server; its messages are the TCP stream's bytes.
const hostLinkSSHLabel = "hostlink-ssh"

// ErrHostUnreachable: the firmware closed the SSH channel before the
// computer said anything, because no SSH server answers on the USB link.
var ErrHostUnreachable = errors.New("the remote computer's SSH server doesn't answer on the USB link")

const (
	hostConnChunk     = 16 << 10
	hostConnHighWater = 1 << 20
	// hostConnMaxQueue bounds what the computer may send ahead of the
	// reader. SSH's window (2 MiB) keeps it far below.
	hostConnMaxQueue = 32 << 20
)

// DialHostSSH opens a stream to the computer's SSH server through the
// firmware's host link (FeatureHostLink). The firmware never sees what the
// SSH session carries.
func (c *Client) DialHostSSH(ctx context.Context) (net.Conn, error) {
	c.pcMu.RLock()
	pc := c.pc
	c.pcMu.RUnlock()
	if pc == nil {
		return nil, errors.New("not connected")
	}
	dc, err := pc.CreateDataChannel(hostLinkSSHLabel, nil)
	if err != nil {
		return nil, err
	}
	conn := newHostConn(dc)
	select {
	case <-conn.opened:
		return conn, nil
	case <-conn.closed:
		return nil, ErrHostUnreachable
	case <-ctx.Done():
		_ = dc.Close()
		return nil, ctx.Err()
	case <-c.closeCh:
		_ = dc.Close()
		return nil, errors.New("session closed")
	}
}

// hostConn is a net.Conn over a data channel. Incoming messages queue in
// memory, so the SCTP reader (which also carries input) never waits for the
// SSH reader; writes wait while the channel's send buffer is full.
type hostConn struct {
	dc *webrtc.DataChannel

	opened    chan struct{}
	closed    chan struct{}
	drained   chan struct{}
	closeOnce sync.Once

	mu            sync.Mutex
	cond          *sync.Cond
	queue         []byte
	gotData       bool
	readDeadline  time.Time
	deadlineTimer *time.Timer
}

func newHostConn(dc *webrtc.DataChannel) *hostConn {
	h := &hostConn{dc: dc, opened: make(chan struct{}), closed: make(chan struct{}), drained: make(chan struct{}, 1)}
	h.cond = sync.NewCond(&h.mu)
	var openOnce sync.Once
	dc.OnOpen(func() { openOnce.Do(func() { close(h.opened) }) })
	dc.OnClose(h.markClosed)
	dc.OnError(func(error) { h.markClosed() })
	dc.OnMessage(func(msg webrtc.DataChannelMessage) {
		h.mu.Lock()
		if len(h.queue)+len(msg.Data) > hostConnMaxQueue {
			h.mu.Unlock()
			_ = h.Close()
			return
		}
		h.queue = append(h.queue, msg.Data...)
		h.gotData = true
		h.mu.Unlock()
		h.cond.Broadcast()
	})
	dc.SetBufferedAmountLowThreshold(hostConnHighWater / 2)
	dc.OnBufferedAmountLow(func() {
		select {
		case h.drained <- struct{}{}:
		default:
		}
	})
	return h
}

func (h *hostConn) markClosed() {
	h.closeOnce.Do(func() { close(h.closed) })
	h.cond.Broadcast()
	select {
	case h.drained <- struct{}{}:
	default:
	}
}

func (h *hostConn) isClosed() bool {
	select {
	case <-h.closed:
		return true
	default:
		return false
	}
}

func (h *hostConn) Read(p []byte) (int, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for len(h.queue) == 0 {
		if h.isClosed() {
			if !h.gotData {
				return 0, ErrHostUnreachable
			}
			return 0, io.EOF
		}
		if !h.readDeadline.IsZero() && !time.Now().Before(h.readDeadline) {
			return 0, os.ErrDeadlineExceeded
		}
		h.cond.Wait()
	}
	n := copy(p, h.queue)
	h.queue = h.queue[n:]
	if len(h.queue) == 0 {
		h.queue = nil // let a large burst's buffer go
	}
	return n, nil
}

func (h *hostConn) Write(p []byte) (int, error) {
	written := 0
	for written < len(p) {
		for h.dc.BufferedAmount() > hostConnHighWater && !h.isClosed() {
			<-h.drained
		}
		if h.isClosed() {
			return written, net.ErrClosed
		}
		end := min(len(p), written+hostConnChunk)
		if err := h.dc.Send(append([]byte(nil), p[written:end]...)); err != nil {
			return written, err
		}
		written = end
	}
	return written, nil
}

func (h *hostConn) Close() error {
	err := h.dc.Close()
	h.markClosed()
	return err
}

func (h *hostConn) LocalAddr() net.Addr  { return hostLinkAddr("blitzkvm") }
func (h *hostConn) RemoteAddr() net.Addr { return hostLinkAddr("computer") }

func (h *hostConn) SetDeadline(t time.Time) error { return h.SetReadDeadline(t) }

// SetReadDeadline wakes a waiting Read when t passes. Writes have no
// deadline: they only wait for the channel's buffer to drain.
func (h *hostConn) SetReadDeadline(t time.Time) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.readDeadline = t
	if h.deadlineTimer != nil {
		h.deadlineTimer.Stop()
		h.deadlineTimer = nil
	}
	if !t.IsZero() {
		h.deadlineTimer = time.AfterFunc(time.Until(t), h.cond.Broadcast)
	}
	return nil
}

func (h *hostConn) SetWriteDeadline(time.Time) error { return nil }

type hostLinkAddr string

func (a hostLinkAddr) Network() string { return hostLinkSSHLabel }
func (a hostLinkAddr) String() string  { return string(a) }

var _ net.Conn = (*hostConn)(nil)
