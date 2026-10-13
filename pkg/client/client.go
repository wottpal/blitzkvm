package client

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"net"
	"net/http"
	"slices"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/dtls/v3"
	"github.com/pion/interceptor"
	"github.com/pion/interceptor/pkg/nack"
	"github.com/pion/rtcp"
	"github.com/pion/webrtc/v4"

	"github.com/wottpal/blitzkvm/pkg/logging"
	"github.com/wottpal/blitzkvm/pkg/protocol/auth"
	"github.com/wottpal/blitzkvm/pkg/protocol/hidrpc"
	"github.com/wottpal/blitzkvm/pkg/protocol/jsonrpc"
	"github.com/wottpal/blitzkvm/pkg/protocol/signaling"
	"github.com/wottpal/blitzkvm/pkg/video"
)

// ErrClosed is returned by calls on a client that has been closed.
var ErrClosed = errors.New("client closed")

// ErrOfferRejected means the device answered the offer with an error message.
var ErrOfferRejected = errors.New("device rejected the WebRTC offer")

// ErrDeviceMismatch means the address now belongs to a different JetKVM than
// the one expected (e.g. after a DHCP change).
var ErrDeviceMismatch = errors.New("address answers as a different device")

const (
	defaultRPCTimeout     = 5 * time.Second
	defaultConnectTimeout = 15 * time.Second
	// keepAliveInterval matches the device's expected HID keepalive rate.
	keepAliveInterval = 50 * time.Millisecond
	// sctpRTOMax caps SCTP's retransmission backoff (see newAPI).
	sctpRTOMax = time.Second
	// macroChunkSteps / macroChunkGrace mirror the upstream web UI: macros go
	// out in chunks of at most 128 wire steps, and a chunk may take its step
	// delays plus this grace before the paste is aborted.
	macroChunkSteps = 128
	macroChunkGrace = 2 * time.Second
)

type Config struct {
	BaseURL    string
	Password   string
	RPCTimeout time.Duration
	// ConnectTimeout bounds one Connect attempt: auth, signaling, offer/answer
	// and ICE. It does not bound the session afterwards.
	ConnectTimeout time.Duration
	// Auth, when set, is reused across clients so a reconnect presents the
	// existing cookie and only logs in again when the device rejects it.
	// (Each login mints a new device-wide token, logging out browser tabs and
	// writing to the device's flash.)
	Auth *auth.Client
	// ExpectedDeviceID, when set, pins the device identity. GET /device is
	// checked before login when the device answers it without one (no
	// password, or a still-valid cookie), so no password is sent to the
	// wrong device; password-protected firmware requires a login for it, and
	// then VerifyIdentity checks over RPC before any input is sent. This
	// catches the address now belonging to another JetKVM (e.g. after a DHCP
	// change); it is not proof against a host impersonating the device.
	ExpectedDeviceID string
	// ICELoopbackOnly gathers only loopback candidates: for tests against a
	// local emulator, where a machine's many interfaces (VPNs, bridges) slow
	// ICE down needlessly.
	ICELoopbackOnly bool
	// OfferH265 also offers H.265. JetKVM streams H.265 whenever the offer
	// contains it (codec preference "auto"), so only enable this when the
	// consumer can decode H.265.
	OfferH265 bool
	// OnAccessUnit receives complete video access units (e.g. to forward
	// them to a hardware decoder in another process).
	OnAccessUnit func(video.AccessUnit)
	// NewVideoSink creates a sink (typically a decoder) for the negotiated
	// codec; used when OnAccessUnit is nil. If both are nil, video is
	// assembled and counted but not decoded.
	NewVideoSink func(ctx context.Context, codec video.Codec) (video.Sink, error)
}

//go:generate go tool github.com/dmarkham/enumer -type=SignalingMode -linecomment -text -output client_enums.go

type SignalingMode uint8

const (
	SignalingModeUnknown    SignalingMode = iota // unknown
	SignalingModeLegacyHTTP                      // legacy_http
	SignalingModeWebSocket                       // websocket
)

type LifecycleEvent struct {
	Type       string
	Connection webrtc.PeerConnectionState
	Err        string
	Signaling  SignalingMode
	PasteState bool
	// LEDMask is set for Type "keyboard_leds" (HID-RPC 0x32).
	LEDMask byte
}

type SerialConsoleEvent struct {
	Text string
}

type StatsSnapshot struct {
	// SampledAt is when the transport statistics were collected (once a
	// second); zero before the first sample.
	SampledAt       time.Time
	SignalingMode   SignalingMode
	RTCState        webrtc.PeerConnectionState
	HIDReady        bool
	VideoReady      bool
	VideoCodec      string
	FrameWidth      int
	FrameHeight     int
	BytesReceived   uint64
	BitrateKbps     float64
	PacketsLost     int32
	NACKsSent       uint32
	JitterMs        float64
	FramesDecoded   uint32
	FramesRendered  uint32
	FramesPerSecond float64
	FramesDropped   uint64
	KeyframeWaits   uint64
	LateRepairs     uint64 // keyframe waits cancelled by a late NACK repair
	RoundTripMs     float64
	// Path is the network the selected candidate pair runs over (PathLAN,
	// PathTailscale, ...); PathRemote is its remote address.
	Path           string
	PathRemote     string
	LastError      string
	TransportDebug string
}

type channels struct {
	rpc           *webrtc.DataChannel
	hid           *webrtc.DataChannel
	hidUnreliable *webrtc.DataChannel
	hidNonOrdered *webrtc.DataChannel
	serial        *webrtc.DataChannel
}

type Client struct {
	cfg        Config
	authClient *auth.Client
	ctx        context.Context
	cancel     context.CancelFunc

	pcMu sync.RWMutex
	pc   *webrtc.PeerConnection
	ch   atomic.Pointer[channels]

	events    *mailbox[jsonrpc.Event]
	lifecycle *mailbox[LifecycleEvent]
	serialCh  chan SerialConsoleEvent

	pendingMu      sync.Mutex
	pending        map[string]chan jsonrpc.Response
	requestCounter atomic.Uint64

	hidReady     chan struct{}
	hidReadyOnce sync.Once
	// hidWheel: the firmware takes wheel reports over HID-RPC.
	hidWheel     atomic.Bool
	rpcReady     chan struct{}
	rpcReadyOnce sync.Once
	// identityVerified is set once ExpectedDeviceID has been confirmed.
	identityVerified atomic.Bool

	// features is what getFirmwareFeatures listed (nil on stock firmware);
	// featuresProbed closes once the probe that follows HID readiness ended.
	features       atomic.Pointer[[]string]
	featuresProbed chan struct{}

	videoMu    sync.RWMutex
	videoSink  video.Sink
	frames     video.FrameSource
	assembler  *video.Assembler
	link       *video.LinkEstimator
	videoCodec string

	signalMu   sync.Mutex
	signalConn *websocket.Conn
	signalMode atomic.Uint32

	remoteMu         sync.Mutex
	remoteApplied    bool
	queuedCandidates []webrtc.ICECandidateInit

	// Pointer routing: reliable while any button is down or changed, and for
	// the first report after the HID handshake.
	pointerMu         sync.Mutex
	lastButtons       byte
	lastX, lastY      int32
	lastRelButtons    byte
	pointerReliableOK bool

	// Held non-modifier keys drive the 50 ms keepalive ticker.
	keysMu       sync.Mutex
	heldKeys     map[byte]bool
	keepAliveRun bool

	macroMu    sync.Mutex
	macroState chan bool

	videoSSRC       atomic.Uint32
	lastKeyframeReq atomic.Int64 // unix nanos

	statsMu      sync.Mutex
	stats        StatsSnapshot
	statsHistory []statsSample
	// hidBytesSent counts bytes handed to the input channels; minus their
	// buffered amount it gives the bytes the device has acknowledged.
	hidBytesSent atomic.Uint64
	// Input stall watch (monitor goroutine only).
	inputStallSince  time.Time
	inputStallLogged bool
	inputAcked       uint64
	rttNanos         atomic.Int64

	// impair is the link model of BLITZKVM_IMPAIR, if set (impair.go).
	impair atomic.Pointer[impairment]

	closeCh        chan struct{}
	closeOnce      sync.Once
	disconnectOnce sync.Once
	lastError      atomic.Value
	transportDebug atomic.Value
}

type statsSample struct {
	at            time.Time
	bytesReceived uint64
	framesDecoded uint32
}

func computeSmoothedRates(history []statsSample) (bitrateKbps, framesPerSecond float64) {
	if len(history) < 2 {
		return 0, 0
	}
	first := history[0]
	last := history[len(history)-1]
	elapsed := last.at.Sub(first.at).Seconds()
	if elapsed <= 0 {
		return 0, 0
	}
	if last.bytesReceived >= first.bytesReceived {
		bitrateKbps = float64(last.bytesReceived-first.bytesReceived) * 8 / elapsed / 1000
	}
	if last.framesDecoded >= first.framesDecoded {
		framesPerSecond = float64(last.framesDecoded-first.framesDecoded) / elapsed
	}
	return bitrateKbps, framesPerSecond
}

func New(cfg Config) (*Client, error) {
	authClient := cfg.Auth
	if authClient == nil {
		var err error
		authClient, err = auth.NewClient()
		if err != nil {
			return nil, err
		}
	}
	if cfg.RPCTimeout == 0 {
		cfg.RPCTimeout = defaultRPCTimeout
	}
	if cfg.ConnectTimeout == 0 {
		cfg.ConnectTimeout = defaultConnectTimeout
	}
	ctx, cancel := context.WithCancel(context.Background())
	c := &Client{
		cfg:        cfg,
		authClient: authClient,
		ctx:        ctx,
		cancel:     cancel,
		events:     newMailbox[jsonrpc.Event](),
		lifecycle:  newMailbox[LifecycleEvent](),
		serialCh:   make(chan SerialConsoleEvent, 128),
		pending:    map[string]chan jsonrpc.Response{},
		hidReady:   make(chan struct{}),
		rpcReady:   make(chan struct{}),
		heldKeys:   map[byte]bool{},
		closeCh:    make(chan struct{}),

		featuresProbed: make(chan struct{}),
	}
	c.ch.Store(&channels{})
	return c, nil
}

// Events delivers JSON-RPC events from the device. The channel is closed
// after the client is closed and remaining events are drained.
func (c *Client) Events() <-chan jsonrpc.Event { return c.events.out }

func (c *Client) SerialEvents() <-chan SerialConsoleEvent { return c.serialCh }

// Lifecycle delivers connection lifecycle events; never drops while open.
func (c *Client) Lifecycle() <-chan LifecycleEvent { return c.lifecycle.out }

// Done is closed when the client is closed.
func (c *Client) Done() <-chan struct{} { return c.closeCh }

func (c *Client) DeviceInfo(ctx context.Context) (auth.DeviceInfo, error) {
	return c.authClient.GetDeviceInfo(ctx, c.cfg.BaseURL)
}

func (c *Client) CreateLocalPassword(ctx context.Context, password string) error {
	return c.authClient.CreateLocalPassword(ctx, c.cfg.BaseURL, password)
}

func (c *Client) UpdateLocalPassword(ctx context.Context, oldPassword, newPassword string) error {
	return c.authClient.UpdateLocalPassword(ctx, c.cfg.BaseURL, oldPassword, newPassword)
}

func (c *Client) DeleteLocalPassword(ctx context.Context, password string) error {
	return c.authClient.DeleteLocalPassword(ctx, c.cfg.BaseURL, password)
}

func (c *Client) SignalingMode() SignalingMode { return SignalingMode(c.signalMode.Load()) }

func (c *Client) peer() *webrtc.PeerConnection {
	c.pcMu.RLock()
	defer c.pcMu.RUnlock()
	return c.pc
}

// newAPI builds a pion API with explicit codecs carrying RTCP feedback (NACK,
// PLI, FIR), the default interceptors (NACK responder, RTCP reports, stats,
// TWCC) and our own NACK generator.
// Offering only what we can decode matters: JetKVM picks H.265 whenever the
// offer mentions it.
func (c *Client) newAPI(local []net.IP) (*webrtc.API, error) {
	feedback := []webrtc.RTCPFeedback{
		{Type: "goog-remb"},
		{Type: "ccm", Parameter: "fir"},
		{Type: "nack"},
		{Type: "nack", Parameter: "pli"},
		{Type: "transport-cc"},
	}
	m := &webrtc.MediaEngine{}
	codecs := []webrtc.RTPCodecParameters{
		{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH264, ClockRate: 90000, SDPFmtpLine: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f", RTCPFeedback: feedback}, PayloadType: 102},
		{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH264, ClockRate: 90000, SDPFmtpLine: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640c1f", RTCPFeedback: feedback}, PayloadType: 112},
		{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH264, ClockRate: 90000, SDPFmtpLine: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=4d001f", RTCPFeedback: feedback}, PayloadType: 127},
	}
	if c.cfg.OfferH265 {
		codecs = append([]webrtc.RTPCodecParameters{
			{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH265, ClockRate: 90000, RTCPFeedback: feedback}, PayloadType: 116},
		}, codecs...)
	}
	for _, codec := range codecs {
		if err := m.RegisterCodec(codec, webrtc.RTPCodecTypeVideo); err != nil {
			return nil, err
		}
	}
	registry := &interceptor.Registry{}
	// NACKs come from nackGenerator, which repeats them a round trip apart
	// (nack.go); pion's own generator gets no streams.
	if err := webrtc.RegisterDefaultInterceptorsWithOptions(m, registry,
		webrtc.WithNackGeneratorOptions(nack.GeneratorStreamsFilter(func(*interceptor.StreamInfo) bool { return false })),
	); err != nil {
		return nil, err
	}
	registry.Add(nackGeneratorFactory{rtt: c.rtt})

	se := webrtc.SettingEngine{}
	// The device encrypts every video packet in pure Go: its ARMv7 core has
	// no AES instructions, and pion prefers AES-256-GCM, whose GHASH is slow
	// there too. AES-128 counter mode with an HMAC-SHA1 tag (SHA-1 has ARM
	// assembly) cut the device's send time for a typing frame by ~10 %.
	se.SetSRTPProtectionProfiles(dtls.SRTP_AES128_CM_HMAC_SHA1_80)
	// Retransmissions reuse their original sequence numbers, and pion drops
	// any SRTP packet more than 64 behind the newest as a replay. On a
	// 5 Mbit/s link that is 120 ms, less than one NACK round trip on
	// cellular, so repairs were discarded and every loss became a keyframe.
	se.SetSRTPReplayProtectionWindow(8192)
	// Detect dead paths quickly; the device itself gives up after ~5 s.
	se.SetICETimeouts(4*time.Second, 8*time.Second, time.Second)
	if c.cfg.ICELoopbackOnly {
		restrictICEToLoopback(&se)
	} else if len(local) > 0 {
		pinICE(&se, local)
	}
	// SCTP (all data channels: keyboard, pointer, RPC) retransmits a lost
	// packet after an RTO that doubles on every miss, up to 60 s by default.
	// After a network hiccup the video resumes at once, but input stays
	// stuck until the backed-off timer fires: measured after a 3.3 s outage,
	// 3.6 s more, and minutes after longer ones. Capped at 1 s (pion's
	// minimum RTO) it is back within 0.7 s.
	se.SetSCTPRTOMax(sctpRTOMax)
	n, err := c.testNet()
	if err != nil {
		return nil, err
	}
	if n != nil {
		se.SetNet(n)
	}
	return webrtc.NewAPI(webrtc.WithMediaEngine(m), webrtc.WithInterceptorRegistry(registry), webrtc.WithSettingEngine(se)), nil
}

// Connect establishes the session. Everything up to an established peer
// connection is bounded by ConnectTimeout; the video stream and data channels
// live until Close.
func (c *Client) Connect(parent context.Context) error {
	ctx, cancel := context.WithTimeout(parent, c.cfg.ConnectTimeout)
	defer cancel()
	// Close() aborts a connect in progress (dial, login, waits).
	stop := context.AfterFunc(c.ctx, cancel)
	defer stop()
	err := c.connect(ctx)
	if err != nil {
		if ctx.Err() != nil && parent.Err() == nil {
			err = fmt.Errorf("connect timed out after %s: %w", c.cfg.ConnectTimeout, err)
		}
		c.emitLifecycle(LifecycleEvent{Type: "connect_error", Err: err.Error()})
	}
	return err
}

func (c *Client) connect(ctx context.Context) error {
	if c.cfg.ExpectedDeviceID != "" {
		info, err := c.authClient.GetDeviceInfo(ctx, c.cfg.BaseURL)
		var authErr *auth.Error
		switch {
		case err == nil:
			if info.DeviceID != c.cfg.ExpectedDeviceID {
				return fmt.Errorf("%w: expected %s, found %s", ErrDeviceMismatch, c.cfg.ExpectedDeviceID, info.DeviceID)
			}
			c.identityVerified.Store(true)
		case errors.As(err, &authErr) && authErr.StatusCode == http.StatusUnauthorized:
			// Password-protected: GET /device needs a login and
			// VerifyIdentity checks over RPC once the session is up. Only
			// log in if a JetKVM answers at all: any other host answering
			// 401 (a router, a camera) must not get the password.
			if _, statusErr := c.authClient.GetDeviceStatus(ctx, c.cfg.BaseURL); statusErr != nil {
				return fmt.Errorf("%w: no JetKVM answers (%v)", ErrDeviceMismatch, statusErr)
			}
		default:
			return fmt.Errorf("verify device identity: %w", err)
		}
	}
	conn, err := c.openSignaling(ctx)
	if err != nil {
		return err
	}
	c.signalMu.Lock()
	select {
	case <-c.closeCh:
		c.signalMu.Unlock()
		_ = conn.Close()
		return ErrClosed
	default:
	}
	c.signalConn = conn
	c.signalMu.Unlock()
	c.signalMode.Store(uint32(SignalingModeWebSocket))
	c.emitLifecycle(LifecycleEvent{Type: "signaling_mode", Signaling: SignalingModeWebSocket})

	api, err := c.newAPI(routeLocalIPs(ctx, c.cfg.BaseURL))
	if err != nil {
		return err
	}
	pc, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		return err
	}
	c.pcMu.Lock()
	c.pc = pc
	c.pcMu.Unlock()
	select {
	case <-c.closeCh:
		_ = pc.Close()
		return ErrClosed
	default:
	}

	connected := make(chan struct{})
	var connectedOnce sync.Once
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		c.noteTransportDebug(fmt.Sprintf("pc_state=%s", state))
		c.emitLifecycle(LifecycleEvent{Type: "peer_state", Connection: state})
		switch state {
		case webrtc.PeerConnectionStateConnected:
			connectedOnce.Do(func() { close(connected) })
		case webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateClosed, webrtc.PeerConnectionStateDisconnected:
			// The device closes its side on ICE disconnect (no ICE restart),
			// so any of these ends the session.
			c.handleTransportDisconnect(state, "pc_state")
		}
	})
	pc.OnTrack(c.onTrack)
	// Local candidates may be gathered before the offer is written. The
	// device applies trickled candidates to whatever session is current —
	// before our offer that is someone else's — so hold them until then.
	var localMu sync.Mutex
	var localQueue []webrtc.ICECandidateInit
	offerSent := false
	pc.OnICECandidate(func(candidate *webrtc.ICECandidate) {
		if candidate == nil {
			return
		}
		init := candidate.ToJSON()
		if init.Candidate == "" {
			return
		}
		localMu.Lock()
		if !offerSent {
			localQueue = append(localQueue, init)
			localMu.Unlock()
			return
		}
		localMu.Unlock()
		_ = c.writeSignal(signalingMessage{Type: "new-ice-candidate", Data: init})
	})

	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo, webrtc.RTPTransceiverInit{
		Direction: webrtc.RTPTransceiverDirectionRecvonly,
	}); err != nil {
		return err
	}
	if err := c.openDataChannels(pc); err != nil {
		return err
	}

	answerCh := make(chan webrtc.SessionDescription, 1)
	errCh := make(chan error, 1)
	go c.readSignaling(conn, pc, answerCh, errCh)

	offer, err := pc.CreateOffer(nil)
	if err != nil {
		return err
	}
	if err := pc.SetLocalDescription(offer); err != nil {
		return err
	}
	rawOffer, err := json.Marshal(pc.LocalDescription())
	if err != nil {
		return err
	}
	if err := c.writeSignal(signalingMessage{Type: "offer", Data: offerSignalData{SD: signaling.EncodeSDP(rawOffer)}}); err != nil {
		return err
	}
	localMu.Lock()
	offerSent = true
	queued := localQueue
	localQueue = nil
	localMu.Unlock()
	for _, candidate := range queued {
		_ = c.writeSignal(signalingMessage{Type: "new-ice-candidate", Data: candidate})
	}

	select {
	case <-ctx.Done():
		return fmt.Errorf("waiting for answer: %w", ctx.Err())
	case <-c.closeCh:
		return ErrClosed
	case err := <-errCh:
		return err
	case answer := <-answerCh:
		if err := pc.SetRemoteDescription(answer); err != nil {
			return err
		}
		c.flushQueuedCandidates(pc)
	}

	select {
	case <-ctx.Done():
		return fmt.Errorf("waiting for ICE: %w", ctx.Err())
	case <-c.closeCh:
		return ErrClosed
	case err := <-errCh:
		return err
	case <-connected:
	}
	go c.monitorStats()
	c.emitLifecycle(LifecycleEvent{Type: "connected"})
	return nil
}

// openSignaling dials the signaling socket, logging in first only if the
// device rejects the current cookie, and reads the device metadata.
func (c *Client) openSignaling(ctx context.Context) (*websocket.Conn, error) {
	conn, resp, err := signaling.DialWebsocket(ctx, c.authClient.HTTPClient(), c.cfg.BaseURL)
	if err != nil && resp != nil && resp.StatusCode == http.StatusUnauthorized {
		if c.cfg.Password == "" {
			return nil, &auth.Error{StatusCode: http.StatusUnauthorized, Message: "device requires a password"}
		}
		if loginErr := c.authClient.Login(ctx, c.cfg.BaseURL, c.cfg.Password); loginErr != nil {
			return nil, loginErr
		}
		conn, resp, err = signaling.DialWebsocket(ctx, c.authClient.HTTPClient(), c.cfg.BaseURL)
		if err != nil && resp != nil && resp.StatusCode == http.StatusUnauthorized {
			return nil, &auth.Error{StatusCode: http.StatusUnauthorized, Message: "device rejected the session after login"}
		}
	}
	if err != nil {
		if resp != nil {
			return nil, fmt.Errorf("signaling: %s: %w", resp.Status, err)
		}
		return nil, fmt.Errorf("signaling: %w", err)
	}

	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetReadDeadline(deadline)
	}
	_, data, err := conn.ReadMessage()
	if err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("signaling metadata: %w", err)
	}
	_ = conn.SetReadDeadline(time.Time{})
	var msg signaling.WSMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		_ = conn.Close()
		return nil, err
	}
	if msg.Type != "device-metadata" {
		_ = conn.Close()
		return nil, fmt.Errorf("unexpected signaling message type %q", msg.Type)
	}
	return conn, nil
}

func (c *Client) readSignaling(conn *websocket.Conn, pc *webrtc.PeerConnection, answerCh chan<- webrtc.SessionDescription, errCh chan<- error) {
	fail := func(err error) {
		select {
		case errCh <- err:
		default:
		}
	}
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			select {
			case <-c.closeCh:
			default:
				c.noteTransportDebug("signaling_read_error")
				fail(fmt.Errorf("signaling closed: %w", err))
			}
			return
		}
		var msg struct {
			Type  string          `json:"type"`
			Data  json.RawMessage `json:"data"`
			Error json.RawMessage `json:"error"`
		}
		if err := json.Unmarshal(data, &msg); err != nil {
			continue
		}
		if msg.Type == "" && len(msg.Error) > 0 {
			fail(fmt.Errorf("%w: %s", ErrOfferRejected, string(msg.Error)))
			continue
		}
		switch msg.Type {
		case "answer":
			var encoded string
			if err := json.Unmarshal(msg.Data, &encoded); err != nil {
				fail(err)
				continue
			}
			answer, err := decodeAnswer(encoded)
			if err != nil {
				fail(err)
				continue
			}
			select {
			case answerCh <- answer:
			default:
			}
		case "new-ice-candidate":
			var candidate webrtc.ICECandidateInit
			if err := json.Unmarshal(msg.Data, &candidate); err != nil {
				continue
			}
			c.addRemoteCandidate(pc, candidate)
		case "other-session-connected":
			// JetKVM Mini signals takeover on the signaling socket.
			c.events.put(jsonrpc.NewEvent("otherSessionConnected", nil))
		}
	}
}

// addRemoteCandidate applies a trickled candidate, queueing it until the
// remote description is set: the device may trickle before its answer.
func (c *Client) addRemoteCandidate(pc *webrtc.PeerConnection, candidate webrtc.ICECandidateInit) {
	c.remoteMu.Lock()
	if !c.remoteApplied {
		c.queuedCandidates = append(c.queuedCandidates, candidate)
		c.remoteMu.Unlock()
		return
	}
	c.remoteMu.Unlock()
	if err := pc.AddICECandidate(candidate); err != nil {
		c.noteTransportDebug("add_candidate: " + err.Error())
	}
}

func (c *Client) flushQueuedCandidates(pc *webrtc.PeerConnection) {
	c.remoteMu.Lock()
	queued := c.queuedCandidates
	c.queuedCandidates = nil
	c.remoteApplied = true
	c.remoteMu.Unlock()
	for _, candidate := range queued {
		if err := pc.AddICECandidate(candidate); err != nil {
			c.noteTransportDebug("add_candidate: " + err.Error())
		}
	}
}

func (c *Client) onTrack(track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
	codec, err := video.CodecFromMime(track.Codec().MimeType)
	if err != nil {
		c.emitLifecycle(LifecycleEvent{Type: "video_error", Err: err.Error()})
		return
	}
	var sink video.Sink
	switch {
	case c.cfg.OnAccessUnit != nil:
		sink = video.SinkFunc(c.cfg.OnAccessUnit)
	case c.cfg.NewVideoSink != nil:
		sink, err = c.cfg.NewVideoSink(c.ctx, codec)
		if err != nil {
			c.emitLifecycle(LifecycleEvent{Type: "video_error", Err: err.Error()})
			return
		}
	default:
		sink = video.SinkFunc(func(video.AccessUnit) {})
	}
	frames, _ := sink.(video.FrameSource)
	c.videoSSRC.Store(uint32(track.SSRC()))
	asm := video.NewAssembler(codec, sink.Push, c.RequestKeyframe)
	link := video.NewLinkEstimator()
	c.videoMu.Lock()
	c.videoSink = sink
	c.frames = frames
	c.assembler = asm
	c.link = link
	c.videoCodec = codec.String()
	c.videoMu.Unlock()
	c.emitLifecycle(LifecycleEvent{Type: "video_ready"})

	go func() {
		err := video.Receive(c.ctx, track, asm, link, c.rtt)
		sink.Close()
		if c.ctx.Err() == nil {
			// The track ended while the session lives on: the picture
			// would stay frozen, so let the session reconnect.
			msg := "video stream ended"
			if err != nil {
				msg = err.Error()
			}
			c.emitLifecycle(LifecycleEvent{Type: "video_lost", Err: msg})
		}
	}()
}

// LinkEstimate is what the video's packet timing says about the link from
// the device right now (zero before video).
func (c *Client) LinkEstimate() video.LinkEstimate {
	c.videoMu.RLock()
	link := c.link
	c.videoMu.RUnlock()
	if link == nil {
		return video.LinkEstimate{}
	}
	return link.Estimate(time.Now())
}

// rtt is the selected candidate pair's latest round-trip time (0 before the
// first measurement).
func (c *Client) rtt() time.Duration { return time.Duration(c.rttNanos.Load()) }

func (c *Client) handleTransportDisconnect(state webrtc.PeerConnectionState, source string) {
	select {
	case <-c.closeCh:
		return
	default:
	}
	c.noteTransportDebug(fmt.Sprintf("disconnect source=%s state=%s", source, state))
	c.disconnectOnce.Do(func() {
		c.emitLifecycle(LifecycleEvent{Type: "peer_state", Connection: state})
		go func() { _ = c.Close() }()
	})
}

// Close tears the session down. Pending calls fail with ErrClosed.
func (c *Client) Close() error {
	var err error
	c.closeOnce.Do(func() {
		close(c.closeCh)
		c.cancel()
		c.noteTransportDebug("client_close")
		c.signalMu.Lock()
		if c.signalConn != nil {
			_ = c.signalConn.Close()
			c.signalConn = nil
		}
		c.signalMu.Unlock()
		c.pcMu.Lock()
		pc := c.pc
		c.pcMu.Unlock()
		if pc != nil {
			err = pc.Close()
		}
		if im := c.impair.Load(); im != nil {
			im.stop()
		}
		c.videoMu.Lock()
		sink := c.videoSink
		c.videoMu.Unlock()
		if sink != nil {
			sink.Close()
		}
		c.events.close()
		c.lifecycle.close()
	})
	return err
}

// VerifyIdentity confirms ExpectedDeviceID over RPC when the pre-login
// check could not (see Config.ExpectedDeviceID). Callers send no input until
// it succeeds.
func (c *Client) VerifyIdentity(ctx context.Context) error {
	if c.cfg.ExpectedDeviceID == "" || c.identityVerified.Load() {
		return nil
	}
	select {
	case <-ctx.Done():
		return fmt.Errorf("verify device identity: %w", ctx.Err())
	case <-c.closeCh:
		return ErrClosed
	case <-c.rpcReady:
	}
	deviceID, err := c.GetDeviceID(ctx)
	if err != nil {
		return fmt.Errorf("verify device identity: %w", err)
	}
	if deviceID != c.cfg.ExpectedDeviceID {
		return fmt.Errorf("%w: expected %s, found %s", ErrDeviceMismatch, c.cfg.ExpectedDeviceID, deviceID)
	}
	c.identityVerified.Store(true)
	return nil
}

func (c *Client) WaitForHID(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-c.closeCh:
		return ErrClosed
	case <-c.hidReady:
		return nil
	}
}

// HIDReady reports whether the HID-RPC handshake completed.
func (c *Client) HIDReady() bool {
	select {
	case <-c.hidReady:
		return true
	default:
		return false
	}
}

// RPCError is a JSON-RPC error response from the device. Data usually holds
// the device's real error text (upstream wraps handler errors as -32603).
type RPCError struct {
	Method  string
	Code    int
	Message string
	Data    string
}

func (e *RPCError) Error() string {
	if e.Data != "" {
		return fmt.Sprintf("%s: %s", e.Method, e.Data)
	}
	return fmt.Sprintf("%s: %s", e.Method, e.Message)
}

// Call performs a JSON-RPC call. A response without "result" (JetKVM's shape
// for handlers that only return an error) is success and leaves out alone.
func (c *Client) Call(ctx context.Context, method string, params any, out any) error {
	rpc := c.ch.Load().rpc
	if rpc == nil {
		return fmt.Errorf("rpc data channel not ready")
	}
	select {
	case <-c.closeCh:
		return ErrClosed
	default:
	}
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, c.cfg.RPCTimeout)
		defer cancel()
	}

	id := fmt.Sprintf("rpc-%d", c.requestCounter.Add(1))
	data, err := jsonrpc.Marshal(jsonrpc.NewRequest(method, params, id))
	if err != nil {
		return err
	}
	respCh := make(chan jsonrpc.Response, 1)
	c.pendingMu.Lock()
	c.pending[id] = respCh
	c.pendingMu.Unlock()
	defer func() {
		c.pendingMu.Lock()
		delete(c.pending, id)
		c.pendingMu.Unlock()
	}()

	if err := rpc.SendText(string(data)); err != nil {
		return err
	}

	select {
	case <-ctx.Done():
		return fmt.Errorf("%s: %w", method, ctx.Err())
	case <-c.closeCh:
		return fmt.Errorf("%s: %w", method, ErrClosed)
	case resp := <-respCh:
		if resp.Error != nil {
			rpcErr := &RPCError{Method: method, Code: resp.Error.Code, Message: resp.Error.Message}
			if s, ok := resp.Error.Data.(string); ok {
				rpcErr.Data = s
			}
			return rpcErr
		}
		if out == nil || resp.Result == nil {
			return nil
		}
		raw, err := json.Marshal(resp.Result)
		if err != nil {
			return err
		}
		return json.Unmarshal(raw, out)
	}
}

func (c *Client) sendHID(dc *webrtc.DataChannel, msg hidrpc.Message) error {
	if dc == nil {
		return fmt.Errorf("hid channel not ready")
	}
	data, err := msg.MarshalBinary()
	if err != nil {
		return err
	}
	if err := dc.Send(data); err != nil {
		return err
	}
	c.hidBytesSent.Add(uint64(len(data)))
	return nil
}

// minKeyframeRequestInterval spaces PLIs: a keyframe takes a few frames to
// arrive, and the patched firmware coalesces requests to two a second.
const minKeyframeRequestInterval = 250 * time.Millisecond

// RequestKeyframe asks the device for an IDR frame (RTCP PLI). Anything that
// drops frames until the next keyframe must ask: the patched firmware sends
// keyframes only on request (or once a minute), so waiting freezes the
// picture. JetKVM 0.5.9 ignores PLI but sends an IDR every 0.5 s anyway.
// Safe from any goroutine; requests within 250 ms of the last are dropped.
func (c *Client) RequestKeyframe() {
	ssrc := c.videoSSRC.Load()
	pc := c.peer()
	if ssrc == 0 || pc == nil {
		return
	}
	now := time.Now().UnixNano()
	last := c.lastKeyframeReq.Load()
	if now-last < int64(minKeyframeRequestInterval) || !c.lastKeyframeReq.CompareAndSwap(last, now) {
		return
	}
	_ = pc.WriteRTCP([]rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: ssrc}})
}

// SendKeypress sends a 0x05 key press/release. While any non-modifier key is
// held the client sends 0x09 keepalives every 50 ms on its own timer, so the
// device's 100 ms auto-release only fires if the link really stalls.
func (c *Client) SendKeypress(key byte, press bool) error {
	if err := c.sendHID(c.ch.Load().hid, hidrpc.Keypress{Key: key, Press: press}); err != nil {
		return err
	}
	if key >= 0xe0 && key <= 0xe7 {
		return nil
	}
	c.keysMu.Lock()
	if press {
		c.heldKeys[key] = true
	} else {
		delete(c.heldKeys, key)
	}
	start := len(c.heldKeys) > 0 && !c.keepAliveRun
	if start {
		c.keepAliveRun = true
	}
	c.keysMu.Unlock()
	if start {
		go c.keepAliveLoop()
	}
	return nil
}

func (c *Client) keepAliveLoop() {
	ticker := time.NewTicker(keepAliveInterval)
	defer ticker.Stop()
	for {
		select {
		case <-c.closeCh:
			return
		case <-ticker.C:
		}
		c.keysMu.Lock()
		if len(c.heldKeys) == 0 {
			c.keepAliveRun = false
			c.keysMu.Unlock()
			return
		}
		c.keysMu.Unlock()
		_ = c.sendHID(c.ch.Load().hid, hidrpc.KeypressKeepAlive{})
	}
}

// SendKeypressKeepAlive is kept for callers that drive their own keepalive;
// the client already sends keepalives while keys are held.
func (c *Client) SendKeypressKeepAlive() error {
	return c.sendHID(c.ch.Load().hid, hidrpc.KeypressKeepAlive{})
}

// ReleaseAllKeys releases every key the client believes is held, plus all
// modifiers, with a single empty keyboard report.
func (c *Client) ReleaseAllKeys() error {
	c.keysMu.Lock()
	clear(c.heldKeys)
	c.keysMu.Unlock()
	return c.sendHID(c.ch.Load().hid, hidrpc.KeyboardReport{Modifier: 0, Keys: make([]byte, hidrpc.HidKeyBufferSize)})
}

// SendAbsPointer sends an absolute pointer report. Moves with no buttons go on
// the unreliable channel (a stale move is worthless); reports while a button
// is held or changing go reliable, as in the upstream web UI, so clicks and
// drags are never lost or reordered against a release.
func (c *Client) SendAbsPointer(x, y int32, buttons byte) error {
	ch := c.ch.Load()
	c.pointerMu.Lock()
	reliable := buttons != 0 || buttons != c.lastButtons || !c.pointerReliableOK
	c.lastButtons = buttons
	c.lastX, c.lastY = x, y
	c.pointerReliableOK = true
	c.pointerMu.Unlock()
	dc := ch.hidUnreliable
	if reliable || dc == nil || dc.ReadyState() != webrtc.DataChannelStateOpen {
		dc = ch.hid
	}
	if err := c.sendHID(dc, hidrpc.Pointer{X: x, Y: y, Buttons: buttons}); err != nil {
		log := logging.Subsystem("client")
		log.Debug().Err(err).Int32("x", x).Int32("y", y).Uint8("buttons", buttons).Msg("failed to send absolute pointer")
		return err
	}
	return nil
}

// SendRelMouse sends a relative mouse report on the reliable channel. Moves
// larger than ±127 are split into several reports instead of being clamped.
func (c *Client) SendRelMouse(dx, dy int, buttons byte) error {
	hid := c.ch.Load().hid
	c.pointerMu.Lock()
	c.lastRelButtons = buttons
	c.pointerMu.Unlock()
	for {
		stepX := max(-127, min(127, dx))
		stepY := max(-127, min(127, dy))
		if err := c.sendHID(hid, hidrpc.Mouse{DX: int8(stepX), DY: int8(stepY), Buttons: buttons}); err != nil {
			return err
		}
		dx -= stepX
		dy -= stepY
		if dx == 0 && dy == 0 {
			return nil
		}
	}
}

// ReleasePointerButtons releases any mouse button the client last reported
// as held, for both the absolute and the relative mouse.
func (c *Client) ReleasePointerButtons() error {
	c.pointerMu.Lock()
	absHeld, relHeld := c.lastButtons != 0, c.lastRelButtons != 0
	x, y := c.lastX, c.lastY
	c.pointerMu.Unlock()
	var errs []error
	if absHeld {
		errs = append(errs, c.SendAbsPointer(x, y, 0))
	}
	if relHeld {
		errs = append(errs, c.SendRelMouse(0, 0, 0))
	}
	return errors.Join(errs...)
}

// SendWheel sends a wheel report: over HID-RPC where the firmware takes it
// (in order with pointer reports, no JSON on the device's single core),
// otherwise as a fire-and-forget JSON-RPC call.
func (c *Client) SendWheel(wheelY, wheelX int8) error {
	if c.hidWheel.Load() {
		return c.sendHID(c.ch.Load().hid, hidrpc.Wheel{Y: wheelY, X: wheelX})
	}
	rpc := c.ch.Load().rpc
	if rpc == nil {
		return fmt.Errorf("rpc data channel not ready")
	}
	id := fmt.Sprintf("rpc-%d", c.requestCounter.Add(1))
	data, err := jsonrpc.Marshal(jsonrpc.NewRequest("wheelReport", WheelReportRequest{WheelY: int(wheelY), WheelX: int(wheelX)}, id))
	if err != nil {
		return err
	}
	return rpc.SendText(string(data))
}

// ExecuteKeyboardMacro sends one macro message (at most macroChunkSteps steps
// to stay below the 64 KiB data channel message limit).
func (c *Client) ExecuteKeyboardMacro(isPaste bool, steps []hidrpc.KeyboardMacroStep) error {
	return c.sendHID(c.ch.Load().hid, hidrpc.KeyboardMacroReport{IsPaste: isPaste, Steps: steps})
}

func (c *Client) CancelKeyboardMacro() error {
	return c.sendHID(c.ch.Load().hid, hidrpc.CancelKeyboardMacro{})
}

// TypeMacro sends steps in chunks of at most 128, waiting for the device to
// report each chunk finished before sending the next (a new macro cancels a
// running one on the device). Cancelling ctx stops the device-side macro.
func (c *Client) TypeMacro(ctx context.Context, steps []hidrpc.KeyboardMacroStep) error {
	c.macroMu.Lock()
	defer c.macroMu.Unlock()
	for start := 0; start < len(steps); start += macroChunkSteps {
		chunk := steps[start:min(len(steps), start+macroChunkSteps)]
		var total time.Duration
		for _, s := range chunk {
			total += time.Duration(s.Delay) * time.Millisecond
		}
		if err := c.runMacroChunk(ctx, chunk, total+macroChunkGrace); err != nil {
			return err
		}
	}
	return nil
}

func (c *Client) runMacroChunk(ctx context.Context, chunk []hidrpc.KeyboardMacroStep, timeout time.Duration) error {
	state := make(chan bool, 4)
	c.keysMu.Lock()
	c.macroState = state
	c.keysMu.Unlock()
	defer func() {
		c.keysMu.Lock()
		c.macroState = nil
		c.keysMu.Unlock()
	}()

	if err := c.ExecuteKeyboardMacro(true, chunk); err != nil {
		return err
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	started := false
	for {
		select {
		case <-ctx.Done():
			_ = c.CancelKeyboardMacro()
			// Wait for the device to report the macro stopped, so that
			// acknowledgement cannot be mistaken for the end of a later
			// paste's first chunk.
			if started {
				wait := time.NewTimer(time.Second)
				for done := false; !done; {
					select {
					case running := <-state:
						done = !running
					case <-wait.C:
						done = true
					case <-c.closeCh:
						done = true
					}
				}
				wait.Stop()
			}
			return ctx.Err()
		case <-c.closeCh:
			return ErrClosed
		case <-timer.C:
			return fmt.Errorf("keyboard macro did not finish within %s", timeout)
		case running := <-state:
			if running {
				started = true
			} else if started {
				return nil
			}
		}
	}
}

func (c *Client) noteMacroState(running bool) {
	c.keysMu.Lock()
	ch := c.macroState
	c.keysMu.Unlock()
	if ch != nil {
		select {
		case ch <- running:
		default:
		}
	}
}

func (c *Client) SendSerialText(text string) error {
	if text == "" {
		return nil
	}
	serial := c.ch.Load().serial
	if serial == nil {
		return fmt.Errorf("serial channel not ready")
	}
	data, err := json.Marshal(struct {
		Type string `json:"type"`
		Data string `json:"data"`
	}{Type: "serial", Data: text})
	if err != nil {
		return err
	}
	return serial.SendText(string(data))
}

func (c *Client) SendSerialRaw(text string) error {
	if text == "" {
		return nil
	}
	serial := c.ch.Load().serial
	if serial == nil {
		return fmt.Errorf("serial channel not ready")
	}
	return serial.SendText(text)
}

func (c *Client) openDataChannels(pc *webrtc.PeerConnection) error {
	set := &channels{}
	var err error

	set.rpc, err = pc.CreateDataChannel("rpc", nil)
	if err != nil {
		return err
	}
	c.watchEssentialChannel(set.rpc)
	set.rpc.OnOpen(func() { c.rpcReadyOnce.Do(func() { close(c.rpcReady) }) })
	set.rpc.OnMessage(func(msg webrtc.DataChannelMessage) {
		if !msg.IsString {
			return
		}
		decoded, err := jsonrpc.DecodeMessage(msg.Data)
		if err != nil {
			return
		}
		switch v := decoded.(type) {
		case jsonrpc.Response:
			c.pendingMu.Lock()
			ch := c.pending[fmt.Sprint(v.ID)]
			c.pendingMu.Unlock()
			if ch != nil {
				select {
				case ch <- v:
				default:
				}
			}
		case jsonrpc.Event:
			c.events.put(v)
		}
	})

	set.hid, err = pc.CreateDataChannel("hidrpc", nil)
	if err != nil {
		return err
	}
	c.watchEssentialChannel(set.hid)
	hid := set.hid
	hid.OnOpen(func() { go c.runHIDHandshake(hid) })
	hid.OnMessage(func(msg webrtc.DataChannelMessage) {
		decoded, err := hidrpc.Decode(msg.Data)
		if err != nil {
			return
		}
		switch v := decoded.(type) {
		case hidrpc.Handshake:
			if v.Version <= hidrpc.Version {
				c.hidReadyOnce.Do(func() {
					c.pointerMu.Lock()
					c.pointerReliableOK = false
					c.pointerMu.Unlock()
					close(c.hidReady)
					c.emitLifecycle(LifecycleEvent{Type: "hid_ready"})
					go c.probeFirmwareFeatures()
				})
			}
		case hidrpc.KeyboardMacroState:
			c.noteMacroState(v.State)
			c.emitLifecycle(LifecycleEvent{Type: "paste_state", PasteState: v.State && v.IsPaste})
		case hidrpc.KeyboardLEDState:
			c.emitLifecycle(LifecycleEvent{Type: "keyboard_leds", LEDMask: v.Mask})
		}
	})

	set.hidUnreliable, err = pc.CreateDataChannel("hidrpc-unreliable-ordered", &webrtc.DataChannelInit{
		Ordered:        &[]bool{true}[0],
		MaxRetransmits: &[]uint16{0}[0],
	})
	if err != nil {
		return err
	}
	set.hidNonOrdered, err = pc.CreateDataChannel("hidrpc-unreliable-nonordered", &webrtc.DataChannelInit{
		Ordered:        &[]bool{false}[0],
		MaxRetransmits: &[]uint16{0}[0],
	})
	if err != nil {
		return err
	}

	set.serial, err = pc.CreateDataChannel("serial", nil)
	if err != nil {
		return err
	}
	set.serial.OnOpen(func() {
		c.emitLifecycle(LifecycleEvent{Type: "serial_ready"})
	})
	set.serial.OnError(func(err error) {
		if err != nil {
			c.emitLifecycle(LifecycleEvent{Type: "serial_error", Err: err.Error()})
		}
	})
	set.serial.OnMessage(func(msg webrtc.DataChannelMessage) {
		text := string(msg.Data)
		if text == "" {
			return
		}
		select {
		case c.serialCh <- SerialConsoleEvent{Text: text}:
		default:
		}
	})
	c.ch.Store(set)
	return nil
}

// watchEssentialChannel ends the session when the RPC or HID channel closes:
// without them the session is useless. Other channels (serial, unreliable
// pointer) closing only degrades features.
func (c *Client) watchEssentialChannel(dc *webrtc.DataChannel) {
	dc.OnClose(func() {
		c.handleTransportDisconnect(webrtc.PeerConnectionStateDisconnected, "datachannel:"+dc.Label()+":close")
	})
	dc.OnError(func(err error) {
		if err != nil {
			c.lastError.Store(err.Error())
		}
		c.handleTransportDisconnect(webrtc.PeerConnectionStateFailed, "datachannel:"+dc.Label()+":error")
	})
}

func (c *Client) noteTransportDebug(msg string) {
	c.transportDebug.Store(msg)
}

func (c *Client) HTTPClient() *http.Client {
	return c.authClient.HTTPClient()
}

// LatestFrameInfo returns the newest decoded picture, if the video sink
// keeps one (see Config.NewVideoSink).
func (c *Client) LatestFrameInfo() (image.Image, time.Time) {
	c.videoMu.RLock()
	frames := c.frames
	c.videoMu.RUnlock()
	if frames == nil {
		return nil, time.Time{}
	}
	frame := frames.Latest()
	if frame == nil {
		return nil, time.Time{}
	}
	return frame.Image, frame.At
}

func (c *Client) emitLifecycle(evt LifecycleEvent) {
	if evt.Err != "" {
		c.lastError.Store(evt.Err)
	}
	c.lifecycle.put(evt)
}

// Stats returns the most recent statistics snapshot. The expensive part
// (pion GetStats) runs on the client's own monitor goroutine once a second,
// never on the caller's (UI) thread.
func (c *Client) Stats() StatsSnapshot {
	c.statsMu.Lock()
	stats := c.stats
	c.statsMu.Unlock()
	stats.SignalingMode = c.SignalingMode()
	stats.HIDReady = c.HIDReady()
	if frame, _ := c.LatestFrameInfo(); frame != nil {
		b := frame.Bounds()
		stats.FrameWidth, stats.FrameHeight = b.Dx(), b.Dy()
		stats.VideoReady = true
	}
	c.videoMu.RLock()
	if c.assembler != nil {
		as := c.assembler.Stats()
		stats.FramesDropped = as.DroppedFrames
		stats.KeyframeWaits = as.KeyframeWaits
		stats.LateRepairs = as.LateRepairs
		if c.frames == nil {
			stats.VideoReady = as.Frames > 0
		}
	}
	if c.frames != nil {
		stats.FramesDecoded = uint32(c.frames.DecodedFrames())
	}
	stats.VideoCodec = c.videoCodec
	c.videoMu.RUnlock()
	if pc := c.peer(); pc != nil {
		stats.RTCState = pc.ConnectionState()
	}
	if err, ok := c.lastError.Load().(string); ok {
		stats.LastError = err
	}
	if debug, ok := c.transportDebug.Load().(string); ok {
		stats.TransportDebug = debug
	}
	return stats
}

// watchInputChannels logs when the input data channels stop draining (data
// waits and no byte has been acknowledged for over a second, an SCTP
// retransmission stall) and how long it lasted, so a stuck keyboard or
// pointer leaves a trace in the app log. Unacknowledged data alone is
// normal: SCTP delays acknowledgements by up to 200 ms.
func (c *Client) watchInputChannels(now time.Time) {
	ch := c.ch.Load()
	if ch == nil {
		return
	}
	sent := c.hidBytesSent.Load()
	var buffered uint64
	for _, dc := range []*webrtc.DataChannel{ch.hid, ch.hidUnreliable} {
		if dc != nil && dc.ReadyState() == webrtc.DataChannelStateOpen {
			buffered += dc.BufferedAmount()
		}
	}
	acked := sent - min(buffered, sent)
	progressed := acked != c.inputAcked
	c.inputAcked = acked
	log := logging.Subsystem("client")
	switch {
	case buffered == 0 || progressed:
		if c.inputStallLogged {
			log.Error().Dur("stalled", now.Sub(c.inputStallSince)).Msg("input data channels recovered")
		}
		c.inputStallSince, c.inputStallLogged = time.Time{}, false
		if buffered > 0 {
			c.inputStallSince = now
		}
	case c.inputStallSince.IsZero():
		c.inputStallSince = now
	case !c.inputStallLogged && now.Sub(c.inputStallSince) >= time.Second:
		c.inputStallLogged = true
		log.Error().Uint64("bufferedBytes", buffered).Msg("input data channels stalled: nothing acknowledged for over a second")
	}
}

func (c *Client) monitorStats() {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		c.collectStats(time.Now())
		select {
		case <-c.closeCh:
			return
		case <-ticker.C:
		}
	}
}

func (c *Client) collectStats(now time.Time) {
	pc := c.peer()
	if pc == nil || pc.ConnectionState() == webrtc.PeerConnectionStateClosed {
		return
	}
	c.watchInputChannels(now)
	report := pc.GetStats()
	var snap StatsSnapshot
	// RTT of the pair ICE actually uses; other succeeded pairs (other
	// interfaces, VPNs) can differ by orders of magnitude.
	selectedPair, localID, remoteID := "", "", ""
	for _, raw := range report {
		if t, ok := raw.(webrtc.TransportStats); ok && t.SelectedCandidatePairID != "" {
			selectedPair = t.SelectedCandidatePairID
		}
	}
	var framesDecoded uint32
	c.videoMu.RLock()
	if c.frames != nil {
		framesDecoded = uint32(c.frames.DecodedFrames())
	} else if c.assembler != nil {
		framesDecoded = uint32(c.assembler.Stats().Frames)
	}
	c.videoMu.RUnlock()
	for _, raw := range report {
		switch v := raw.(type) {
		case webrtc.InboundRTPStreamStats:
			if v.Kind != "video" {
				continue
			}
			snap.BytesReceived = v.BytesReceived
			snap.PacketsLost = v.PacketsLost
			snap.NACKsSent = v.NACKCount
			snap.JitterMs = v.Jitter * 1000
			snap.FramesRendered = v.FramesRendered
		case webrtc.ICECandidatePairStats:
			selected := v.ID == selectedPair || (selectedPair == "" && v.Nominated)
			if selected && v.CurrentRoundTripTime > 0 {
				snap.RoundTripMs = v.CurrentRoundTripTime * 1000
			}
			if selected {
				localID, remoteID = v.LocalCandidateID, v.RemoteCandidateID
			}
		}
	}
	if localID != "" {
		var local, remote net.IP
		for _, raw := range report {
			if v, ok := raw.(webrtc.ICECandidateStats); ok {
				switch v.ID {
				case localID:
					local = net.ParseIP(v.IP)
				case remoteID:
					remote = net.ParseIP(v.IP)
				}
			}
		}
		if local != nil && remote != nil {
			snap.Path, snap.PathRemote = pathKind(local, remote), remote.String()
		}
	}
	if snap.RoundTripMs > 0 {
		c.rttNanos.Store(int64(snap.RoundTripMs * float64(time.Millisecond)))
	}
	c.statsMu.Lock()
	c.statsHistory = append(c.statsHistory, statsSample{at: now, bytesReceived: snap.BytesReceived, framesDecoded: framesDecoded})
	cutoff := now.Add(-3 * time.Second)
	trimmed := c.statsHistory[:0]
	for _, sample := range c.statsHistory {
		if sample.at.Before(cutoff) && len(c.statsHistory) > 2 {
			continue
		}
		trimmed = append(trimmed, sample)
	}
	c.statsHistory = trimmed
	snap.BitrateKbps, snap.FramesPerSecond = computeSmoothedRates(c.statsHistory)
	snap.SampledAt = now
	c.stats = snap
	c.statsMu.Unlock()
}

func (c *Client) runHIDHandshake(dc *webrtc.DataChannel) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	send := func() {
		if dc.ReadyState() == webrtc.DataChannelStateOpen {
			_ = c.sendHID(dc, hidrpc.Handshake{Version: hidrpc.Version})
		}
	}
	send()
	for {
		select {
		case <-c.closeCh:
			return
		case <-c.hidReady:
			return
		case <-ticker.C:
			if dc.ReadyState() != webrtc.DataChannelStateOpen {
				return
			}
			send()
		}
	}
}

// restrictICEToLoopback limits candidate gathering to 127.0.0.1.
func restrictICEToLoopback(se *webrtc.SettingEngine) {
	se.SetIncludeLoopbackCandidate(true)
	se.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	se.SetIPFilter(func(ip net.IP) bool { return ip.IsLoopback() })
}

// RestrictICEToLoopback exposes the loopback-only ICE setup for test
// servers (the emulator).
func RestrictICEToLoopback(se *webrtc.SettingEngine) { restrictICEToLoopback(se) }

func decodeAnswer(encoded string) (webrtc.SessionDescription, error) {
	rawAnswer, err := signaling.DecodeSDP(encoded)
	if err != nil {
		return webrtc.SessionDescription{}, err
	}
	var answer webrtc.SessionDescription
	if err := json.Unmarshal(rawAnswer, &answer); err != nil {
		return webrtc.SessionDescription{}, err
	}
	return answer, nil
}

func (c *Client) writeSignal(msg any) error {
	c.signalMu.Lock()
	defer c.signalMu.Unlock()
	if c.signalConn == nil {
		return fmt.Errorf("signaling connection not ready")
	}
	_ = c.signalConn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	return c.signalConn.WriteJSON(msg)
}

// Protocol additions of the fork firmware, as getFirmwareFeatures names them.
const (
	// FeatureHIDRPCWheel: wheel reports over HID-RPC (D12).
	FeatureHIDRPCWheel = "hidrpcWheel"
	// FeatureRefreshRegions: the refreshRegions RPC and setVideoEncoderParams'
	// autoRefresh, so the client plans still refreshes (D13).
	FeatureRefreshRegions = "refreshRegions"
)

// probeFirmwareFeatures asks which protocol additions the firmware has (the
// fork's getFirmwareFeatures; stock firmware has no such method).
func (c *Client) probeFirmwareFeatures() {
	defer close(c.featuresProbed)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var features []string
	if err := c.Call(ctx, "getFirmwareFeatures", nil, &features); err != nil {
		return
	}
	c.features.Store(&features)
	c.hidWheel.Store(slices.Contains(features, FeatureHIDRPCWheel))
}

// HasFirmwareFeature reports whether getFirmwareFeatures listed name. It
// waits for the probe, which starts once HID-RPC is ready; false if ctx ends
// or the client closes first.
func (c *Client) HasFirmwareFeature(ctx context.Context, name string) bool {
	select {
	case <-c.featuresProbed:
	case <-ctx.Done():
		return false
	case <-c.closeCh:
		return false
	}
	features := c.features.Load()
	return features != nil && slices.Contains(*features, name)
}
