package broker

import (
	"bufio"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"

	"github.com/wottpal/blitzkvm/approval/wire"
)

// linkConn is the target daemon's connection over the host link.
type linkConn struct {
	rw     io.ReadWriteCloser
	target string
	out    chan []byte
	done   chan struct{}
	once   sync.Once
}

func (l *linkConn) send(msg any) {
	data, err := json.Marshal(msg)
	if err != nil {
		return
	}
	select {
	case l.out <- append(data, '\n'):
	case <-l.done:
	default:
		l.close() // a daemon that doesn't read loses its link
	}
}

func (l *linkConn) close() {
	l.once.Do(func() {
		close(l.done)
		_ = l.rw.Close()
	})
}

// flushAndClose closes once what was sent before is written.
func (l *linkConn) flushAndClose() {
	select {
	case l.out <- nil:
		select {
		case <-l.done:
		case <-time.After(5 * time.Second):
			l.close()
		}
	case <-l.done:
	}
}

func (l *linkConn) writer() {
	for {
		select {
		case data := <-l.out:
			if data == nil { // flushAndClose
				l.close()
				return
			}
			if _, err := l.rw.Write(data); err != nil {
				l.close()
				return
			}
		case <-l.done:
			return
		}
	}
}

type deadliner interface{ SetReadDeadline(time.Time) error }

type linkMsg struct {
	Op     string         `json:"op"`
	Auth   *wire.Envelope `json:"auth"`
	Roster *wire.Envelope `json:"roster"`
	Ask    *wire.Envelope `json:"ask"`
	ID     string         `json:"id"`
	Seq    int            `json:"seq"`
	Step   *wire.Step     `json:"step"`
	OK     bool           `json:"ok"`
	Note   string         `json:"note"`
}

// ServeLink serves the target daemon on one host-link connection until it
// closes. A newer authenticated connection replaces an older one.
func (b *Broker) ServeLink(ctx context.Context, rw io.ReadWriteCloser) {
	l := &linkConn{rw: rw, out: make(chan []byte, 64), done: make(chan struct{})}
	defer l.close()
	go l.writer()
	go func() {
		select {
		case <-ctx.Done():
			l.close()
		case <-l.done:
		}
	}()
	scanner := bufio.NewScanner(rw)
	scanner.Buffer(make([]byte, 4096), maxMessage)
	read := func(timeout time.Duration) (*linkMsg, error) {
		if d, ok := rw.(deadliner); ok {
			_ = d.SetReadDeadline(time.Now().Add(timeout))
		}
		if !scanner.Scan() {
			if err := scanner.Err(); err != nil {
				return nil, err
			}
			return nil, io.EOF
		}
		var m linkMsg
		if err := json.Unmarshal(scanner.Bytes(), &m); err != nil {
			return nil, fmt.Errorf("link message: %w", err)
		}
		return &m, nil
	}

	nonce := wire.Nonce(32)
	l.send(map[string]any{"op": "hello", "broker": b.ID(), "nonce": wire.Bytes(nonce)})
	// A connection that doesn't authenticate at once gives its slot back.
	m, err := read(authTimeout)
	if err != nil || m.Op != "auth" {
		return
	}
	target, err := b.checkLinkAuth(m.Auth, nonce)
	if err != nil {
		b.cfg.Logf("approvals: link auth refused: %v", err)
		l.send(map[string]any{"op": "rejected", "reason": err.Error()})
		l.flushAndClose()
		return
	}
	l.target = target
	b.mu.Lock()
	old := b.link
	b.link = l
	roster := b.rosterEnv
	b.mu.Unlock()
	if old != nil {
		old.close()
	}
	b.cfg.Logf("approvals: target %s connected", target)
	l.send(map[string]any{"op": "ready", "roster": roster})
	defer func() {
		b.mu.Lock()
		if b.link == l {
			b.link = nil
		}
		b.mu.Unlock()
		b.linkGone(l)
	}()

	go func() {
		t := time.NewTicker(pingEvery)
		defer t.Stop()
		for {
			select {
			case <-t.C:
				l.send(map[string]string{"op": "ping"})
			case <-l.done:
				return
			}
		}
	}()
	for {
		m, err := read(idleTimeout)
		if err != nil {
			return
		}
		b.handleLink(ctx, l, m)
	}
}

func (b *Broker) checkLinkAuth(env *wire.Envelope, nonce []byte) (string, error) {
	b.mu.Lock()
	roster := b.roster
	b.mu.Unlock()
	if roster == nil {
		return "", errors.New("approvals aren't enabled")
	}
	if env == nil {
		return "", errors.New("no auth")
	}
	var peek wire.LinkAuth
	if err := env.Peek(&peek); err != nil {
		return "", err
	}
	target := roster.Target(peek.Target)
	if target == nil {
		return "", errors.New("unknown target")
	}
	var auth wire.LinkAuth
	if err := env.Verify("link", target.Key, &auth); err != nil {
		return "", err
	}
	if auth.V != 1 || auth.Broker != b.ID() || subtle.ConstantTimeCompare(auth.Nonce, nonce) != 1 {
		return "", errors.New("link auth for another hello")
	}
	return target.ID, nil
}

func (b *Broker) handleLink(ctx context.Context, l *linkConn, m *linkMsg) {
	switch m.Op {
	case "ping":
		l.send(map[string]string{"op": "pong"})
	case "pong":
	case "roster":
		if err := b.acceptRoster(m.Roster); err != nil && !errors.Is(err, wire.ErrRosterStale) {
			b.cfg.Logf("approvals: roster from the target refused: %v", err)
		}
	case "ask":
		req, err := b.takeAsk(l, m.Ask)
		if err != nil {
			id := ""
			var peek wire.Ask
			if m.Ask != nil && m.Ask.Peek(&peek) == nil {
				id = peek.ID
			}
			l.send(map[string]any{"op": "rejected", "id": id, "reason": err.Error()})
			return
		}
		l.send(map[string]any{"op": "request", "request": req})
	case "cancel":
		b.finish(m.ID, l.target, "cancelled", "")
	case "done":
		state := "done"
		if !m.OK {
			state = "failed"
		}
		b.finish(m.ID, l.target, state, m.Note)
	case "step":
		// Off the read loop, so an abort can stop a step mid-way.
		go func(m *linkMsg) {
			typed, err := b.step(ctx, l.target, m.ID, m.Step)
			reply := map[string]any{"op": "stepped", "id": m.ID, "seq": m.Seq, "ok": err == nil}
			if m.Step != nil && m.Step.Secret != nil {
				reply["typed"] = typed
			}
			if err != nil {
				reply["error"] = err.Error()
			}
			l.send(reply)
		}(m)
	case "abort":
		b.abort(l.target, m.ID)
	}
}

// takeAsk turns a daemon's ask into a signed request and offers it.
func (b *Broker) takeAsk(l *linkConn, env *wire.Envelope) (*wire.Envelope, error) {
	target := l.target
	if !b.cfg.Synced() {
		return nil, errors.New("the JetKVM's clock isn't set yet")
	}
	now := b.cfg.Now()
	b.mu.Lock()
	roster := b.roster
	b.mu.Unlock()
	if roster == nil {
		return nil, errors.New("approvals aren't enabled")
	}
	t := roster.Target(target)
	if t == nil || env == nil {
		return nil, errors.New("unknown target")
	}
	var ask wire.Ask
	if err := env.Verify("ask", t.Key, &ask); err != nil {
		return nil, err
	}
	if ask.Target != target {
		return nil, errors.New("ask for another target")
	}
	if err := ask.Check(now); err != nil {
		return nil, err
	}
	if ask.Issued > now.Unix()+int64(wire.ClockSkew/time.Second) {
		return nil, errors.New("ask from the future")
	}
	seal, err := wire.NewSealKey()
	if err != nil {
		return nil, err
	}
	reqEnv, err := wire.Sign(b.key, "request", wire.Request{V: 1, Ask: env, Seal: seal.Public(),
		Issued: now.Unix(), Expires: ask.Expires})
	if err != nil {
		return nil, err
	}
	verified, err := wire.VerifyRequest(roster, reqEnv, now)
	if err != nil {
		return nil, err
	}

	b.mu.Lock()
	if _, dup := b.pending[ask.ID]; dup {
		b.mu.Unlock()
		return nil, errors.New("duplicate ask")
	}
	open := 0
	for _, p := range b.pending {
		if p.state == "pending" || p.state == "approved" {
			open++
		}
	}
	recent := b.asks[:0]
	for _, at := range b.asks {
		if now.Sub(at) < time.Minute {
			recent = append(recent, at)
		}
	}
	b.asks = recent
	if open >= maxPending || len(b.asks) >= asksPerMinute {
		b.mu.Unlock()
		return nil, errors.New("too many requests")
	}
	b.asks = append(b.asks, now)
	p := &pending{link: l, verified: verified, env: reqEnv, sealKey: seal, state: "pending", pushed: now}
	b.pending[ask.ID] = p
	b.record(p, "")
	var ids []string
	for _, a := range roster.Approvers {
		ids = append(ids, a.ID)
	}
	b.mu.Unlock()
	b.cfg.Logf("approvals: request %s (%s)", ask.ID, ask.Kind)
	for _, id := range ids {
		b.deliver(id, map[string]any{"op": "request", "request": reqEnv}, &push{collapse: ask.ID})
	}
	return reqEnv, nil
}

// finish ends a request on the daemon's word.
func (b *Broker) finish(id, target, state, note string) {
	b.mu.Lock()
	p := b.pending[id]
	if p == nil || p.verified.Ask.Target != target || (p.state != "pending" && p.state != "approved") {
		b.mu.Unlock()
		return
	}
	if state == "done" && p.state != "approved" {
		state = "failed"
	}
	leftPending := p.state == "pending"
	p.state, p.ended = state, b.cfg.Now()
	wipe(p.secret)
	p.secret = nil
	b.stopLocked(p)
	b.record(p, note)
	b.mu.Unlock()
	b.applyHold()
	b.status(id, map[string]any{"op": "status", "id": id, "state": state, "note": note}, leftPending)
}

// linkGone fails what this connection was still driving (not what a newer
// connection of the same daemon asked meanwhile).
func (b *Broker) linkGone(l *linkConn) {
	b.mu.Lock()
	var ids []string
	for id, p := range b.pending {
		if p.link == l && (p.state == "pending" || p.state == "approved") {
			ids = append(ids, id)
			if p.stepCancel != nil {
				p.stepCancel()
			}
		}
	}
	b.mu.Unlock()
	for _, id := range ids {
		b.finish(id, l.target, "cancelled", "the target disconnected")
	}
}

// abort stops the step running for a request at once (between characters).
func (b *Broker) abort(target, id string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if p := b.pending[id]; p != nil && p.verified.Ask.Target == target && p.stepCancel != nil {
		p.stepCancel()
	}
}

// step presses what the daemon asks for, for an approved screen ask; for a
// secret it returns how many characters it typed.
func (b *Broker) step(ctx context.Context, target, id string, s *wire.Step) (int, error) {
	if s == nil {
		return 0, errors.New("no step")
	}
	actions := 0
	for _, set := range []bool{s.Click != nil, s.Secret != nil, len(s.Keys) > 0, s.Erase > 0} {
		if set {
			actions++
		}
	}
	if actions != 1 {
		return 0, errors.New("a step does exactly one thing")
	}
	b.mu.Lock()
	p := b.pending[id]
	switch {
	case p == nil || p.verified.Ask.Target != target:
		b.mu.Unlock()
		return 0, errors.New("unknown request")
	case b.roster == nil || b.roster.Target(target) == nil:
		b.mu.Unlock()
		return 0, errors.New("the target left the roster")
	case p.state != "approved" || !wire.Typing(p.verified.Ask.Kind):
		b.mu.Unlock()
		return 0, errors.New("the request isn't approved for screen steps")
	case b.cfg.Now().Sub(p.decided) > stepWindow:
		b.mu.Unlock()
		return 0, errors.New("the approval is too old for screen steps")
	}
	var secret []byte
	if s.Secret != nil {
		if p.secretSet {
			b.mu.Unlock()
			return 0, errors.New("the secret was typed already")
		}
		if p.secret == nil {
			b.mu.Unlock()
			return 0, errors.New("the approval carries no secret")
		}
		secret, p.secret, p.secretSet = p.secret, nil, true
	}
	// Abortable from here on, also while it waits for another step.
	stepCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	p.stepCancel = cancel
	b.mu.Unlock()
	defer wipe(secret)
	defer func() {
		b.mu.Lock()
		p.stepCancel = nil
		b.mu.Unlock()
	}()
	select {
	case b.typing <- struct{}{}:
	case <-stepCtx.Done():
		return 0, errors.New("stopped before it started")
	}
	defer func() { <-b.typing }()
	// The request may have ended (cancelled, expired, failed) while this
	// step waited its turn.
	b.mu.Lock()
	live := b.pending[id] == p && p.state == "approved" && b.cfg.Now().Sub(p.decided) <= stepWindow
	b.mu.Unlock()
	if !live || stepCtx.Err() != nil {
		return 0, errors.New("the request ended before its step")
	}
	switch {
	case s.Click != nil:
		if s.Click.X < 0 || s.Click.X > 1 || s.Click.Y < 0 || s.Click.Y > 1 {
			return 0, errors.New("click outside the display")
		}
		return 0, b.cfg.HID.Click(stepCtx, s.Click.X, s.Click.Y)
	case s.Secret != nil:
		// Character by character from the bytes (which are wiped), never
		// the whole secret as a string.
		n, err := s.Secret.Check(secret)
		if err != nil {
			return 0, err
		}
		i := 0
		for rest := secret; len(rest) > 0; i++ {
			strokes, size := s.Secret.Next(rest)
			if err := stepCtx.Err(); err != nil {
				return i, fmt.Errorf("stopped after %d of %d characters", i, n)
			}
			if err := b.cfg.HID.Type(stepCtx, strokes); err != nil {
				return i, err
			}
			rest = rest[size:]
		}
		return i, nil
	case len(s.Keys) > 0:
		if err := wire.CheckKeys(s.Keys); err != nil {
			return 0, err
		}
		return 0, b.cfg.HID.Type(stepCtx, s.Keys)
	case s.Erase > 0:
		if s.Erase > 256 {
			return 0, errors.New("erase too long")
		}
		strokes := make([]wire.Stroke, s.Erase)
		for i := range strokes {
			strokes[i] = wire.Stroke{0x2A, 0}
		}
		return 0, b.cfg.HID.Type(stepCtx, strokes)
	}
	return 0, errors.New("empty step")
}
