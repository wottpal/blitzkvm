package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"slices"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/wottpal/blitzkvm/pkg/client"
	"github.com/wottpal/blitzkvm/pkg/engineipc"
	"github.com/wottpal/blitzkvm/pkg/hostlink"
	"github.com/wottpal/blitzkvm/pkg/input"
	"github.com/wottpal/blitzkvm/pkg/logging"
	"github.com/wottpal/blitzkvm/pkg/session"
)

// Clipboard sync with a remote Mac over the firmware's host link
// (pkg/hostlink). clipboardInstall types an installer on the Mac that lets
// this app's key in; while clipboardStart runs, the Mac's clipboard changes
// arrive as "clipboard" events and clipboardSet sends this Mac's.
//
// "clipboardState" events: connecting, active, error (it retries),
// needsSetup (the Mac no longer accepts the key, or its host key changed:
// it stops) and off.

// clipboardParams are the clipboard commands' Params.
type clipboardParams struct {
	// User is the Mac account (clipboardStart, clipboardUninstall; a hint
	// for clipboardInstall).
	User string `json:"user,omitempty"`
	// PrivateKeyPath is this app's key (OpenSSH format).
	PrivateKeyPath string `json:"privateKeyPath"`
	// HostKey pins the Mac's SSH host key (from clipboardInstall's result).
	HostKey string `json:"hostKey,omitempty"`
	// Comment ends the installed key's line (clipboardInstall).
	Comment string `json:"comment,omitempty"`
}

// clipboardInstallResult is clipboardInstall's result.
type clipboardInstallResult struct {
	User    string `json:"user"`
	Name    string `json:"name,omitempty"`
	HostKey string `json:"hostKey"`
}

// hostLinkState is the firmware's getHostLinkState answer.
type hostLinkState struct {
	Enabled       bool        `json:"enabled"`
	Running       bool        `json:"running"`
	DeviceAddress string      `json:"deviceAddress"`
	HostAddress   string      `json:"hostAddress"`
	SSH           bool        `json:"ssh"`
	Report        *hostReport `json:"report"`
	Error         string      `json:"error"`
}

// hostReport is what the installer sent the firmware from the Mac.
type hostReport struct {
	User string    `json:"user"`
	Name string    `json:"name"`
	At   time.Time `json:"at"`
}

// HID usages for the installer's keystrokes.
const (
	hidModGUI = 0x08 // left ⌘
	hidSpace  = 0x2c
	hidEnter  = 0x28
)

const (
	// macWaitTimeout bounds the wait for the Mac on a link just turned on:
	// it re-enumerates the JetKVM and brings the interface up.
	macWaitTimeout = 40 * time.Second
	// reportTimeout bounds the wait for the installer's report after it was
	// typed.
	reportTimeout = 45 * time.Second
)

var errNeedsFirmware = errors.New("clipboard sync needs the BlitzKVM firmware with the USB link (0.5.9-fork.8 or later)")

func (e *Engine) clipboardEvent(state, message string) {
	_ = e.w.WriteJSON(engineipc.TypeEvent, engineipc.Event{Type: "clipboardState", Text: state, Message: message})
}

func (e *Engine) clipboardSetupStep(message string) {
	_ = e.w.WriteJSON(engineipc.TypeEvent, engineipc.Event{Type: "clipboardSetup", Message: message})
}

func (e *Engine) replyResult(id int64, result any) {
	data, err := json.Marshal(result)
	res := engineipc.CommandResult{ID: id, Result: data}
	if err != nil {
		res.Error = err.Error()
	}
	_ = e.w.WriteJSON(engineipc.TypeCommandDone, res)
}

func parseClipboardParams(raw json.RawMessage) (clipboardParams, []byte, error) {
	var p clipboardParams
	if err := json.Unmarshal(raw, &p); err != nil {
		return p, nil, fmt.Errorf("clipboard params: %w", err)
	}
	key, err := os.ReadFile(p.PrivateKeyPath)
	if err != nil {
		return p, nil, fmt.Errorf("this Mac's clipboard key: %w", err)
	}
	return p, key, nil
}

func hostState(ctx context.Context, c *session.Controller, probe bool) (hostLinkState, error) {
	var params json.RawMessage
	if probe {
		params = json.RawMessage(`{"probe":true}`)
	}
	raw, err := c.Call(ctx, "getHostLinkState", params)
	if err != nil {
		return hostLinkState{}, err
	}
	var state hostLinkState
	return state, json.Unmarshal(raw, &state)
}

// connectMac opens an SSH client to the Mac over the host link; the
// connection reports when it last received anything.
func connectMac(ctx context.Context, c *session.Controller, login hostlink.Login) (*ssh.Client, *hostlink.ActivityConn, string, error) {
	dialCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	raw, err := c.DialHostSSH(dialCtx)
	if err != nil {
		return nil, nil, "", err
	}
	conn := hostlink.NewActivityConn(raw)
	client, hostKey, err := hostlink.Connect(dialCtx, conn, login)
	return client, conn, hostKey, err
}

// clipboardInstall sets up clipboard sync: it turns the USB link on, waits
// for the Mac's SSH server, types the installer into Terminal there, waits
// for its report and logs in once with the key. Result:
// clipboardInstallResult.
func (e *Engine) clipboardInstall(cmd engineipc.Command) {
	result, err := e.installClipboard(cmd.Params)
	if err != nil {
		e.reply(cmd.ID, err, "")
		return
	}
	e.replyResult(cmd.ID, result)
}

func (e *Engine) installClipboard(raw json.RawMessage) (*clipboardInstallResult, error) {
	c := e.controller()
	if c == nil {
		return nil, errors.New("not connected")
	}
	p, privateKey, err := parseClipboardParams(raw)
	if err != nil {
		return nil, err
	}
	signer, err := ssh.ParsePrivateKey(privateKey)
	if err != nil {
		return nil, fmt.Errorf("this Mac's clipboard key: %w", err)
	}
	ctx, cancel := context.WithTimeout(e.ctx, 4*time.Minute)
	defer cancel()
	if !c.HasFirmwareFeature(ctx, client.FeatureHostLink) {
		return nil, errNeedsFirmware
	}

	state, err := hostState(ctx, c, false)
	if err != nil {
		return nil, err
	}
	if !state.Enabled || !state.Running {
		e.clipboardSetupStep("Turning on the USB link…")
		if _, err := c.Call(ctx, "setHostLinkState", json.RawMessage(`{"enabled":true}`)); err != nil {
			return nil, fmt.Errorf("turning on the USB link: %w", err)
		}
	}
	e.clipboardSetupStep("Looking for the remote Mac…")
	if state, err = waitForMacSSH(ctx, c); err != nil {
		return nil, err
	}

	// Set up before (a key installed and the user known): no typing.
	if p.User != "" {
		sshClient, _, hostKey, err := connectMac(ctx, c, hostlink.Login{User: p.User, PrivateKey: privateKey})
		if err == nil {
			sshClient.Close()
			return &clipboardInstallResult{User: p.User, HostKey: hostKey}, nil
		}
	}

	layout := input.NormalizeKeyboardLayoutCode(c.Snapshot().KeyboardLayout)
	if layout == "" {
		layout = "en-US"
	}
	line, err := hostlink.AuthorizedKey(string(ssh.MarshalAuthorizedKey(signer.PublicKey())), state.DeviceAddress, p.Comment)
	if err != nil {
		return nil, err
	}
	command, err := hostlink.InstallCommand(line, state.DeviceAddress)
	if err != nil {
		return nil, err
	}
	if !slices.Contains(input.MacLayoutsTyping(hostlink.InstallerChars), layout) || !hostlink.TypeSafe(command) {
		return nil, fmt.Errorf("setup types a command on the remote Mac, which the %s keyboard layout can't type on a Mac. "+
			"Set the JetKVM's keyboard layout and the remote Mac's input source to one of %s for the setup",
			layoutName(layout), installerLayoutNames())
	}
	var before time.Time
	if state.Report != nil {
		before = state.Report.At
	}
	if err := e.typeInstaller(ctx, c, layout, command); err != nil {
		return nil, err
	}

	e.clipboardSetupStep("Waiting for the remote Mac…")
	report, err := waitForReport(ctx, c, before)
	if err != nil {
		return nil, err
	}
	// The installer ran in the window opened for it, which is in front:
	// close it (its shell is idle, so Terminal doesn't ask).
	if key, ok := input.MacLetterKey(layout, 'w'); ok {
		_ = sleepCtx(ctx, time.Second)
		_ = c.TapKey(ctx, hidModGUI, key)
	}

	e.clipboardSetupStep("Checking the connection…")
	sshClient, _, hostKey, err := connectMac(ctx, c, hostlink.Login{User: report.User, PrivateKey: privateKey})
	if err != nil {
		return nil, describeMacError(err)
	}
	sshClient.Close()
	return &clipboardInstallResult{User: report.User, Name: report.Name, HostKey: hostKey}, nil
}

// waitForMacSSH waits until the Mac's SSH server answers on the link.
func waitForMacSSH(ctx context.Context, c *session.Controller) (hostLinkState, error) {
	deadline := time.Now().Add(macWaitTimeout)
	var state hostLinkState
	var err error
	for {
		state, err = hostState(ctx, c, true)
		if err == nil && state.SSH {
			return state, nil
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			break
		}
		if err := sleepCtx(ctx, 2*time.Second); err != nil {
			return state, err
		}
	}
	switch {
	case err != nil:
		return state, err
	case !state.Running:
		return state, fmt.Errorf("the USB link didn't start: %s", state.Error)
	case state.HostAddress == "":
		return state, errors.New("no Mac answers on the USB link. Clipboard sync needs a Mac on the other end, switched on")
	default:
		return state, errors.New("the remote Mac doesn't accept SSH connections. Turn on Remote Login in its System Settings › General › Sharing, then try again")
	}
}

// typeInstaller opens a new Terminal window on the Mac (⌘Space finds
// Terminal in Spotlight or a launcher in its place) and types command, all
// as a Mac with the input source of layout types it.
func (e *Engine) typeInstaller(ctx context.Context, c *session.Controller, layout, command string) error {
	newWindow, okN := input.MacLetterKey(layout, 'n')
	terminal, okT := input.BuildMacTyping(layout, "Terminal", defaultPasteMS)
	typed, okC := input.BuildMacTyping(layout, command, defaultPasteMS)
	if !okN || !okT || !okC {
		return fmt.Errorf("the %s keyboard layout can't type the setup command on a Mac", layoutName(layout))
	}
	steps := []struct {
		message string
		do      func() error
		wait    time.Duration
	}{
		{"Opening Terminal on the remote Mac…", func() error { return c.TapKey(ctx, hidModGUI, hidSpace) }, 1200 * time.Millisecond},
		{"", func() error { return c.TypeMacro(ctx, terminal) }, 900 * time.Millisecond},
		{"", func() error { return c.TapKey(ctx, 0, hidEnter) }, 3 * time.Second},
		{"", func() error { return c.TapKey(ctx, hidModGUI, newWindow) }, 1500 * time.Millisecond},
		{"Typing the setup command…", func() error { return c.TypeMacro(ctx, typed) }, 300 * time.Millisecond},
		{"", func() error { return c.TapKey(ctx, 0, hidEnter) }, 0},
	}
	for _, step := range steps {
		if step.message != "" {
			e.clipboardSetupStep(step.message)
		}
		if err := step.do(); err != nil {
			return fmt.Errorf("typing on the remote Mac: %w", err)
		}
		if err := sleepCtx(ctx, step.wait); err != nil {
			return err
		}
	}
	return nil
}

// layoutName is a keyboard layout's name ("English (UK)").
func layoutName(code string) string {
	for _, layout := range input.SupportedKeyboardLayouts() {
		if layout.Code == code {
			return layout.Label
		}
	}
	return code
}

// installerLayoutNames lists the layouts the installer can be typed in.
func installerLayoutNames() string {
	codes := input.MacLayoutsTyping(hostlink.InstallerChars)
	names := make([]string, len(codes))
	for i, code := range codes {
		names[i] = layoutName(code)
	}
	return strings.Join(names, ", ")
}

// waitForReport waits for a report newer than before.
func waitForReport(ctx context.Context, c *session.Controller, before time.Time) (*hostReport, error) {
	deadline := time.Now().Add(reportTimeout)
	for time.Now().Before(deadline) {
		state, err := hostState(ctx, c, false)
		if err == nil && state.Report != nil && state.Report.At.After(before) {
			return state.Report, nil
		}
		if err := sleepCtx(ctx, time.Second); err != nil {
			return nil, err
		}
	}
	return nil, errors.New("the remote Mac didn't confirm the setup. It must be unlocked and show its desktop while BlitzKVM types, " +
		"and the JetKVM's keyboard layout must match its input source; then try again")
}

// describeMacError explains connection errors (keeping them for errors.Is).
func describeMacError(err error) error {
	switch {
	case errors.Is(err, hostlink.ErrKeyRefused):
		return fmt.Errorf("%w. Remote Login may be limited to other users (System Settings › General › Sharing), or the key was removed", err)
	case errors.Is(err, client.ErrHostUnreachable):
		return fmt.Errorf("%w (is Remote Login still on?)", err)
	}
	return err
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return ctx.Err()
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// clipboardUninstall removes this app's key from the Mac and turns the USB
// link off. A running sync stops only once that worked.
func (e *Engine) clipboardUninstall(cmd engineipc.Command) {
	e.reply(cmd.ID, e.uninstallClipboard(cmd.Params), "")
}

func (e *Engine) uninstallClipboard(raw json.RawMessage) error {
	c := e.controller()
	if c == nil {
		return errors.New("not connected")
	}
	p, privateKey, err := parseClipboardParams(raw)
	if err != nil {
		return err
	}
	signer, err := ssh.ParsePrivateKey(privateKey)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(e.ctx, time.Minute)
	defer cancel()
	sshClient, _, _, err := connectMac(ctx, c, hostlink.Login{User: p.User, PrivateKey: privateKey, HostKey: p.HostKey})
	if err != nil {
		return describeMacError(err)
	}
	defer sshClient.Close()
	command, err := hostlink.UninstallCommand(string(ssh.MarshalAuthorizedKey(signer.PublicKey())))
	if err != nil {
		return err
	}
	if _, err := hostlink.Run(ctx, sshClient, command); err != nil {
		return fmt.Errorf("removing the key on the remote Mac: %w", err)
	}
	e.clipboardStop()
	if _, err := c.Call(ctx, "setHostLinkState", json.RawMessage(`{"enabled":false}`)); err != nil {
		return fmt.Errorf("turning off the USB link: %w", err)
	}
	return nil
}

// clipRun is one clipboardStart's sync: its loop, its session while
// connected to the Mac, and the clip waiting to go out.
type clipRun struct {
	cancel context.CancelFunc
	done   chan struct{}

	mu      sync.Mutex
	session *hostlink.ClipboardSession
	pending *hostlink.Clip
	wake    chan struct{}
}

// clipboardStart runs the sync until clipboardStop (or the engine ends),
// reconnecting whenever the session or the link comes back.
func (e *Engine) clipboardStart(cmd engineipc.Command) {
	p, privateKey, err := parseClipboardParams(cmd.Params)
	if err != nil {
		e.reply(cmd.ID, err, "")
		return
	}
	if p.User == "" || p.HostKey == "" {
		e.reply(cmd.ID, errors.New("clipboard sync isn't set up"), "")
		return
	}
	e.clipboardStop()
	ctx, cancel := context.WithCancel(e.ctx)
	run := &clipRun{cancel: cancel, done: make(chan struct{}), wake: make(chan struct{}, 1)}
	e.clipMu.Lock()
	e.clip = run
	e.clipMu.Unlock()
	go func() {
		defer close(run.done)
		e.runClipboard(ctx, run, hostlink.Login{User: p.User, PrivateKey: privateKey, HostKey: p.HostKey})
	}()
	e.reply(cmd.ID, nil, "")
}

// clipboardStop ends the running sync and waits for its loop, so its last
// events come before the next run's.
func (e *Engine) clipboardStop() {
	e.clipMu.Lock()
	run := e.clip
	e.clip = nil
	e.clipMu.Unlock()
	if run != nil {
		run.cancel()
		<-run.done
	}
}

// clipboardSet hands this Mac's clipboard to the running session's writer.
// The latest clip wins; while no session runs, it is dropped.
func (e *Engine) clipboardSet(raw json.RawMessage) error {
	var clip hostlink.Clip
	if err := json.Unmarshal(raw, &clip); err != nil {
		return fmt.Errorf("clip: %w", err)
	}
	if clip.Size() > hostlink.MaxClipBytes {
		return fmt.Errorf("clip too large: %d bytes", clip.Size())
	}
	e.clipMu.Lock()
	run := e.clip
	e.clipMu.Unlock()
	if run == nil {
		return nil
	}
	run.mu.Lock()
	connected := run.session != nil
	if connected {
		run.pending = &clip
	}
	run.mu.Unlock()
	if connected {
		select {
		case run.wake <- struct{}{}:
		default:
		}
	}
	return nil
}

// writeClips sends the run's pending clips to s until it ends.
func writeClips(run *clipRun, s *hostlink.ClipboardSession) {
	log := logging.Subsystem("clipboard")
	for {
		select {
		case <-s.Done():
			return
		case <-run.wake:
		}
		run.mu.Lock()
		clip := run.pending
		run.pending = nil
		run.mu.Unlock()
		if clip != nil {
			if err := s.Set(*clip); err != nil {
				log.Warn().Err(err).Msg("sending the clipboard to the remote Mac failed")
			}
		}
	}
}

func (e *Engine) runClipboard(ctx context.Context, run *clipRun, login hostlink.Login) {
	log := logging.Subsystem("clipboard")
	defer e.clipboardEvent("off", "")
	attempt := 0
	for ctx.Err() == nil {
		c := e.controller()
		if c == nil || c.Snapshot().Phase != session.PhaseConnected {
			if sleepCtx(ctx, time.Second) != nil {
				return
			}
			continue
		}
		e.clipboardEvent("connecting", "")
		started := time.Now()
		err := e.syncClipboard(ctx, c, run, login)
		if ctx.Err() != nil {
			return
		}
		if time.Since(started) > time.Minute {
			attempt = 0
		}
		err = describeMacError(err)
		log.Warn().Err(err).Msg("clipboard sync stopped")
		if errors.Is(err, hostlink.ErrHostKeyChanged) || errors.Is(err, hostlink.ErrKeyRefused) {
			// Retrying won't help: it needs setting up again.
			e.clipboardEvent("needsSetup", err.Error())
			<-ctx.Done()
			return
		}
		e.clipboardEvent("error", err.Error())
		wait := min(2*time.Second<<min(attempt, 4), 30*time.Second)
		attempt++
		if sleepCtx(ctx, wait) != nil {
			return
		}
	}
}

// syncClipboard runs one session until it ends.
func (e *Engine) syncClipboard(ctx context.Context, c *session.Controller, run *clipRun, login hostlink.Login) error {
	if !c.HasFirmwareFeature(ctx, client.FeatureHostLink) {
		return errNeedsFirmware
	}
	sshClient, conn, _, err := connectMac(ctx, c, login)
	if err != nil {
		return err
	}
	defer sshClient.Close()
	go hostlink.KeepAlive(sshClient, conn, 15*time.Second, 30*time.Second)
	s, err := hostlink.StartClipboard(sshClient, func(clip hostlink.Clip) {
		data, err := json.Marshal(clip)
		if err != nil {
			return
		}
		_ = e.w.WriteJSON(engineipc.TypeEvent, engineipc.Event{Type: "clipboard", Clip: data})
	})
	if err != nil {
		return err
	}
	run.mu.Lock()
	run.session, run.pending = s, nil
	run.mu.Unlock()
	defer func() {
		run.mu.Lock()
		run.session, run.pending = nil, nil
		run.mu.Unlock()
	}()
	go writeClips(run, s)
	e.clipboardEvent("active", "")
	select {
	case <-s.Done():
		return s.Err()
	case <-ctx.Done():
		s.Close()
		return ctx.Err()
	}
}
