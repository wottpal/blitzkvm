package broker

// Regression tests for the 2026-11-02 review of the broker: each failed
// before its fix.

import (
	"context"
	"encoding/json"
	"math/big"
	"sync"
	"testing"
	"time"

	"github.com/wottpal/blitzkvm/approval/wire"
)

// deadlineConn records the deadline of each Read.
type deadlineConn struct {
	*chanConn
	mu        sync.Mutex
	deadlines []time.Duration
}

func (d *deadlineConn) Read(ctx context.Context) ([]byte, error) {
	if dl, ok := ctx.Deadline(); ok {
		d.mu.Lock()
		d.deadlines = append(d.deadlines, time.Until(dl))
		d.mu.Unlock()
	}
	return d.chanConn.Read(ctx)
}

func approveWithSecret(t *testing.T, h *harness, mac *approverClient, d *daemon, secret string) string {
	id, _ := d.ask(h.target, wire.KindSecurityAgent, wire.SecretMac, false)
	reqEnv := envFrom(t, d.read()["request"])
	mac.next("request")
	mac.decide(reqEnv, wire.Approve, h.mac.presence, secret)
	if m := d.read(); m["op"] != "decision" {
		t.Fatalf("daemon got %v", m)
	}
	return id
}

func TestReviewApproverPreAuthWaitsIdleTimeout(t *testing.T) {
	h := newHarness(t)
	mine, theirs := connPair()
	dc := &deadlineConn{chanConn: theirs}
	go h.b.ServeApprover(h.ctx, dc)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, _ = mine.Read(ctx) // hello
	time.Sleep(50 * time.Millisecond)
	dc.mu.Lock()
	defer dc.mu.Unlock()
	if len(dc.deadlines) == 0 {
		t.Fatal("no read")
	}
	t.Logf("pre-auth read deadline: %v (authTimeout %v)", dc.deadlines[0].Round(time.Second), authTimeout)
	if dc.deadlines[0] > authTimeout+time.Second {
		t.Errorf("pre-auth approver read waits %v", dc.deadlines[0].Round(time.Second))
	}
}

func TestReviewAbortLostWhileQueued(t *testing.T) {
	h := newHarness(t)
	slow := &slowHID{delay: 40 * time.Millisecond}
	h.b.cfg.HID = slow
	mac := h.connectApprover(h.mac)
	d, _ := h.connectDaemon(h.target)
	a := approveWithSecret(t, h, mac, d, "aaaaaaaaaa")
	b := approveWithSecret(t, h, mac, d, "bbbbbbbbbb")
	km := &wire.KeyMap{Map: map[string][]wire.Stroke{"a": {{4, 0}}, "b": {{5, 0}}}}
	d.send(map[string]any{"op": "step", "id": a, "seq": 1, "step": wire.Step{Secret: km}})
	time.Sleep(60 * time.Millisecond)
	d.send(map[string]any{"op": "step", "id": b, "seq": 1, "step": wire.Step{Secret: km}})
	time.Sleep(60 * time.Millisecond)
	d.send(map[string]any{"op": "abort", "id": b}) // b is queued behind a
	got := map[string]map[string]any{}
	for len(got) < 2 {
		m := d.read()
		if m == nil {
			t.Fatal("no reply")
		}
		if m["op"] == "stepped" {
			got[m["id"].(string)] = m
		}
	}
	t.Logf("b after abort: %v", got[b])
	if got[b]["ok"] == true {
		t.Errorf("aborted step typed its whole secret (%v chars)", got[b]["typed"])
	}
}

func TestReviewCancelDoesNotStopTyping(t *testing.T) {
	h := newHarness(t)
	slow := &slowHID{delay: 30 * time.Millisecond}
	h.b.cfg.HID = slow
	mac := h.connectApprover(h.mac)
	d, _ := h.connectDaemon(h.target)
	id := approveWithSecret(t, h, mac, d, "aaaaaaaaaaaaaaa")
	d.send(map[string]any{"op": "step", "id": id, "seq": 1,
		"step": wire.Step{Secret: &wire.KeyMap{Map: map[string][]wire.Stroke{"a": {{4, 0}}}}}})
	time.Sleep(80 * time.Millisecond)
	d.send(map[string]any{"op": "cancel", "id": id})
	for {
		m := d.read()
		if m == nil {
			t.Fatal("no reply")
		}
		if m["op"] == "stepped" {
			t.Logf("stepped after cancel: %v", m)
			if m["ok"] == true {
				t.Errorf("typing went on after the request was cancelled (%v chars)", m["typed"])
			}
			return
		}
	}
}

func TestReviewUnlockReplayForwardedEachTime(t *testing.T) {
	h := newHarness(t)
	phone := h.connectApprover(h.phone)
	phone.next("roster")
	d, _ := h.connectDaemon(h.target)
	env, _ := wire.Sign(h.phone.transport, "unlock", wire.UnlockRequest{V: 1, Broker: h.b.ID(), Target: h.target.ID(),
		Approver: h.phone.id, Nonce: wire.Nonce(32), Issued: time.Now().Unix()})
	box, _ := wire.SealBox(h.b.Identity().Seal, mustJSON(map[string]any{"op": "unlock", "unlock": env}))
	for i := 0; i < 5; i++ {
		// A relay (or anyone who saw the box) replays the very same box.
		h.b.fromApprover(h.phone.id, box)
	}
	n := 0
	for i := 0; i < 5; i++ {
		if m := d.read(); m != nil && m["op"] == "unlock" {
			n++
		}
	}
	t.Logf("daemon got %d copies of one unlock request", n)
	if n > 1 {
		t.Errorf("no replay filter at the broker (%d forwarded)", n)
	}
}

func TestReviewRemovedTargetKeepsLink(t *testing.T) {
	h := newHarness(t)
	mac := h.connectApprover(h.mac)
	mac.next("roster")
	d, _ := h.connectDaemon(h.target)
	next := h.roster
	next.Seq, next.Targets = 2, nil
	env, _ := wire.Sign(h.mac.presence, "roster", next)
	if err := h.b.acceptRoster(env); err != nil {
		t.Fatal(err)
	}
	// The removed target's link is closed rather than sent the roster.
	if m := d.read(); len(m) != 0 {
		t.Fatalf("the removed target's link got %v", m)
	}
	unlock, _ := wire.Sign(h.mac.transport, "unlock", wire.UnlockRequest{V: 1, Broker: h.b.ID(), Target: h.target.ID(),
		Approver: h.mac.id, Nonce: wire.Nonce(32), Issued: time.Now().Unix()})
	mac.sendBox(map[string]any{"op": "unlock", "unlock": unlock})
	if m := d.read(); m != nil && m["op"] == "unlock" {
		t.Errorf("removed target still connected and still gets unlock requests")
	}
}

func TestReviewRosterUpdateChangesSealKey(t *testing.T) {
	h := newHarness(t)
	other, _ := wire.NewSealKey()
	next := h.roster
	next.Seq = 2
	next.Broker.Seal = other.Public()
	env, _ := wire.Sign(h.mac.presence, "roster", next)
	if err := h.b.acceptRoster(env); err == nil {
		t.Errorf("roster with a foreign broker seal key accepted")
	}
}

func TestReviewAskLifetimeOverflow(t *testing.T) {
	// D * 1e9 ≡ 512 (mod 2^64): D = inv(1953125) mod 2^55.
	mod := new(big.Int).Lsh(big.NewInt(1), 55)
	inv := new(big.Int).ModInverse(big.NewInt(1953125), mod)
	D := inv.Int64()
	now := time.Now().Unix()
	a := wire.Ask{V: 1, ID: wire.RandomID(), Target: "t", Kind: wire.KindConfirm, Title: "x", Secret: wire.SecretNone,
		Nonce: wire.Nonce(32), Issued: now, Expires: now + D}
	if err := a.Check(time.Now()); err == nil {
		t.Errorf("ask with lifetime %d s (%.0f years) passes Check", D, float64(D)/3.15e7)
	}
}

func TestReviewDenyWithoutLinkSendsNoStatus(t *testing.T) {
	h := newHarness(t)
	mac := h.connectApprover(h.mac)
	mac.next("roster")
	d, _ := h.connectDaemon(h.target)
	_, _ = d.ask(h.target, wire.KindConfirm, wire.SecretNone, false)
	reqEnv := envFrom(t, d.read()["request"])
	mac.next("request")
	h.b.mu.Lock()
	h.b.link = nil // the window between a link ending and linkGone
	h.b.mu.Unlock()
	mac.decide(reqEnv, wire.Deny, h.mac.transport, "")
	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	for {
		data, err := mac.conn.Read(ctx)
		if err != nil {
			t.Errorf("no status after a denial without a link")
			return
		}
		var f struct {
			Op  string     `json:"op"`
			Box wire.Bytes `json:"box"`
		}
		_ = json.Unmarshal(data, &f)
		if f.Op == "box" {
			msg, _ := h.mac.seal.OpenBox(f.Box)
			var m map[string]any
			_ = json.Unmarshal(msg, &m)
			if m["op"] == "status" {
				t.Logf("status: %v", m)
				return
			}
		}
	}
}

func TestReviewStoredRosterForAnotherBroker(t *testing.T) {
	h := newHarness(t) // broker A with its roster stored
	store := h.b.cfg.Store.(*memStore)
	data, _ := store.Load(rosterFile)
	fresh := &memStore{files: map[string][]byte{rosterFile: data}} // no key file: new keys
	b2, err := New(Config{Store: fresh, HID: &fakeHID{}, Logf: t.Logf})
	if err != nil {
		t.Fatalf("New refused: %v", err)
	}
	var env wire.Envelope
	_ = json.Unmarshal(data, &env)
	var r wire.Roster
	_ = env.Peek(&r)
	if b2.Enabled() && r.Broker.ID != b2.ID() {
		t.Errorf("enabled with a roster for broker %s while being %s", r.Broker.ID, b2.ID())
	}
	_ = time.Now
}

// The session's input stays blocked from the approval of a screen request
// until it ends, not just while a key is pressed.
func TestHoldsInputForAnApprovedScreenRequest(t *testing.T) {
	h := newHarness(t)
	mac := h.connectApprover(h.mac)
	d, _ := h.connectDaemon(h.target)
	id := approveWithSecret(t, h, mac, d, "pw")
	holds := func() []bool {
		h.hid.mu.Lock()
		defer h.hid.mu.Unlock()
		return append([]bool(nil), h.hid.holds...)
	}
	if got := holds(); len(got) != 1 || !got[0] {
		t.Fatalf("holds after the approval: %v", got)
	}
	d.send(map[string]any{"op": "done", "id": id, "ok": true})
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if got := holds(); len(got) == 2 && !got[1] {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("holds after done: %v", holds())
}
