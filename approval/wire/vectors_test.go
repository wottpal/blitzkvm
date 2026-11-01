package wire

import (
	"encoding/hex"
	"encoding/json"
	"flag"
	"math/big"
	"os"
	"testing"
	"time"

	"golang.org/x/crypto/cryptobyte"
	"golang.org/x/crypto/cryptobyte/asn1"
)

var update = flag.Bool("update", false, "rewrite testdata/vectors.json")

const vectorsPath = "../testdata/vectors.json"

// Vectors pin the protocol for the Swift and TypeScript implementations:
// they check what Go made (and Go checks them here, so the file stays true).
type Vectors struct {
	Comment string `json:"comment"`
	Now     int64  `json:"now"`
	Keys    map[string]struct {
		Scalar Bytes  `json:"scalar"`
		Public Bytes  `json:"public"`
		ID     string `json:"id"`
	} `json:"keys"`
	Envelope struct {
		Env           *Envelope `json:"env"`
		SignedMessage string    `json:"signedMessageHex"`
		Digest        string    `json:"digest"`
		DER           string    `json:"derSignatureHex"`
		Signer        string    `json:"signer"`
		Tampered      *Envelope `json:"tampered"`
	} `json:"envelope"`
	Box struct {
		Recipient string `json:"recipient"`
		Plaintext string `json:"plaintext"`
		Box       Bytes  `json:"box"`
	} `json:"box"`
	Secret struct {
		Recipient     string `json:"recipient"`
		RequestDigest string `json:"requestDigest"`
		Plaintext     string `json:"plaintext"`
		Box           Bytes  `json:"box"`
	} `json:"secret"`
	Roster    *Envelope `json:"roster"`
	Roster2   *Envelope `json:"roster2"`
	Request   *Envelope `json:"request"`
	Code      string    `json:"code"`
	Approve   *Envelope `json:"approve"`
	Deny      *Envelope `json:"deny"`
	Forged    *Envelope `json:"approveSignedByTransport"`
	RelayAuth *Envelope `json:"relayAuth"`
	Unlock    *Envelope `json:"unlock"`
	Enroll    struct {
		Token    Bytes    `json:"token"`
		Approver Approver `json:"approver"`
		Pairing  Bytes    `json:"pairing"`
		MAC      Bytes    `json:"mac"`
	} `json:"enroll"`
}

func derSignature(raw []byte) string {
	var b cryptobyte.Builder
	b.AddASN1(asn1.SEQUENCE, func(b *cryptobyte.Builder) {
		b.AddASN1BigInt(new(big.Int).SetBytes(raw[:32]))
		b.AddASN1BigInt(new(big.Int).SetBytes(raw[32:]))
	})
	return hex.EncodeToString(b.BytesOrPanic())
}

func makeVectors(t *testing.T) *Vectors {
	v := &Vectors{Comment: "approval protocol v1 test vectors (PROTOCOL.md); regenerate with go test ./wire -run TestVectors -update",
		Now: time.Now().Unix()}
	v.Keys = map[string]struct {
		Scalar Bytes  `json:"scalar"`
		Public Bytes  `json:"public"`
		ID     string `json:"id"`
	}{}
	f := newFixture(t)
	addSigning := func(name string, k *SigningKey) {
		v.Keys[name] = struct {
			Scalar Bytes  `json:"scalar"`
			Public Bytes  `json:"public"`
			ID     string `json:"id"`
		}{k.Scalar(), k.Public(), k.ID()}
	}
	addSeal := func(name string, k *SealKey) {
		v.Keys[name] = struct {
			Scalar Bytes  `json:"scalar"`
			Public Bytes  `json:"public"`
			ID     string `json:"id"`
		}{k.Scalar(), k.Public(), k.ID()}
	}
	addSigning("broker", f.broker)
	addSeal("brokerSeal", f.brokerSeal)
	addSigning("target", f.target)
	addSigning("macPresence", f.macPresence)
	addSigning("macTransport", f.macTrans)
	addSeal("macSeal", f.macSeal)
	addSigning("phonePresence", f.phonePresence)
	addSigning("phoneTransport", f.phoneTran)
	addSeal("phoneSeal", f.phoneSeal)

	env, _ := Sign(f.target, "ask", map[string]any{"v": 1, "hello": "wörld"})
	v.Envelope.Env = env
	v.Envelope.SignedMessage = hex.EncodeToString(signedMessage(env.Type, env.Payload))
	v.Envelope.Digest = env.DigestHex()
	v.Envelope.DER = derSignature(env.Sig)
	v.Envelope.Signer = "target"
	tampered := *env
	tampered.Payload = append(Bytes(nil), env.Payload...)
	tampered.Payload[len(tampered.Payload)-2] ^= 0x01
	v.Envelope.Tampered = &tampered

	v.Box.Recipient = "phoneSeal"
	v.Box.Plaintext = `{"op":"sync"}`
	v.Box.Box, _ = SealBox(f.phoneSeal.Public(), []byte(v.Box.Plaintext))

	reqSeal := mustSeal(t)
	addSeal("requestSeal", reqSeal)
	v.Roster = f.rosterEnv
	r2 := *f.roster
	r2.Seq = 2
	r2.Owners = []string{f.macPresence.ID(), f.phonePresence.ID()}
	v.Roster2, _ = Sign(f.macPresence, "roster", r2)

	askEnv, _ := Sign(f.target, "ask", Ask{V: 1, ID: "00112233445566778899aabbccddeeff", Target: f.target.ID(),
		Kind: KindOnePassword, Title: "1Password: op wants CLI access", Detail: "op ← bash ← claude",
		Requester: &Requester{UID: 501, User: "user", Chain: []Process{{PID: 42, Name: "op", Path: "/opt/homebrew/bin/op", Signer: "developer:2BUA8C4S2C"}}},
		Evidence:  &Evidence{Window: &Rect{X: 552, Y: 219, W: 400, H: 346}, Display: &Size{W: 1504, H: 948}},
		Secret:    SecretOnePassword, Nonce: Nonce(32), Issued: v.Now, Expires: v.Now + 120})
	v.Request, _ = Sign(f.broker, "request", Request{V: 1, Ask: askEnv, Seal: reqSeal.Public(), Issued: v.Now, Expires: v.Now + 120})
	v.Code = Code(askEnv.Digest())

	reqDigest := v.Request.Digest()
	v.Secret.Recipient = "requestSeal"
	v.Secret.RequestDigest = v.Request.DigestHex()
	v.Secret.Plaintext = "correct horse ^battery`~"
	v.Secret.Box, _ = SealSecret(reqSeal.Public(), reqDigest, PadSecret([]byte(v.Secret.Plaintext)))

	approve := Decision{V: 1, Request: v.Request.DigestHex(), Ask: askEnv.DigestHex(), Decision: Approve,
		Approver: f.phonePresence.ID(), Issued: v.Now, Secret: v.Secret.Box}
	v.Approve, _ = Sign(f.phonePresence, "decision", approve)
	v.Forged, _ = Sign(f.phoneTran, "decision", approve)
	v.Deny, _ = Sign(f.phoneTran, "decision", Decision{V: 1, Request: v.Request.DigestHex(), Ask: askEnv.DigestHex(),
		Decision: Deny, Approver: f.phonePresence.ID(), Issued: v.Now})
	v.RelayAuth, _ = Sign(f.phoneTran, "relay", RelayAuth{V: 1, Role: "approver", Broker: f.broker.ID(),
		Approver: f.phonePresence.ID(), Endpoint: "outbox", Nonce: Nonce(32), Issued: v.Now})
	v.Unlock, _ = Sign(f.phoneTran, "unlock", UnlockRequest{V: 1, Broker: f.broker.ID(), Target: f.target.ID(),
		Approver: f.phonePresence.ID(), Nonce: Nonce(32), Issued: v.Now})
	v.Enroll.Token = Nonce(32)
	v.Enroll.Approver = Approver{ID: f.phonePresence.ID(), Name: "Dennis' iPhone", Platform: "ios", Presence: f.phonePresence.Public(),
		Transport: f.phoneTran.Public(), Seal: f.phoneSeal.Public()}
	v.Enroll.Pairing = PairingHash(v.Enroll.Token)
	v.Enroll.MAC = EnrollMAC(v.Enroll.Token, v.Enroll.Approver)
	return v
}

func TestVectors(t *testing.T) {
	if *update {
		data, _ := json.MarshalIndent(makeVectors(t), "", "  ")
		if err := os.WriteFile(vectorsPath, append(data, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	data, err := os.ReadFile(vectorsPath)
	if err != nil {
		t.Fatal(err)
	}
	var v Vectors
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	pub := func(name string) []byte { return v.Keys[name].Public }
	for name, k := range v.Keys {
		if KID(k.Public) != k.ID {
			t.Errorf("%s: kid", name)
		}
	}
	if err := v.Envelope.Env.Verify("ask", pub(v.Envelope.Signer), nil); err != nil {
		t.Errorf("envelope: %v", err)
	}
	if v.Envelope.Env.DigestHex() != v.Envelope.Digest || derSignature(v.Envelope.Env.Sig) != v.Envelope.DER {
		t.Error("envelope digest or DER")
	}
	if v.Envelope.Tampered.Verify("ask", pub(v.Envelope.Signer), nil) == nil {
		t.Error("tampered envelope verifies")
	}
	seal, _ := SealKeyFromScalar(v.Keys[v.Box.Recipient].Scalar)
	if msg, err := seal.OpenBox(v.Box.Box); err != nil || string(msg) != v.Box.Plaintext {
		t.Errorf("box: %v", err)
	}
	roster, err := AcceptRoster(nil, v.Roster)
	if err != nil {
		t.Fatalf("roster: %v", err)
	}
	if _, err := AcceptRoster(roster, v.Roster2); err != nil {
		t.Errorf("roster2: %v", err)
	}
	req, err := VerifyRequest(roster, v.Request, time.Unix(v.Now, 0))
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	if Code(req.AskDigest) != v.Code {
		t.Error("code")
	}
	reqSeal, _ := SealKeyFromScalar(v.Keys[v.Secret.Recipient].Scalar)
	if pw, err := reqSeal.OpenSecret(v.Secret.Box, req.RequestDigest); err != nil || string(UnpadSecret(pw)) != v.Secret.Plaintext || len(pw)%SecretBlock != 0 {
		t.Errorf("secret: %v", err)
	}
	at := time.Unix(v.Now, 0)
	if _, err := VerifyDecision(roster, req, v.Approve, at); err != nil {
		t.Errorf("approve: %v", err)
	}
	if _, err := VerifyDecision(roster, req, v.Deny, at); err != nil {
		t.Errorf("deny: %v", err)
	}
	if _, err := VerifyDecision(roster, req, v.Forged, at); err == nil {
		t.Error("approval signed by the transport key verifies")
	}
	if err := v.RelayAuth.Verify("relay", pub("phoneTransport"), nil); err != nil {
		t.Errorf("relay auth: %v", err)
	}
	if _, err := VerifyUnlock(roster, v.Unlock, v.Keys["target"].ID, at); err != nil {
		t.Errorf("unlock: %v", err)
	}
	e := Enroll{V: 1, Pairing: v.Enroll.Pairing, Approver: v.Enroll.Approver, MAC: v.Enroll.MAC}
	if !CheckEnrollMAC(v.Enroll.Token, &e) {
		t.Error("enroll MAC")
	}
}
