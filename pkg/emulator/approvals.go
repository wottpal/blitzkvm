package emulator

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gorilla/websocket"
	"github.com/wottpal/blitzkvm/approval/broker"
	"github.com/wottpal/blitzkvm/approval/wire"
	"github.com/wottpal/blitzkvm/pkg/logging"
)

// FeatureApprovals is fork firmware D20's getFirmwareFeatures entry.
const FeatureApprovals = "approvals"

// The emulator runs the same broker as the firmware (approval/broker), so it
// behaves like D20 by construction; only its keyboard, storage and link
// transport are the emulator's own: clicks and strokes are recorded as
// inputs, the store is a directory, and the host link is a TCP listener.

type approvalsHID struct{ s *Server }

func (h approvalsHID) Click(ctx context.Context, x, y float64) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	h.s.mu.Lock()
	defer h.s.mu.Unlock()
	h.s.appendInputLocked("approvals", "click", fmt.Sprintf("%.4f,%.4f", x, y))
	return nil
}

func (h approvalsHID) Type(ctx context.Context, strokes []wire.Stroke) error {
	h.s.mu.Lock()
	defer h.s.mu.Unlock()
	for _, st := range strokes {
		if err := ctx.Err(); err != nil { // as the firmware, between strokes
			return err
		}
		h.s.appendInputLocked("approvals", "stroke", fmt.Sprintf("%02x:%02x", st[0], st[1]))
	}
	return nil
}

// Hold is recorded; the emulator's session input isn't blocked.
func (h approvalsHID) Hold(on bool) {
	h.s.mu.Lock()
	defer h.s.mu.Unlock()
	h.s.appendInputLocked("approvals", "hold", fmt.Sprint(on))
}

type dirStore struct{ dir string }

func (d dirStore) Load(name string) ([]byte, error) { return os.ReadFile(filepath.Join(d.dir, name)) }

func (d dirStore) Save(name string, data []byte) error {
	tmp, err := os.CreateTemp(d.dir, name+".*")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	tmp.Close()
	return os.Rename(tmp.Name(), filepath.Join(d.dir, name))
}

func (d dirStore) Remove(name string) error {
	if err := os.Remove(filepath.Join(d.dir, name)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// wsConn adapts a gorilla WebSocket to broker.Conn.
type wsConn struct{ c *websocket.Conn }

func (w wsConn) Read(ctx context.Context) ([]byte, error) {
	if deadline, ok := ctx.Deadline(); ok {
		_ = w.c.SetReadDeadline(deadline)
	} else {
		_ = w.c.SetReadDeadline(time.Time{})
	}
	_, data, err := w.c.ReadMessage()
	return data, err
}

func (w wsConn) Write(_ context.Context, data []byte) error {
	return w.c.WriteMessage(websocket.TextMessage, data)
}

func (w wsConn) Close() error { return w.c.Close() }

func (s *Server) startApprovals() error {
	dir := s.cfg.ApprovalsDir
	if dir == "" {
		var err error
		if dir, err = os.MkdirTemp("", "emulator-approvals-*"); err != nil {
			return err
		}
	}
	log := logging.Subsystem("emulator")
	b, err := broker.New(broker.Config{
		Store: dirStore{dir: dir},
		HID:   approvalsHID{s: s},
		Logf:  func(format string, args ...any) { log.Info().Msgf(format, args...) },
		DialRelay: func(ctx context.Context, url string) (broker.Conn, error) {
			url = strings.Replace(strings.Replace(url, "https://", "wss://", 1), "http://", "ws://", 1)
			c, _, err := websocket.DefaultDialer.DialContext(ctx, url, nil)
			if err != nil {
				return nil, err
			}
			c.SetReadLimit(64 << 10)
			return wsConn{c}, nil
		},
	})
	if err != nil {
		return err
	}
	addr := s.cfg.ApprovalsLink
	if addr == "" {
		addr = "127.0.0.1:0"
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	s.approvals, s.approvalsLink = b, ln
	return nil
}

// ApprovalsLinkAddr is where the emulated host link takes the target
// daemon ("" without Config.Approvals).
func (s *Server) ApprovalsLinkAddr() string {
	if s.approvalsLink == nil {
		return ""
	}
	return s.approvalsLink.Addr().String()
}

// Approvals is the emulator's broker (nil without Config.Approvals).
func (s *Server) Approvals() *broker.Broker { return s.approvals }

func (s *Server) runApprovals(ctx context.Context) {
	if s.approvals == nil {
		return
	}
	go s.approvals.Run(ctx)
	go func() {
		<-ctx.Done()
		_ = s.approvalsLink.Close()
	}()
	for {
		conn, err := s.approvalsLink.Accept()
		if err != nil {
			return
		}
		go s.approvals.ServeLink(ctx, conn)
	}
}

func (s *Server) handleApprovalsWS(w http.ResponseWriter, r *http.Request) {
	if s.approvals == nil {
		http.NotFound(w, r)
		return
	}
	// Native clients only: a browser (it sends Origin) never reaches the broker.
	upgrader := websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return r.Header.Get("Origin") == "" }}
	c, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	c.SetReadLimit(64 << 10)
	s.mu.Lock()
	ctx := s.serveCtx
	s.mu.Unlock()
	if ctx == nil {
		ctx = context.Background()
	}
	s.approvals.ServeApprover(ctx, wsConn{c})
}

type approvalsRequest struct {
	Enabled bool            `json:"enabled"`
	Roster  json.RawMessage `json:"roster"`
}

func (s *Server) setApprovalsEnabled(raw any) (broker.State, error) {
	params, err := decodeParams[approvalsRequest](raw)
	if err != nil {
		return broker.State{}, errors.New("missing enabled")
	}
	if !params.Enabled {
		err := s.approvals.Disable()
		return s.approvals.State(), err
	}
	var env wire.Envelope
	if err := json.Unmarshal(params.Roster, &env); err != nil {
		return broker.State{}, errors.New("missing roster")
	}
	if err := s.approvals.Enable(&env); err != nil {
		return broker.State{}, err
	}
	return s.approvals.State(), nil
}
