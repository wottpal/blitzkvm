// Package engine is the core of the jetkvm-engine helper process: it runs one
// JetKVM session (session.Controller) and speaks the engineipc protocol with
// the native app over a pair of byte streams (the helper's stdin/stdout).
package engine

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/lkarlslund/jetkvm-desktop/pkg/engineipc"
	"github.com/lkarlslund/jetkvm-desktop/pkg/input"
	"github.com/lkarlslund/jetkvm-desktop/pkg/logging"
	"github.com/lkarlslund/jetkvm-desktop/pkg/session"
	"github.com/lkarlslund/jetkvm-desktop/pkg/video"
)

const (
	snapshotInterval = 100 * time.Millisecond
	statsInterval    = time.Second
	// videoQueueDepth bounds access units waiting for the app. If the app
	// falls behind, units are dropped until the next keyframe rather than
	// building latency.
	videoQueueDepth = 16
	defaultRPCWait  = 10 * time.Second
	defaultPasteMS  = 20
)

// Engine runs one device session.
type Engine struct {
	w   *engineipc.Writer
	ctx context.Context

	mu   sync.Mutex
	ctrl *session.Controller

	video        chan []byte
	needKeyframe atomic.Bool
	droppedUnits atomic.Uint64
}

// Run serves the protocol until in reaches EOF or ctx ends. Closing the
// app's end of the pipe (or the app dying) stops the engine.
func Run(ctx context.Context, in io.Reader, out io.Writer) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	e := &Engine{w: engineipc.NewWriter(out), ctx: ctx, video: make(chan []byte, videoQueueDepth)}
	go e.videoWriter(ctx)
	go e.snapshotLoop(ctx)
	defer e.stopSession()

	r := engineipc.NewReader(in)
	for {
		typ, payload, err := r.ReadFrame()
		if err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				return nil
			}
			return err
		}
		if err := e.dispatch(typ, payload); err != nil {
			e.logf("%v", err)
		}
	}
}

func (e *Engine) controller() *session.Controller {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.ctrl
}

func (e *Engine) dispatch(typ byte, payload []byte) error {
	switch typ {
	case engineipc.TypeCommand:
		var cmd engineipc.Command
		if err := json.Unmarshal(payload, &cmd); err != nil {
			return fmt.Errorf("bad command: %w", err)
		}
		return e.command(cmd)
	case engineipc.TypeKey:
		if len(payload) != 2 {
			return fmt.Errorf("bad key frame")
		}
		if c := e.controller(); c != nil {
			return c.SendKeypress(payload[0], payload[1] != 0)
		}
	case engineipc.TypeAbsPointer:
		if len(payload) != 9 {
			return fmt.Errorf("bad pointer frame")
		}
		if c := e.controller(); c != nil {
			x := int32(binary.BigEndian.Uint32(payload[0:4]))
			y := int32(binary.BigEndian.Uint32(payload[4:8]))
			return c.SendAbsPointer(x, y, payload[8])
		}
	case engineipc.TypeRelPointer:
		if len(payload) != 5 {
			return fmt.Errorf("bad relative pointer frame")
		}
		if c := e.controller(); c != nil {
			dx := int16(binary.BigEndian.Uint16(payload[0:2]))
			dy := int16(binary.BigEndian.Uint16(payload[2:4]))
			return c.SendRelMouse(int(dx), int(dy), payload[4])
		}
	case engineipc.TypeWheel:
		if len(payload) != 2 {
			return fmt.Errorf("bad wheel frame")
		}
		if c := e.controller(); c != nil {
			return c.SendWheel(int8(payload[0]), int8(payload[1]))
		}
	default:
		return fmt.Errorf("unknown frame type 0x%02x", typ)
	}
	return nil
}

func (e *Engine) command(cmd engineipc.Command) error {
	switch cmd.Cmd {
	case "connect":
		baseURL, err := NormalizeBaseURL(cmd.BaseURL)
		if err != nil {
			e.reply(cmd.ID, err, "")
			return nil
		}
		e.startSession(baseURL, cmd.Password, cmd.OfferH265)
		e.reply(cmd.ID, nil, "")
	case "disconnect":
		e.stopSession()
		e.reply(cmd.ID, nil, "")
	case "reconnect":
		if c := e.controller(); c != nil {
			c.ReconnectNow()
		}
		e.reply(cmd.ID, nil, "")
	case "releaseAll":
		var err error
		if c := e.controller(); c != nil {
			err = c.ReleaseAllInput()
		}
		e.reply(cmd.ID, err, "")
	case "rpc":
		go e.rpc(cmd)
	case "paste":
		go e.paste(cmd)
	case "cancelPaste":
		var err error
		if c := e.controller(); c != nil {
			err = c.CancelPaste()
		}
		e.reply(cmd.ID, err, "")
	case "ping":
		e.reply(cmd.ID, nil, "")
	default:
		e.reply(cmd.ID, fmt.Errorf("unknown command %q", cmd.Cmd), "")
	}
	return nil
}

func (e *Engine) reply(id int64, err error, invalid string) {
	if id == 0 {
		return
	}
	res := engineipc.CommandResult{ID: id, Invalid: invalid}
	if err != nil {
		res.Error = err.Error()
	}
	_ = e.w.WriteJSON(engineipc.TypeCommandDone, res)
}

func (e *Engine) rpc(cmd engineipc.Command) {
	res := engineipc.RPCResult{ID: cmd.ID}
	c := e.controller()
	if c == nil {
		res.Error = "not connected"
	} else {
		ctx, cancel := context.WithTimeout(e.ctx, defaultRPCWait)
		result, err := c.Call(ctx, cmd.Method, cmd.Params)
		cancel()
		if err != nil {
			res.Error = err.Error()
		} else {
			res.Result = result
		}
	}
	_ = e.w.WriteJSON(engineipc.TypeRPCResult, res)
}

func (e *Engine) paste(cmd engineipc.Command) {
	c := e.controller()
	if c == nil {
		e.reply(cmd.ID, errors.New("not connected"), "")
		return
	}
	delay := cmd.Delay
	if delay <= 0 {
		delay = defaultPasteMS
	}
	invalid, err := c.ExecutePaste(cmd.Text, uint16(min(delay, 65534)))
	e.reply(cmd.ID, err, input.InvalidRunesString(invalid))
}

func (e *Engine) startSession(baseURL, password string, offerH265 bool) {
	e.stopSession()
	ctrl := session.New(session.Config{
		BaseURL:      baseURL,
		Password:     password,
		Reconnect:    true,
		OfferH265:    offerH265,
		OnAccessUnit: e.onAccessUnit,
	})
	e.mu.Lock()
	e.ctrl = ctrl
	e.mu.Unlock()
	e.needKeyframe.Store(true)
	ctrl.Start(e.ctx)
}

func (e *Engine) stopSession() {
	e.mu.Lock()
	ctrl := e.ctrl
	e.ctrl = nil
	e.mu.Unlock()
	if ctrl != nil {
		ctrl.Stop()
	}
}

// onAccessUnit runs on the RTP goroutine: it must not block.
func (e *Engine) onAccessUnit(au video.AccessUnit) {
	if e.needKeyframe.Load() {
		if !au.Keyframe {
			e.droppedUnits.Add(1)
			return
		}
		e.needKeyframe.Store(false)
	}
	var flags byte
	if au.Keyframe {
		flags |= engineipc.FlagKeyframe
	}
	hdr := engineipc.AccessUnitHeader{
		Codec:            byte(au.Codec),
		Flags:            flags,
		RTPTimestamp:     au.RTPTimestamp,
		ReceivedUnixNano: au.CompletedAt.UnixNano(),
	}
	frame := make([]byte, 0, engineipc.AccessUnitHeaderSize+len(au.Data))
	frame = hdr.Append(frame)
	frame = append(frame, au.Data...)
	select {
	case e.video <- frame:
	default:
		e.droppedUnits.Add(1)
		e.needKeyframe.Store(true)
	}
}

func (e *Engine) videoWriter(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case frame := <-e.video:
			if err := e.w.WriteFrame(engineipc.TypeAccessUnit, frame); err != nil {
				return
			}
		}
	}
}

// snapshotLoop publishes the session snapshot whenever it changes, and
// transport statistics once a second.
func (e *Engine) snapshotLoop(ctx context.Context) {
	ticker := time.NewTicker(snapshotInterval)
	defer ticker.Stop()
	var last []byte
	var lastStats time.Time
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			c := e.controller()
			if c == nil {
				continue
			}
			snap, err := json.Marshal(c.Snapshot())
			if err == nil && string(snap) != string(last) {
				last = snap
				_ = e.w.WriteJSON(engineipc.TypeEvent, engineipc.Event{Type: "snapshot", Snapshot: snap})
			}
			if now.Sub(lastStats) >= statsInterval {
				lastStats = now
				stats := c.Stats()
				payload, err := json.Marshal(struct {
					Stats        any    `json:"stats"`
					DroppedUnits uint64 `json:"engineDroppedUnits"`
				}{stats, e.droppedUnits.Load()})
				if err == nil {
					_ = e.w.WriteJSON(engineipc.TypeEvent, engineipc.Event{Type: "stats", Stats: payload})
				}
			}
		}
	}
}

func (e *Engine) logf(format string, args ...any) {
	log := logging.Subsystem("engine")
	log.Warn().Msgf(format, args...)
}

// NormalizeBaseURL turns "jetkvm.local", "192.168.1.5" or a URL into a base
// URL without path, defaulting to http.
func NormalizeBaseURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", errors.New("host or URL is required")
	}
	if !strings.Contains(raw, "://") {
		raw = "http://" + raw
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return "", err
	}
	if (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Hostname() == "" {
		return "", fmt.Errorf("invalid device address %q", raw)
	}
	parsed.Path, parsed.RawQuery, parsed.Fragment = "", "", ""
	return strings.TrimRight(parsed.String(), "/"), nil
}
