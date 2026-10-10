package emulator

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/lkarlslund/jetkvm-desktop/pkg/logging"
	"github.com/lkarlslund/jetkvm-desktop/pkg/protocol/hidrpc"
)

// HID-RPC handling modelled on jetkvm/kvm hidrpc.go and
// internal/usbgadget/hid_keyboard.go (release/0.5.9):
//
//   - Messages are dispatched to four FIFO queues by type (handshake;
//     keyboard + macros; pointer; everything else incl. keepalive and macro
//     cancel). Each queue is processed sequentially, so a running macro blocks
//     later keyboard messages but not pointer input or a cancel.
//   - A 0x05 key press of a non-modifier key auto-releases after 100 ms unless
//     0x09 keepalives (expected every 50 ms) extend it. Keepalives arriving
//     more than 50 ms late, or more than 225 ms after the last valid one, are
//     ignored. Full 0x02 keyboard reports never auto-release.
//   - State reports (LEDs 0x32, keys down 0x33, macro state 0x34) go over HID
//     once the 0x01 handshake completed, otherwise as JSON-RPC events.
const (
	hidQueueCount      = 4
	hidQueueDepth      = 256
	autoReleaseDelay   = 100 * time.Millisecond
	keepAliveRate      = 50 * time.Millisecond
	keepAliveMaxLate   = 50 * time.Millisecond
	keepAliveExtension = keepAliveRate + keepAliveMaxLate
	keepAliveMaxStale  = 225 * time.Millisecond
)

func hidQueueIndex(msgType byte) int {
	switch msgType {
	case hidrpc.TypeHandshake:
		return 0
	case hidrpc.TypeKeyboardReport, hidrpc.TypeKeypressReport, hidrpc.TypeKeyboardMacro,
		hidrpc.TypeKeyboardLEDState, hidrpc.TypeKeysDownState, hidrpc.TypeKeyboardMacroState:
		return 1
	case hidrpc.TypePointerReport, hidrpc.TypeMouseReport, hidrpc.TypeWheelReport:
		return 2
	default:
		return 3
	}
}

type hidState struct {
	sess      *session
	queues    [hidQueueCount]chan hidQueued
	available atomic.Bool

	kaMu           sync.Mutex
	lastKeepAlive  time.Time
	lastTimerReset time.Time
	autoRelease    map[byte]*time.Timer

	macroMu     sync.Mutex
	macroCancel context.CancelFunc
}

type hidQueued struct {
	channel string
	data    []byte
}

func newHIDState(ctx context.Context, sess *session) *hidState {
	h := &hidState{sess: sess, autoRelease: map[byte]*time.Timer{}}
	for i := range h.queues {
		q := make(chan hidQueued, hidQueueDepth)
		h.queues[i] = q
		go func() {
			for {
				select {
				case <-ctx.Done():
					return
				case msg := <-q:
					if err := h.process(ctx, msg.channel, msg.data); err != nil {
						log := logging.Subsystem("emulator")
						log.Debug().Err(err).Str("channel", msg.channel).Msg("HID message failed")
					}
				}
			}
		}()
	}
	return h
}

func (h *hidState) enqueue(channel string, data []byte) {
	if len(data) == 0 {
		return
	}
	select {
	case h.queues[hidQueueIndex(data[0])] <- hidQueued{channel: channel, data: append([]byte(nil), data...)}:
	default:
		log := logging.Subsystem("emulator")
		log.Warn().Uint8("type", data[0]).Msg("HID queue full, dropping message")
	}
}

func (h *hidState) process(ctx context.Context, channel string, data []byte) error {
	srv := h.sess.serverRef
	msg, err := hidrpc.Decode(data)
	if err != nil {
		return err
	}
	srv.appendInput(channel, fmt.Sprintf("%T", msg), fmt.Sprintf("%+v", msg))

	switch v := msg.(type) {
	case hidrpc.Handshake:
		if delay := srv.cfg.Faults.HIDHandshakeDelay; delay > 0 {
			time.Sleep(delay)
		}
		reply, _ := hidrpc.Handshake{Version: v.Version}.MarshalBinary()
		if err := h.sess.sendHID(reply); err != nil {
			return err
		}
		h.available.Store(true)
		return nil
	case hidrpc.Keypress:
		srv.applyKeypress(v.Key, v.Press)
		if _, isModifier := modifierMask(v.Key); !isModifier {
			if v.Press {
				h.scheduleAutoRelease(v.Key)
			} else {
				h.cancelAutoRelease(v.Key)
			}
		}
		h.reportKeysDown()
		return nil
	case hidrpc.KeyboardReport:
		srv.setKeyboardReport(v.Modifier, v.Keys)
		h.reportKeysDown()
		return nil
	case hidrpc.KeypressKeepAlive:
		h.keepAlive(time.Now())
		return nil
	case hidrpc.KeyboardMacroReport:
		return h.runMacro(ctx, v)
	case hidrpc.CancelKeyboardMacro:
		h.cancelMacro()
		return nil
	case hidrpc.Pointer:
		srv.recordPointer(v.X, v.Y, v.Buttons)
		return nil
	case hidrpc.Mouse:
		srv.recordRelativeMouse(v.DX, v.DY, v.Buttons)
		return nil
	}
	return nil
}

func (h *hidState) scheduleAutoRelease(key byte) {
	h.kaMu.Lock()
	defer h.kaMu.Unlock()
	if t := h.autoRelease[key]; t != nil {
		t.Stop()
	}
	h.autoRelease[key] = time.AfterFunc(autoReleaseDelay, func() { h.performAutoRelease(key) })
}

func (h *hidState) cancelAutoRelease(key byte) {
	h.kaMu.Lock()
	defer h.kaMu.Unlock()
	if t := h.autoRelease[key]; t != nil {
		t.Stop()
		delete(h.autoRelease, key)
	}
}

func (h *hidState) cancelAllAutoRelease() {
	h.kaMu.Lock()
	defer h.kaMu.Unlock()
	for key, t := range h.autoRelease {
		t.Stop()
		delete(h.autoRelease, key)
	}
}

func (h *hidState) performAutoRelease(key byte) {
	h.kaMu.Lock()
	if h.autoRelease[key] == nil {
		h.kaMu.Unlock()
		return
	}
	delete(h.autoRelease, key)
	h.kaMu.Unlock()

	srv := h.sess.serverRef
	srv.applyKeypress(key, false)
	srv.appendInput("emulator", "autoRelease", fmt.Sprintf("key=%d", key))
	h.reportKeysDown()
}

// keepAlive implements upstream's jitter-tolerant extension of all pending
// auto-release timers.
func (h *hidState) keepAlive(now time.Time) {
	h.kaMu.Lock()
	defer h.kaMu.Unlock()

	if !h.lastTimerReset.IsZero() && now.Sub(h.lastTimerReset) > keepAliveMaxStale {
		return
	}
	extension := keepAliveExtension
	if !h.lastKeepAlive.IsZero() {
		lateness := now.Sub(h.lastKeepAlive) - keepAliveRate
		if lateness > 0 {
			if lateness > keepAliveMaxLate {
				return
			}
			extension -= lateness
		}
	}
	h.lastKeepAlive = now
	h.lastTimerReset = now
	for _, t := range h.autoRelease {
		t.Reset(extension)
	}
}

func (h *hidState) runMacro(ctx context.Context, report hidrpc.KeyboardMacroReport) error {
	h.cancelMacro()
	macroCtx, cancel := context.WithCancel(ctx)
	h.macroMu.Lock()
	h.macroCancel = cancel
	h.macroMu.Unlock()
	defer func() {
		cancel()
		h.macroMu.Lock()
		h.macroCancel = nil
		h.macroMu.Unlock()
	}()

	srv := h.sess.serverRef
	h.reportMacroState(true)
	defer h.reportMacroState(false)
	for _, step := range report.Steps {
		srv.setKeyboardReport(step.Modifier, step.Keys[:])
		h.reportKeysDown()
		select {
		case <-time.After(time.Duration(step.Delay) * time.Millisecond):
		case <-macroCtx.Done():
			srv.setKeyboardReport(0, make([]byte, hidrpc.HidKeyBufferSize))
			h.reportKeysDown()
			srv.appendInput("emulator", "macroCancelled", "")
			return nil
		}
	}
	srv.appendInput("emulator", "macroDone", fmt.Sprintf("steps=%d", len(report.Steps)))
	return nil
}

func (h *hidState) cancelMacro() {
	h.macroMu.Lock()
	cancel := h.macroCancel
	h.macroMu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (h *hidState) reportKeysDown() {
	srv := h.sess.serverRef
	srv.mu.Lock()
	state := keysDownState(srv.state.KeyboardModifiers, srv.state.KeysDown)
	srv.mu.Unlock()
	if h.available.Load() {
		msg, _ := hidrpc.KeysDownState{Modifier: state.Modifier, Keys: state.Keys}.MarshalBinary()
		_ = h.sess.sendHID(msg)
		return
	}
	_ = h.sess.sendEvent("keysDownState", state)
}

func (h *hidState) reportLEDs(mask byte) {
	if h.available.Load() {
		msg, _ := hidrpc.KeyboardLEDState{Mask: mask}.MarshalBinary()
		_ = h.sess.sendHID(msg)
		return
	}
	_ = h.sess.sendEvent("keyboardLedState", map[string]any{
		"num_lock":    mask&0x01 != 0,
		"caps_lock":   mask&0x02 != 0,
		"scroll_lock": mask&0x04 != 0,
		"compose":     mask&0x08 != 0,
		"kana":        mask&0x10 != 0,
		"shift":       mask&0x40 != 0,
	})
}

func (h *hidState) reportMacroState(running bool) {
	if h.available.Load() {
		msg, _ := hidrpc.KeyboardMacroState{State: running, IsPaste: true}.MarshalBinary()
		_ = h.sess.sendHID(msg)
		return
	}
	_ = h.sess.sendEvent("keyboardMacroState", map[string]any{"state": running, "isPaste": true})
}

// clearKeyboard mirrors upstream's behaviour on takeover and session close:
// stop auto-release timers, cancel macros and release every key.
func (h *hidState) clearKeyboard() {
	h.cancelAllAutoRelease()
	h.cancelMacro()
	srv := h.sess.serverRef
	srv.setKeyboardReport(0, make([]byte, hidrpc.HidKeyBufferSize))
}
