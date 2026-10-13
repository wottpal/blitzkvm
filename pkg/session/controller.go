package session

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/webrtc/v4"

	"github.com/wottpal/blitzkvm/pkg/client"
	"github.com/wottpal/blitzkvm/pkg/hotkeys"
	"github.com/wottpal/blitzkvm/pkg/input"
	"github.com/wottpal/blitzkvm/pkg/logging"
	"github.com/wottpal/blitzkvm/pkg/protocol/auth"
	"github.com/wottpal/blitzkvm/pkg/protocol/tlspin"
	"github.com/wottpal/blitzkvm/pkg/video"
	"github.com/wottpal/blitzkvm/pkg/virtualmedia"
)

//go:generate go tool github.com/dmarkham/enumer -type=Phase -linecomment -text -output controller_enums.go

type Phase uint8

const (
	PhaseIdle         Phase = iota // idle
	PhaseConnecting                // connecting
	PhaseConnected                 // connected
	PhaseReconnecting              // reconnecting
	PhaseDisconnected              // disconnected
	PhaseAuthFailed                // auth_failed
	PhaseOtherSession              // other_session
	PhaseRebooting                 // rebooting
	PhaseFatal                     // fatal_error
)

type Config struct {
	BaseURL         string
	Password        string
	RPCTimeout      time.Duration
	MutationTimeout time.Duration
	// ConnectTimeout bounds each connection attempt (default 15 s).
	ConnectTimeout time.Duration
	Reconnect      bool
	ReconnectBase  time.Duration
	ReconnectMax   time.Duration
	// ExpectedDeviceID makes every connect verify the device's identity
	// before any input is sent (see client.Config.ExpectedDeviceID).
	ExpectedDeviceID string
	// CertSHA256 pins an https device's certificate authority (see
	// tlspin); empty trusts the first one seen, reported in the snapshot.
	CertSHA256 string
	// OnSerialText receives serial console output as it arrives (while the
	// serial-console extension is active), in addition to the snapshot's
	// scrollback. It must not block.
	OnSerialText func(string)
	// ICELoopbackOnly restricts ICE to loopback (tests against a local
	// emulator).
	ICELoopbackOnly bool
	// OfferH265 lets the device stream H.265; only for consumers that can
	// decode it (see client.Config.OfferH265).
	OfferH265 bool
	// OnAccessUnit forwards video access units instead of decoding them.
	OnAccessUnit func(video.AccessUnit)
	// NewVideoSink creates the video decoder (see client.Config).
	NewVideoSink func(ctx context.Context, codec video.Codec) (video.Sink, error)
	// AutoQuality adapts the device's stream quality to the link (see
	// autoquality.go); otherwise QualityLevel (a ladder level name, if set)
	// is applied on each connect.
	AutoQuality  bool
	QualityLevel string
	// ClientRefresh: the client refreshes still pictures itself
	// (refreshRegions), so on firmware that offers it every level applied
	// live turns the device's own still refresh off (autoRefresh). Only for
	// clients that plan refreshes and send input.
	ClientRefresh bool
	// OnAudioPacket receives the device's audio while Audio is on (see
	// client.Config.OnAudioPacket); nil never asks for it.
	OnAudioPacket func(client.AudioPacket)
	// Audio asks the device for its audio (SetAudio changes it).
	Audio bool
	// EnableDeviceAudio turns the device's audio on where it is off, once,
	// and reconnects so the device attaches it. Only for clients that may
	// change device settings.
	EnableDeviceAudio bool
}

type Snapshot struct {
	Phase                  Phase
	Status                 string
	BaseURL                string
	DeviceID               string
	Hostname               string
	ActiveExtension        string
	ATXState               *ATXState
	SerialSettings         *SerialSettings
	SerialConsoleReady     bool
	SerialConsoleBuffer    string
	SerialConsoleError     string
	SerialConsoleTruncated bool
	Quality                float64
	KeyboardLayout         string
	EDID                   string
	AppVersion             string
	SystemVersion          string
	AppUpdateAvailable     bool
	SystemUpdateAvailable  bool
	HIDReady               bool
	VideoReady             bool
	LastError              string
	RTCState               webrtc.PeerConnectionState
	SignalingMode          client.SignalingMode
	PasteInProgress        bool
	// VideoSignal is "ready" or the device's HDMI error ("no_signal",
	// "no_lock", "out_of_range"); empty until the first videoInputState.
	VideoSignal    string
	VideoWidth     int
	VideoHeight    int
	VideoFPS       float64
	KeyboardLEDs   byte
	USBState       string
	FailsafeActive bool
	FailsafeReason string
	// CertSHA256 is the pinned certificate authority of an https device.
	CertSHA256 string
	// AutoQuality is on when the quality follows the link; QualityLevel
	// names the current rung of the ladder.
	AutoQuality  bool
	QualityLevel string
	// ClientRefresh is on while the device leaves still refreshes to the
	// client (Config.ClientRefresh on firmware that offers it, with a level
	// applied live); MinQP and StillQP are that level's QP floor and still
	// refresh QP.
	ClientRefresh bool
	MinQP         int
	StillQP       int
}

type Controller struct {
	cfg  Config
	auth *auth.Client
	pin  *tlspin.Pin

	mu           sync.RWMutex
	snapshot     Snapshot
	serialLog    serialScrollback
	current      *client.Client
	runParent    context.Context
	cancelRun    context.CancelFunc
	running      bool
	runGen       uint64
	runDone      chan struct{}
	reconnectNow bool
	// wake interrupts a retry wait (ReconnectNow).
	wake chan struct{}

	// autoRunning marks clients with a running quality governor.
	autoRunning map[*client.Client]bool
	// encoderParamsOK caches, for encoderParamsClient, whether the device
	// takes live encoder parameters (patched firmware).
	encoderParamsClient *client.Client
	encoderParamsOK     bool

	// audio is Config.Audio as SetAudio left it (read for every packet);
	// audioTurnedOn is set once the controller tried to turn the device's
	// audio on, which it does at most once.
	audio         atomic.Bool
	audioTurnedOn bool

	pasteMu     sync.Mutex
	pasteCancel context.CancelFunc
	pasteGen    uint64
}

const (
	serialScrollbackMaxLines = 5000
	serialScrollbackMaxBytes = 1 << 20
)

type serialScrollback struct {
	chunks    []string
	lineCount int
	byteCount int
	truncated bool
}

func (s *serialScrollback) Reset() {
	s.chunks = nil
	s.lineCount = 0
	s.byteCount = 0
	s.truncated = false
}

func (s *serialScrollback) Append(text string) (string, bool) {
	if text == "" {
		return s.String(), s.truncated
	}
	s.chunks = append(s.chunks, text)
	s.byteCount += len(text)
	s.lineCount += serialChunkLines(text)
	for s.byteCount > serialScrollbackMaxBytes || s.lineCount > serialScrollbackMaxLines {
		if len(s.chunks) == 0 {
			break
		}
		dropped := s.chunks[0]
		s.chunks = s.chunks[1:]
		s.byteCount -= len(dropped)
		s.lineCount -= serialChunkLines(dropped)
		s.truncated = true
	}
	return s.String(), s.truncated
}

func (s *serialScrollback) String() string {
	if len(s.chunks) == 0 {
		return ""
	}
	return strings.Join(s.chunks, "")
}

func serialChunkLines(text string) int {
	if text == "" {
		return 0
	}
	return strings.Count(text, "\n") + 1
}

func defaultSerialSettings() SerialSettings {
	return SerialSettings{
		BaudRate: 9600,
		DataBits: 8,
		Parity:   "none",
		StopBits: "1",
		Terminator: Terminator{
			Label: "LF (\\n)",
			Value: "\n",
		},
		HideSerialSettings: false,
		EnableEcho:         false,
		NormalizeMode:      "names",
		NormalizeLineEnd:   "keep",
		TabRender:          "",
		PreserveANSI:       true,
		ShowNLTag:          true,
		Buttons:            []QuickButton{},
	}
}

func New(cfg Config) *Controller {
	if cfg.RPCTimeout == 0 {
		cfg.RPCTimeout = 5 * time.Second
	}
	if cfg.MutationTimeout == 0 {
		cfg.MutationTimeout = 20 * time.Second
	}
	if cfg.ReconnectBase == 0 {
		cfg.ReconnectBase = 500 * time.Millisecond
	}
	if cfg.ReconnectMax == 0 {
		cfg.ReconnectMax = 10 * time.Second
	}
	if cfg.ConnectTimeout == 0 {
		cfg.ConnectTimeout = 15 * time.Second
	}
	// One cookie jar for the controller's lifetime: reconnects reuse the
	// session cookie instead of logging in (each login rotates the device's
	// token, logging out other clients, and writes to its flash).
	pin := tlspin.New(cfg.CertSHA256)
	authClient, err := auth.NewClient(pin.TLSConfig())
	if err != nil {
		panic(fmt.Sprintf("auth client: %v", err))
	}
	c := &Controller{
		cfg:  cfg,
		auth: authClient,
		pin:  pin,
		wake: make(chan struct{}, 1),
		snapshot: Snapshot{
			Phase:       PhaseIdle,
			Status:      "idle",
			BaseURL:     cfg.BaseURL,
			AutoQuality: cfg.AutoQuality,
		},
	}
	c.audio.Store(cfg.Audio)
	return c
}

func (c *Controller) Snapshot() Snapshot {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.snapshot
}

func (c *Controller) SetPassword(password string) {
	c.mu.Lock()
	c.cfg.Password = password
	c.mu.Unlock()
}

func (c *Controller) Reboot() error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	err := current.Reboot(ctx)
	if errors.Is(err, client.ErrClosed) && c.Snapshot().Phase == PhaseRebooting {
		// The device announced the reboot (willReboot) and the session
		// ended before its reply, as firmware does.
		return nil
	}
	return err
}

func (c *Controller) TryUpdate() error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	return current.TryUpdate(ctx)
}

func (c *Controller) FactoryReset() error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	return current.FactoryReset(ctx)
}

func (c *Controller) SetQuality(value float64) error {
	if err := c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetStreamQualityFactor(ctx, value)
	}, func(ctx context.Context) (bool, error) {
		current := c.clientIfConnected()
		if current == nil {
			return false, errors.New("client not connected")
		}
		quality, err := current.GetStreamQualityFactor(ctx)
		if err != nil {
			return false, err
		}
		return quality == value, nil
	}); err != nil {
		return err
	}
	c.setState(func(s *Snapshot) {
		s.Quality = value
	})
	return nil
}

func (c *Controller) SetKeyboardLayout(layout string) error {
	layout = normalizeKeyboardLayoutCode(layout)
	if layout == "" {
		return errors.New("keyboard layout is required")
	}
	if err := c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetKeyboardLayout(ctx, layout)
	}, func(ctx context.Context) (bool, error) {
		current := c.clientIfConnected()
		if current == nil {
			return false, errors.New("client not connected")
		}
		currentLayout, err := current.GetKeyboardLayout(ctx)
		if err != nil {
			return false, err
		}
		return normalizeKeyboardLayoutCode(currentLayout) == layout, nil
	}); err != nil {
		return err
	}
	c.setState(func(s *Snapshot) {
		s.KeyboardLayout = layout
	})
	return nil
}

func (c *Controller) SetTLSMode(mode TLSMode) error {
	if mode == "" {
		return errors.New("tls mode is required")
	}
	return c.SetTLSState(TLSState{Mode: mode})
}

func (c *Controller) SetDisplayRotation(rotation DisplayRotation) error {
	if rotation == "" {
		return errors.New("display rotation is required")
	}
	return c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetDisplayRotation(ctx, string(rotation))
	}, func(ctx context.Context) (bool, error) {
		current, err := c.GetDisplayRotation(ctx)
		if err != nil {
			return false, err
		}
		return current == rotation, nil
	})
}

func (c *Controller) SetUSBEmulation(enabled bool) error {
	return c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetUSBEmulationState(ctx, enabled)
	}, func(ctx context.Context) (bool, error) {
		current, err := c.GetUSBEmulationState(ctx)
		if err != nil {
			return false, err
		}
		return current == enabled, nil
	})
}

func (c *Controller) SetATXPowerAction(action ATXPowerAction) error {
	if action == "" {
		return errors.New("ATX power action is required")
	}
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	return current.SetATXPowerAction(ctx, string(action))
}

func (c *Controller) SetActiveExtension(extensionID string) error {
	if err := c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetActiveExtension(ctx, extensionID)
	}, func(ctx context.Context) (bool, error) {
		current, err := c.GetActiveExtension(ctx)
		if err != nil {
			return false, err
		}
		return current == extensionID, nil
	}); err != nil {
		return err
	}

	c.setState(func(s *Snapshot) {
		s.ActiveExtension = extensionID
		s.SerialConsoleError = ""
	})
	if extensionID != "serial-console" {
		c.setState(func(s *Snapshot) {
			s.SerialSettings = nil
		})
		return nil
	}

	getCtx, getCancel := context.WithTimeout(context.Background(), c.cfg.RPCTimeout)
	defer getCancel()
	settings, err := c.GetSerialSettings(getCtx)
	if err != nil {
		defaults := defaultSerialSettings()
		c.setState(func(s *Snapshot) {
			s.SerialSettings = &defaults
			s.SerialConsoleError = err.Error()
		})
		return nil
	}
	c.setState(func(s *Snapshot) {
		s.SerialSettings = settings
	})
	return nil
}

func (c *Controller) SetDCPowerState(enabled bool) error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	return current.SetDCPowerState(ctx, enabled)
}

func (c *Controller) SetDCRestoreState(state int) error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	return current.SetDCRestoreState(ctx, state)
}

func (c *Controller) SetSerialSettings(settings SerialSettings) error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	buttons := make([]client.QuickButton, 0, len(settings.Buttons))
	for _, button := range settings.Buttons {
		buttons = append(buttons, client.QuickButton{
			ID:      button.ID,
			Label:   button.Label,
			Command: button.Command,
			Terminator: client.Terminator{
				Label: button.Terminator.Label,
				Value: button.Terminator.Value,
			},
			Sort: button.Sort,
		})
	}
	setCtx, setCancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer setCancel()
	if err := current.SetSerialSettings(setCtx, client.SerialSettings{
		BaudRate: settings.BaudRate,
		DataBits: settings.DataBits,
		Parity:   settings.Parity,
		StopBits: settings.StopBits,
		Terminator: client.Terminator{
			Label: settings.Terminator.Label,
			Value: settings.Terminator.Value,
		},
		HideSerialSettings: settings.HideSerialSettings,
		EnableEcho:         settings.EnableEcho,
		NormalizeMode:      settings.NormalizeMode,
		NormalizeLineEnd:   settings.NormalizeLineEnd,
		TabRender:          settings.TabRender,
		PreserveANSI:       settings.PreserveANSI,
		ShowNLTag:          settings.ShowNLTag,
		Buttons:            buttons,
	}); err != nil {
		return err
	}
	settingsCopy := settings
	c.setState(func(s *Snapshot) {
		s.SerialSettings = &settingsCopy
		s.SerialConsoleError = ""
	})
	return nil
}

func (c *Controller) SetSerialCommandHistory(history []string) error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	return current.SetSerialCommandHistory(ctx, history)
}

func (c *Controller) SendCustomCommand(command string) error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	return current.SendCustomCommand(ctx, command)
}

func (c *Controller) SendSerialText(text string) error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	return current.SendSerialText(text)
}

func (c *Controller) SendSerialRaw(text string) error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	return current.SendSerialRaw(text)
}

func (c *Controller) SendSerialTerminator() error {
	c.mu.RLock()
	settings := c.snapshot.SerialSettings
	c.mu.RUnlock()

	terminator := "\n"
	if settings != nil && settings.Terminator.Value != "" {
		terminator = settings.Terminator.Value
	}
	return c.SendSerialRaw(terminator)
}

func (c *Controller) SetUSBDevices(devices USBDevices) error {
	return c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetUSBDevices(ctx, client.USBDevices{
			AbsoluteMouse: devices.AbsoluteMouse,
			RelativeMouse: devices.RelativeMouse,
			Keyboard:      devices.Keyboard,
			MassStorage:   devices.MassStorage,
			SerialConsole: devices.SerialConsole,
			Audio:         devices.Audio,
			Network:       devices.Network,
		})
	}, func(ctx context.Context) (bool, error) {
		current, err := c.GetUSBDevices(ctx)
		if err != nil {
			return false, err
		}
		return current == devices, nil
	})
}

func (c *Controller) SetUSBNetworkConfig(cfg USBNetworkConfig) error {
	return c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetUSBNetworkConfig(ctx, client.USBNetworkConfig{
			Enabled:         cfg.Enabled,
			HostPreset:      cfg.HostPreset,
			Protocol:        cfg.Protocol,
			SharingMode:     cfg.SharingMode,
			UplinkMode:      cfg.UplinkMode,
			UplinkInterface: cfg.UplinkInterface,
			IPv4SubnetCIDR:  cfg.IPv4SubnetCIDR,
			DHCPEnabled:     cfg.DHCPEnabled,
			DNSProxyEnabled: cfg.DNSProxyEnabled,
		})
	}, func(ctx context.Context) (bool, error) {
		current, err := c.GetUSBNetworkConfig(ctx)
		if err != nil {
			return false, err
		}
		return current == cfg, nil
	})
}

func (c *Controller) SetNetworkSettings(settings NetworkSettings) error {
	if strings.TrimSpace(settings.DHCPClient) == "" &&
		strings.TrimSpace(settings.Hostname) == "" &&
		strings.TrimSpace(settings.Domain) == "" &&
		strings.TrimSpace(settings.HTTPProxy) == "" &&
		strings.TrimSpace(settings.IPv4Mode) == "" &&
		settings.IPv4Static == nil &&
		strings.TrimSpace(settings.IPv6Mode) == "" &&
		settings.IPv6Static == nil &&
		strings.TrimSpace(settings.LLDPMode) == "" &&
		len(settings.LLDPTxTLVs) == 0 &&
		strings.TrimSpace(settings.MDNSMode) == "" &&
		strings.TrimSpace(settings.TimeSyncMode) == "" &&
		len(settings.TimeSyncOrdering) == 0 &&
		!settings.TimeSyncDisableFallback &&
		settings.TimeSyncParallel == 0 &&
		len(settings.TimeSyncNTPServers) == 0 &&
		len(settings.TimeSyncHTTPUrls) == 0 {
		return errors.New("network settings are required")
	}
	return c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetNetworkSettings(ctx, networkSettingsToClient(settings))
	}, func(ctx context.Context) (bool, error) {
		current, err := c.GetNetworkSettings(ctx)
		if err != nil {
			return false, err
		}
		return reflect.DeepEqual(current, settings), nil
	})
}

func (c *Controller) GetCloudState(ctx context.Context) (CloudState, error) {
	current := c.clientIfConnected()
	if current == nil {
		return CloudState{}, errors.New("client not connected")
	}
	state, err := current.GetCloudState(ctx)
	if err != nil {
		return CloudState{}, err
	}
	return CloudState{
		Connected: state.Connected,
		URL:       state.URL,
		AppURL:    state.AppURL,
	}, nil
}

func (c *Controller) GetActiveExtension(ctx context.Context) (string, error) {
	current := c.clientIfConnected()
	if current == nil {
		return "", errors.New("client not connected")
	}
	return current.GetActiveExtension(ctx)
}

func (c *Controller) GetATXState(ctx context.Context) (*ATXState, error) {
	current := c.clientIfConnected()
	if current == nil {
		return nil, errors.New("client not connected")
	}
	state, err := current.GetATXState(ctx)
	if err != nil {
		return nil, err
	}
	return &ATXState{
		Power: state.Power,
		HDD:   state.HDD,
	}, nil
}

func (c *Controller) GetDCPowerState(ctx context.Context) (*DCPowerState, error) {
	current := c.clientIfConnected()
	if current == nil {
		return nil, errors.New("client not connected")
	}
	state, err := current.GetDCPowerState(ctx)
	if err != nil {
		return nil, err
	}
	return &DCPowerState{
		IsOn:         state.IsOn,
		Voltage:      state.Voltage,
		Current:      state.Current,
		Power:        state.Power,
		RestoreState: state.RestoreState,
	}, nil
}

func (c *Controller) GetSerialSettings(ctx context.Context) (*SerialSettings, error) {
	current := c.clientIfConnected()
	if current == nil {
		return nil, errors.New("client not connected")
	}
	settings, err := current.GetSerialSettings(ctx)
	if err != nil {
		return nil, err
	}
	buttons := make([]QuickButton, 0, len(settings.Buttons))
	for _, button := range settings.Buttons {
		buttons = append(buttons, QuickButton{
			ID:      button.ID,
			Label:   button.Label,
			Command: button.Command,
			Terminator: Terminator{
				Label: button.Terminator.Label,
				Value: button.Terminator.Value,
			},
			Sort: button.Sort,
		})
	}
	return &SerialSettings{
		BaudRate: settings.BaudRate,
		DataBits: settings.DataBits,
		Parity:   settings.Parity,
		StopBits: settings.StopBits,
		Terminator: Terminator{
			Label: settings.Terminator.Label,
			Value: settings.Terminator.Value,
		},
		HideSerialSettings: settings.HideSerialSettings,
		EnableEcho:         settings.EnableEcho,
		NormalizeMode:      settings.NormalizeMode,
		NormalizeLineEnd:   settings.NormalizeLineEnd,
		TabRender:          settings.TabRender,
		PreserveANSI:       settings.PreserveANSI,
		ShowNLTag:          settings.ShowNLTag,
		Buttons:            buttons,
	}, nil
}

func (c *Controller) GetSerialCommandHistory(ctx context.Context) ([]string, error) {
	current := c.clientIfConnected()
	if current == nil {
		return nil, errors.New("client not connected")
	}
	return current.GetSerialCommandHistory(ctx)
}

func (c *Controller) GetLocalAccessState(ctx context.Context) (LocalAuthMode, bool, error) {
	current := c.clientIfConnected()
	if current == nil {
		return LocalAuthModeUnknown, false, errors.New("client not connected")
	}
	info, err := current.DeviceInfo(ctx)
	if err != nil {
		return LocalAuthModeUnknown, false, err
	}
	return sessionLocalAuthMode(info.AuthMode), info.LoopbackOnly, nil
}

func (c *Controller) GetTLSState(ctx context.Context) (TLSState, error) {
	current := c.clientIfConnected()
	if current == nil {
		return TLSState{}, errors.New("client not connected")
	}
	state, err := current.GetTLSState(ctx)
	if err != nil {
		return TLSState{}, err
	}
	return TLSState{
		Mode:        TLSMode(state.Mode),
		Certificate: state.Certificate,
		PrivateKey:  state.PrivateKey,
	}, nil
}

func (c *Controller) SetTLSState(state TLSState) error {
	if state.Mode == TLSModeUnknown {
		return errors.New("tls mode is required")
	}
	if state.Mode == TLSModeCustom {
		if strings.TrimSpace(state.Certificate) == "" {
			return errors.New("certificate is required for custom TLS")
		}
		if strings.TrimSpace(state.PrivateKey) == "" {
			return errors.New("private key is required for custom TLS")
		}
	}
	return c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetTLSState(ctx, client.TLSState{
			Mode:        string(state.Mode),
			Certificate: state.Certificate,
			PrivateKey:  state.PrivateKey,
		})
	}, func(ctx context.Context) (bool, error) {
		current, err := c.GetTLSState(ctx)
		if err != nil {
			return false, err
		}
		if current.Mode != state.Mode {
			return false, nil
		}
		if state.Mode != TLSModeCustom {
			return true, nil
		}
		return current.Certificate == state.Certificate && current.PrivateKey == state.PrivateKey, nil
	})
}

func (c *Controller) CreateLocalPassword(password string) error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	return current.CreateLocalPassword(ctx, password)
}

func (c *Controller) UpdateLocalPassword(oldPassword, newPassword string) error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	return current.UpdateLocalPassword(ctx, oldPassword, newPassword)
}

func (c *Controller) DeleteLocalPassword(password string) error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	return current.DeleteLocalPassword(ctx, password)
}

func (c *Controller) GetUSBEmulationState(ctx context.Context) (bool, error) {
	current := c.clientIfConnected()
	if current == nil {
		return false, errors.New("client not connected")
	}
	return current.GetUSBEmulationState(ctx)
}

func (c *Controller) GetUSBConfig(ctx context.Context) (USBConfig, error) {
	current := c.clientIfConnected()
	if current == nil {
		return USBConfig{}, errors.New("client not connected")
	}
	cfg, err := current.GetUSBConfig(ctx)
	if err != nil {
		return USBConfig{}, err
	}
	return USBConfig{
		VendorID:     cfg.VendorID,
		ProductID:    cfg.ProductID,
		SerialNumber: cfg.SerialNumber,
		Manufacturer: cfg.Manufacturer,
		Product:      cfg.Product,
	}, nil
}

func (c *Controller) GetUSBDevices(ctx context.Context) (USBDevices, error) {
	current := c.clientIfConnected()
	if current == nil {
		return USBDevices{}, errors.New("client not connected")
	}
	devices, err := current.GetUSBDevices(ctx)
	if err != nil {
		return USBDevices{}, err
	}
	return USBDevices{
		AbsoluteMouse: devices.AbsoluteMouse,
		RelativeMouse: devices.RelativeMouse,
		Keyboard:      devices.Keyboard,
		MassStorage:   devices.MassStorage,
		SerialConsole: devices.SerialConsole,
		Audio:         devices.Audio,
		Network:       devices.Network,
	}, nil
}

func (c *Controller) GetUSBNetworkConfig(ctx context.Context) (USBNetworkConfig, error) {
	current := c.clientIfConnected()
	if current == nil {
		return USBNetworkConfig{}, errors.New("client not connected")
	}
	cfg, err := current.GetUSBNetworkConfig(ctx)
	if err != nil {
		return USBNetworkConfig{}, err
	}
	return USBNetworkConfig{
		Enabled:         cfg.Enabled,
		HostPreset:      cfg.HostPreset,
		Protocol:        cfg.Protocol,
		SharingMode:     cfg.SharingMode,
		UplinkMode:      cfg.UplinkMode,
		UplinkInterface: cfg.UplinkInterface,
		IPv4SubnetCIDR:  cfg.IPv4SubnetCIDR,
		DHCPEnabled:     cfg.DHCPEnabled,
		DNSProxyEnabled: cfg.DNSProxyEnabled,
	}, nil
}

func (c *Controller) GetDisplayRotation(ctx context.Context) (DisplayRotation, error) {
	current := c.clientIfConnected()
	if current == nil {
		return DisplayRotationUnknown, errors.New("client not connected")
	}
	state, err := current.GetDisplayRotation(ctx)
	if err != nil {
		return DisplayRotationUnknown, err
	}
	return DisplayRotation(state.Rotation), nil
}

func (c *Controller) GetNetworkSettings(ctx context.Context) (NetworkSettings, error) {
	current := c.clientIfConnected()
	if current == nil {
		return NetworkSettings{}, errors.New("client not connected")
	}
	settings, err := current.GetNetworkSettings(ctx)
	if err != nil {
		return NetworkSettings{}, err
	}
	return networkSettingsFromClient(settings), nil
}

func (c *Controller) GetNetworkState(ctx context.Context) (NetworkState, error) {
	current := c.clientIfConnected()
	if current == nil {
		return NetworkState{}, errors.New("client not connected")
	}
	state, err := current.GetNetworkState(ctx)
	if err != nil {
		return NetworkState{}, err
	}
	var lease *DHCPLease
	if state.DHCPLease != nil {
		lease = &DHCPLease{
			IP:              state.DHCPLease.IP,
			Netmask:         state.DHCPLease.Netmask,
			DNSServers:      append([]string(nil), state.DHCPLease.DNSServers...),
			Broadcast:       state.DHCPLease.Broadcast,
			Domain:          state.DHCPLease.Domain,
			NTPServers:      append([]string(nil), state.DHCPLease.NTPServers...),
			Hostname:        state.DHCPLease.Hostname,
			Routers:         append([]string(nil), state.DHCPLease.Routers...),
			ServerID:        state.DHCPLease.ServerID,
			LeaseExpiry:     state.DHCPLease.LeaseExpiry,
			MTU:             state.DHCPLease.MTU,
			TTL:             state.DHCPLease.TTL,
			BootpNextServer: state.DHCPLease.BootpNextServer,
			BootpServerName: state.DHCPLease.BootpServerName,
			BootpFile:       state.DHCPLease.BootpFile,
			DHCPClient:      state.DHCPLease.DHCPClient,
		}
	}
	addresses := make([]IPv6Address, 0, len(state.IPv6Addresses))
	for _, address := range state.IPv6Addresses {
		addresses = append(addresses, IPv6Address{Address: address.Address, Prefix: address.Prefix})
	}
	return NetworkState{
		InterfaceName: state.InterfaceName,
		MACAddress:    state.MACAddress,
		IPv4:          state.IPv4,
		IPv4Addresses: append([]string(nil), state.IPv4Addresses...),
		IPv6:          state.IPv6,
		IPv6Addresses: addresses,
		IPv6LinkLocal: state.IPv6LinkLocal,
		IPv6Gateway:   state.IPv6Gateway,
		DHCPLease:     lease,
		Hostname:      state.Hostname,
	}, nil
}

func (c *Controller) RenewDHCPLease() error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	return current.RenewDHCPLease(ctx)
}

func (c *Controller) GetDeveloperModeState(ctx context.Context) (*bool, error) {
	current := c.clientIfConnected()
	if current == nil {
		return nil, errors.New("client not connected")
	}
	state, err := current.GetDeveloperModeState(ctx)
	if err != nil {
		return nil, err
	}
	return &state.Enabled, nil
}

func (c *Controller) GetDevChannelState(ctx context.Context) (*bool, error) {
	current := c.clientIfConnected()
	if current == nil {
		return nil, errors.New("client not connected")
	}
	enabled, err := current.GetDevChannelState(ctx)
	if err != nil {
		return nil, err
	}
	return &enabled, nil
}

func (c *Controller) GetLocalLoopbackOnly(ctx context.Context) (*bool, error) {
	current := c.clientIfConnected()
	if current == nil {
		return nil, errors.New("client not connected")
	}
	enabled, err := current.GetLocalLoopbackOnly(ctx)
	if err != nil {
		return nil, err
	}
	return &enabled, nil
}

func (c *Controller) GetLocalVersion(ctx context.Context) (VersionInfo, error) {
	current := c.clientIfConnected()
	if current == nil {
		return VersionInfo{}, errors.New("client not connected")
	}
	version, err := current.GetLocalVersion(ctx)
	if err != nil {
		return VersionInfo{}, err
	}
	return VersionInfo{
		AppVersion:    version.AppVersion,
		SystemVersion: version.SystemVersion,
	}, nil
}

func (c *Controller) GetUpdateStatus(ctx context.Context) (UpdateStatus, error) {
	current := c.clientIfConnected()
	if current == nil {
		return UpdateStatus{}, errors.New("client not connected")
	}
	status, err := current.GetUpdateStatus(ctx)
	if err != nil {
		return UpdateStatus{}, err
	}
	return UpdateStatus{
		Local: VersionInfo{
			AppVersion:    status.Local.AppVersion,
			SystemVersion: status.Local.SystemVersion,
		},
		Remote: VersionInfo{
			AppVersion:    status.Remote.AppVersion,
			SystemVersion: status.Remote.SystemVersion,
		},
		AppUpdateAvailable:    status.AppUpdateAvailable,
		SystemUpdateAvailable: status.SystemUpdateAvailable,
	}, nil
}

func (c *Controller) GetPublicIPAddresses(ctx context.Context, refresh bool) ([]PublicIP, error) {
	current := c.clientIfConnected()
	if current == nil {
		return nil, errors.New("client not connected")
	}
	addresses, err := current.GetPublicIPAddresses(ctx, refresh)
	if err != nil {
		return nil, err
	}
	out := make([]PublicIP, 0, len(addresses))
	for _, address := range addresses {
		out = append(out, PublicIP{
			IPAddress:   address.IPAddress,
			LastUpdated: address.LastUpdated,
		})
	}
	return out, nil
}

func (c *Controller) GetTailscaleStatus(ctx context.Context) (*TailscaleStatus, error) {
	current := c.clientIfConnected()
	if current == nil {
		return nil, errors.New("client not connected")
	}
	status, err := current.GetTailscaleStatus(ctx)
	if err != nil {
		return nil, err
	}
	var self *TailscalePeer
	if status.Self != nil {
		self = &TailscalePeer{
			HostName:     status.Self.HostName,
			DNSName:      status.Self.DNSName,
			TailscaleIPs: append([]string(nil), status.Self.TailscaleIPs...),
			Online:       status.Self.Online,
			OS:           status.Self.OS,
		}
	}
	return &TailscaleStatus{
		Installed:    status.Installed,
		Running:      status.Running,
		BackendState: status.BackendState,
		AuthURL:      status.AuthURL,
		ControlURL:   status.ControlURL,
		Self:         self,
		Health:       append([]string(nil), status.Health...),
	}, nil
}

func (c *Controller) GetVideoCodec(ctx context.Context) (VideoCodec, error) {
	current := c.clientIfConnected()
	if current == nil {
		return VideoCodecUnknown, errors.New("client not connected")
	}
	codec, err := current.GetVideoCodecPreference(ctx)
	if err != nil {
		return VideoCodecUnknown, err
	}
	return VideoCodec(codec), nil
}

func (c *Controller) GetEDID(ctx context.Context) (string, error) {
	current := c.clientIfConnected()
	if current == nil {
		return "", errors.New("client not connected")
	}
	return current.GetEDID(ctx)
}

func networkSettingsToClient(settings NetworkSettings) client.NetworkSettings {
	var ipv4Static *client.IPv4StaticConfig
	if settings.IPv4Static != nil {
		ipv4Static = &client.IPv4StaticConfig{
			Address: settings.IPv4Static.Address,
			Netmask: settings.IPv4Static.Netmask,
			Gateway: settings.IPv4Static.Gateway,
			DNS:     append([]string(nil), settings.IPv4Static.DNS...),
		}
	}
	var ipv6Static *client.IPv6StaticConfig
	if settings.IPv6Static != nil {
		ipv6Static = &client.IPv6StaticConfig{
			Prefix:  settings.IPv6Static.Prefix,
			Gateway: settings.IPv6Static.Gateway,
			DNS:     append([]string(nil), settings.IPv6Static.DNS...),
		}
	}
	return client.NetworkSettings{
		DHCPClient:              settings.DHCPClient,
		Hostname:                settings.Hostname,
		Domain:                  settings.Domain,
		HTTPProxy:               settings.HTTPProxy,
		IPv4Mode:                settings.IPv4Mode,
		IPv4Static:              ipv4Static,
		IPv6Mode:                settings.IPv6Mode,
		IPv6Static:              ipv6Static,
		LLDPMode:                settings.LLDPMode,
		LLDPTxTLVs:              append([]string(nil), settings.LLDPTxTLVs...),
		MDNSMode:                settings.MDNSMode,
		TimeSyncMode:            settings.TimeSyncMode,
		TimeSyncOrdering:        append([]string(nil), settings.TimeSyncOrdering...),
		TimeSyncDisableFallback: settings.TimeSyncDisableFallback,
		TimeSyncParallel:        settings.TimeSyncParallel,
		TimeSyncNTPServers:      append([]string(nil), settings.TimeSyncNTPServers...),
		TimeSyncHTTPUrls:        append([]string(nil), settings.TimeSyncHTTPUrls...),
	}
}

func networkSettingsFromClient(settings client.NetworkSettings) NetworkSettings {
	var ipv4Static *IPv4StaticConfig
	if settings.IPv4Static != nil {
		ipv4Static = &IPv4StaticConfig{
			Address: settings.IPv4Static.Address,
			Netmask: settings.IPv4Static.Netmask,
			Gateway: settings.IPv4Static.Gateway,
			DNS:     append([]string(nil), settings.IPv4Static.DNS...),
		}
	}
	var ipv6Static *IPv6StaticConfig
	if settings.IPv6Static != nil {
		ipv6Static = &IPv6StaticConfig{
			Prefix:  settings.IPv6Static.Prefix,
			Gateway: settings.IPv6Static.Gateway,
			DNS:     append([]string(nil), settings.IPv6Static.DNS...),
		}
	}
	return NetworkSettings{
		DHCPClient:              settings.DHCPClient,
		Hostname:                settings.Hostname,
		Domain:                  settings.Domain,
		HTTPProxy:               settings.HTTPProxy,
		IPv4Mode:                settings.IPv4Mode,
		IPv4Static:              ipv4Static,
		IPv6Mode:                settings.IPv6Mode,
		IPv6Static:              ipv6Static,
		LLDPMode:                settings.LLDPMode,
		LLDPTxTLVs:              append([]string(nil), settings.LLDPTxTLVs...),
		MDNSMode:                settings.MDNSMode,
		TimeSyncMode:            settings.TimeSyncMode,
		TimeSyncOrdering:        append([]string(nil), settings.TimeSyncOrdering...),
		TimeSyncDisableFallback: settings.TimeSyncDisableFallback,
		TimeSyncParallel:        settings.TimeSyncParallel,
		TimeSyncNTPServers:      append([]string(nil), settings.TimeSyncNTPServers...),
		TimeSyncHTTPUrls:        append([]string(nil), settings.TimeSyncHTTPUrls...),
	}
}

func (c *Controller) GetBacklightSettings(ctx context.Context) (BacklightSettings, error) {
	current := c.clientIfConnected()
	if current == nil {
		return BacklightSettings{}, errors.New("client not connected")
	}
	settings, err := current.GetBacklightSettings(ctx)
	if err != nil {
		return BacklightSettings{}, err
	}
	return BacklightSettings{
		MaxBrightness: settings.MaxBrightness,
		DimAfter:      settings.DimAfter,
		OffAfter:      settings.OffAfter,
	}, nil
}

func (c *Controller) GetVideoSleepMode(ctx context.Context) (*VideoSleepMode, error) {
	current := c.clientIfConnected()
	if current == nil {
		return nil, errors.New("client not connected")
	}
	state, err := current.GetVideoSleepMode(ctx)
	if err != nil {
		return nil, err
	}
	return &VideoSleepMode{
		Enabled:  state.Enabled,
		Duration: state.Duration,
	}, nil
}

func (c *Controller) GetSSHKeyState(ctx context.Context) (string, error) {
	current := c.clientIfConnected()
	if current == nil {
		return "", errors.New("client not connected")
	}
	return current.GetSSHKeyState(ctx)
}

func (c *Controller) GetKeyboardMacros(ctx context.Context) ([]KeyboardMacro, error) {
	current := c.clientIfConnected()
	if current == nil {
		return nil, errors.New("client not connected")
	}
	macros, err := current.GetKeyboardMacros(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]KeyboardMacro, 0, len(macros))
	for _, macro := range macros {
		steps := make([]KeyboardMacroStep, 0, len(macro.Steps))
		for _, step := range macro.Steps {
			steps = append(steps, KeyboardMacroStep{
				Keys:      append([]string(nil), step.Keys...),
				Modifiers: append([]string(nil), step.Modifiers...),
				Delay:     step.Delay,
			})
		}
		out = append(out, KeyboardMacro{
			ID:        macro.ID,
			Name:      macro.Name,
			Steps:     steps,
			SortOrder: macro.SortOrder,
		})
	}
	return out, nil
}

func (c *Controller) GetMQTTSettings(ctx context.Context) (MQTTSettings, error) {
	current := c.clientIfConnected()
	if current == nil {
		return MQTTSettings{}, errors.New("client not connected")
	}
	settings, err := current.GetMQTTSettings(ctx)
	if err != nil {
		return MQTTSettings{}, err
	}
	return MQTTSettings{
		Enabled:           settings.Enabled,
		Broker:            settings.Broker,
		Port:              settings.Port,
		Username:          settings.Username,
		Password:          settings.Password,
		BaseTopic:         settings.BaseTopic,
		UseTLS:            settings.UseTLS,
		TLSInsecure:       settings.TLSInsecure,
		EnableHADiscovery: settings.EnableHADiscovery,
		EnableActions:     settings.EnableActions,
		DebounceMs:        settings.DebounceMs,
	}, nil
}

func (c *Controller) SetMQTTSettings(settings MQTTSettings) error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	return current.SetMQTTSettings(ctx, client.MQTTSettings{
		Enabled:           settings.Enabled,
		Broker:            settings.Broker,
		Port:              settings.Port,
		Username:          settings.Username,
		Password:          settings.Password,
		BaseTopic:         settings.BaseTopic,
		UseTLS:            settings.UseTLS,
		TLSInsecure:       settings.TLSInsecure,
		EnableHADiscovery: settings.EnableHADiscovery,
		EnableActions:     settings.EnableActions,
		DebounceMs:        settings.DebounceMs,
	})
}

func (c *Controller) GetMQTTStatus(ctx context.Context) (MQTTStatus, error) {
	current := c.clientIfConnected()
	if current == nil {
		return MQTTStatus{}, errors.New("client not connected")
	}
	status, err := current.GetMQTTStatus(ctx)
	if err != nil {
		return MQTTStatus{}, err
	}
	return MQTTStatus{
		Connected: status.Connected,
		Error:     status.Error,
	}, nil
}

func (c *Controller) TestMQTTConnection(settings MQTTSettings) (MQTTTestResult, error) {
	current := c.clientIfConnected()
	if current == nil {
		return MQTTTestResult{}, errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	result, err := current.TestMQTTConnection(ctx, client.MQTTSettings{
		Enabled:           settings.Enabled,
		Broker:            settings.Broker,
		Port:              settings.Port,
		Username:          settings.Username,
		Password:          settings.Password,
		BaseTopic:         settings.BaseTopic,
		UseTLS:            settings.UseTLS,
		TLSInsecure:       settings.TLSInsecure,
		EnableHADiscovery: settings.EnableHADiscovery,
		EnableActions:     settings.EnableActions,
		DebounceMs:        settings.DebounceMs,
	})
	if err != nil {
		return MQTTTestResult{}, err
	}
	return MQTTTestResult{
		Success: result.Success,
		Error:   result.Error,
	}, nil
}

func (c *Controller) GetAutoUpdateState(ctx context.Context) (bool, error) {
	current := c.clientIfConnected()
	if current == nil {
		return false, errors.New("client not connected")
	}
	return current.GetAutoUpdateState(ctx)
}

func (c *Controller) SetAutoUpdateState(enabled bool) error {
	return c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetAutoUpdateState(ctx, enabled)
	}, func(ctx context.Context) (bool, error) {
		current, err := c.GetAutoUpdateState(ctx)
		if err != nil {
			return false, err
		}
		return current == enabled, nil
	})
}

func (c *Controller) SetDeveloperModeState(enabled bool) error {
	return c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetDeveloperModeState(ctx, enabled)
	}, func(ctx context.Context) (bool, error) {
		current, err := c.GetDeveloperModeState(ctx)
		if err != nil {
			return false, err
		}
		return current != nil && *current == enabled, nil
	})
}

func (c *Controller) SetDevChannelState(enabled bool) error {
	return c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetDevChannelState(ctx, enabled)
	}, func(ctx context.Context) (bool, error) {
		current, err := c.GetDevChannelState(ctx)
		if err != nil {
			return false, err
		}
		return current != nil && *current == enabled, nil
	})
}

func (c *Controller) SetLocalLoopbackOnly(enabled bool) error {
	return c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetLocalLoopbackOnly(ctx, enabled)
	}, func(ctx context.Context) (bool, error) {
		current, err := c.GetLocalLoopbackOnly(ctx)
		if err != nil {
			return false, err
		}
		return current != nil && *current == enabled, nil
	})
}

func (c *Controller) SetVideoCodec(codec VideoCodec) error {
	if codec == "" {
		return errors.New("video codec is required")
	}
	return c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetVideoCodecPreference(ctx, string(codec))
	}, func(ctx context.Context) (bool, error) {
		current, err := c.GetVideoCodec(ctx)
		if err != nil {
			return false, err
		}
		return current == codec, nil
	})
}

func (c *Controller) SetEDID(edid string) error {
	return c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetEDID(ctx, edid)
	}, func(ctx context.Context) (bool, error) {
		current := c.clientIfConnected()
		if current == nil {
			return false, errors.New("client not connected")
		}
		currentEDID, err := current.GetEDID(ctx)
		if err != nil {
			return false, err
		}
		return currentEDID == edid, nil
	})
}

func (c *Controller) SetBacklightSettings(settings BacklightSettings) error {
	return c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetBacklightSettings(ctx, client.BacklightSettings{
			MaxBrightness: settings.MaxBrightness,
			DimAfter:      settings.DimAfter,
			OffAfter:      settings.OffAfter,
		})
	}, func(ctx context.Context) (bool, error) {
		current, err := c.GetBacklightSettings(ctx)
		if err != nil {
			return false, err
		}
		return current == settings, nil
	})
}

func (c *Controller) SetVideoSleepMode(duration int) error {
	return c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetVideoSleepMode(ctx, duration)
	}, func(ctx context.Context) (bool, error) {
		current, err := c.GetVideoSleepMode(ctx)
		if err != nil {
			return false, err
		}
		return current != nil && current.Duration == duration, nil
	})
}

func (c *Controller) SetSSHKeyState(sshKey string) error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	return current.SetSSHKeyState(ctx, sshKey)
}

func (c *Controller) SetKeyboardMacros(macros []KeyboardMacro) error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	items := make([]client.KeyboardMacro, 0, len(macros))
	for _, macro := range macros {
		steps := make([]client.KeyboardMacroStep, 0, len(macro.Steps))
		for _, step := range macro.Steps {
			steps = append(steps, client.KeyboardMacroStep{
				Keys:      append([]string(nil), step.Keys...),
				Modifiers: append([]string(nil), step.Modifiers...),
				Delay:     step.Delay,
			})
		}
		items = append(items, client.KeyboardMacro{
			ID:        macro.ID,
			Name:      macro.Name,
			Steps:     steps,
			SortOrder: macro.SortOrder,
		})
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	return current.SetKeyboardMacros(ctx, items)
}

func (c *Controller) GetJigglerState(ctx context.Context) (bool, error) {
	current := c.clientIfConnected()
	if current == nil {
		return false, errors.New("client not connected")
	}
	return current.GetJigglerState(ctx)
}

func (c *Controller) SetJigglerState(enabled bool) error {
	return c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetJigglerState(ctx, enabled)
	}, func(ctx context.Context) (bool, error) {
		current, err := c.GetJigglerState(ctx)
		if err != nil {
			return false, err
		}
		return current == enabled, nil
	})
}

func (c *Controller) GetJigglerConfig(ctx context.Context) (JigglerConfig, error) {
	current := c.clientIfConnected()
	if current == nil {
		return JigglerConfig{}, errors.New("client not connected")
	}
	cfg, err := current.GetJigglerConfig(ctx)
	if err != nil {
		return JigglerConfig{}, err
	}
	return JigglerConfig{
		InactivityLimitSeconds: cfg.InactivityLimitSeconds,
		JitterPercentage:       cfg.JitterPercentage,
		ScheduleCronTab:        cfg.ScheduleCronTab,
		Timezone:               cfg.Timezone,
	}, nil
}

func (c *Controller) SetJigglerConfig(cfg JigglerConfig) error {
	return c.mutateAndConfirm(func(ctx context.Context) error {
		current := c.clientIfConnected()
		if current == nil {
			return errors.New("client not connected")
		}
		return current.SetJigglerConfig(ctx, client.JigglerConfig{
			InactivityLimitSeconds: cfg.InactivityLimitSeconds,
			JitterPercentage:       cfg.JitterPercentage,
			ScheduleCronTab:        cfg.ScheduleCronTab,
			Timezone:               cfg.Timezone,
		})
	}, func(ctx context.Context) (bool, error) {
		current, err := c.GetJigglerConfig(ctx)
		if err != nil {
			return false, err
		}
		return current == cfg, nil
	})
}

func (c *Controller) GetVirtualMediaState(ctx context.Context) (*virtualmedia.State, error) {
	current := c.clientIfConnected()
	if current == nil {
		return nil, errors.New("client not connected")
	}
	return current.GetVirtualMediaState(ctx)
}

func (c *Controller) UnmountMedia() error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	return current.UnmountMedia(ctx)
}

func (c *Controller) MountMediaURL(url string, mode virtualmedia.Mode) error {
	if strings.TrimSpace(url) == "" {
		return errors.New("url is required")
	}
	if mode == "" {
		return errors.New("mode is required")
	}
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	return current.MountMediaURL(ctx, strings.TrimSpace(url), mode)
}

func (c *Controller) GetStorageSpace(ctx context.Context) (virtualmedia.StorageSpace, error) {
	current := c.clientIfConnected()
	if current == nil {
		return virtualmedia.StorageSpace{}, errors.New("client not connected")
	}
	return current.GetStorageSpace(ctx)
}

func (c *Controller) ListStorageFiles(ctx context.Context) ([]virtualmedia.StorageFile, error) {
	current := c.clientIfConnected()
	if current == nil {
		return nil, errors.New("client not connected")
	}
	return current.ListStorageFiles(ctx)
}

func (c *Controller) DeleteStorageFile(filename string) error {
	if strings.TrimSpace(filename) == "" {
		return errors.New("filename is required")
	}
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	return current.DeleteStorageFile(ctx, filename)
}

func (c *Controller) MountStorageFile(filename string, mode virtualmedia.Mode) error {
	if strings.TrimSpace(filename) == "" {
		return errors.New("filename is required")
	}
	if mode == "" {
		return errors.New("mode is required")
	}
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()
	return current.MountStorageFile(ctx, filename, mode)
}

func (c *Controller) UploadStorageFile(path string, progress func(virtualmedia.UploadProgress)) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	return c.UploadStorageFileContext(ctx, path, progress)
}

// UploadStorageFileContext uploads a local file to the device's storage
// until done or ctx ends. A cancelled upload resumes where it stopped when
// the same file is uploaded again.
func (c *Controller) UploadStorageFileContext(ctx context.Context, path string, progress func(virtualmedia.UploadProgress)) error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	path = strings.TrimSpace(path)
	if path == "" {
		return errors.New("path is required")
	}
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return errors.New("path must be a file")
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()

	name := filepath.Base(path)
	start, err := current.StartStorageFileUpload(ctx, name, info.Size())
	if err != nil {
		return err
	}
	if start.AlreadyUploadedBytes > info.Size() {
		// A partial upload of a bigger file with this name: it cannot be
		// the start of this one. Remove it and start over.
		if err := current.DeleteStorageFile(ctx, name+".incomplete"); err != nil {
			return fmt.Errorf("remove an older partial upload of %s: %w", name, err)
		}
		if start, err = current.StartStorageFileUpload(ctx, name, info.Size()); err != nil {
			return err
		}
	}
	if start.AlreadyUploadedBytes > 0 {
		if _, err := file.Seek(start.AlreadyUploadedBytes, 0); err != nil {
			return err
		}
	}
	if err := current.UploadStorageFile(ctx, start.DataChannel, file, start.AlreadyUploadedBytes, info.Size(), progress); err != nil {
		return err
	}
	// The device answers 200 even when it kept less than the whole file
	// (a superseded or short transfer); check what it stored.
	files, err := current.ListStorageFiles(ctx)
	if err != nil {
		return fmt.Errorf("check the uploaded file: %w", err)
	}
	for _, f := range files {
		if f.Filename == name && f.Size == info.Size() {
			return nil
		}
	}
	return fmt.Errorf("the device did not store all of %s; upload it again to resume", name)
}

func (c *Controller) SendKeypress(key byte, press bool) error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	return current.SendKeypress(key, press)
}

func (c *Controller) SendKeypressKeepAlive() error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	return current.SendKeypressKeepAlive()
}

func (c *Controller) SendAbsPointer(x, y int32, buttons byte) error {
	log := logging.Subsystem("session")
	current := c.clientIfConnected()
	if current == nil {
		err := errors.New("client not connected")
		log.Debug().Err(err).Int32("x", x).Int32("y", y).Uint8("buttons", buttons).Msg("failed to send absolute pointer")
		return err
	}
	if err := current.SendAbsPointer(x, y, buttons); err != nil {
		log.Debug().Err(err).Int32("x", x).Int32("y", y).Uint8("buttons", buttons).Msg("failed to forward absolute pointer")
		return err
	}
	return nil
}

// SendRelMouse sends a relative move; large deltas are split, not clamped.
func (c *Controller) SendRelMouse(dx, dy int, buttons byte) error {
	log := logging.Subsystem("session")
	current := c.clientIfConnected()
	if current == nil {
		err := errors.New("client not connected")
		log.Debug().Err(err).Int("dx", dx).Int("dy", dy).Uint8("buttons", buttons).Msg("failed to send relative mouse")
		return err
	}
	if err := current.SendRelMouse(dx, dy, buttons); err != nil {
		log.Debug().Err(err).Int("dx", dx).Int("dy", dy).Uint8("buttons", buttons).Msg("failed to forward relative mouse")
		return err
	}
	return nil
}

// ReleaseAllInput releases every key and mouse button on the remote. Call it
// whenever local input focus is lost mid-press (focus change, ⌘Tab, resize).
func (c *Controller) ReleaseAllInput() error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	return errors.Join(current.ReleaseAllKeys(), current.ReleasePointerButtons())
}

// RequestKeyframe asks the device for a keyframe (see client.RequestKeyframe).
func (c *Controller) RequestKeyframe() {
	c.mu.RLock()
	current := c.current
	c.mu.RUnlock()
	if current != nil {
		current.RequestKeyframe()
	}
}

func (c *Controller) SendWheel(wheelY, wheelX int8) error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	return current.SendWheel(wheelY, wheelX)
}

func (c *Controller) ExecutePaste(text string, delay uint16) ([]rune, error) {
	current := c.clientIfConnected()
	if current == nil {
		return nil, errors.New("client not connected")
	}
	layout := c.Snapshot().KeyboardLayout
	steps, invalid := input.BuildPasteMacro(layout, text, delay)
	if len(steps) == 0 && len(invalid) > 0 {
		return invalid, errors.New("no pasteable characters in input")
	}
	if len(steps) == 0 {
		return invalid, nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	c.pasteMu.Lock()
	if c.pasteCancel != nil {
		c.pasteCancel()
	}
	c.pasteCancel = cancel
	c.pasteGen++
	gen := c.pasteGen
	c.pasteMu.Unlock()
	defer func() {
		cancel()
		c.pasteMu.Lock()
		// Only clear our own registration: a newer paste may have replaced it.
		if c.pasteGen == gen {
			c.pasteCancel = nil
		}
		c.pasteMu.Unlock()
	}()
	// Chunked (≤128 steps per message), each chunk waits for the device to
	// finish: long texts no longer exceed the data channel message limit.
	return invalid, current.TypeMacro(ctx, steps)
}

func (c *Controller) CancelPaste() error {
	c.pasteMu.Lock()
	cancel := c.pasteCancel
	c.pasteMu.Unlock()
	if cancel != nil {
		cancel()
		return nil
	}
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	return current.CancelKeyboardMacro()
}

func (c *Controller) ExecuteRemoteHotkey(action hotkeys.Action) error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("client not connected")
	}
	steps, err := hotkeys.MacroSteps(action)
	if err != nil {
		return err
	}
	return current.ExecuteKeyboardMacro(false, steps)
}

func (c *Controller) Stats() client.StatsSnapshot {
	c.mu.RLock()
	current := c.current
	snap := c.snapshot
	c.mu.RUnlock()
	if current == nil {
		return client.StatsSnapshot{
			SignalingMode: snap.SignalingMode,
			RTCState:      snap.RTCState,
			HIDReady:      snap.HIDReady,
			VideoReady:    snap.VideoReady,
			LastError:     snap.LastError,
		}
	}
	stats := current.Stats()
	stats.HIDReady = snap.HIDReady
	stats.VideoReady = snap.VideoReady
	if stats.SignalingMode == client.SignalingModeUnknown {
		stats.SignalingMode = snap.SignalingMode
	}
	if stats.RTCState == webrtc.PeerConnectionStateUnknown {
		stats.RTCState = snap.RTCState
	}
	if stats.LastError == "" {
		stats.LastError = snap.LastError
	}
	return stats
}

func (c *Controller) mutateAndConfirm(mutate func(context.Context) error, confirm func(context.Context) (bool, error)) error {
	ctx, cancel := context.WithTimeout(context.Background(), c.cfg.MutationTimeout)
	defer cancel()

	resultCh := make(chan error, 1)
	go func() {
		resultCh <- mutate(ctx)
	}()

	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case err := <-resultCh:
			if err == nil {
				return nil
			}
			confirmCtx, confirmCancel := context.WithTimeout(context.Background(), c.cfg.RPCTimeout)
			confirmed, confirmErr := confirm(confirmCtx)
			confirmCancel()
			if confirmErr == nil && confirmed {
				return nil
			}
			return err
		case <-ticker.C:
			confirmCtx, confirmCancel := context.WithTimeout(context.Background(), c.cfg.RPCTimeout)
			confirmed, err := confirm(confirmCtx)
			confirmCancel()
			if err == nil && confirmed {
				return nil
			}
		case <-ctx.Done():
			confirmCtx, confirmCancel := context.WithTimeout(context.Background(), c.cfg.RPCTimeout)
			confirmed, err := confirm(confirmCtx)
			confirmCancel()
			if err == nil && confirmed {
				return nil
			}
			return ctx.Err()
		}
	}
}

func sessionLocalAuthMode(mode auth.LocalAuthMode) LocalAuthMode {
	switch mode {
	case auth.LocalAuthModeNoPassword:
		return LocalAuthModeNoPassword
	case auth.LocalAuthModePassword:
		return LocalAuthModePassword
	default:
		return LocalAuthModeUnknown
	}
}

func normalizeKeyboardLayoutCode(layout string) string {
	trimmed := strings.TrimSpace(layout)
	if trimmed == "" {
		return ""
	}
	return input.NormalizeKeyboardLayoutCode(trimmed)
}

func extractString(v any, key string) string {
	if m, ok := v.(map[string]any); ok {
		if s, ok := m[key].(string); ok {
			return s
		}
	}
	return ""
}

func extractBool(v any, key string) bool {
	if m, ok := v.(map[string]any); ok {
		if b, ok := m[key].(bool); ok {
			return b
		}
	}
	return false
}

// Call forwards a raw JSON-RPC call to the device. It powers settings UIs
// that are generated from the upstream schema instead of hand-written
// wrappers. result is nil for void methods.
func (c *Controller) Call(ctx context.Context, method string, params json.RawMessage) (json.RawMessage, error) {
	current := c.clientIfConnected()
	if current == nil {
		return nil, errors.New("client not connected")
	}
	var p any
	if len(params) > 0 {
		p = params
	}
	var result json.RawMessage
	if err := current.Call(ctx, method, p, &result); err != nil {
		return nil, err
	}
	return result, nil
}
