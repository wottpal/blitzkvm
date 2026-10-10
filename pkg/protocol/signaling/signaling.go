package signaling

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

// ExchangeRequest is the payload of an "offer" signaling message.
type ExchangeRequest struct {
	SD string `json:"sd"`
}

type WSMessage struct {
	Type string          `json:"type"`
	Data json.RawMessage `json:"data"`
}

type DeviceMetadata struct {
	DeviceVersion string `json:"deviceVersion"`
}

func EncodeSDP(raw []byte) string {
	return base64.StdEncoding.EncodeToString(raw)
}

func DecodeSDP(encoded string) ([]byte, error) {
	return base64.StdEncoding.DecodeString(encoded)
}

func WebsocketURL(baseURL string) (string, error) {
	parsed, err := url.Parse(strings.TrimRight(baseURL, "/"))
	if err != nil {
		return "", err
	}

	switch parsed.Scheme {
	case "http":
		parsed.Scheme = "ws"
	case "https":
		parsed.Scheme = "wss"
	default:
		return "", fmt.Errorf("unsupported base URL scheme %q", parsed.Scheme)
	}

	parsed.Path = strings.TrimRight(parsed.Path, "/") + "/webrtc/signaling/client"
	return parsed.String(), nil
}

func DialWebsocket(ctx context.Context, client *http.Client, baseURL string) (*websocket.Conn, *http.Response, error) {
	wsURL, err := WebsocketURL(baseURL)
	if err != nil {
		return nil, nil, err
	}

	header := http.Header{}
	if client != nil && client.Jar != nil {
		httpURL, err := url.Parse(strings.TrimRight(baseURL, "/"))
		if err != nil {
			return nil, nil, err
		}
		for _, cookie := range client.Jar.Cookies(httpURL) {
			header.Add("Cookie", cookie.String())
		}
	}

	// HandshakeTimeout bounds the HTTP upgrade even if ctx has no deadline.
	dialer := websocket.Dialer{HandshakeTimeout: 10 * time.Second, Proxy: http.ProxyFromEnvironment}
	return dialer.DialContext(ctx, wsURL, header)
}
