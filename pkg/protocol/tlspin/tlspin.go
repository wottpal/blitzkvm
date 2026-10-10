// Package tlspin trusts a JetKVM's HTTPS certificate on first use.
//
// In self-signed mode the device issues a certificate per hostname, signed
// by a device CA that it sends along in the chain (jetkvm/kvm
// internal/websecure). That CA is pinned: it holds across the device's
// addresses (LAN IP, .local, VPN name) and leaf renewals. The chain must
// actually be signed up to the pinned CA, since the CA certificate itself is
// public (the device sends it to every client).
//
// A chain that verifies against the system roots for the dialed hostname (a
// custom, publicly trusted certificate) is accepted, and the device is then
// pinned to public trust (WebPKI), so a later self-signed certificate is
// refused instead of being trusted as a new first use.
package tlspin

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
)

// ErrChanged means the device presented a different certificate than the
// pinned one.
var ErrChanged = errors.New("the device's TLS certificate changed")

// WebPKI is the pin of a device whose certificate is publicly trusted.
const WebPKI = "webpki"

// Pin holds the expected anchor fingerprint (or WebPKI); empty means trust
// on first use.
type Pin struct {
	mu       sync.Mutex
	expected string
}

func New(expected string) *Pin {
	return &Pin{expected: strings.ToLower(strings.TrimSpace(expected))}
}

// Fingerprint is the hex SHA-256 of a DER certificate.
func Fingerprint(der []byte) string {
	sum := sha256.Sum256(der)
	return hex.EncodeToString(sum[:])
}

// Pinned returns the pin (learned on first use if it was not given), or ""
// if nothing has been seen.
func (p *Pin) Pinned() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.expected
}

// TLSConfig verifies servers with the pin. It disables Go's chain check
// because the device CA is self-signed; VerifyConnection replaces it.
func (p *Pin) TLSConfig() *tls.Config {
	return &tls.Config{
		InsecureSkipVerify: true, //nolint:gosec // verified by VerifyConnection
		MinVersion:         tls.VersionTLS12,
		VerifyConnection:   p.verify,
	}
}

func (p *Pin) verify(cs tls.ConnectionState) error {
	certs := cs.PeerCertificates
	if len(certs) == 0 {
		return errors.New("tls: no certificate")
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.expected == "" || p.expected == WebPKI {
		if publiclyTrusted(cs) {
			p.expected = WebPKI
			return nil
		}
		if p.expected == WebPKI {
			return fmt.Errorf("%w: it is no longer publicly trusted", ErrChanged)
		}
	}
	anchor, err := anchorOf(certs)
	if err != nil {
		return err
	}
	fp := Fingerprint(anchor.Raw)
	if p.expected == "" {
		p.expected = fp
	}
	if fp != p.expected {
		return fmt.Errorf("%w (pinned %s, presented %s)", ErrChanged, short(p.expected), short(fp))
	}
	return nil
}

// anchorOf checks that each certificate is signed by the next and returns
// what to pin: the self-signed root at the end of the chain (the device CA),
// or the leaf when the chain does not end in one. The TLS handshake has
// already proven possession of the leaf's key.
func anchorOf(certs []*x509.Certificate) (*x509.Certificate, error) {
	for i := 0; i+1 < len(certs); i++ {
		if err := certs[i].CheckSignatureFrom(certs[i+1]); err != nil {
			// As good as a different certificate: stop, don't retry.
			return nil, fmt.Errorf("%w: the certificate chain is not signed through (%v)", ErrChanged, err)
		}
	}
	last := certs[len(certs)-1]
	if len(certs) > 1 && last.CheckSignatureFrom(last) == nil {
		return last, nil
	}
	return certs[0], nil
}

// publiclyTrusted reports whether the chain verifies against the system
// roots for the dialed hostname. IP addresses carry no server name in TLS,
// so they never count as publicly trusted here.
func publiclyTrusted(cs tls.ConnectionState) bool {
	if cs.ServerName == "" {
		return false
	}
	intermediates := x509.NewCertPool()
	for _, cert := range cs.PeerCertificates[1:] {
		intermediates.AddCert(cert)
	}
	_, err := cs.PeerCertificates[0].Verify(x509.VerifyOptions{DNSName: cs.ServerName, Intermediates: intermediates})
	return err == nil
}

func short(fp string) string {
	if len(fp) > 16 {
		return fp[:16] + "…"
	}
	return fp
}
