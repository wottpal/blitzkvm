package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"strings"
	"time"
)

type Client struct {
	httpClient *http.Client
}

type LocalAuthMode uint8

const (
	LocalAuthModeUnknown LocalAuthMode = iota
	LocalAuthModeNoPassword
	LocalAuthModePassword
)

type DeviceInfo struct {
	AuthMode     LocalAuthMode
	DeviceID     string
	LoopbackOnly bool
}

type Error struct {
	StatusCode int
	Message    string
	RetryAfter int
}

func (e *Error) Error() string {
	if e == nil {
		return ""
	}
	if e.Message == "" {
		return fmt.Sprintf("login failed with status %d", e.StatusCode)
	}
	if e.RetryAfter > 0 {
		return fmt.Sprintf("%s (retry after %ds)", e.Message, e.RetryAfter)
	}
	return e.Message
}

func NewClient() (*Client, error) {
	jar, err := cookiejar.New(nil)
	if err != nil {
		return nil, err
	}
	return &Client{
		httpClient: &http.Client{
			Jar: jar,
			Transport: &http.Transport{
				Proxy:                 http.ProxyFromEnvironment,
				DialContext:           (&net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
				ForceAttemptHTTP2:     false,
				MaxIdleConns:          0,
				MaxIdleConnsPerHost:   -1,
				IdleConnTimeout:       0,
				TLSHandshakeTimeout:   5 * time.Second,
				ResponseHeaderTimeout: 10 * time.Second,
				ExpectContinueTimeout: time.Second,
				DisableKeepAlives:     true,
			},
		},
	}, nil
}

func (c *Client) HTTPClient() *http.Client {
	return c.httpClient
}

func (c *Client) GetDeviceInfo(ctx context.Context, baseURL string) (DeviceInfo, error) {
	var payload struct {
		AuthMode     *string `json:"authMode"`
		DeviceID     string  `json:"deviceId"`
		LoopbackOnly bool    `json:"loopbackOnly"`
	}
	if err := c.doJSON(ctx, http.MethodGet, baseURL, "/device", nil, &payload); err != nil {
		return DeviceInfo{}, err
	}
	return DeviceInfo{
		AuthMode:     parseLocalAuthMode(payload.AuthMode),
		DeviceID:     payload.DeviceID,
		LoopbackOnly: payload.LoopbackOnly,
	}, nil
}

func (c *Client) Login(ctx context.Context, baseURL, password string) error {
	if password == "" {
		return nil
	}

	if err := c.doJSON(ctx, http.MethodPost, baseURL, "/auth/login-local", struct {
		Password string `json:"password"`
	}{Password: password}, nil); err != nil {
		return err
	}
	return nil
}

func (c *Client) CreateLocalPassword(ctx context.Context, baseURL, password string) error {
	return c.doJSON(ctx, http.MethodPost, baseURL, "/auth/password-local", struct {
		Password string `json:"password"`
	}{Password: password}, nil)
}

func (c *Client) UpdateLocalPassword(ctx context.Context, baseURL, oldPassword, newPassword string) error {
	return c.doJSON(ctx, http.MethodPut, baseURL, "/auth/password-local", struct {
		OldPassword string `json:"oldPassword"`
		NewPassword string `json:"newPassword"`
	}{
		OldPassword: oldPassword,
		NewPassword: newPassword,
	}, nil)
}

func (c *Client) DeleteLocalPassword(ctx context.Context, baseURL, password string) error {
	return c.doJSON(ctx, http.MethodDelete, baseURL, "/auth/local-password", struct {
		Password string `json:"password"`
	}{Password: password}, nil)
}

func (c *Client) doJSON(ctx context.Context, method, baseURL, path string, body any, out any) error {
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(data)
	}

	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(baseURL, "/")+path, reader)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		if resp.StatusCode == http.StatusCreated {
			// Some mutation endpoints return 201 on success.
		} else {
			return loginError(resp)
		}
	}
	if out == nil {
		return nil
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil && err != io.EOF {
		return loginError(resp)
	}
	return nil
}

func parseLocalAuthMode(value *string) LocalAuthMode {
	if value == nil {
		return LocalAuthModeUnknown
	}
	switch *value {
	case "noPassword":
		return LocalAuthModeNoPassword
	case "password":
		return LocalAuthModePassword
	default:
		return LocalAuthModeUnknown
	}
}

func loginError(resp *http.Response) error {
	var payload struct {
		Error      string `json:"error"`
		RetryAfter int    `json:"retry_after"`
	}
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if len(data) > 0 && json.Unmarshal(data, &payload) == nil && payload.Error != "" {
		return &Error{
			StatusCode: resp.StatusCode,
			Message:    payload.Error,
			RetryAfter: payload.RetryAfter,
		}
	}
	return &Error{
		StatusCode: resp.StatusCode,
		Message:    fmt.Sprintf("login failed with status %s", resp.Status),
	}
}
