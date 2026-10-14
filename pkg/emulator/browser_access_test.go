package emulator

import (
	"context"
	"errors"
	"net/http"
	"testing"

	"github.com/wottpal/blitzkvm/pkg/client"
)

// The browser access switch (fork firmware D16).

const safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

func statusFor(t *testing.T, srv *Server, header, value string) int {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, srv.BaseURL()+"/device/status", nil)
	if err != nil {
		t.Fatal(err)
	}
	if header != "" {
		req.Header.Set(header, value)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	return resp.StatusCode
}

func TestBrowserAccessNeedsD16(t *testing.T) {
	srv := startTestServer(t, Config{})
	c := connectClient(t, client.Config{BaseURL: srv.BaseURL()})
	ctx := context.Background()
	for _, method := range []string{"getBrowserAccessState", "setBrowserAccessState"} {
		var rpcErr *client.RPCError
		if err := c.Call(ctx, method, map[string]any{"enabled": false}, nil); !errors.As(err, &rpcErr) || rpcErr.Code != -32601 {
			t.Fatalf("%s: want method not found, got %v", method, err)
		}
	}
	if c.HasFirmwareFeature(ctx, client.FeatureBrowserAccess) {
		t.Fatal("browserAccess listed")
	}
}

func TestBrowserAccessOffRefusesBrowsersOnly(t *testing.T) {
	srv := startTestServer(t, Config{BrowserAccess: true})
	c := connectClient(t, client.Config{BaseURL: srv.BaseURL()})
	ctx := context.Background()
	if !c.HasFirmwareFeature(ctx, client.FeatureBrowserAccess) {
		t.Fatal("browserAccess not listed")
	}
	if code := statusFor(t, srv, "User-Agent", safariUserAgent); code != http.StatusOK {
		t.Fatalf("browser while on: %d", code)
	}

	if err := c.Call(ctx, "setBrowserAccessState", map[string]any{"enabled": false}, nil); err != nil {
		t.Fatal(err)
	}
	var state client.BrowserAccessState
	if err := c.Call(ctx, "getBrowserAccessState", nil, &state); err != nil || state.Enabled {
		t.Fatalf("state %+v, %v; want off", state, err)
	}
	for _, h := range [][2]string{{"User-Agent", safariUserAgent}, {"Origin", srv.BaseURL()}, {"Sec-Fetch-Site", "same-origin"}} {
		if code := statusFor(t, srv, h[0], h[1]); code != http.StatusForbidden {
			t.Fatalf("browser (%s) while off: %d, want 403", h[0], code)
		}
	}
	if code := statusFor(t, srv, "", ""); code != http.StatusOK {
		t.Fatalf("native client while off: %d, want 200", code)
	}

	// A native client still connects, and turns it back on.
	again := connectClient(t, client.Config{BaseURL: srv.BaseURL()})
	if err := again.Call(ctx, "setBrowserAccessState", map[string]any{"enabled": true}, nil); err != nil {
		t.Fatal(err)
	}
	if code := statusFor(t, srv, "User-Agent", safariUserAgent); code != http.StatusOK {
		t.Fatalf("browser after turning it on: %d", code)
	}
}
