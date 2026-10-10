package session

import (
	"context"
	"errors"
	"fmt"
	"image"
	"math/rand/v2"
	"net/url"
	"strings"
	"time"

	"github.com/pion/webrtc/v4"

	"github.com/lkarlslund/jetkvm-desktop/pkg/client"
	"github.com/lkarlslund/jetkvm-desktop/pkg/protocol/auth"
)

// Session lifecycle. One goroutine (run) owns connecting, watching and
// reconnecting; everything else reads Snapshot(). Slow work (closing a
// client, RPC bootstrap) never runs under c.mu, which the UI takes several
// times per frame.

const (
	// stableSessionAfter resets the reconnect backoff once a session has
	// stayed up this long, so a flapping link does not accumulate delay.
	stableSessionAfter = 30 * time.Second
	hidReadyTimeout    = 5 * time.Second
	stopWaitTimeout    = 3 * time.Second
)

func (c *Controller) Start(parent context.Context) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cancelRun != nil {
		return
	}
	ctx, cancel := context.WithCancel(parent)
	c.runParent = ctx
	c.cancelRun = cancel
	c.launchRunLocked(ctx)
}

// launchRunLocked starts a run loop. Each loop has a generation so a stale
// loop that is still winding down cannot clear the running flag of its
// successor.
func (c *Controller) launchRunLocked(ctx context.Context) {
	c.runGen++
	gen := c.runGen
	done := make(chan struct{})
	c.runDone = done
	c.running = true
	go func() {
		defer close(done)
		c.run(ctx, gen)
	}()
}

// Stop ends the session and waits (bounded) for the run loop to exit.
func (c *Controller) Stop() {
	c.mu.Lock()
	if c.cancelRun != nil {
		c.cancelRun()
		c.cancelRun = nil
	}
	c.running = false
	c.runParent = nil
	current := c.current
	c.current = nil
	done := c.runDone
	c.mu.Unlock()
	if current != nil {
		_ = current.Close()
	}
	if done != nil {
		select {
		case <-done:
		case <-time.After(stopWaitTimeout):
		}
	}
}

// ReconnectNow drops the current session and reconnects immediately,
// restarting the run loop if it had given up (auth failure, takeover).
func (c *Controller) ReconnectNow() {
	c.mu.Lock()
	current := c.current
	parent := c.runParent
	restart := !c.running && parent != nil && parent.Err() == nil
	if restart {
		c.launchRunLocked(parent)
	} else {
		c.reconnectNow = true
	}
	c.mu.Unlock()
	if current != nil {
		_ = current.Close()
	}
}

func (c *Controller) LatestFrame() image.Image {
	img, _ := c.LatestFrameInfo()
	return img
}

func (c *Controller) LatestFrameInfo() (image.Image, time.Time) {
	c.mu.RLock()
	current := c.current
	c.mu.RUnlock()
	if current == nil {
		return nil, time.Time{}
	}
	return current.LatestFrameInfo()
}

func (c *Controller) run(ctx context.Context, gen uint64) {
	defer func() {
		c.mu.Lock()
		if c.runGen == gen {
			c.running = false
		}
		c.mu.Unlock()
	}()

	attempt := 0
	retry := func() bool {
		c.mu.Lock()
		immediate := c.reconnectNow
		c.reconnectNow = false
		reconnect := c.cfg.Reconnect
		base, maxDelay := c.cfg.ReconnectBase, c.cfg.ReconnectMax
		c.mu.Unlock()
		if !reconnect || ctx.Err() != nil {
			return false
		}
		delay := backoff(attempt, base, maxDelay)
		if immediate {
			delay = 0
		}
		attempt++
		return sleepWithContext(ctx, delay)
	}

	for ctx.Err() == nil {
		c.setState(func(s *Snapshot) {
			if attempt == 0 {
				s.Phase = PhaseConnecting
				s.Status = "connecting"
			} else {
				s.Phase = PhaseReconnecting
				s.Status = fmt.Sprintf("reconnecting (attempt %d)", attempt)
			}
			s.HIDReady = false
			s.VideoReady = false
			s.SerialConsoleReady = false
			s.SerialConsoleError = ""
			s.SerialConsoleBuffer = ""
			s.SerialConsoleTruncated = false
			s.SerialSettings = nil
		})
		c.serialLog.Reset()

		cl, err := c.newClient()
		if err != nil {
			c.setConnectError(err)
			if !retry() {
				return
			}
			continue
		}
		c.setClient(cl)

		if err := cl.Connect(ctx); err != nil {
			_ = cl.Close()
			c.setConnectError(err)
			if isAuthError(err) || !retry() {
				return
			}
			continue
		}
		waitCtx, cancel := context.WithTimeout(ctx, hidReadyTimeout)
		err = cl.WaitForHID(waitCtx)
		cancel()
		if err != nil {
			_ = cl.Close()
			c.setConnectError(fmt.Errorf("HID channel not ready: %w", err))
			if !retry() {
				return
			}
			continue
		}

		// Input works as soon as HID is ready; device details load in the
		// background so a slow RPC (e.g. getEDID without HDMI signal) cannot
		// block typing.
		connectedAt := time.Now()
		c.setStateFor(cl, func(s *Snapshot) {
			s.Phase = PhaseConnected
			s.Status = "connected"
			s.HIDReady = true
			s.LastError = ""
		})
		go c.bootstrap(ctx, cl)

		reason := c.watch(ctx, cl)
		_ = cl.Close()
		if ctx.Err() != nil {
			return
		}
		if time.Since(connectedAt) >= stableSessionAfter {
			attempt = 0
		}

		switch reason {
		case "other_session":
			c.setState(func(s *Snapshot) {
				s.Phase = PhaseOtherSession
				s.Status = "another session took over"
				s.HIDReady = false
			})
			return
		case "rebooting":
			c.setState(func(s *Snapshot) {
				s.Phase = PhaseRebooting
				s.Status = "device rebooting"
				s.HIDReady = false
			})
		default:
			c.setState(func(s *Snapshot) {
				s.Phase = PhaseReconnecting
				s.Status = "connection lost, retrying"
				s.HIDReady = false
			})
		}
		if !retry() {
			return
		}
	}
}

// bootstrap loads device details after connecting. Results are dropped if
// the client has been replaced meanwhile.
func (c *Controller) bootstrap(ctx context.Context, cl *client.Client) {
	if deviceID, err := cl.GetDeviceID(ctx); err == nil {
		c.setStateFor(cl, func(s *Snapshot) { s.DeviceID = deviceID })
	}
	if activeExtension, err := cl.GetActiveExtension(ctx); err == nil {
		c.setStateFor(cl, func(s *Snapshot) { s.ActiveExtension = activeExtension })
		switch activeExtension {
		case "atx-power":
			if atxState, stateErr := cl.GetATXState(ctx); stateErr == nil {
				c.setStateFor(cl, func(s *Snapshot) {
					s.ATXState = &ATXState{Power: atxState.Power, HDD: atxState.HDD}
				})
			}
		case "serial-console":
			settings, stateErr := cl.GetSerialSettings(ctx)
			if stateErr != nil {
				defaults := defaultSerialSettings()
				c.setStateFor(cl, func(s *Snapshot) {
					s.SerialSettings = &defaults
					s.SerialConsoleError = stateErr.Error()
				})
			} else {
				converted := serialSettingsFromClient(settings)
				c.setStateFor(cl, func(s *Snapshot) { s.SerialSettings = &converted })
			}
		}
	}
	if quality, err := cl.GetStreamQualityFactor(ctx); err == nil {
		c.setStateFor(cl, func(s *Snapshot) { s.Quality = quality })
	}
	if keyboardLayout, err := cl.GetKeyboardLayout(ctx); err == nil {
		c.setStateFor(cl, func(s *Snapshot) { s.KeyboardLayout = normalizeKeyboardLayoutCode(keyboardLayout) })
	}
	if version, err := cl.GetLocalVersion(ctx); err == nil {
		c.setStateFor(cl, func(s *Snapshot) {
			s.AppVersion = version.AppVersion
			s.SystemVersion = version.SystemVersion
		})
	}
	if network, err := cl.GetNetworkSettings(ctx); err == nil {
		c.setStateFor(cl, func(s *Snapshot) { s.Hostname = network.Hostname })
	}
	// Slow or network-dependent: getEDID stalls without an HDMI signal and
	// getUpdateStatus asks the update server. Last, and off the input path.
	if edid, err := cl.GetEDID(ctx); err == nil {
		c.setStateFor(cl, func(s *Snapshot) { s.EDID = edid })
	}
	if updateStatus, err := cl.GetUpdateStatus(ctx); err == nil {
		c.setStateFor(cl, func(s *Snapshot) {
			s.AppUpdateAvailable = updateStatus.AppUpdateAvailable
			s.SystemUpdateAvailable = updateStatus.SystemUpdateAvailable
		})
	}
}

func serialSettingsFromClient(settings client.SerialSettings) SerialSettings {
	buttons := make([]QuickButton, 0, len(settings.Buttons))
	for _, button := range settings.Buttons {
		buttons = append(buttons, QuickButton{
			ID:         button.ID,
			Label:      button.Label,
			Command:    button.Command,
			Terminator: Terminator{Label: button.Terminator.Label, Value: button.Terminator.Value},
			Sort:       button.Sort,
		})
	}
	return SerialSettings{
		BaudRate:           settings.BaudRate,
		DataBits:           settings.DataBits,
		Parity:             settings.Parity,
		StopBits:           settings.StopBits,
		Terminator:         Terminator{Label: settings.Terminator.Label, Value: settings.Terminator.Value},
		HideSerialSettings: settings.HideSerialSettings,
		EnableEcho:         settings.EnableEcho,
		NormalizeMode:      settings.NormalizeMode,
		NormalizeLineEnd:   settings.NormalizeLineEnd,
		TabRender:          settings.TabRender,
		PreserveANSI:       settings.PreserveANSI,
		ShowNLTag:          settings.ShowNLTag,
		Buttons:            buttons,
	}
}

// watch processes a connected client's events until it ends. It returns why.
func (c *Controller) watch(ctx context.Context, cl *client.Client) string {
	events, serial, lifecycle := cl.Events(), cl.SerialEvents(), cl.Lifecycle()
	for {
		select {
		case <-ctx.Done():
			return "stopped"
		case <-cl.Done():
			return "disconnected"
		case evt, ok := <-events:
			if !ok {
				return "disconnected"
			}
			switch evt.Method {
			case "otherSessionConnected":
				return "other_session"
			case "willReboot":
				if redirect := extractString(evt.Params, "redirectTo"); redirect != "" {
					c.followRedirect(redirect)
				}
				return "rebooting"
			case "networkState":
				if host := extractString(evt.Params, "hostname"); host != "" {
					c.setState(func(s *Snapshot) { s.Hostname = host })
				}
			case "videoInputState":
				c.applyVideoInputState(evt.Params)
			case "keyboardLedState":
				mask := ledMaskFromJSON(evt.Params)
				c.setState(func(s *Snapshot) { s.KeyboardLEDs = mask })
			case "usbState":
				if state, ok := evt.Params.(string); ok {
					c.setState(func(s *Snapshot) { s.USBState = state })
				}
			case "failsafeMode":
				active := extractBool(evt.Params, "active")
				reason := extractString(evt.Params, "reason")
				c.setState(func(s *Snapshot) {
					s.FailsafeActive = active
					s.FailsafeReason = reason
				})
			case "atxState":
				c.setState(func(s *Snapshot) {
					s.ATXState = &ATXState{
						Power: extractBool(evt.Params, "power"),
						HDD:   extractBool(evt.Params, "hdd"),
					}
				})
			}
		case text, ok := <-serial:
			if !ok {
				serial = nil
				continue
			}
			c.mu.RLock()
			activeExtension := c.snapshot.ActiveExtension
			c.mu.RUnlock()
			if activeExtension != "serial-console" {
				continue
			}
			buffer, truncated := c.serialLog.Append(text.Text)
			c.setState(func(s *Snapshot) {
				s.SerialConsoleBuffer = buffer
				s.SerialConsoleTruncated = truncated
			})
		case life, ok := <-lifecycle:
			if !ok {
				return "disconnected"
			}
			switch life.Type {
			case "signaling_mode":
				c.setState(func(s *Snapshot) { s.SignalingMode = life.Signaling })
			case "hid_ready":
				c.setState(func(s *Snapshot) { s.HIDReady = true })
			case "video_ready":
				c.setState(func(s *Snapshot) { s.VideoReady = true })
			case "serial_ready":
				c.setState(func(s *Snapshot) {
					s.SerialConsoleReady = true
					s.SerialConsoleError = ""
				})
			case "paste_state":
				c.setState(func(s *Snapshot) { s.PasteInProgress = life.PasteState })
			case "keyboard_leds":
				c.setState(func(s *Snapshot) { s.KeyboardLEDs = life.LEDMask })
			case "peer_state":
				c.setState(func(s *Snapshot) { s.RTCState = life.Connection })
				switch life.Connection {
				case webrtc.PeerConnectionStateDisconnected, webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateClosed:
					return "disconnected"
				}
			case "connect_error", "video_error":
				c.setState(func(s *Snapshot) { s.LastError = life.Err })
			case "serial_error":
				c.setState(func(s *Snapshot) { s.SerialConsoleError = life.Err })
			}
		}
	}
}

// applyVideoInputState parses the device's videoInputState payload
// ({ready, streaming, error, width, height, fps}). Older firmware sent a bare
// string, which is still accepted.
func (c *Controller) applyVideoInputState(params any) {
	var signal string
	var width, height int
	var fps float64
	switch v := params.(type) {
	case string:
		signal = v
	case map[string]any:
		if extractBool(v, "ready") {
			signal = "ready"
		} else if e := extractString(v, "error"); e != "" {
			signal = e
		} else {
			signal = "no_signal"
		}
		width = int(extractFloat(v, "width"))
		height = int(extractFloat(v, "height"))
		fps = extractFloat(v, "fps")
	}
	if signal == "" {
		return
	}
	c.setState(func(s *Snapshot) {
		s.VideoSignal = signal
		s.VideoWidth, s.VideoHeight, s.VideoFPS = width, height, fps
		if signal != "ready" {
			s.Status = "video: " + strings.ReplaceAll(signal, "_", " ")
		} else if s.Phase == PhaseConnected {
			s.Status = "connected"
		}
	})
}

// followRedirect switches the base URL to the address the device announced
// in willReboot.redirectTo (e.g. "//192.168.1.60" after an IP change), so the
// reconnect after the reboot reaches it.
func (c *Controller) followRedirect(redirect string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	current, err := url.Parse(c.cfg.BaseURL)
	if err != nil {
		return
	}
	target, err := url.Parse(redirect)
	if err != nil || target.Host == "" {
		return
	}
	current.Host = target.Host
	c.cfg.BaseURL = strings.TrimRight(current.String(), "/")
	c.snapshot.BaseURL = c.cfg.BaseURL
}

func ledMaskFromJSON(params any) byte {
	var mask byte
	if m, ok := params.(map[string]any); ok {
		if v, ok := m["mask"].(float64); ok {
			return byte(v)
		}
		bits := []struct {
			key string
			bit byte
		}{{"num_lock", 0x01}, {"caps_lock", 0x02}, {"scroll_lock", 0x04}, {"compose", 0x08}, {"kana", 0x10}, {"shift", 0x40}}
		for _, b := range bits {
			if extractBool(m, b.key) {
				mask |= b.bit
			}
		}
	}
	return mask
}

func (c *Controller) newClient() (*client.Client, error) {
	c.mu.RLock()
	cfg := client.Config{
		BaseURL:        c.cfg.BaseURL,
		Password:       c.cfg.Password,
		RPCTimeout:     c.cfg.RPCTimeout,
		ConnectTimeout: c.cfg.ConnectTimeout,
		Auth:           c.auth,
		OfferH265:      c.cfg.OfferH265,
		OnAccessUnit:   c.cfg.OnAccessUnit,
	}
	c.mu.RUnlock()
	return client.New(cfg)
}

func (c *Controller) setConnectError(err error) {
	c.setState(func(s *Snapshot) {
		s.LastError = err.Error()
		s.HIDReady = false
		s.VideoReady = false
		s.SerialConsoleReady = false
		if isAuthError(err) {
			s.Phase = PhaseAuthFailed
			s.Status = "authentication failed"
			var authErr *auth.Error
			if errors.As(err, &authErr) && authErr.StatusCode == 429 {
				s.Status = "too many failed logins, device locked"
			}
		} else {
			s.Phase = PhaseDisconnected
			s.Status = "connection failed"
		}
	})
}

func (c *Controller) setState(update func(*Snapshot)) {
	c.mu.Lock()
	defer c.mu.Unlock()
	update(&c.snapshot)
}

// setStateFor applies update only while cl is still the current client.
func (c *Controller) setStateFor(cl *client.Client, update func(*Snapshot)) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.current != cl {
		return
	}
	update(&c.snapshot)
}

// setClient installs cl and closes its predecessor outside the lock.
func (c *Controller) setClient(cl *client.Client) {
	c.mu.Lock()
	prev := c.current
	c.current = cl
	c.mu.Unlock()
	if prev != nil && prev != cl {
		_ = prev.Close()
	}
}

func (c *Controller) clientIfConnected() *client.Client {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c.current == nil || c.snapshot.Phase != PhaseConnected {
		return nil
	}
	return c.current
}

// backoff returns a capped exponential delay with jitter in [d/2, d]. It
// never overflows, whatever the attempt count.
func backoff(attempt int, base, maxDelay time.Duration) time.Duration {
	if base <= 0 || maxDelay <= 0 {
		return 0
	}
	d := maxDelay
	if attempt >= 0 && attempt < 32 {
		if shifted := base << attempt; shifted > 0 && shifted < maxDelay {
			d = shifted
		}
	}
	half := d / 2
	return half + time.Duration(rand.Int64N(int64(d-half)+1))
}

func sleepWithContext(ctx context.Context, d time.Duration) bool {
	if d <= 0 {
		return ctx.Err() == nil
	}
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func isAuthError(err error) bool {
	var authErr *auth.Error
	if errors.As(err, &authErr) {
		switch authErr.StatusCode {
		case 401, 403, 429:
			return true
		}
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "unauthorized") ||
		strings.Contains(msg, "authentication failed")
}

func extractFloat(v any, key string) float64 {
	if m, ok := v.(map[string]any); ok {
		if f, ok := m[key].(float64); ok {
			return f
		}
	}
	return 0
}
