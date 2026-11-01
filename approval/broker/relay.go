package broker

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/wottpal/blitzkvm/approval/wire"
)

// relayConn is the broker's WebSocket to the relay.
type relayConn struct {
	c    Conn
	out  chan []byte
	done chan struct{}
	once sync.Once
}

func (r *relayConn) send(msg any) {
	data, err := json.Marshal(msg)
	if err != nil {
		return
	}
	select {
	case r.out <- data:
	case <-r.done:
	default:
		r.close()
	}
}

func (r *relayConn) close() {
	r.once.Do(func() {
		close(r.done)
		_ = r.c.Close()
	})
}

type allowed struct {
	ID        string     `json:"id"`
	Transport wire.Bytes `json:"transport"`
	Platform  string     `json:"platform"`
}

func (r *relayConn) sendAllow(roster *wire.Roster) {
	list := make([]allowed, 0, len(roster.Approvers))
	for _, a := range roster.Approvers {
		list = append(list, allowed{ID: a.ID, Transport: a.Transport, Platform: a.Platform})
	}
	r.send(map[string]any{"op": "allow", "approvers": list})
}

// runRelay keeps a connection to the roster's relay, reconnecting with
// backoff, and follows roster changes.
func (b *Broker) runRelay(ctx context.Context) {
	backoff := time.Second
	for ctx.Err() == nil {
		b.mu.Lock()
		url := ""
		if b.roster != nil {
			url = strings.TrimRight(b.roster.Relay, "/")
		}
		changed := b.rosterCh
		b.mu.Unlock()
		if url == "" {
			select {
			case <-ctx.Done():
			case <-changed:
			}
			continue
		}
		started := time.Now()
		err := b.relaySession(ctx, url+"/v1/b/"+b.ID()+"/ws", changed)
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			b.cfg.Logf("approvals: relay: %v", err)
		}
		if time.Since(started) > time.Minute {
			backoff = time.Second
		}
		select {
		case <-ctx.Done():
		case <-changed:
			backoff = time.Second
		case <-time.After(backoff):
			backoff = min(backoff*2, time.Minute)
		}
	}
}

type relayMsg struct {
	Op    string     `json:"op"`
	Nonce wire.Bytes `json:"nonce"`
	From  *string    `json:"from"`
	Box   wire.Bytes `json:"box"`
}

func (b *Broker) relaySession(ctx context.Context, url string, changed <-chan struct{}) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	c, err := b.cfg.DialRelay(ctx, url)
	if err != nil {
		return err
	}
	r := &relayConn{c: c, out: make(chan []byte, 256), done: make(chan struct{})}
	defer r.close()
	go func() {
		select {
		case <-ctx.Done():
		case <-changed: // another relay, or none
		case <-r.done:
		}
		r.close()
	}()
	read := func() (*relayMsg, error) {
		readCtx, done := context.WithTimeout(ctx, 2*idleTimeout)
		defer done()
		data, err := c.Read(readCtx)
		if err != nil {
			return nil, err
		}
		var m relayMsg
		if err := json.Unmarshal(data, &m); err != nil {
			return nil, err
		}
		return &m, nil
	}
	hello, err := read()
	if err != nil {
		return err
	}
	if hello.Op != "hello" || len(hello.Nonce) == 0 {
		return errors.New("unexpected relay hello")
	}
	auth, err := wire.Sign(b.key, "relay", wire.RelayAuth{V: 1, Role: "broker", Broker: b.ID(), Key: b.key.Public(),
		Endpoint: "socket", Nonce: hello.Nonce, Issued: b.cfg.Now().Unix()})
	if err != nil {
		return err
	}
	data, _ := json.Marshal(map[string]any{"op": "auth", "auth": auth})
	if err := c.Write(ctx, data); err != nil {
		return err
	}
	go func() {
		for {
			select {
			case data := <-r.out:
				if err := c.Write(ctx, data); err != nil {
					r.close()
					return
				}
			case <-r.done:
				return
			}
		}
	}()
	b.mu.Lock()
	roster := b.roster
	b.relay = r
	b.mu.Unlock()
	defer func() {
		b.mu.Lock()
		if b.relay == r {
			b.relay = nil
		}
		b.mu.Unlock()
	}()
	if roster != nil {
		r.sendAllow(roster)
	}
	b.cfg.Logf("approvals: relay connected")
	ping := time.NewTicker(30 * time.Second)
	defer ping.Stop()
	go func() {
		for {
			select {
			case <-ping.C:
				r.send(map[string]string{"op": "ping"})
			case <-r.done:
				return
			}
		}
	}()
	for {
		m, err := read()
		if err != nil {
			return err
		}
		if m.Op == "from" && m.From != nil {
			b.fromApprover(*m.From, m.Box)
		}
	}
}
