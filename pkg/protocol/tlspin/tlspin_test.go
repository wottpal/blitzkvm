package tlspin

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"math/big"
	"testing"
	"time"
)

type keyed struct {
	cert *x509.Certificate
	key  *ecdsa.PrivateKey
}

// issue creates a certificate signed by parent (self-signed if nil).
func issue(t *testing.T, name string, isCA bool, parent *keyed) keyed {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: name},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: isCA, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageDigitalSignature,
	}
	if isCA {
		tmpl.KeyUsage |= x509.KeyUsageCertSign
	}
	signer, signerKey := tmpl, key
	if parent != nil {
		signer, signerKey = parent.cert, parent.key
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, signer, &key.PublicKey, signerKey)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return keyed{cert, key}
}

func state(chain ...keyed) tls.ConnectionState {
	var certs []*x509.Certificate
	for _, c := range chain {
		certs = append(certs, c.cert)
	}
	return tls.ConnectionState{PeerCertificates: certs}
}

func TestPinsTheDeviceCAOnFirstUse(t *testing.T) {
	ca := issue(t, "device CA", true, nil)
	p := New("")
	// Leaves differ per hostname; the CA they chain to is pinned.
	if err := p.verify(state(issue(t, "192.168.1.5", false, &ca), ca)); err != nil {
		t.Fatal(err)
	}
	if p.Pinned() != Fingerprint(ca.cert.Raw) {
		t.Fatalf("pinned %s", p.Pinned())
	}
	if err := p.verify(state(issue(t, "kvm.tailnet.ts.net", false, &ca), ca)); err != nil {
		t.Fatalf("same CA, other hostname: %v", err)
	}
	other := issue(t, "another CA", true, nil)
	if err := p.verify(state(issue(t, "192.168.1.5", false, &other), other)); !errors.Is(err, ErrChanged) {
		t.Fatalf("another CA accepted: %v", err)
	}
}

// The device CA is public (sent to every client), so an interceptor can
// present it after its own leaf. The leaf must be signed by it.
func TestRejectsALeafNotSignedByThePinnedCA(t *testing.T) {
	ca := issue(t, "device CA", true, nil)
	forged := issue(t, "interceptor", false, nil) // self-signed, not by ca
	p := New(Fingerprint(ca.cert.Raw))
	if err := p.verify(state(forged, ca)); err == nil {
		t.Fatal("a forged leaf followed by the pinned CA was accepted")
	}
	if err := New("").verify(state(forged, ca)); err == nil {
		t.Fatal("a chain that is not signed through was accepted on first use")
	}
}

// A chain that does not end in a self-signed root (e.g. a public
// certificate reached by IP, ending in an intermediate) pins the leaf, not
// the shared intermediate.
func TestPinsTheLeafWithoutASelfSignedRoot(t *testing.T) {
	root := issue(t, "public root", true, nil)
	intermediate := issue(t, "public intermediate", true, &root)
	leaf := issue(t, "kvm.example.com", false, &intermediate)
	p := New("")
	if err := p.verify(state(leaf, intermediate)); err != nil {
		t.Fatal(err)
	}
	if p.Pinned() != Fingerprint(leaf.cert.Raw) {
		t.Fatal("pinned the intermediate instead of the leaf")
	}
	otherLeaf := issue(t, "attacker.example.com", false, &intermediate)
	if err := p.verify(state(otherLeaf, intermediate)); !errors.Is(err, ErrChanged) {
		t.Fatalf("another leaf from the same intermediate was accepted: %v", err)
	}
}

func TestGivenPinIsEnforced(t *testing.T) {
	ca := issue(t, "device CA", true, nil)
	other := issue(t, "another CA", true, nil)
	p := New(Fingerprint(ca.cert.Raw))
	if err := p.verify(state(issue(t, "x", false, &other), other)); !errors.Is(err, ErrChanged) {
		t.Fatalf("wrong CA accepted: %v", err)
	}
	if p.Pinned() != Fingerprint(ca.cert.Raw) {
		t.Fatal("a mismatch must not replace the pin")
	}
	if err := p.verify(state()); err == nil {
		t.Fatal("no certificate accepted")
	}
}

// Once publicly trusted, a self-signed certificate must not be accepted as
// a new first use.
func TestWebPKIPinRefusesSelfSigned(t *testing.T) {
	ca := issue(t, "device CA", true, nil)
	p := New(WebPKI)
	if err := p.verify(state(issue(t, "x", false, &ca), ca)); !errors.Is(err, ErrChanged) {
		t.Fatalf("self-signed accepted for a publicly trusted device: %v", err)
	}
	if p.Pinned() != WebPKI {
		t.Fatal("the WebPKI pin was replaced")
	}
}
