package broker

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"io"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/wottpal/blitzkvm/approval/wire"
)

// memStore is a Store in memory.
type memStore struct {
	mu    sync.Mutex
	files map[string][]byte
}

func (s *memStore) Load(name string) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if d, ok := s.files[name]; ok {
		return d, nil
	}
	return nil, os.ErrNotExist
}

func (s *memStore) Save(name string, data []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.files[name] = data
	return nil
}

func (s *memStore) Remove(name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.files, name)
	return nil
}

// fakeHID records what the broker pressed.
type fakeHID struct {
	mu      sync.Mutex
	clicks  []wire.Point
	strokes []wire.Stroke
	holds   []bool
	// gate, when set, makes Type wait for it (a slow keyboard).
	gate chan struct{}
}

func (h *fakeHID) Hold(on bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.holds = append(h.holds, on)
}

func (h *fakeHID) Click(_ context.Context, x, y float64) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.clicks = append(h.clicks, wire.Point{X: x, Y: y})
	return nil
}

func (h *fakeHID) Type(ctx context.Context, s []wire.Stroke) error {
	if h.gate != nil {
		select {
		case <-h.gate:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.strokes = append(h.strokes, s...)
	return nil
}

// chanConn is one end of an in-memory message connection.
type chanConn struct {
	in, out chan []byte
	closed  chan struct{}
	once    *sync.Once
}

func connPair() (*chanConn, *chanConn) {
	a, b := make(chan []byte, 64), make(chan []byte, 64)
	closed, once := make(chan struct{}), &sync.Once{}
	return &chanConn{in: a, out: b, closed: closed, once: once}, &chanConn{in: b, out: a, closed: closed, once: once}
}

func (c *chanConn) Read(ctx context.Context) ([]byte, error) {
	select {
	case d := <-c.in:
		return d, nil
	case <-c.closed:
		return nil, io.EOF
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (c *chanConn) Write(_ context.Context, d []byte) error {
	select {
	case c.out <- d:
		return nil
	case <-c.closed:
		return io.EOF
	}
}

func (c *chanConn) Close() error {
	c.once.Do(func() { close(c.closed) })
	return nil
}

type party struct {
	presence, transport *wire.SigningKey
	seal                *wire.SealKey
	id                  string
}

func newParty(t *testing.T) *party {
	p, _ := wire.NewSigningKey()
	tr, _ := wire.NewSigningKey()
	s, _ := wire.NewSealKey()
	return &party{presence: p, transport: tr, seal: s, id: p.ID()}
}

func (p *party) approver(name, platform string) wire.Approver {
	return wire.Approver{ID: p.id, Name: name, Platform: platform, Presence: p.presence.Public(),
		Transport: p.transport.Public(), Seal: p.seal.Public()}
}

type harness struct {
	// offset runs the broker's clock ahead of the real one.
	offset atomic.Int64
	t      *testing.T
	b      *Broker
	hid    *fakeHID
	synced bool
	mac    *party
	phone  *party
	target *wire.SigningKey
	roster wire.Roster
	ctx    context.Context
}

func newHarness(t *testing.T) *harness {
	h := &harness{t: t, hid: &fakeHID{}, synced: true, mac: newParty(t), phone: newParty(t)}
	h.target, _ = wire.NewSigningKey()
	var cancel context.CancelFunc
	h.ctx, cancel = context.WithCancel(context.Background())
	t.Cleanup(cancel)
	b, err := New(Config{Store: &memStore{files: map[string][]byte{}}, HID: h.hid,
		Now:    func() time.Time { return time.Now().Add(time.Duration(h.offset.Load())) },
		Synced: func() bool { return h.synced }, Logf: t.Logf})
	if err != nil {
		t.Fatal(err)
	}
	h.b = b
	h.roster = wire.Roster{V: 1, Seq: 1, Issued: time.Now().Unix(), Broker: b.Identity(), Owners: []string{h.mac.id},
		Approvers: []wire.Approver{h.mac.approver("Mac", "macos"), h.phone.approver("iPhone", "ios")},
		Targets:   []wire.Target{{ID: h.target.ID(), Name: "Mac mini", Key: h.target.Public()}}}
	env, _ := wire.Sign(h.mac.presence, "roster", h.roster)
	if err := b.Enable(env); err != nil {
		t.Fatal(err)
	}
	go b.Run(h.ctx)
	return h
}

// daemon is a fake target daemon on the link.
type daemon struct {
	t    *testing.T
	conn net.Conn
	r    *bufio.Scanner
}

func (h *harness) connectDaemon(key *wire.SigningKey) (*daemon, error) {
	a, bEnd := net.Pipe()
	go h.b.ServeLink(h.ctx, bEnd)
	d := &daemon{t: h.t, conn: a, r: bufio.NewScanner(a)}
	hello := d.read()
	if hello == nil {
		return nil, errors.New("no hello")
	}
	auth, _ := wire.Sign(key, "link", wire.LinkAuth{V: 1, Broker: h.b.ID(), Target: key.ID(),
		Nonce: decodeBytes(hello["nonce"]), Issued: time.Now().Unix()})
	d.send(map[string]any{"op": "auth", "auth": auth})
	ready := d.read()
	if ready == nil || ready["op"] != "ready" {
		return nil, errors.New(string(mustJSON(ready)))
	}
	return d, nil
}

func mustJSON(v any) []byte { d, _ := json.Marshal(v); return d }

func decodeBytes(v any) []byte {
	s, _ := v.(string)
	b, _ := wire.B64.DecodeString(s)
	return b
}

func (d *daemon) send(m any) {
	d.t.Helper()
	if _, err := d.conn.Write(append(mustJSON(m), '\n')); err != nil {
		d.t.Fatal(err)
	}
}

func (d *daemon) read() map[string]any {
	d.t.Helper()
	_ = d.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	for d.r.Scan() {
		var m map[string]any
		if err := json.Unmarshal(d.r.Bytes(), &m); err != nil {
			d.t.Fatal(err)
		}
		if m["op"] == "ping" {
			continue
		}
		return m
	}
	return nil
}

func (d *daemon) ask(key *wire.SigningKey, kind, secret string, grantable bool) (string, *wire.Envelope) {
	now := time.Now().Unix()
	id := wire.RandomID()
	by := ""
	if kind == wire.KindUnlock {
		by = "0123456789abcdef01234567"
	}
	env, _ := wire.Sign(key, "ask", wire.Ask{V: 1, ID: id, Target: key.ID(), Kind: kind, Title: "test " + kind,
		Secret: secret, Grantable: grantable, RequestedBy: by, Nonce: wire.Nonce(32), Issued: now, Expires: now + 60})
	d.send(map[string]any{"op": "ask", "ask": env})
	return id, env
}

// approverClient is a fake approver on a direct WebSocket.
type approverClient struct {
	t    *testing.T
	p    *party
	conn *chanConn
	h    *harness
}

func (h *harness) connectApprover(p *party) *approverClient {
	mine, theirs := connPair()
	go h.b.ServeApprover(h.ctx, theirs)
	a := &approverClient{t: h.t, p: p, conn: mine, h: h}
	var hello map[string]any
	_ = json.Unmarshal(a.raw(), &hello)
	auth, _ := wire.Sign(p.transport, "hello", wire.HelloAuth{V: 1, Broker: h.b.ID(), Approver: p.id,
		Nonce: decodeBytes(hello["nonce"]), Issued: time.Now().Unix()})
	_ = mine.Write(h.ctx, mustJSON(map[string]any{"op": "auth", "auth": auth}))
	return a
}

func (a *approverClient) raw() []byte {
	a.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	d, err := a.conn.Read(ctx)
	if err != nil {
		a.t.Fatalf("approver read: %v", err)
	}
	return d
}

// next returns the next opened box message with op (skipping others).
func (a *approverClient) next(op string) map[string]any {
	a.t.Helper()
	for {
		var f struct {
			Op  string     `json:"op"`
			Box wire.Bytes `json:"box"`
		}
		_ = json.Unmarshal(a.raw(), &f)
		if f.Op != "box" {
			continue
		}
		data, err := a.p.seal.OpenBox(f.Box)
		if err != nil {
			a.t.Fatalf("box: %v", err)
		}
		var m map[string]any
		_ = json.Unmarshal(data, &m)
		if m["op"] == op {
			return m
		}
	}
}

func (a *approverClient) sendBox(m any) {
	box, _ := wire.SealBox(a.h.b.Identity().Seal, mustJSON(m))
	_ = a.conn.Write(a.h.ctx, mustJSON(map[string]any{"op": "box", "box": wire.Bytes(box)}))
}

func envFrom(t *testing.T, v any) *wire.Envelope {
	var env wire.Envelope
	if err := json.Unmarshal(mustJSON(v), &env); err != nil {
		t.Fatal(err)
	}
	return &env
}

func (a *approverClient) decide(reqEnv *wire.Envelope, decision string, key *wire.SigningKey, secret string) {
	var req wire.Request
	_ = reqEnv.Peek(&req)
	d := wire.Decision{V: 1, Request: reqEnv.DigestHex(), Ask: req.Ask.DigestHex(), Decision: decision,
		Approver: a.p.id, Issued: time.Now().Unix()}
	if secret != "" {
		d.Secret, _ = wire.SealSecret(req.Seal, reqEnv.Digest(), []byte(secret))
	}
	env, _ := wire.Sign(key, "decision", d)
	a.sendBox(map[string]any{"op": "decision", "decision": env})
}

func TestSudoApprovedEndToEnd(t *testing.T) {
	h := newHarness(t)
	phone := h.connectApprover(h.phone)
	phone.next("roster")
	d, err := h.connectDaemon(h.target)
	if err != nil {
		t.Fatal(err)
	}
	id, _ := d.ask(h.target, wire.KindSudo, wire.SecretNone, true)
	reply := d.read()
	if reply["op"] != "request" {
		t.Fatalf("ask: %v", reply)
	}
	got := phone.next("request")
	reqEnv := envFrom(t, got["request"])
	if _, err := wire.VerifyRequest(&h.roster, reqEnv, time.Now()); err != nil {
		t.Fatalf("approver can't verify the request: %v", err)
	}
	phone.decide(reqEnv, wire.Approve, h.phone.presence, "")
	dec := d.read()
	if dec["op"] != "decision" || dec["id"] != id {
		t.Fatalf("daemon got %v", dec)
	}
	if st := phone.next("status"); st["state"] != "approved" {
		t.Fatalf("status %v", st)
	}
	if st := phone.next("status"); st["state"] != "done" {
		t.Fatalf("status %v", st)
	}
	// A second (replayed) decision changes nothing.
	phone.decide(reqEnv, wire.Deny, h.phone.transport, "")
	d.send(map[string]any{"op": "ping"})
	if m := d.read(); m["op"] != "pong" {
		t.Fatalf("after replay the daemon got %v", m)
	}
}

func TestLinkAuthRefusesStrangers(t *testing.T) {
	h := newHarness(t)
	stranger, _ := wire.NewSigningKey()
	if _, err := h.connectDaemon(stranger); err == nil {
		t.Fatal("a target outside the roster connected")
	}
}

func TestScreenStepsNeedApprovalAndUseTheSecretOnce(t *testing.T) {
	h := newHarness(t)
	mac := h.connectApprover(h.mac)
	mac.next("roster")
	d, _ := h.connectDaemon(h.target)
	id, _ := d.ask(h.target, wire.KindUnlock, wire.SecretMac, false)
	reqEnv := envFrom(t, d.read()["request"])
	step := func(seq int, s wire.Step) map[string]any {
		d.send(map[string]any{"op": "step", "id": id, "seq": seq, "step": s})
		return d.read()
	}
	keyMap := &wire.KeyMap{Map: map[string][]wire.Stroke{"p": {{0x13, 0}}, "w": {{0x1A, 0}}, "^": {{0x35, 0}, {0x2C, 0}}}}
	if r := step(1, wire.Step{Secret: keyMap}); r["ok"] != false {
		t.Fatalf("secret typed before approval: %v", r)
	}
	if r := step(2, wire.Step{Click: &wire.Point{X: 0.5, Y: 0.5}}); r["ok"] != false {
		t.Fatalf("click before approval: %v", r)
	}
	mac.next("request")
	mac.decide(reqEnv, wire.Approve, h.mac.presence, "pw^")
	if m := d.read(); m["op"] != "decision" {
		t.Fatalf("daemon got %v", m)
	}
	if r := step(3, wire.Step{Keys: []wire.Stroke{{0x04, 0}}}); r["ok"] != false {
		t.Fatalf("a letter passed as a key step: %v", r)
	}
	if r := step(4, wire.Step{Keys: []wire.Stroke{{0, 2}}}); r["ok"] != true {
		t.Fatalf("shift tap: %v", r)
	}
	if r := step(5, wire.Step{Secret: keyMap}); r["ok"] != true {
		t.Fatalf("secret: %v", r)
	}
	if r := step(6, wire.Step{Secret: keyMap}); r["ok"] != false {
		t.Fatalf("secret typed twice: %v", r)
	}
	if r := step(7, wire.Step{Keys: []wire.Stroke{{0x28, 0}}}); r["ok"] != true {
		t.Fatalf("return: %v", r)
	}
	want := []wire.Stroke{{0, 2}, {0x13, 0}, {0x1A, 0}, {0x35, 0}, {0x2C, 0}, {0x28, 0}}
	if string(mustJSON(h.hid.strokes)) != string(mustJSON(want)) {
		t.Fatalf("typed %v, want %v", h.hid.strokes, want)
	}
	d.send(map[string]any{"op": "done", "id": id, "ok": true})
	if st := mac.next("status"); st["state"] != "approved" {
		t.Fatalf("status %v", st)
	}
	if st := mac.next("status"); st["state"] != "done" {
		t.Fatalf("status %v", st)
	}
	if r := step(8, wire.Step{Keys: []wire.Stroke{{0x28, 0}}}); r["ok"] != false {
		t.Fatalf("step after done: %v", r)
	}
}

func TestUnmappedSecretTypesNothing(t *testing.T) {
	h := newHarness(t)
	mac := h.connectApprover(h.mac)
	d, _ := h.connectDaemon(h.target)
	id, _ := d.ask(h.target, wire.KindSecurityAgent, wire.SecretMac, false)
	reqEnv := envFrom(t, d.read()["request"])
	mac.next("request")
	mac.decide(reqEnv, wire.Approve, h.mac.presence, "aé")
	d.read()
	d.send(map[string]any{"op": "step", "id": id, "seq": 1,
		"step": wire.Step{Secret: &wire.KeyMap{Map: map[string][]wire.Stroke{"a": {{4, 0}}}}}})
	if r := d.read(); r["ok"] != false {
		t.Fatalf("partial secret typed: %v", r)
	}
	if len(h.hid.strokes) != 0 {
		t.Fatalf("typed %v", h.hid.strokes)
	}
}

func TestDecisionFromRevokedApproverIsIgnored(t *testing.T) {
	h := newHarness(t)
	mac := h.connectApprover(h.mac)
	mac.next("roster")
	phone := h.connectApprover(h.phone)
	phone.next("roster")
	d, _ := h.connectDaemon(h.target)
	d.ask(h.target, wire.KindConfirm, wire.SecretNone, false)
	reqEnv := envFrom(t, d.read()["request"])
	// The owner removes the phone.
	next := h.roster
	next.Seq = 2
	next.Approvers = next.Approvers[:1]
	env, _ := wire.Sign(h.mac.presence, "roster", next)
	mac.sendBox(map[string]any{"op": "roster", "roster": env})
	if m := d.read(); m["op"] != "roster" {
		t.Fatalf("daemon didn't get the new roster: %v", m)
	}
	phone.decide(reqEnv, wire.Approve, h.phone.presence, "")
	d.send(map[string]any{"op": "ping"})
	if m := d.read(); m["op"] != "pong" {
		t.Fatalf("revoked approver's decision reached the daemon: %v", m)
	}
	if st := h.b.State(); st.Seq != 2 || len(st.Approvers) != 1 {
		t.Fatalf("state %+v", st)
	}
}

func TestNoAsksBeforeClockSync(t *testing.T) {
	h := newHarness(t)
	h.synced = false
	d, _ := h.connectDaemon(h.target)
	d.ask(h.target, wire.KindSudo, wire.SecretNone, false)
	if m := d.read(); m["op"] != "rejected" {
		t.Fatalf("ask taken with an unsynced clock: %v", m)
	}
}

func TestPendingLimit(t *testing.T) {
	h := newHarness(t)
	d, _ := h.connectDaemon(h.target)
	for i := 0; i < maxPending; i++ {
		d.ask(h.target, wire.KindConfirm, wire.SecretNone, false)
		if m := d.read(); m["op"] != "request" {
			t.Fatalf("ask %d: %v", i, m)
		}
	}
	d.ask(h.target, wire.KindConfirm, wire.SecretNone, false)
	if m := d.read(); m["op"] != "rejected" {
		t.Fatalf("ask over the limit: %v", m)
	}
}

func TestPairingAndEnrollment(t *testing.T) {
	h := newHarness(t)
	mac := h.connectApprover(h.mac)
	mac.next("roster")
	token := wire.Nonce(32)
	pairing, _ := wire.Sign(h.mac.presence, "pairing", wire.Pairing{V: 1, Hash: wire.PairingHash(token), Expires: time.Now().Add(time.Minute).Unix()})
	mac.sendBox(map[string]any{"op": "pairing", "pairing": pairing})

	newcomer := newParty(t)
	enrollWith := func(tok []byte) {
		a := newcomer.approver("iPad", "ios")
		env, _ := wire.Sign(newcomer.presence, "enroll", wire.Enroll{V: 1, Pairing: wire.PairingHash(tok), Approver: a, MAC: wire.EnrollMAC(tok, a)})
		mine, theirs := connPair()
		go h.b.ServeApprover(h.ctx, theirs)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, _ = mine.Read(ctx) // hello
		box, _ := wire.SealBox(h.b.Identity().Seal, mustJSON(map[string]any{"op": "enroll", "enroll": env}))
		_ = mine.Write(ctx, mustJSON(map[string]any{"op": "box", "box": wire.Bytes(box)}))
	}
	enrollWith(wire.Nonce(32)) // unknown token: nothing reaches the owner
	enrollWith(token)
	m := mac.next("enrolling")
	var e wire.Enroll
	if err := envFrom(t, m["enroll"]).Verify("enroll", newcomer.presence.Public(), &e); err != nil || e.Approver.Name != "iPad" {
		t.Fatalf("enrolling: %v", err)
	}
	// Only the owner, who kept the token, can tell it's the scanned device.
	if !wire.CheckEnrollMAC(token, &e) || wire.CheckEnrollMAC(wire.Nonce(32), &e) {
		t.Fatal("enrollment MAC")
	}
	// A replayed pairing doesn't bring the spent token back.
	mac.sendBox(map[string]any{"op": "pairing", "pairing": pairing})
	mac.sendBox(map[string]any{"op": "sync"})
	mac.next("roster")
	h.b.mu.Lock()
	left := len(h.b.pairings)
	h.b.mu.Unlock()
	if left != 0 {
		t.Fatal("the pairing can be used twice, or came back on replay")
	}
}

func TestRelayCarriesRequestsAndDecisions(t *testing.T) {
	h := &harness{t: t, hid: &fakeHID{}, synced: true, mac: newParty(t), phone: newParty(t)}
	h.target, _ = wire.NewSigningKey()
	var cancel context.CancelFunc
	h.ctx, cancel = context.WithCancel(context.Background())
	defer cancel()
	relayEnds := make(chan *chanConn, 4)
	b, err := New(Config{Store: &memStore{files: map[string][]byte{}}, HID: h.hid, Logf: t.Logf,
		DialRelay: func(ctx context.Context, url string) (Conn, error) {
			mine, theirs := connPair()
			relayEnds <- mine
			return theirs, nil
		}})
	if err != nil {
		t.Fatal(err)
	}
	h.b = b
	h.roster = wire.Roster{V: 1, Seq: 1, Issued: time.Now().Unix(), Broker: b.Identity(), Relay: "https://relay.example",
		Owners: []string{h.mac.id}, Approvers: []wire.Approver{h.mac.approver("Mac", "macos"), h.phone.approver("iPhone", "ios")},
		Targets: []wire.Target{{ID: h.target.ID(), Name: "Mac mini", Key: h.target.Public()}}}
	env, _ := wire.Sign(h.mac.presence, "roster", h.roster)
	if err := b.Enable(env); err != nil {
		t.Fatal(err)
	}
	go b.Run(h.ctx)
	relay := <-relayEnds
	read := func() map[string]any {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		for {
			d, err := relay.Read(ctx)
			if err != nil {
				t.Fatal(err)
			}
			var m map[string]any
			_ = json.Unmarshal(d, &m)
			if m["op"] != "ping" {
				return m
			}
		}
	}
	nonce := wire.Nonce(32)
	_ = relay.Write(h.ctx, mustJSON(map[string]any{"op": "hello", "nonce": wire.Bytes(nonce)}))
	auth := read()
	var ra wire.RelayAuth
	if err := envFrom(t, auth["auth"]).Verify("relay", b.Identity().Key, &ra); err != nil || ra.Role != "broker" || ra.Broker != b.ID() {
		t.Fatalf("relay auth: %v %+v", err, ra)
	}
	if m := read(); m["op"] != "allow" || len(m["approvers"].([]any)) != 2 {
		t.Fatalf("allow: %v", m)
	}
	d, _ := h.connectDaemon(h.target)
	d.ask(h.target, wire.KindSudo, wire.SecretNone, false)
	reqEnv := envFrom(t, d.read()["request"])
	pushed := map[string]bool{}
	for len(pushed) < 2 {
		m := read()
		if m["op"] == "send" && m["push"] != nil {
			pushed[m["to"].(string)] = true
		}
	}
	// The phone answers through the relay.
	var req wire.Request
	_ = reqEnv.Peek(&req)
	dec, _ := wire.Sign(h.phone.presence, "decision", wire.Decision{V: 1, Request: reqEnv.DigestHex(), Ask: req.Ask.DigestHex(),
		Decision: wire.Approve, Approver: h.phone.id, Issued: time.Now().Unix()})
	box, _ := wire.SealBox(b.Identity().Seal, mustJSON(map[string]any{"op": "decision", "decision": dec}))
	_ = relay.Write(h.ctx, mustJSON(map[string]any{"op": "from", "from": h.phone.id, "box": wire.Bytes(box)}))
	if m := d.read(); m["op"] != "decision" {
		t.Fatalf("daemon got %v", m)
	}
}

// Admitting an iPhone changes the roster but not the relay: the roster must
// reach the new approver over the same relay connection, not get lost while
// the connection restarts (the iPhone would wait for its admission forever).
func TestRelayCarriesNewRosterToNewApprover(t *testing.T) {
	h := &harness{t: t, hid: &fakeHID{}, synced: true, mac: newParty(t), phone: newParty(t)}
	h.target, _ = wire.NewSigningKey()
	var cancel context.CancelFunc
	h.ctx, cancel = context.WithCancel(context.Background())
	defer cancel()
	relayEnds := make(chan *chanConn, 4)
	b, err := New(Config{Store: &memStore{files: map[string][]byte{}}, HID: h.hid, Logf: t.Logf,
		DialRelay: func(ctx context.Context, url string) (Conn, error) {
			mine, theirs := connPair()
			relayEnds <- mine
			return theirs, nil
		}})
	if err != nil {
		t.Fatal(err)
	}
	h.b = b
	h.roster = wire.Roster{V: 1, Seq: 1, Issued: time.Now().Unix(), Broker: b.Identity(), Relay: "https://relay.example",
		Owners: []string{h.mac.id}, Approvers: []wire.Approver{h.mac.approver("Mac", "macos")},
		Targets: []wire.Target{{ID: h.target.ID(), Name: "Mac mini", Key: h.target.Public()}}}
	env, _ := wire.Sign(h.mac.presence, "roster", h.roster)
	if err := b.Enable(env); err != nil {
		t.Fatal(err)
	}
	go b.Run(h.ctx)
	relay := <-relayEnds
	read := func() map[string]any {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		for {
			d, err := relay.Read(ctx)
			if err != nil {
				t.Fatalf("relay connection: %v", err)
			}
			var m map[string]any
			_ = json.Unmarshal(d, &m)
			if m["op"] != "ping" {
				return m
			}
		}
	}
	_ = relay.Write(h.ctx, mustJSON(map[string]any{"op": "hello", "nonce": wire.Bytes(wire.Nonce(32))}))
	if m := read(); m["op"] != "auth" {
		t.Fatalf("auth: %v", m)
	}
	if m := read(); m["op"] != "allow" || len(m["approvers"].([]any)) != 1 {
		t.Fatalf("allow: %v", m)
	}
	// The Mac, reaching the broker through the relay, admits the iPhone.
	next := h.roster
	next.Seq, next.Issued = 2, time.Now().Unix()
	next.Approvers = append(append([]wire.Approver(nil), next.Approvers...), h.phone.approver("iPhone", "ios"))
	rosterEnv, _ := wire.Sign(h.mac.presence, "roster", next)
	box, _ := wire.SealBox(b.Identity().Seal, mustJSON(map[string]any{"op": "roster", "roster": rosterEnv}))
	_ = relay.Write(h.ctx, mustJSON(map[string]any{"op": "from", "from": h.mac.id, "box": wire.Bytes(box)}))
	allowed, toPhone := false, false
	for !allowed || !toPhone {
		m := read()
		switch {
		case m["op"] == "allow":
			allowed = len(m["approvers"].([]any)) == 2
		case m["op"] == "send" && m["to"] == h.phone.id:
			toPhone = true
		}
	}
	select {
	case <-relayEnds:
		t.Fatal("the broker dialed the relay again for a roster with the same relay")
	case <-time.After(200 * time.Millisecond):
	}
}

// An open request is pushed to the iPhone again (each time under a new
// collapse id), every 20 s, 10 s for a 1Password prompt, never to the Mac;
// once answered, the iPhone gets one quiet push that replaces it, and no
// more repeats.
func TestRepeatsUntilAnswered(t *testing.T) {
	for _, tc := range []struct {
		kind  string
		every time.Duration
	}{{wire.KindSudo, repeatOther}, {wire.KindOnePassword, repeatOnePassword}} {
		t.Run(tc.kind, func(t *testing.T) {
			h := &harness{t: t, hid: &fakeHID{}, synced: true, mac: newParty(t), phone: newParty(t)}
			h.target, _ = wire.NewSigningKey()
			var cancel context.CancelFunc
			h.ctx, cancel = context.WithCancel(context.Background())
			defer cancel()
			relayEnds := make(chan *chanConn, 4)
			b, err := New(Config{Store: &memStore{files: map[string][]byte{}}, HID: h.hid, Logf: t.Logf,
				Now:    func() time.Time { return time.Now().Add(time.Duration(h.offset.Load())) },
				Synced: func() bool { return true },
				DialRelay: func(ctx context.Context, url string) (Conn, error) {
					mine, theirs := connPair()
					relayEnds <- mine
					return theirs, nil
				}})
			if err != nil {
				t.Fatal(err)
			}
			h.b = b
			h.roster = wire.Roster{V: 1, Seq: 1, Issued: time.Now().Unix(), Broker: b.Identity(), Relay: "https://relay.example",
				Owners: []string{h.mac.id}, Approvers: []wire.Approver{h.mac.approver("Mac", "macos"), h.phone.approver("iPhone", "ios")},
				Targets: []wire.Target{{ID: h.target.ID(), Name: "Mac mini", Key: h.target.Public()}}}
			env, _ := wire.Sign(h.mac.presence, "roster", h.roster)
			if err := b.Enable(env); err != nil {
				t.Fatal(err)
			}
			go b.runRelay(h.ctx) // no Run: the test drives repeat() and the clock
			relay := <-relayEnds
			read := func(wait time.Duration) map[string]any {
				ctx, cancel := context.WithTimeout(context.Background(), wait)
				defer cancel()
				for {
					d, err := relay.Read(ctx)
					if err != nil {
						return nil
					}
					var m map[string]any
					_ = json.Unmarshal(d, &m)
					if m["op"] != "ping" {
						return m
					}
				}
			}
			_ = relay.Write(h.ctx, mustJSON(map[string]any{"op": "hello", "nonce": wire.Bytes(wire.Nonce(32))}))
			read(5 * time.Second) // auth
			read(5 * time.Second) // allow
			d, _ := h.connectDaemon(h.target)
			id, _ := d.ask(h.target, tc.kind, wire.SecretNone, false)
			reqEnv := envFrom(t, d.read()["request"])
			for i := 0; i < 2; i++ { // the first push, to both
				if m := read(5 * time.Second); m["op"] != "send" || m["push"] == nil {
					t.Fatalf("first push: %v", m)
				}
			}
			for n := 1; n <= 2; n++ {
				b.repeat()
				if m := read(300 * time.Millisecond); m != nil {
					t.Fatalf("repeated early: %v", m)
				}
				h.offset.Add(int64(tc.every))
				b.repeat()
				m := read(5 * time.Second)
				push, _ := m["push"].(map[string]any)
				if m["to"] != h.phone.id || push["collapse"] != fmt.Sprintf("%s.%d", id, n) || push["quiet"] != nil || push["repeat"] != true {
					t.Fatalf("repeat %d: %v", n, m)
				}
				if m := read(300 * time.Millisecond); m != nil {
					t.Fatalf("a repeat went to the Mac too: %v", m)
				}
			}
			// The phone denies through the relay.
			var req wire.Request
			_ = reqEnv.Peek(&req)
			dec, _ := wire.Sign(h.phone.transport, "decision", wire.Decision{V: 1, Request: reqEnv.DigestHex(), Ask: req.Ask.DigestHex(),
				Decision: wire.Deny, Approver: h.phone.id, Issued: time.Now().Unix()})
			box, _ := wire.SealBox(b.Identity().Seal, mustJSON(map[string]any{"op": "decision", "decision": dec}))
			_ = relay.Write(h.ctx, mustJSON(map[string]any{"op": "from", "from": h.phone.id, "box": wire.Bytes(box)}))
			ended := map[string]map[string]any{}
			for len(ended) < 2 {
				m := read(5 * time.Second)
				if m == nil {
					t.Fatal("no status")
				}
				if m["op"] == "send" {
					p, _ := m["push"].(map[string]any)
					ended[m["to"].(string)] = p
				}
			}
			if p := ended[h.phone.id]; p == nil || p["collapse"] != id+".end" || p["quiet"] != true {
				t.Fatalf("the phone's end push: %v", p)
			}
			if p := ended[h.mac.id]; p != nil {
				t.Fatalf("the Mac got a push: %v", p)
			}
			h.offset.Add(int64(tc.every))
			b.repeat()
			if m := read(300 * time.Millisecond); m != nil {
				t.Fatalf("repeated after the answer: %v", m)
			}
		})
	}
}

func TestDaemonGoneCancelsItsRequests(t *testing.T) {
	h := newHarness(t)
	mac := h.connectApprover(h.mac)
	mac.next("roster")
	d, _ := h.connectDaemon(h.target)
	id, _ := d.ask(h.target, wire.KindConfirm, wire.SecretNone, false)
	d.read()
	mac.next("request")
	d.conn.Close()
	st := mac.next("status")
	if st["id"] != id || st["state"] != "cancelled" {
		t.Fatalf("status %v", st)
	}
}

func TestUnlockReachesTheDaemon(t *testing.T) {
	h := newHarness(t)
	phone := h.connectApprover(h.phone)
	phone.next("roster")
	d, _ := h.connectDaemon(h.target)
	unlock := func(key *wire.SigningKey, approver, target string, issued int64) *wire.Envelope {
		env, _ := wire.Sign(key, "unlock", wire.UnlockRequest{V: 1, Broker: h.b.ID(), Target: target, Approver: approver,
			Nonce: wire.Nonce(32), Issued: issued})
		return env
	}
	now := time.Now().Unix()
	for name, env := range map[string]*wire.Envelope{
		"unsigned":         nil,
		"presence-signed":  unlock(h.phone.presence, h.phone.id, h.target.ID(), now), // not the transport key
		"another approver": unlock(h.phone.transport, h.mac.id, h.target.ID(), now),
		"another target":   unlock(h.phone.transport, h.phone.id, "0123456789abcdef01234567", now),
		"stale":            unlock(h.phone.transport, h.phone.id, h.target.ID(), now-120),
	} {
		phone.sendBox(map[string]any{"op": "unlock", "unlock": env})
		d.send(map[string]any{"op": "ping"})
		if m := d.read(); m["op"] != "pong" {
			t.Fatalf("%s unlock request reached the daemon: %v", name, m)
		}
	}
	good := unlock(h.phone.transport, h.phone.id, h.target.ID(), now)
	phone.sendBox(map[string]any{"op": "unlock", "unlock": good})
	m := d.read()
	if m["op"] != "unlock" {
		t.Fatalf("daemon got %v", m)
	}
	if _, err := wire.VerifyUnlock(&h.roster, envFrom(t, m["unlock"]), h.target.ID(), time.Now()); err != nil {
		t.Fatalf("forwarded request: %v", err)
	}
}

func TestApprovedScreenAskWithoutStepsFails(t *testing.T) {
	h := newHarness(t)
	mac := h.connectApprover(h.mac)
	d, _ := h.connectDaemon(h.target)
	id, _ := d.ask(h.target, wire.KindSecurityAgent, wire.SecretMac, false)
	reqEnv := envFrom(t, d.read()["request"])
	mac.next("request")
	mac.decide(reqEnv, wire.Approve, h.mac.presence, "pw")
	d.read() // decision
	h.offset.Store(int64(stepWindow + time.Second))
	h.b.expire()
	d.send(map[string]any{"op": "step", "id": id, "seq": 1, "step": wire.Step{Keys: []wire.Stroke{{0x28, 0}}}})
	if r := d.read(); r["ok"] != false {
		t.Fatalf("step after the window: %v", r)
	}
	h.b.mu.Lock()
	secret := h.b.pending[id].secret
	h.b.mu.Unlock()
	if secret != nil {
		t.Fatal("the secret outlived its request")
	}
}

func TestDisableDropsEverything(t *testing.T) {
	h := newHarness(t)
	mac := h.connectApprover(h.mac)
	mac.next("roster")
	d, _ := h.connectDaemon(h.target)
	if err := h.b.Disable(); err != nil {
		t.Fatal(err)
	}
	if m := d.read(); m != nil {
		t.Fatalf("daemon still connected: %v", m)
	}
	if h.b.Enabled() {
		t.Fatal("still enabled")
	}
	if _, err := h.connectDaemon(h.target); err == nil {
		t.Fatal("a daemon connected to a disabled broker")
	}
}

// slowHID types one stroke per call slowly, so a test can abort mid-secret.
type slowHID struct {
	fakeHID
	delay time.Duration
}

func (h *slowHID) Type(ctx context.Context, s []wire.Stroke) error {
	select {
	case <-time.After(h.delay):
	case <-ctx.Done():
		return ctx.Err()
	}
	return h.fakeHID.Type(ctx, s)
}

func TestAbortStopsASecretMidway(t *testing.T) {
	h := newHarness(t)
	slow := &slowHID{delay: 50 * time.Millisecond}
	h.b.cfg.HID = slow
	mac := h.connectApprover(h.mac)
	d, _ := h.connectDaemon(h.target)
	id, _ := d.ask(h.target, wire.KindSecurityAgent, wire.SecretMac, false)
	reqEnv := envFrom(t, d.read()["request"])
	mac.next("request")
	mac.decide(reqEnv, wire.Approve, h.mac.presence, "aaaaaaaaaaaaaaaaaaaa")
	d.read() // decision
	d.send(map[string]any{"op": "step", "id": id, "seq": 1,
		"step": wire.Step{Secret: &wire.KeyMap{Map: map[string][]wire.Stroke{"a": {{4, 0}}}}}})
	time.Sleep(180 * time.Millisecond)
	d.send(map[string]any{"op": "abort", "id": id})
	r := d.read()
	typed, _ := r["typed"].(float64)
	if r["ok"] != false || typed < 1 || typed >= 20 {
		t.Fatalf("abort: %v", r)
	}
	slow.mu.Lock()
	n := len(slow.strokes)
	slow.mu.Unlock()
	if n != int(typed) {
		t.Fatalf("typed %d strokes, reported %v", n, typed)
	}
}

func TestKeyMapTypesCharactersOnly(t *testing.T) {
	for name, m := range map[string]map[string][]wire.Stroke{
		"command-tab": {"a": {{0x2B, 0x08}, {4, 0}}},
		"control":     {"a": {{4, 0x01}}},
		"return":      {"a": {{0x28, 0}}},
		"three":       {"a": {{4, 0}, {4, 0}, {4, 0}}},
	} {
		if _, err := (&wire.KeyMap{Map: m}).Chars("a"); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
	if _, err := (&wire.KeyMap{Map: map[string][]wire.Stroke{"^": {{0x35, 0x40}, {0x2C, 0}}, "A": {{4, 0x02}}}}).Chars("^A"); err != nil {
		t.Fatal(err)
	}
}

func TestPaddedSecretIsTypedWithoutItsPadding(t *testing.T) {
	h := newHarness(t)
	mac := h.connectApprover(h.mac)
	d, _ := h.connectDaemon(h.target)
	id, _ := d.ask(h.target, wire.KindSecurityAgent, wire.SecretMac, false)
	reqEnv := envFrom(t, d.read()["request"])
	mac.next("request")
	var req wire.Request
	_ = reqEnv.Peek(&req)
	sealed, _ := wire.SealSecret(req.Seal, reqEnv.Digest(), wire.PadSecret([]byte("ab")))
	dec, _ := wire.Sign(h.mac.presence, "decision", wire.Decision{V: 1, Request: reqEnv.DigestHex(), Ask: req.Ask.DigestHex(),
		Decision: wire.Approve, Approver: h.mac.id, Issued: time.Now().Unix(), Secret: sealed})
	mac.sendBox(map[string]any{"op": "decision", "decision": dec})
	d.read()
	d.send(map[string]any{"op": "step", "id": id, "seq": 1,
		"step": wire.Step{Secret: &wire.KeyMap{Map: map[string][]wire.Stroke{"a": {{4, 0}}, "b": {{5, 0}}}}}})
	if r := d.read(); r["ok"] != true || r["typed"] != float64(2) {
		t.Fatalf("step: %v", r)
	}
	if len(sealed) != 65+64+16 {
		t.Fatalf("box of %d bytes", len(sealed))
	}
}

func TestReconnectKeepsTheNewLinksRequests(t *testing.T) {
	h := newHarness(t)
	mac := h.connectApprover(h.mac)
	mac.next("roster")
	old, _ := h.connectDaemon(h.target)
	newer, _ := h.connectDaemon(h.target) // replaces old
	id, _ := newer.ask(h.target, wire.KindConfirm, wire.SecretNone, false)
	if m := newer.read(); m["op"] != "request" {
		t.Fatalf("ask: %v", m)
	}
	_ = old.conn.Close()
	time.Sleep(200 * time.Millisecond)
	h.b.mu.Lock()
	state := h.b.pending[id].state
	h.b.mu.Unlock()
	if state != "pending" {
		t.Fatalf("the old link's end cancelled the new link's request: %s", state)
	}
}

func TestConcurrentRostersDontRollBack(t *testing.T) {
	h := newHarness(t)
	var wg sync.WaitGroup
	for seq := uint64(2); seq <= 20; seq++ {
		next := h.roster
		next.Seq = seq
		env, _ := wire.Sign(h.mac.presence, "roster", next)
		wg.Add(1)
		go func() { defer wg.Done(); _ = h.b.acceptRoster(env) }()
	}
	wg.Wait()
	if st := h.b.State(); st.Seq != 20 {
		t.Fatalf("ended at seq %d", st.Seq)
	}
	data, _ := h.b.cfg.Store.Load(rosterFile)
	var env wire.Envelope
	_ = json.Unmarshal(data, &env)
	var saved wire.Roster
	_ = env.Peek(&saved)
	if saved.Seq != 20 {
		t.Fatalf("saved seq %d", saved.Seq)
	}
}

func TestLinkAuthTimesOut(t *testing.T) {
	h := newHarness(t)
	a, bEnd := net.Pipe()
	done := make(chan struct{})
	go func() { h.b.ServeLink(h.ctx, bEnd); close(done) }()
	r := bufio.NewReader(a)
	_ = a.SetReadDeadline(time.Now().Add(time.Second))
	_, _ = r.ReadString('\n') // hello
	select {
	case <-done:
	case <-time.After(authTimeout + 2*time.Second):
		t.Fatal("an unauthenticated link kept its slot")
	}
}

func TestScreenFollowsTheRequest(t *testing.T) {
	h := newHarness(t)
	jpeg := []byte("\xff\xd8 a picture of the screen \xff\xd9")
	h.b.cfg.Screen = func(context.Context) ([]byte, error) { return jpeg, nil }
	mac := h.connectApprover(h.mac)
	mac.next("roster")
	d, err := h.connectDaemon(h.target)
	if err != nil {
		t.Fatal(err)
	}
	id, _ := d.ask(h.target, wire.KindSudo, wire.SecretNone, false)
	d.read()
	mac.next("request")
	check := func(m map[string]any) {
		t.Helper()
		env := envFrom(t, m["screen"])
		s, err := wire.VerifyScreen(&h.roster, env, decodeBytes(m["jpeg"]))
		if err != nil || s.Request != id {
			t.Fatalf("screen %v: %v", s, err)
		}
		// The signature covers the picture: another one doesn't verify.
		if _, err := wire.VerifyScreen(&h.roster, env, append(decodeBytes(m["jpeg"]), 0)); err == nil {
			t.Fatal("a changed picture verified")
		}
	}
	check(mac.next("screen"))
	// An approver that connects later gets it with the open request.
	phone := h.connectApprover(h.phone)
	phone.next("request")
	check(phone.next("screen"))
}

func TestEncodeScreenFits(t *testing.T) {
	// Noise compresses worst: a large noisy picture still fits, smaller.
	img := image.NewYCbCr(image.Rect(0, 0, 1280, 720), image.YCbCrSubsampleRatio422)
	for i := range img.Y {
		img.Y[i] = byte(i*7919 ^ i>>3)
	}
	for i := range img.Cb {
		img.Cb[i], img.Cr[i] = byte(i*31), byte(i*17)
	}
	data, err := EncodeScreen(img)
	if err != nil || len(data) > wire.MaxScreen {
		t.Fatalf("%d bytes: %v", len(data), err)
	}
	got, err := jpeg.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if w := got.Bounds().Dx(); w >= 1280 || w < 160 {
		t.Fatalf("width %d", w)
	}
}

func TestScreenFromYUYV(t *testing.T) {
	// Limited-range black and white, then grey with colour: full range out.
	frame := []byte{16, 128, 235, 128, 126, 16, 126, 240}
	img, err := ScreenFromYUYV(4, 1, frame)
	if err != nil {
		t.Fatal(err)
	}
	if got := img.Y; !bytes.Equal(got[:4], []byte{0, 255, 128, 128}) {
		t.Fatalf("luma %v", got[:4])
	}
	if img.Cb[0] != 128 || img.Cr[0] != 128 || img.Cb[1] != 0 || img.Cr[1] != 255 {
		t.Fatalf("chroma %v %v", img.Cb[:2], img.Cr[:2])
	}
	if _, err := ScreenFromYUYV(3, 1, frame); err == nil {
		t.Fatal("odd width")
	}
	if _, err := ScreenFromYUYV(4, 2, frame); err == nil {
		t.Fatal("short frame")
	}
}
