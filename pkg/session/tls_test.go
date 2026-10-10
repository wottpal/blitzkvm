package session

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/lkarlslund/jetkvm-desktop/pkg/emulator"
	"github.com/lkarlslund/jetkvm-desktop/pkg/protocol/tlspin"
)

// The genuine device CA is pinned. An interceptor terminates TLS with its
// own key, presents [its own leaf, the genuine (public) CA] and proxies to
// the device: it must not get the password.
func TestInterceptorWithThePinnedCAGetsNoPassword(t *testing.T) {
	srv, ctx, cancel := startEmulatorWith(t, emulator.Config{TLS: true})
	defer cancel()
	realCA := srv.CertificateAuthority()

	evilKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(9), Subject: pkix.Name{CommonName: "mitm"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IPAddresses: []net.IP{net.IPv4(127, 0, 0, 1)}}
	evilLeaf, _ := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &evilKey.PublicKey, evilKey)

	target, _ := url.Parse(srv.BaseURL())
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.Transport = &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}
	var mu sync.Mutex
	var stolen []string
	mitm := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "login") {
			body, _ := io.ReadAll(r.Body)
			mu.Lock()
			stolen = append(stolen, string(body))
			mu.Unlock()
			r.Body = io.NopCloser(bytes.NewReader(body))
		}
		proxy.ServeHTTP(w, r)
	}))
	mitm.TLS = &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{evilLeaf, realCA}, PrivateKey: evilKey}}}
	mitm.StartTLS()
	defer mitm.Close()

	c := New(Config{BaseURL: mitm.URL, ICELoopbackOnly: true, Password: "secret", RPCTimeout: 2 * time.Second,
		CertSHA256: tlspin.Fingerprint(realCA)})
	c.Start(ctx)
	defer c.Stop()
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		n := len(stolen)
		mu.Unlock()
		if n > 0 || c.Snapshot().Phase == PhaseFatal {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(stolen) > 0 {
		t.Fatalf("the interceptor captured the login despite the pin: %s", stolen[0])
	}
	if c.Snapshot().Phase != PhaseFatal {
		t.Fatalf("phase %v (%s), want fatal", c.Snapshot().Phase, c.Snapshot().Status)
	}
}
