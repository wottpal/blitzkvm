package broker

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"sync"
	"time"

	"github.com/wottpal/blitzkvm/approval/wire"
)

// approverConn is an approver's direct WebSocket.
type approverConn struct {
	c    Conn
	out  chan []byte
	done chan struct{}
	once sync.Once
}

func (a *approverConn) send(msg any) {
	data, err := json.Marshal(msg)
	if err != nil {
		return
	}
	select {
	case a.out <- data:
	case <-a.done:
	default:
		a.close()
	}
}

func (a *approverConn) close() {
	a.once.Do(func() {
		close(a.done)
		_ = a.c.Close()
	})
}

func (a *approverConn) writer(ctx context.Context) {
	for {
		select {
		case data := <-a.out:
			if err := a.c.Write(ctx, data); err != nil {
				a.close()
				return
			}
		case <-a.done:
			return
		}
	}
}

type frame struct {
	Op   string         `json:"op"`
	Auth *wire.Envelope `json:"auth"`
	Box  wire.Bytes     `json:"box"`
}

// approverMsg is what a box carries from an approver.
type approverMsg struct {
	Op       string         `json:"op"`
	Decision *wire.Envelope `json:"decision"`
	Roster   *wire.Envelope `json:"roster"`
	Pairing  *wire.Envelope `json:"pairing"`
	Enroll   *wire.Envelope `json:"enroll"`
	Unlock   *wire.Envelope `json:"unlock"`
}

// ServeApprover serves one approver's direct WebSocket until it closes.
func (b *Broker) ServeApprover(ctx context.Context, c Conn) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	a := &approverConn{c: c, out: make(chan []byte, 64), done: make(chan struct{})}
	defer a.close()
	go a.writer(ctx)
	go func() {
		select {
		case <-ctx.Done():
			a.close()
		case <-a.done:
		}
	}()
	nonce := wire.Nonce(32)
	a.send(map[string]any{"op": "hello", "broker": b.ID(), "nonce": wire.Bytes(nonce)})
	read := func() (*frame, error) {
		readCtx, done := context.WithTimeout(ctx, idleTimeout)
		defer done()
		data, err := c.Read(readCtx)
		if err != nil {
			return nil, err
		}
		if len(data) > maxMessage {
			return nil, errors.New("message too large")
		}
		var f frame
		if err := json.Unmarshal(data, &f); err != nil {
			return nil, err
		}
		return &f, nil
	}
	first, err := read()
	if err != nil {
		return
	}
	if first.Op == "box" {
		// Not an approver (yet): one enrollment, then goodbye.
		b.fromApprover("", first.Box)
		return
	}
	if first.Op != "auth" {
		return
	}
	id, err := b.checkHello(first.Auth, nonce)
	if err != nil {
		b.cfg.Logf("approvals: approver auth refused: %v", err)
		return
	}
	b.mu.Lock()
	if b.direct[id] == nil {
		b.direct[id] = map[*approverConn]bool{}
	}
	b.direct[id][a] = true
	b.mu.Unlock()
	a.send(map[string]string{"op": "ready"})
	defer func() {
		b.mu.Lock()
		delete(b.direct[id], a)
		if len(b.direct[id]) == 0 {
			delete(b.direct, id)
		}
		b.mu.Unlock()
	}()
	b.sync(id)
	for {
		f, err := read()
		if err != nil {
			return
		}
		switch f.Op {
		case "box":
			b.fromApprover(id, f.Box)
		case "ping":
			a.send(map[string]string{"op": "pong"})
		}
	}
}

func (b *Broker) checkHello(env *wire.Envelope, nonce []byte) (string, error) {
	b.mu.Lock()
	roster := b.roster
	b.mu.Unlock()
	if roster == nil {
		return "", errors.New("approvals aren't enabled")
	}
	if env == nil {
		return "", errors.New("no auth")
	}
	var peek wire.HelloAuth
	if err := env.Peek(&peek); err != nil {
		return "", err
	}
	approver := roster.Approver(peek.Approver)
	if approver == nil {
		return "", wire.ErrUnknownApprover
	}
	var auth wire.HelloAuth
	if err := env.Verify("hello", approver.Transport, &auth); err != nil {
		return "", err
	}
	if auth.V != 1 || auth.Broker != b.ID() || subtle.ConstantTimeCompare(auth.Nonce, nonce) != 1 {
		return "", errors.New("auth for another hello")
	}
	return approver.ID, nil
}

// fromApprover opens a box from an approver (id "" for an unauthenticated
// sender, who may only enroll) and acts on it. The id comes from the
// direct connection's handshake or the relay; nothing here trusts it beyond
// routing replies: decisions, rosters and pairings carry their own
// signatures.
func (b *Broker) fromApprover(id string, box []byte) {
	data, err := b.seal.OpenBox(box)
	if err != nil {
		return
	}
	var m approverMsg
	if err := json.Unmarshal(data, &m); err != nil {
		return
	}
	if id == "" {
		if m.Op == "enroll" {
			b.enroll(m.Enroll)
		}
		return
	}
	b.mu.Lock()
	known := b.roster != nil && b.roster.Approver(id) != nil
	b.mu.Unlock()
	if !known {
		return
	}
	switch m.Op {
	case "decision":
		b.decide(m.Decision)
	case "roster":
		if err := b.acceptRoster(m.Roster); err != nil && !errors.Is(err, wire.ErrRosterStale) {
			b.cfg.Logf("approvals: roster from %s refused: %v", id, err)
		}
	case "pairing":
		b.pairing(m.Pairing)
	case "unlock":
		// Forwarded only when an approver signed it; the target checks it
		// again against its own roster before it asks anyone.
		b.mu.Lock()
		link, roster := b.link, b.roster
		b.mu.Unlock()
		if link == nil || roster == nil {
			return
		}
		if _, err := wire.VerifyUnlock(roster, m.Unlock, link.target, b.cfg.Now()); err != nil {
			b.cfg.Logf("approvals: unlock request refused: %v", err)
			return
		}
		link.send(map[string]any{"op": "unlock", "unlock": m.Unlock})
	case "sync":
		b.sync(id)
	}
}

// sync sends an approver the roster and the open requests.
func (b *Broker) sync(id string) {
	b.mu.Lock()
	roster := b.rosterEnv
	var open []*wire.Envelope
	for _, p := range b.pending {
		if p.state == "pending" {
			open = append(open, p.env)
		}
	}
	b.mu.Unlock()
	if roster != nil {
		b.deliver(id, map[string]any{"op": "roster", "roster": roster}, "")
	}
	for _, env := range open {
		b.deliver(id, map[string]any{"op": "request", "request": env}, "")
	}
}

// decide applies an approver's decision: the first valid one wins.
func (b *Broker) decide(env *wire.Envelope) {
	if env == nil || !b.cfg.Synced() {
		return
	}
	var peek wire.Decision
	if err := env.Peek(&peek); err != nil {
		return
	}
	now := b.cfg.Now()
	b.mu.Lock()
	var p *pending
	for _, candidate := range b.pending {
		if candidate.env.DigestHex() == peek.Request {
			p = candidate
			break
		}
	}
	roster := b.roster
	if p == nil || roster == nil || p.state != "pending" {
		b.mu.Unlock()
		return
	}
	d, err := wire.VerifyDecision(roster, p.verified, env, now)
	if err != nil {
		b.mu.Unlock()
		b.cfg.Logf("approvals: decision refused: %v", err)
		return
	}
	var secret []byte
	if len(d.Secret) > 0 {
		padded, err := p.sealKey.OpenSecret(d.Secret, p.verified.RequestDigest)
		if err != nil {
			b.mu.Unlock()
			b.cfg.Logf("approvals: decision secret doesn't open")
			return
		}
		secret = append([]byte(nil), wire.UnpadSecret(padded)...)
		wipe(padded)
	}
	p.by, p.decided = d.Approver, now
	if d.Decision == wire.Approve {
		p.state, p.secret = "approved", secret
	} else {
		p.state, p.ended = "denied", now
	}
	b.record(p, "")
	link := b.link
	id, target, state := p.verified.Ask.ID, p.verified.Ask.Target, p.state
	typing := wire.Typing(p.verified.Ask.Kind)
	sent := link != nil && link.target == target
	b.mu.Unlock()
	if sent {
		link.send(map[string]any{"op": "decision", "id": id, "decision": env})
	} else {
		b.finish(id, target, "failed", "the target isn't connected")
		return
	}
	b.broadcast(map[string]any{"op": "status", "id": id, "state": state, "by": d.Approver})
	if state == "approved" && !typing {
		// Nothing to press: the target has what it needs.
		b.finish(id, target, "done", "")
	}
}

// pairing stores the hash of an owner's one-time pairing token.
func (b *Broker) pairing(env *wire.Envelope) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if env == nil || b.roster == nil {
		return
	}
	owner := b.roster.Approver(env.Key)
	if owner == nil || !b.roster.IsOwner(owner.ID) {
		return
	}
	var p wire.Pairing
	if err := env.Verify("pairing", owner.Presence, &p); err != nil || p.V != 1 || len(p.Hash) != 32 {
		return
	}
	if _, spent := b.used[string(p.Hash)]; spent {
		return // a replayed pairing doesn't bring a used token back
	}
	until := time.Unix(p.Expires, 0)
	if max := b.cfg.Now().Add(pairingLifetime); until.After(max) {
		until = max
	}
	b.pairings[string(p.Hash)] = until
}

// enroll passes a new device's enrollment for a live pairing to the owners
// (once per pairing). The broker can't check its MAC: only the inviting
// owner and the device know the token, so the owner's app checks it before
// it offers to add the device, and the broker can't slip in a device of
// its own.
func (b *Broker) enroll(env *wire.Envelope) {
	if env == nil {
		return
	}
	var peek wire.Enroll
	if err := env.Peek(&peek); err != nil {
		return
	}
	var e wire.Enroll
	if err := env.Verify("enroll", peek.Approver.Presence, &e); err != nil || e.V != 1 {
		return
	}
	if e.Approver.ID != wire.KID(e.Approver.Presence) {
		return
	}
	b.mu.Lock()
	until, ok := b.pairings[string(e.Pairing)]
	if ok {
		delete(b.pairings, string(e.Pairing)) // one use
		b.used[string(e.Pairing)] = until
	}
	var owners []string
	if b.roster != nil {
		owners = append(owners, b.roster.Owners...)
	}
	b.mu.Unlock()
	if !ok || b.cfg.Now().After(until) {
		b.cfg.Logf("approvals: enrollment for an unknown or expired pairing")
		return
	}
	b.cfg.Logf("approvals: %q (%s) asks to become an approver", e.Approver.Name, e.Approver.Platform)
	for _, id := range owners {
		b.deliver(id, map[string]any{"op": "enrolling", "enroll": env}, "enroll")
	}
}
