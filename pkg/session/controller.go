package session

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/webrtc/v4"

	"github.com/wottpal/blitzkvm/pkg/client"
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
	// NoDirectPath keeps a device reached over its own Tailscale on the
	// tunnel (see client.Config.NoDirectPath).
	NoDirectPath bool
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

func (c *Controller) ListStorageFiles(ctx context.Context) ([]virtualmedia.StorageFile, error) {
	current := c.clientIfConnected()
	if current == nil {
		return nil, errors.New("client not connected")
	}
	return current.ListStorageFiles(ctx)
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
