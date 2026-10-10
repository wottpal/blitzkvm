// Package emulator is a fake JetKVM device for tests and manual runs. It aims
// to be faithful to firmware 0.5.9 (jetkvm/kvm release/0.5.9) in everything a
// client can observe: signaling, auth, JSON-RPC shapes (including void
// responses), HID-RPC timing semantics, session takeover and video.
package emulator

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/interceptor"
	"github.com/pion/webrtc/v4"

	"github.com/lkarlslund/jetkvm-desktop/pkg/client"
	"github.com/lkarlslund/jetkvm-desktop/pkg/logging"
	"github.com/lkarlslund/jetkvm-desktop/pkg/protocol/jsonrpc"
	"github.com/lkarlslund/jetkvm-desktop/pkg/protocol/signaling"
	"github.com/lkarlslund/jetkvm-desktop/pkg/virtualmedia"
)

type AuthMode string

const (
	AuthModeUnset      AuthMode = ""
	AuthModeNoPassword AuthMode = "noPassword"
	AuthModePassword   AuthMode = "password"
)

// DefaultDeviceVersion is what the emulator reports in device-metadata.
const DefaultDeviceVersion = "0.5.9"

type Config struct {
	ListenAddr string
	AuthMode   AuthMode
	Password   string
	Width      int
	Height     int
	FPS        int
	// GOP is the keyframe interval in frames. Default fps/2, like the device.
	GOP int
	// ReplayH264 / ReplayH265 are Annex-B clips with access-unit delimiters.
	// When set they replace the OpenH264 test pattern for that codec.
	ReplayH264 string
	ReplayH265 string
	// DeviceVersion reported in device-metadata; default DefaultDeviceVersion.
	DeviceVersion string
	// TakeoverCloseDelay is how long a replaced session survives after
	// otherSessionConnected. Default 1 s, like the device.
	TakeoverCloseDelay time.Duration
	Netem              NetemConfig
	Faults             FaultConfig
}

type FaultConfig struct {
	RPCDelay              time.Duration
	DropRPCMethod         string
	ApplyButDropRPCMethod string
	DisconnectAfter       time.Duration
	HIDHandshakeDelay     time.Duration
	InitialVideoState     string
	// SignalingAnswerError makes the signaling socket answer offers with
	// {"error":{}} instead of an answer, as the device does on failure.
	SignalingAnswerError bool
	// SignalingSilent accepts the socket but never answers offers.
	SignalingSilent bool
}

// USBDevices mirrors upstream usbgadget.Devices. Unknown fields sent by a
// client (e.g. "network") are ignored, as on the device.
type USBDevices struct {
	AbsoluteMouse bool `json:"absolute_mouse"`
	RelativeMouse bool `json:"relative_mouse"`
	Keyboard      bool `json:"keyboard"`
	MassStorage   bool `json:"mass_storage"`
	SerialConsole bool `json:"serial_console"`
	Audio         bool `json:"audio"`
}

// VideoInputState mirrors upstream native.VideoState (videoInputState event
// and getVideoState result).
type VideoInputState struct {
	Ready     bool    `json:"ready"`
	Streaming uint8   `json:"streaming"`
	Error     string  `json:"error,omitempty"`
	Width     int     `json:"width"`
	Height    int     `json:"height"`
	FPS       float64 `json:"fps"`
}

type DeviceState struct {
	DeviceID             string
	ActiveExtension      string
	ATXState             map[string]any
	DCPowerState         client.DCPowerState
	SerialSettings       client.SerialSettings
	SerialCommandHistory []string
	// VideoState is "ready", or an upstream error such as "no_signal",
	// "no_lock", "out_of_range"; "rebooting" while a reboot is simulated.
	VideoState          string
	StreamQualityFactor float64
	VideoCodec          string
	EDID                string
	AutoUpdateEnabled   bool
	KeyboardLEDMask     byte
	KeyboardModifiers   byte
	KeysDown            []byte
	Hostname            string
	CloudURL            string
	CloudAppURL         string
	KeyboardLayout      string
	DeveloperMode       bool
	DevChannel          bool
	LoopbackOnly        bool
	SSHKey              string
	JigglerEnabled      bool
	JigglerConfig       client.JigglerConfig
	TLSMode             string
	TLSCertificate      string
	TLSPrivateKey       string
	DisplayRotation     string
	BacklightSettings   client.BacklightSettings
	VideoSleepDuration  int
	USBEmulation        bool
	USBConfig           client.USBConfig
	USBDevices          USBDevices
	AudioEnabled        bool
	NetworkSettings     client.NetworkSettings
	NetworkState        client.NetworkState
	MQTTSettings        client.MQTTSettings
	MQTTConnected       bool
	MQTTError           string
	KeyboardMacros      []client.KeyboardMacro
}

type InputRecord struct {
	Channel string
	Type    string
	Data    string
	At      time.Time
}

type Server struct {
	cfg        Config
	httpServer *http.Server
	listener   net.Listener
	limiter    *loginLimiter
	netemStats NetemStats

	mu           sync.Mutex
	session      *session
	sessionCount int
	loginCount   int
	negotiated   []string
	token        string
	state        DeviceState
	inputs       []InputRecord
	media        *virtualmedia.State
	storage      map[string]storedFile
	uploads      map[string]*pendingUpload
}

type storedFile struct {
	data      []byte
	createdAt time.Time
}

type pendingUpload struct {
	filename string
	size     int64
}

type session struct {
	serverRef *Server
	pc        *webrtc.PeerConnection
	ctx       context.Context
	cancel    context.CancelFunc
	hidState  *hidState

	mu     sync.Mutex
	rpc    *webrtc.DataChannel
	hid    *webrtc.DataChannel
	opened map[string]bool
}

func NewServer(cfg Config) (*Server, error) {
	if cfg.ListenAddr == "" {
		cfg.ListenAddr = "127.0.0.1:8080"
	}
	if cfg.Width == 0 {
		cfg.Width = 960
	}
	if cfg.Height == 0 {
		cfg.Height = 540
	}
	if cfg.FPS == 0 {
		cfg.FPS = 15
	}
	if cfg.GOP <= 0 {
		cfg.GOP = max(1, cfg.FPS/2)
	}
	if cfg.DeviceVersion == "" {
		cfg.DeviceVersion = DefaultDeviceVersion
	}
	if cfg.TakeoverCloseDelay == 0 {
		cfg.TakeoverCloseDelay = time.Second
	}
	s := &Server{
		cfg:     cfg,
		limiter: newLoginLimiter(),
		state:   defaultDeviceState(),
		inputs:  make([]InputRecord, 0, 32),
		storage: map[string]storedFile{
			"debian.iso": {data: bytes.Repeat([]byte("D"), 8*1024), createdAt: time.Now().Add(-2 * time.Hour)},
			"tools.img":  {data: bytes.Repeat([]byte("I"), 4*1024), createdAt: time.Now().Add(-1 * time.Hour)},
		},
		uploads: make(map[string]*pendingUpload),
	}
	if cfg.Faults.InitialVideoState != "" {
		s.state.VideoState = cfg.Faults.InitialVideoState
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/device/status", s.handleDeviceStatus)
	mux.HandleFunc("/device/setup", s.handleSetup)
	mux.HandleFunc("/device", s.handleDevice)
	mux.HandleFunc("/auth/login-local", s.handleLogin)
	mux.HandleFunc("/auth/logout", s.handleLogout)
	mux.HandleFunc("/auth/password-local", s.handlePasswordLocal)
	mux.HandleFunc("/auth/local-password", s.handleDeletePassword)
	mux.HandleFunc("/cloud/state", s.handleCloudState)
	mux.HandleFunc("/storage/upload", s.handleStorageUpload)
	// Firmware 0.5.9 removed the legacy POST /webrtc/session route (#1569);
	// only WebSocket signaling exists.
	mux.HandleFunc("/webrtc/signaling/client", s.handleSignalingClient)
	mux.HandleFunc("/healthz", s.handleHealth)

	s.httpServer = &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	return s, nil
}

func defaultDeviceState() DeviceState {
	return DeviceState{
		DeviceID:        "emu-jetkvm-001",
		ActiveExtension: "",
		ATXState:        map[string]any{"power": false, "hdd": false},
		DCPowerState: client.DCPowerState{
			IsOn:         false,
			Voltage:      12.0,
			RestoreState: 2,
		},
		SerialSettings: client.SerialSettings{
			BaudRate:         9600,
			DataBits:         8,
			Parity:           "none",
			StopBits:         "1",
			Terminator:       client.Terminator{Label: "LF (\\n)", Value: "\n"},
			NormalizeMode:    "names",
			NormalizeLineEnd: "keep",
			PreserveANSI:     true,
			ShowNLTag:        true,
			Buttons: []client.QuickButton{
				{ID: "emu-btn-1", Label: "Help", Command: "help", Terminator: client.Terminator{Label: "LF (\\n)", Value: "\n"}, Sort: 0},
				{ID: "emu-btn-2", Label: "Status", Command: "status", Terminator: client.Terminator{Label: "CRLF (\\r\\n)", Value: "\r\n"}, Sort: 1},
			},
		},
		SerialCommandHistory: []string{"help", "status"},
		VideoState:           "ready",
		StreamQualityFactor:  0.75,
		VideoCodec:           "auto",
		AutoUpdateEnabled:    true,
		KeysDown:             []byte{0, 0, 0, 0, 0, 0},
		Hostname:             "jetkvm-emulator",
		KeyboardLayout:       "en_US",
		JigglerConfig: client.JigglerConfig{
			InactivityLimitSeconds: 60,
			JitterPercentage:       25,
			ScheduleCronTab:        "0 * * * * *",
		},
		TLSMode:         "disabled",
		DisplayRotation: "270",
		BacklightSettings: client.BacklightSettings{
			MaxBrightness: 64,
			DimAfter:      300,
			OffAfter:      600,
		},
		VideoSleepDuration: -1,
		USBEmulation:       true,
		USBConfig: client.USBConfig{
			VendorID:     "0xCafe",
			ProductID:    "0x4000",
			SerialNumber: "JETKVM-DESKTOP",
			Manufacturer: "JetKVM",
			Product:      "JetKVM Default",
		},
		USBDevices: USBDevices{
			Keyboard:      true,
			AbsoluteMouse: true,
			RelativeMouse: true,
			MassStorage:   true,
			Audio:         true,
		},
		AudioEnabled: true,
		NetworkSettings: client.NetworkSettings{
			DHCPClient:   "dhcpcd",
			Hostname:     "jetkvm-emulator",
			Domain:       "lab.example",
			IPv4Mode:     "dhcp",
			MDNSMode:     "auto",
			IPv6Mode:     "slaac",
			TimeSyncMode: "ntp_only",
			IPv4Static: &client.IPv4StaticConfig{
				Address: "192.168.1.50",
				Netmask: "255.255.255.0",
				Gateway: "192.168.1.1",
				DNS:     []string{"1.1.1.1", "8.8.8.8"},
			},
			IPv6Static: &client.IPv6StaticConfig{
				Prefix:  "2001:db8::50/64",
				Gateway: "2001:db8::1",
				DNS:     []string{"2606:4700:4700::1111"},
			},
			TimeSyncNTPServers: []string{"0.pool.ntp.org", "1.pool.ntp.org"},
			TimeSyncHTTPUrls:   []string{"https://time.cloudflare.com"},
		},
		NetworkState: client.NetworkState{
			InterfaceName: "eth0",
			MACAddress:    "02:42:ac:11:00:02",
			IPv4:          "192.168.1.50",
			IPv4Addresses: []string{"192.168.1.50/24"},
			IPv6:          "2001:db8::50",
			IPv6Addresses: []client.IPv6Address{{Address: "2001:db8::50", Prefix: "64"}},
			IPv6LinkLocal: "fe80::1",
			IPv6Gateway:   "2001:db8::1",
			Hostname:      "jetkvm-emulator",
			DHCPLease: &client.DHCPLease{
				IP:          "192.168.1.50",
				Netmask:     "255.255.255.0",
				DNSServers:  []string{"1.1.1.1", "8.8.8.8"},
				Domain:      "lab.example",
				Routers:     []string{"192.168.1.1"},
				ServerID:    "192.168.1.1",
				LeaseExpiry: time.Now().Add(8 * time.Hour),
				DHCPClient:  "dhcpcd",
			},
		},
		MQTTSettings: client.MQTTSettings{
			Broker:    "mqtt.local",
			Port:      1883,
			BaseTopic: "jetkvm",
		},
		KeyboardMacros: []client.KeyboardMacro{},
	}
}

func (s *Server) ListenAndServe(ctx context.Context) error {
	ln, err := net.Listen("tcp", s.cfg.ListenAddr)
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.listener = ln
	s.mu.Unlock()

	errCh := make(chan error, 1)
	go func() {
		errCh <- s.httpServer.Serve(ln)
	}()

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = ln.Close()
		_ = s.httpServer.Shutdown(shutdownCtx)
		s.mu.Lock()
		current := s.session
		s.mu.Unlock()
		if current != nil {
			current.close()
		}
		err := <-errCh
		if err == nil || errors.Is(err, http.ErrServerClosed) || errors.Is(err, net.ErrClosed) {
			return nil
		}
		return err
	case err := <-errCh:
		if err == http.ErrServerClosed {
			return nil
		}
		return err
	}
}

func (s *Server) BaseURL() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.listener == nil {
		return ""
	}
	return "http://" + s.listener.Addr().String()
}

func (s *Server) Inputs() []InputRecord {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]InputRecord, len(s.inputs))
	copy(out, s.inputs)
	return out
}

// State returns a snapshot of the emulated device state.
func (s *Server) State() DeviceState {
	s.mu.Lock()
	defer s.mu.Unlock()
	st := s.state
	st.KeysDown = append([]byte(nil), s.state.KeysDown...)
	return st
}

// SessionCount reports how many WebRTC sessions have been created so far.
func (s *Server) SessionCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.sessionCount
}

// LoginCount reports successful password logins (each one rotates the token).
func (s *Server) LoginCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.loginCount
}

// NegotiatedCodecs lists the video codec chosen for each session, in order.
func (s *Server) NegotiatedCodecs() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.negotiated...)
}

// NetemStats exposes what the configured network impairment did.
func (s *Server) NetemStats() (sent, dropped int64) {
	return s.netemStats.Sent.Load(), s.netemStats.Dropped.Load()
}

func (s *Server) SetActiveExtension(name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state.ActiveExtension = strings.TrimSpace(name)
}

func (s *Server) SetATXState(power, hdd bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state.ATXState = map[string]any{"power": power, "hdd": hdd}
}

// SetKeyboardLEDs simulates the host toggling lock LEDs; the active session is
// notified over HID-RPC (after the handshake) or as a JSON-RPC event.
func (s *Server) SetKeyboardLEDs(mask byte) {
	s.mu.Lock()
	s.state.KeyboardLEDMask = mask
	current := s.session
	s.mu.Unlock()
	if current != nil {
		current.hidState.reportLEDs(mask)
	}
}

// SetVideoState changes the HDMI input state and notifies the active session.
func (s *Server) SetVideoState(state string) {
	s.mu.Lock()
	s.state.VideoState = state
	current := s.session
	payload := s.videoInputStateLocked()
	s.mu.Unlock()
	if current != nil {
		_ = current.sendEvent("videoInputState", payload)
	}
}

// SendWillReboot emits upstream's willReboot event (redirectTo may be empty).
func (s *Server) SendWillReboot(redirectTo string) {
	s.mu.Lock()
	current := s.session
	s.mu.Unlock()
	if current == nil {
		return
	}
	var params any
	if redirectTo != "" {
		params = map[string]string{"healthCheck": redirectTo + "/device/status", "redirectTo": redirectTo}
	}
	_ = current.sendEvent("willReboot", params)
}

// DisconnectSession closes the active WebRTC session as a network drop would.
func (s *Server) DisconnectSession() {
	s.mu.Lock()
	current := s.session
	s.mu.Unlock()
	if current != nil {
		current.close()
	}
}

func (s *Server) videoInputStateLocked() VideoInputState {
	st := VideoInputState{Width: s.cfg.Width, Height: s.cfg.Height, FPS: float64(s.cfg.FPS)}
	switch s.state.VideoState {
	case "ready":
		st.Ready = true
		st.Streaming = 1
	case "rebooting":
	default:
		st.Error = s.state.VideoState
		st.Width, st.Height, st.FPS = 0, 0, 0
	}
	return st
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	s.writeCORS(w, r)
	_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if s.handlePreflight(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	s.mu.Lock()
	mode, password := s.cfg.AuthMode, s.cfg.Password
	s.mu.Unlock()
	if mode == AuthModeNoPassword {
		writeJSONError(w, http.StatusBadRequest, "Login is disabled in noPassword mode")
		return
	}

	ip := clientIP(r)
	now := time.Now()
	if ok, retryAfter := s.limiter.allowed(ip, now); !ok {
		w.Header().Set("Retry-After", itoa(retryAfter))
		w.WriteHeader(http.StatusTooManyRequests)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"error":       "Too many failed attempts. Please try again later.",
			"retry_after": retryAfter,
		})
		return
	}

	var req struct {
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	if req.Password != password {
		s.limiter.recordFailure(ip, now)
		writeJSONError(w, http.StatusUnauthorized, "Invalid password")
		return
	}
	s.limiter.recordSuccess(ip)

	token := s.issueToken()
	s.mu.Lock()
	s.loginCount++
	s.mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: "authToken", Value: token, Path: "/", MaxAge: 7 * 24 * 3600, HttpOnly: true})
	_ = json.NewEncoder(w).Encode(map[string]string{"message": "Login successful"})
}

// issueToken rotates the single device-wide token, logging out every other
// holder (browser tabs, other clients), as upstream does on each login.
func (s *Server) issueToken() string {
	token := newAuthToken()
	s.mu.Lock()
	s.token = token
	s.mu.Unlock()
	return token
}

func (s *Server) authorized(r *http.Request) bool {
	s.mu.Lock()
	mode, token := s.cfg.AuthMode, s.token
	s.mu.Unlock()
	if mode == AuthModeNoPassword || mode == AuthModeUnset {
		return true
	}
	cookie, err := r.Cookie("authToken")
	return err == nil && token != "" && cookie.Value == token
}

func (s *Server) handleSignalingClient(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		writeJSONError(w, http.StatusUnauthorized, "Unauthorized")
		return
	}
	upgrader := websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()

	// gorilla/websocket allows one concurrent writer; trickled candidates are
	// written from pion callbacks.
	var writeMu sync.Mutex
	writeJSON := func(v any) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		return conn.WriteJSON(v)
	}

	_ = writeJSON(map[string]any{
		"type": "device-metadata",
		"data": map[string]any{"deviceVersion": s.cfg.DeviceVersion},
	})

	var current *session
	for {
		_, msg, err := conn.ReadMessage()
		if err != nil {
			return
		}
		if bytes.Equal(msg, []byte("ping")) {
			writeMu.Lock()
			_ = conn.WriteMessage(websocket.TextMessage, []byte("pong"))
			writeMu.Unlock()
			continue
		}

		var message struct {
			Type string          `json:"type"`
			Data json.RawMessage `json:"data"`
		}
		if err := json.Unmarshal(msg, &message); err != nil {
			continue
		}

		switch message.Type {
		case "offer":
			if s.cfg.Faults.SignalingSilent {
				continue
			}
			if s.cfg.Faults.SignalingAnswerError {
				_ = writeJSON(map[string]any{"error": map[string]any{}})
				continue
			}
			var req signaling.ExchangeRequest
			if err := json.Unmarshal(message.Data, &req); err != nil {
				_ = writeJSON(map[string]any{"error": map[string]any{}})
				continue
			}
			sess, answer, err := s.exchangeOffer(req.SD, func(c webrtc.ICECandidateInit) {
				_ = writeJSON(map[string]any{"type": "new-ice-candidate", "data": c})
			})
			if err != nil {
				_ = writeJSON(map[string]any{"error": map[string]any{}})
				continue
			}
			current = sess
			_ = writeJSON(map[string]any{"type": "answer", "data": answer})
		case "new-ice-candidate":
			var candidate webrtc.ICECandidateInit
			if err := json.Unmarshal(message.Data, &candidate); err != nil {
				continue
			}
			if current != nil {
				_ = current.pc.AddICECandidate(candidate)
			}
		}
	}
}

func (s *Server) handleDeviceStatus(w http.ResponseWriter, r *http.Request) {
	if s.handlePreflight(w, r) {
		return
	}
	s.mu.Lock()
	isSetup := s.cfg.AuthMode != AuthModeUnset
	s.mu.Unlock()
	_ = json.NewEncoder(w).Encode(map[string]bool{"isSetup": isSetup})
}

// handleDevice serves GET /device. Like upstream it needs no login, which lets
// clients verify a device's identity before sending a stored password.
func (s *Server) handleDevice(w http.ResponseWriter, r *http.Request) {
	if s.handlePreflight(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	s.mu.Lock()
	authMode := string(s.cfg.AuthMode)
	deviceID, loopbackOnly := s.state.DeviceID, s.state.LoopbackOnly
	s.mu.Unlock()
	_ = json.NewEncoder(w).Encode(map[string]any{
		"authMode":     &authMode,
		"deviceId":     deviceID,
		"loopbackOnly": loopbackOnly,
	})
}

func (s *Server) handleSetup(w http.ResponseWriter, r *http.Request) {
	if s.handlePreflight(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		LocalAuthMode string `json:"localAuthMode"`
		Password      string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	s.mu.Lock()
	if s.cfg.AuthMode != AuthModeUnset {
		s.mu.Unlock()
		writeJSONError(w, http.StatusBadRequest, "Device is already set up")
		return
	}
	switch AuthMode(req.LocalAuthMode) {
	case AuthModeNoPassword:
		s.cfg.AuthMode = AuthModeNoPassword
		s.mu.Unlock()
	case AuthModePassword:
		if req.Password == "" {
			s.mu.Unlock()
			writeJSONError(w, http.StatusBadRequest, "Password is required for password mode")
			return
		}
		s.cfg.AuthMode = AuthModePassword
		s.cfg.Password = req.Password
		s.mu.Unlock()
		http.SetCookie(w, &http.Cookie{Name: "authToken", Value: s.issueToken(), Path: "/", HttpOnly: true})
	default:
		s.mu.Unlock()
		writeJSONError(w, http.StatusBadRequest, "Invalid localAuthMode")
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]string{"message": "Device setup completed successfully"})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if s.handlePreflight(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	s.mu.Lock()
	s.token = ""
	s.mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: "authToken", Value: "", Path: "/", MaxAge: -1, HttpOnly: true})
	_ = json.NewEncoder(w).Encode(map[string]string{"message": "Logout successful"})
}

func (s *Server) handlePasswordLocal(w http.ResponseWriter, r *http.Request) {
	if s.handlePreflight(w, r) {
		return
	}
	switch r.Method {
	case http.MethodPost:
		var req struct {
			Password string `json:"password"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Password == "" {
			writeJSONError(w, http.StatusBadRequest, "Invalid request")
			return
		}
		s.mu.Lock()
		if s.cfg.AuthMode != AuthModeNoPassword {
			s.mu.Unlock()
			writeJSONError(w, http.StatusBadRequest, "Password mode is not enabled")
			return
		}
		s.cfg.AuthMode = AuthModePassword
		s.cfg.Password = req.Password
		s.mu.Unlock()
		http.SetCookie(w, &http.Cookie{Name: "authToken", Value: s.issueToken(), Path: "/", HttpOnly: true})
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(map[string]string{"message": "Password set successfully"})
	case http.MethodPut:
		var req struct {
			OldPassword string `json:"oldPassword"`
			NewPassword string `json:"newPassword"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.NewPassword == "" {
			writeJSONError(w, http.StatusBadRequest, "Invalid request")
			return
		}
		s.mu.Lock()
		if s.cfg.AuthMode != AuthModePassword {
			s.mu.Unlock()
			writeJSONError(w, http.StatusBadRequest, "Password mode is not enabled")
			return
		}
		if s.cfg.Password != "" && req.OldPassword != s.cfg.Password {
			s.mu.Unlock()
			writeJSONError(w, http.StatusUnauthorized, "Incorrect old password")
			return
		}
		s.cfg.Password = req.NewPassword
		s.mu.Unlock()
		http.SetCookie(w, &http.Cookie{Name: "authToken", Value: s.issueToken(), Path: "/", HttpOnly: true})
		_ = json.NewEncoder(w).Encode(map[string]string{"message": "Password updated successfully"})
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleDeletePassword(w http.ResponseWriter, r *http.Request) {
	if s.handlePreflight(w, r) {
		return
	}
	if r.Method != http.MethodDelete {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "Invalid request")
		return
	}
	s.mu.Lock()
	if s.cfg.AuthMode != AuthModePassword {
		s.mu.Unlock()
		writeJSONError(w, http.StatusBadRequest, "Password mode is not enabled")
		return
	}
	if req.Password != s.cfg.Password {
		s.mu.Unlock()
		writeJSONError(w, http.StatusUnauthorized, "Incorrect password")
		return
	}
	s.cfg.Password = ""
	s.cfg.AuthMode = AuthModeNoPassword
	s.token = ""
	s.mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: "authToken", Value: "", Path: "/", MaxAge: -1, HttpOnly: true})
	_ = json.NewEncoder(w).Encode(map[string]string{"message": "Password disabled successfully"})
}

func (s *Server) handleCloudState(w http.ResponseWriter, r *http.Request) {
	if s.handlePreflight(w, r) {
		return
	}
	if !s.authorized(r) {
		writeJSONError(w, http.StatusUnauthorized, "Unauthorized")
		return
	}
	s.mu.Lock()
	url, appURL := s.state.CloudURL, s.state.CloudAppURL
	s.mu.Unlock()
	_ = json.NewEncoder(w).Encode(map[string]any{"connected": url != "", "url": url, "appUrl": appURL})
}

func (s *Server) handleStorageUpload(w http.ResponseWriter, r *http.Request) {
	if s.handlePreflight(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorized(r) {
		writeJSONError(w, http.StatusUnauthorized, "Unauthorized")
		return
	}
	uploadID := strings.TrimSpace(r.URL.Query().Get("uploadId"))
	if uploadID == "" {
		http.Error(w, "missing uploadId", http.StatusBadRequest)
		return
	}
	data, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "failed to read upload", http.StatusInternalServerError)
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	upload, ok := s.uploads[uploadID]
	if !ok {
		http.Error(w, "upload not found", http.StatusNotFound)
		return
	}
	incompleteName := upload.filename + ".incomplete"
	file := s.storage[incompleteName]
	file.data = append(file.data, data...)
	if file.createdAt.IsZero() {
		file.createdAt = time.Now()
	}
	if int64(len(file.data)) >= upload.size {
		s.storage[upload.filename] = storedFile{data: file.data[:upload.size], createdAt: file.createdAt}
		delete(s.storage, incompleteName)
		delete(s.uploads, uploadID)
	} else {
		s.storage[incompleteName] = file
	}
	_ = json.NewEncoder(w).Encode(map[string]string{"message": "Upload completed"})
}

func (s *Server) handlePreflight(w http.ResponseWriter, r *http.Request) bool {
	s.writeCORS(w, r)
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return true
	}
	return false
}

func (s *Server) writeCORS(w http.ResponseWriter, r *http.Request) {
	origin := r.Header.Get("Origin")
	if origin == "" {
		origin = "*"
	}
	w.Header().Set("Access-Control-Allow-Origin", origin)
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
	w.Header().Set("Access-Control-Allow-Credentials", "true")
	if origin != "*" {
		w.Header().Set("Vary", "Origin")
	}
	w.Header().Set("Content-Type", "application/json")
}

func writeJSONError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
}

// newPeerConnection builds the device-side peer connection like upstream:
// default codecs (H.264 and H.265), default interceptors (NACK responder,
// RTCP reports, TWCC), host candidates only, and optional network impairment
// placed closest to the wire.
func (s *Server) newPeerConnection() (*webrtc.PeerConnection, error) {
	mediaEngine := &webrtc.MediaEngine{}
	if err := mediaEngine.RegisterDefaultCodecs(); err != nil {
		return nil, err
	}
	registry := &interceptor.Registry{}
	if s.cfg.Netem.enabled() {
		registry.Add(&netemFactory{cfg: s.cfg.Netem, stats: &s.netemStats})
	}
	if err := webrtc.RegisterDefaultInterceptors(mediaEngine, registry); err != nil {
		return nil, err
	}
	api := webrtc.NewAPI(webrtc.WithMediaEngine(mediaEngine), webrtc.WithInterceptorRegistry(registry))
	return api.NewPeerConnection(webrtc.Configuration{})
}

// exchangeOffer creates a session for the offer and returns the encoded
// answer without waiting for ICE gathering; candidates trickle through
// onCandidate (possibly before the caller has written the answer, exactly as
// on the device). A new session takes over the previous one immediately.
func (s *Server) exchangeOffer(encoded string, onCandidate func(webrtc.ICECandidateInit)) (*session, string, error) {
	rawOffer, err := signaling.DecodeSDP(encoded)
	if err != nil {
		return nil, "", err
	}
	var offer webrtc.SessionDescription
	if err := json.Unmarshal(rawOffer, &offer); err != nil {
		return nil, "", err
	}

	pc, err := s.newPeerConnection()
	if err != nil {
		return nil, "", err
	}
	ctx, cancel := context.WithCancel(context.Background())
	sess := &session{pc: pc, ctx: ctx, cancel: cancel, opened: map[string]bool{}, serverRef: s}
	sess.hidState = newHIDState(ctx, sess)

	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c != nil && onCandidate != nil {
			onCandidate(c.ToJSON())
		}
	})
	pc.OnDataChannel(sess.attachDataChannel)
	pc.OnICEConnectionStateChange(func(state webrtc.ICEConnectionState) {
		// Upstream closes the peer connection as soon as ICE reports
		// disconnected or failed; there is no ICE restart.
		switch state {
		case webrtc.ICEConnectionStateDisconnected, webrtc.ICEConnectionStateFailed:
			_ = pc.Close()
		case webrtc.ICEConnectionStateClosed:
			sess.cancel()
		}
	})
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		if state == webrtc.PeerConnectionStateClosed || state == webrtc.PeerConnectionStateFailed {
			sess.cancel()
			s.mu.Lock()
			isCurrent := s.session == sess
			s.mu.Unlock()
			if isCurrent {
				sess.hidState.clearKeyboard()
			}
		}
	})

	s.mu.Lock()
	preference := s.state.VideoCodec
	s.mu.Unlock()
	mimeType := resolveCodec(offer.SDP, preference)
	videoTrack, err := webrtc.NewTrackLocalStaticSample(webrtc.RTPCodecCapability{MimeType: mimeType}, "video", "jetkvm-desktop-emulator")
	if err != nil {
		cancel()
		_ = pc.Close()
		return nil, "", err
	}
	sender, err := pc.AddTrack(videoTrack)
	if err != nil {
		cancel()
		_ = pc.Close()
		return nil, "", err
	}
	go func() {
		// Read RTCP so interceptors (NACK responder, reports) see feedback.
		// Like the device, PLI/FIR are otherwise ignored.
		buf := make([]byte, 1500)
		for {
			if _, _, err := sender.Read(buf); err != nil {
				return
			}
		}
	}()

	if err := pc.SetRemoteDescription(offer); err != nil {
		cancel()
		_ = pc.Close()
		return nil, "", err
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		cancel()
		_ = pc.Close()
		return nil, "", err
	}
	if err := pc.SetLocalDescription(answer); err != nil {
		cancel()
		_ = pc.Close()
		return nil, "", err
	}

	s.mu.Lock()
	prev := s.session
	s.session = sess
	s.sessionCount++
	s.negotiated = append(s.negotiated, mimeType)
	s.mu.Unlock()
	if prev != nil {
		_ = prev.sendEvent("otherSessionConnected", nil)
		prev.hidState.clearKeyboard()
		delay := s.cfg.TakeoverCloseDelay
		go func() {
			time.Sleep(delay)
			prev.close()
		}()
	}

	if s.cfg.Faults.DisconnectAfter > 0 {
		go func() {
			// Count from ICE connected, not from the offer, so slow test
			// machines don't trip the fault before the session is usable.
			if !sess.waitConnected(ctx) {
				return
			}
			select {
			case <-ctx.Done():
			case <-time.After(s.cfg.Faults.DisconnectAfter):
				sess.close()
			}
		}()
	}
	go func() {
		// Start encoding once the transport is up, so the first frame (a
		// keyframe) reaches the client even with a long GOP. A real device
		// encodes continuously but its GOP is only 0.5 s.
		if !sess.waitConnected(ctx) {
			return
		}
		if err := s.startVideo(ctx, mimeType, videoTrack); err != nil {
			log := logging.Subsystem("emulator")
			log.Warn().Err(err).Msg("video source failed")
		}
	}()

	rawAnswer, err := json.Marshal(pc.LocalDescription())
	if err != nil {
		sess.close()
		return nil, "", err
	}
	return sess, signaling.EncodeSDP(rawAnswer), nil
}

func (s *Server) appendInput(channel, typ, data string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.appendInputLocked(channel, typ, data)
}

func (s *Server) appendInputLocked(channel, typ, data string) {
	s.inputs = append(s.inputs, InputRecord{Channel: channel, Type: typ, Data: data, At: time.Now()})
}

func (s *Server) recordPointer(x, y int32, buttons byte) {
	if buttons != 0 {
		log := logging.Subsystem("emulator")
		log.Trace().Int32("x", x).Int32("y", y).Uint8("buttons", buttons).Msg("received absolute pointer")
	}
}

func (s *Server) recordRelativeMouse(dx, dy int8, buttons byte) {
	if buttons != 0 {
		log := logging.Subsystem("emulator")
		log.Trace().Int8("dx", dx).Int8("dy", dy).Uint8("buttons", buttons).Msg("received relative mouse")
	}
}

func (sess *session) attachDataChannel(dc *webrtc.DataChannel) {
	s := sess.serverRef
	sess.mu.Lock()
	sess.opened[dc.Label()] = true
	sess.mu.Unlock()

	switch dc.Label() {
	case "rpc":
		sess.mu.Lock()
		sess.rpc = dc
		sess.mu.Unlock()
		dc.OnOpen(func() {
			s.mu.Lock()
			video := s.videoInputStateLocked()
			atx := mapsClone(s.state.ATXState)
			atxActive := s.state.ActiveExtension == "atx-power"
			s.mu.Unlock()
			_ = sess.sendEvent("videoInputState", video)
			if atxActive {
				_ = sess.sendEvent("atxState", atx)
			}
			_ = sess.sendEvent("usbState", "configured")
			_ = sess.sendEvent("failsafeMode", map[string]any{"active": false, "reason": ""})
		})
		dc.OnMessage(func(msg webrtc.DataChannelMessage) {
			if !msg.IsString {
				return
			}
			// Upstream handles each JSON-RPC message on its own goroutine,
			// so responses may arrive out of order.
			data := append([]byte(nil), msg.Data...)
			go func() { _ = sess.handleRPC(data) }()
		})
	case "hidrpc":
		sess.mu.Lock()
		sess.hid = dc
		sess.mu.Unlock()
		dc.OnMessage(func(msg webrtc.DataChannelMessage) {
			sess.hidState.enqueue("hidrpc", msg.Data)
		})
	case "hidrpc-unreliable-ordered", "hidrpc-unreliable-nonordered":
		label := dc.Label()
		dc.OnMessage(func(msg webrtc.DataChannelMessage) {
			sess.hidState.enqueue(label, msg.Data)
		})
	}
}

func (sess *session) waitConnected(ctx context.Context) bool {
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	for {
		if sess.pc.ICEConnectionState() == webrtc.ICEConnectionStateConnected {
			return true
		}
		select {
		case <-ctx.Done():
			return false
		case <-ticker.C:
		}
	}
}

func (sess *session) sendEvent(method string, params any) error {
	sess.mu.Lock()
	rpc := sess.rpc
	sess.mu.Unlock()
	if rpc == nil {
		return nil
	}
	data, err := jsonrpc.Marshal(jsonrpc.NewEvent(method, params))
	if err != nil {
		return err
	}
	return rpc.SendText(string(data))
}

func (sess *session) sendHID(data []byte) error {
	sess.mu.Lock()
	hid := sess.hid
	sess.mu.Unlock()
	if hid == nil {
		return nil
	}
	return hid.Send(data)
}

func (sess *session) close() {
	sess.cancel()
	if sess.pc != nil {
		_ = sess.pc.Close()
	}
}

func itoa(v int) string {
	b, _ := json.Marshal(v)
	return string(b)
}
