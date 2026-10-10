package emulator

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"time"
)

// newDeviceCertificate mimics the firmware's self-signed TLS mode
// (internal/websecure): a device CA, and a leaf for the device signed by it,
// sent together as the chain.
func newDeviceCertificate() (*tls.Certificate, error) {
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	caTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(now.UnixNano()),
		Subject:               pkix.Name{CommonName: "JetKVM Self-Signed CA", Organization: []string{"JetKVM"}},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(365 * 24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		return nil, err
	}
	ca, err := x509.ParseCertificate(caDER)
	if err != nil {
		return nil, err
	}
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	leafTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(now.UnixNano() + 1),
		Subject:      pkix.Name{CommonName: "jetkvm.local"},
		DNSNames:     []string{"jetkvm.local", "localhost"},
		IPAddresses:  []net.IP{net.IPv4(127, 0, 0, 1)},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(90 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTemplate, ca, &leafKey.PublicKey, caKey)
	if err != nil {
		return nil, err
	}
	return &tls.Certificate{Certificate: [][]byte{leafDER, caDER}, PrivateKey: leafKey}, nil
}

// RotateCertificate replaces the device CA, as if another device (or an
// interceptor) now answered at this address. Only for TLS servers.
func (s *Server) RotateCertificate() error {
	cert, err := newDeviceCertificate()
	if err != nil {
		return err
	}
	s.tlsCert.Store(cert)
	return nil
}

// CertificateAuthority returns the DER of the current device CA (nil without
// TLS).
func (s *Server) CertificateAuthority() []byte {
	cert := s.tlsCert.Load()
	if cert == nil {
		return nil
	}
	return cert.Certificate[len(cert.Certificate)-1]
}
