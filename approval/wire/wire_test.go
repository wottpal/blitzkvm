package wire

import (
	"bytes"
	"encoding/json"
	"errors"
	"testing"
	"time"
)

func mustSigning(t *testing.T) *SigningKey {
	t.Helper()
	k, err := NewSigningKey()
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func mustSeal(t *testing.T) *SealKey {
	t.Helper()
	k, err := NewSealKey()
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func TestEnvelopeSignVerify(t *testing.T) {
	k := mustSigning(t)
	env, err := Sign(k, "ask", map[string]int{"v": 1})
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]int
	if err := env.Verify("ask", k.Public(), &out); err != nil || out["v"] != 1 {
		t.Fatalf("verify: %v %v", err, out)
	}
	if err := env.Verify("decision", k.Public(), nil); !errors.Is(err, ErrType) {
		t.Fatalf("type confusion accepted: %v", err)
	}
	other := mustSigning(t)
	if err := env.Verify("ask", other.Public(), nil); !errors.Is(err, ErrSigner) {
		t.Fatalf("other key accepted: %v", err)
	}
	tampered := *env
	tampered.Payload = append(Bytes(nil), env.Payload...)
	tampered.Payload[0] ^= 1
	if err := tampered.Verify("ask", k.Public(), nil); !errors.Is(err, ErrSignature) {
		t.Fatalf("tampered payload accepted: %v", err)
	}
	// A signature over one type doesn't verify as another type with the
	// same payload (the type is part of the signed message).
	retyped := *env
	retyped.Type = "roster"
	if err := retyped.Verify("roster", k.Public(), nil); !errors.Is(err, ErrSignature) {
		t.Fatalf("retyped envelope accepted: %v", err)
	}
	data, _ := json.Marshal(env)
	var back Envelope
	if err := json.Unmarshal(data, &back); err != nil || back.Verify("ask", k.Public(), nil) != nil {
		t.Fatalf("round trip: %v", err)
	}
}

func TestB64RejectsPadding(t *testing.T) {
	var b Bytes
	if err := json.Unmarshal([]byte(`"AAE="`), &b); err == nil {
		t.Fatal("padded b64 accepted")
	}
	if err := json.Unmarshal([]byte(`"+/8"`), &b); err == nil {
		t.Fatal("standard alphabet accepted")
	}
}

func TestBoxes(t *testing.T) {
	k := mustSeal(t)
	box, err := SealBox(k.Public(), []byte("hello"))
	if err != nil {
		t.Fatal(err)
	}
	if msg, err := k.OpenBox(box); err != nil || string(msg) != "hello" {
		t.Fatalf("open: %v %q", err, msg)
	}
	if _, err := mustSeal(t).OpenBox(box); !errors.Is(err, ErrOpen) {
		t.Fatalf("another key opened the box: %v", err)
	}
	box[len(box)-1] ^= 1
	if _, err := k.OpenBox(box); !errors.Is(err, ErrOpen) {
		t.Fatalf("tampered box opened: %v", err)
	}
	digest := [32]byte{1, 2, 3}
	secret, err := SealSecret(k.Public(), digest, []byte("pw"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := k.OpenSecret(secret, [32]byte{9}); !errors.Is(err, ErrOpen) {
		t.Fatalf("secret opened for another request: %v", err)
	}
	if _, err := k.OpenBox(secret); !errors.Is(err, ErrOpen) {
		t.Fatalf("secret opened as a message box: %v", err)
	}
	if pw, err := k.OpenSecret(secret, digest); err != nil || string(pw) != "pw" {
		t.Fatalf("open secret: %v", err)
	}
}

// fixture is a broker, a target and two approvers (an owner Mac, an iPhone).
type fixture struct {
	broker, target           *SigningKey
	brokerSeal               *SealKey
	macPresence, macTrans    *SigningKey
	phonePresence, phoneTran *SigningKey
	macSeal, phoneSeal       *SealKey
	roster                   *Roster
	rosterEnv                *Envelope
}

func newFixture(t *testing.T) *fixture {
	f := &fixture{broker: mustSigning(t), target: mustSigning(t), brokerSeal: mustSeal(t),
		macPresence: mustSigning(t), macTrans: mustSigning(t), phonePresence: mustSigning(t), phoneTran: mustSigning(t),
		macSeal: mustSeal(t), phoneSeal: mustSeal(t)}
	f.roster = &Roster{V: 1, Seq: 1, Issued: time.Now().Unix(),
		Broker: Broker{ID: f.broker.ID(), Key: f.broker.Public(), Seal: f.brokerSeal.Public()},
		Owners: []string{f.macPresence.ID()},
		Approvers: []Approver{
			{ID: f.macPresence.ID(), Name: "Mac", Platform: "macos", Presence: f.macPresence.Public(),
				Transport: f.macTrans.Public(), Seal: f.macSeal.Public()},
			{ID: f.phonePresence.ID(), Name: "iPhone", Platform: "ios", Presence: f.phonePresence.Public(),
				Transport: f.phoneTran.Public(), Seal: f.phoneSeal.Public()},
		},
		Targets: []Target{{ID: f.target.ID(), Name: "Mac mini", Key: f.target.Public()}},
	}
	var err error
	if f.rosterEnv, err = Sign(f.macPresence, "roster", f.roster); err != nil {
		t.Fatal(err)
	}
	return f
}

func TestRosterRules(t *testing.T) {
	f := newFixture(t)
	genesis, err := AcceptRoster(nil, f.rosterEnv)
	if err != nil {
		t.Fatalf("genesis: %v", err)
	}
	// Not newer.
	if _, err := AcceptRoster(genesis, f.rosterEnv); !errors.Is(err, ErrRosterStale) {
		t.Fatalf("replayed roster accepted: %v", err)
	}
	// Signed by a non-owner approver.
	next := *f.roster
	next.Seq = 2
	byPhone, _ := Sign(f.phonePresence, "roster", next)
	if _, err := AcceptRoster(genesis, byPhone); !errors.Is(err, ErrRosterSigner) {
		t.Fatalf("roster from a non-owner accepted: %v", err)
	}
	// An owner removes the phone (revocation), then the phone's old roster
	// can't come back.
	revoked := *f.roster
	revoked.Seq = 2
	revoked.Approvers = revoked.Approvers[:1]
	env2, _ := Sign(f.macPresence, "roster", revoked)
	r2, err := AcceptRoster(genesis, env2)
	if err != nil || r2.Approver(f.phonePresence.ID()) != nil {
		t.Fatalf("revocation: %v", err)
	}
	if _, err := AcceptRoster(r2, f.rosterEnv); !errors.Is(err, ErrRosterStale) {
		t.Fatalf("rollback accepted: %v", err)
	}
	// A genesis signed by someone who makes themselves owner of another
	// broker's roster is still self-consistent, but can't replace the
	// current one.
	evil := mustSigning(t)
	forged := *f.roster
	forged.Seq = 9
	forged.Approvers = append([]Approver{{ID: evil.ID(), Name: "x", Platform: "macos", Presence: evil.Public(),
		Transport: evil.Public(), Seal: f.macSeal.Public()}}, forged.Approvers...)
	forged.Owners = []string{evil.ID()}
	forgedEnv, _ := Sign(evil, "roster", forged)
	if _, err := AcceptRoster(r2, forgedEnv); !errors.Is(err, ErrRosterSigner) {
		t.Fatalf("forged roster accepted: %v", err)
	}
	// Another broker's roster.
	moved := revoked
	moved.Seq = 3
	other := mustSigning(t)
	moved.Broker = Broker{ID: other.ID(), Key: other.Public(), Seal: f.brokerSeal.Public()}
	movedEnv, _ := Sign(f.macPresence, "roster", moved)
	if _, err := AcceptRoster(r2, movedEnv); !errors.Is(err, ErrRosterBroker) {
		t.Fatalf("roster for another broker accepted: %v", err)
	}
}

func (f *fixture) ask(t *testing.T, kind, secret string, grantable bool) *Envelope {
	now := time.Now().Unix()
	env, err := Sign(f.target, "ask", Ask{V: 1, ID: RandomID(), Target: f.target.ID(), Kind: kind, Title: "sudo true",
		Secret: secret, Grantable: grantable, Nonce: Nonce(32), Issued: now, Expires: now + 60})
	if err != nil {
		t.Fatal(err)
	}
	return env
}

func (f *fixture) request(t *testing.T, ask *Envelope, seal *SealKey) *Envelope {
	now := time.Now().Unix()
	env, err := Sign(f.broker, "request", Request{V: 1, Ask: ask, Seal: seal.Public(), Issued: now, Expires: now + 60})
	if err != nil {
		t.Fatal(err)
	}
	return env
}

func TestDecisionChecks(t *testing.T) {
	f := newFixture(t)
	reqSeal := mustSeal(t)
	reqEnv := f.request(t, f.ask(t, KindSudo, SecretNone, true), reqSeal)
	now := time.Now()
	req, err := VerifyRequest(f.roster, reqEnv, now)
	if err != nil {
		t.Fatal(err)
	}
	decide := func(key *SigningKey, d Decision) *Envelope {
		if d.Request == "" {
			d.Request = reqEnv.DigestHex()
		}
		if d.Ask == "" {
			d.Ask = req.Request.Ask.DigestHex()
		}
		if d.Issued == 0 {
			d.Issued = now.Unix()
		}
		d.V = 1
		env, err := Sign(key, "decision", d)
		if err != nil {
			t.Fatal(err)
		}
		return env
	}
	phone := f.phonePresence.ID()
	ok := decide(f.phonePresence, Decision{Decision: Approve, Grant: 10, Approver: phone})
	if _, err := VerifyDecision(f.roster, req, ok, now); err != nil {
		t.Fatalf("approval: %v", err)
	}
	cases := map[string]*Envelope{
		"approval by the transport key": decide(f.phoneTran, Decision{Decision: Approve, Approver: phone}),
		"approval by another key":       decide(f.macPresence, Decision{Decision: Approve, Approver: phone}),
		"unknown approver":              decide(mustSigning(t), Decision{Decision: Approve, Approver: "abc"}),
		"other request":                 decide(f.phonePresence, Decision{Decision: Approve, Approver: phone, Request: "00"}),
		"stale":                         decide(f.phonePresence, Decision{Decision: Approve, Approver: phone, Issued: now.Unix() - 61}),
		"odd grant":                     decide(f.phonePresence, Decision{Decision: Approve, Approver: phone, Grant: 60}),
		"secret for sudo":               decide(f.phonePresence, Decision{Decision: Approve, Approver: phone, Secret: []byte{1}}),
	}
	for name, env := range cases {
		if _, err := VerifyDecision(f.roster, req, env, now); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
	deny := decide(f.phoneTran, Decision{Decision: Deny, Approver: phone})
	if _, err := VerifyDecision(f.roster, req, deny, now); err != nil {
		t.Fatalf("denial by the transport key: %v", err)
	}
	if _, err := VerifyDecision(f.roster, req, ok, time.Unix(req.Ask.Expires, 0)); !errors.Is(err, ErrExpired) {
		t.Fatalf("decision after expiry: %v", err)
	}
	// Request A's decision doesn't apply to request B.
	reqB, err := VerifyRequest(f.roster, f.request(t, f.ask(t, KindSudo, SecretNone, true), reqSeal), now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := VerifyDecision(f.roster, reqB, ok, now); !errors.Is(err, ErrMismatch) {
		t.Fatalf("decision for A applied to B: %v", err)
	}
}

func TestRequestFromUnknownTargetOrBroker(t *testing.T) {
	f := newFixture(t)
	stranger := mustSigning(t)
	now := time.Now().Unix()
	ask, _ := Sign(stranger, "ask", Ask{V: 1, ID: RandomID(), Target: stranger.ID(), Kind: KindSudo, Title: "x",
		Secret: SecretNone, Nonce: Nonce(32), Issued: now, Expires: now + 60})
	if _, err := VerifyRequest(f.roster, f.request(t, ask, mustSeal(t)), time.Now()); err == nil {
		t.Fatal("ask from an unknown target accepted")
	}
	good := f.ask(t, KindSudo, SecretNone, false)
	forged, _ := Sign(stranger, "request", Request{V: 1, Ask: good, Seal: mustSeal(t).Public(), Issued: now, Expires: now + 60})
	if _, err := VerifyRequest(f.roster, forged, time.Now()); err == nil {
		t.Fatal("request from another broker accepted")
	}
}

func TestKeyMapAndKeys(t *testing.T) {
	m := &KeyMap{Map: map[string][]Stroke{"a": {{4, 0}}, "^": {{0x35, 0}, {0x2C, 0}}}}
	s, err := m.Chars("a^a")
	if err != nil || len(s) != 3 || len(s[1]) != 2 {
		t.Fatalf("strokes: %v %v", s, err)
	}
	if _, err := m.Chars("ab"); err == nil {
		t.Fatal("unmapped character accepted")
	}
	if err := CheckKeys([]Stroke{{0x28, 0}, {0, 2}}); err != nil {
		t.Fatal(err)
	}
	if err := CheckKeys([]Stroke{{4, 0}}); err == nil {
		t.Fatal("a letter passed as a safe key")
	}
	if err := CheckKeys([]Stroke{{0x28, 8}}); err == nil {
		t.Fatal("⌘Return passed as a safe key")
	}
}

func TestCode(t *testing.T) {
	if c := Code([32]byte{0x01, 0x02}); c != "58" { // 258 % 100
		t.Fatalf("code %q", c)
	}
	if c := Code([32]byte{0, 7}); c != "07" {
		t.Fatalf("code %q", c)
	}
}

func TestSigningKeyScalarRoundTrip(t *testing.T) {
	k := mustSigning(t)
	back, err := SigningKeyFromScalar(k.Scalar())
	if err != nil || !bytes.Equal(back.Public(), k.Public()) {
		t.Fatalf("round trip: %v", err)
	}
}
