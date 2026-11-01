package emulator

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/wottpal/blitzkvm/approval/wire"
)

// TestApprovalsOverTheEmulator runs D20's broker as the emulator serves it:
// a target daemon on the loopback host link, an approver on the WebSocket
// route, a sudo ask approved end to end, and a screen ask's steps recorded
// as inputs.
func TestApprovalsOverTheEmulator(t *testing.T) {
	srv, err := NewServer(Config{ListenAddr: "127.0.0.1:0", ICELoopbackOnly: true, Approvals: true, ApprovalsDir: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = srv.ListenAndServe(ctx) }()
	for deadline := time.Now().Add(2 * time.Second); srv.BaseURL() == "" && time.Now().Before(deadline); {
		time.Sleep(10 * time.Millisecond)
	}

	presence, _ := wire.NewSigningKey()
	transport, _ := wire.NewSigningKey()
	seal, _ := wire.NewSealKey()
	target, _ := wire.NewSigningKey()
	b := srv.Approvals()
	roster := wire.Roster{V: 1, Seq: 1, Issued: time.Now().Unix(), Broker: b.Identity(), Owners: []string{presence.ID()},
		Approvers: []wire.Approver{{ID: presence.ID(), Name: "Mac", Platform: "macos", Presence: presence.Public(),
			Transport: transport.Public(), Seal: seal.Public()}},
		Targets: []wire.Target{{ID: target.ID(), Name: "Mac mini", Key: target.Public()}}}
	env, _ := wire.Sign(presence, "roster", roster)
	raw, _ := json.Marshal(env)
	var params any
	_ = json.Unmarshal([]byte(`{"enabled":true,"roster":`+string(raw)+`}`), &params)
	if state, err := srv.setApprovalsEnabled(params); err != nil || !state.Enabled {
		t.Fatalf("enable: %v %+v", err, state)
	}

	wsURL := strings.Replace(srv.BaseURL(), "http://", "ws://", 1) + "/approvals/v1/ws"
	// A browser can't reach the broker.
	if _, resp, err := websocket.DefaultDialer.Dial(wsURL, http.Header{"Origin": {"https://evil.example"}}); err == nil || resp.StatusCode != http.StatusForbidden {
		t.Fatalf("browser origin accepted: %v", err)
	}
	ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	var hello struct {
		Op    string     `json:"op"`
		Nonce wire.Bytes `json:"nonce"`
	}
	_ = ws.ReadJSON(&hello)
	auth, _ := wire.Sign(transport, "hello", wire.HelloAuth{V: 1, Broker: b.ID(), Approver: presence.ID(), Nonce: hello.Nonce, Issued: time.Now().Unix()})
	_ = ws.WriteJSON(map[string]any{"op": "auth", "auth": auth})
	next := func(op string) map[string]json.RawMessage {
		_ = ws.SetReadDeadline(time.Now().Add(5 * time.Second))
		for {
			var f struct {
				Op  string     `json:"op"`
				Box wire.Bytes `json:"box"`
			}
			if err := ws.ReadJSON(&f); err != nil {
				t.Fatalf("approver read: %v", err)
			}
			data, err := seal.OpenBox(f.Box)
			if err != nil {
				continue
			}
			var m map[string]json.RawMessage
			_ = json.Unmarshal(data, &m)
			if string(m["op"]) == `"`+op+`"` {
				return m
			}
		}
	}
	next("roster")

	conn, err := net.Dial("tcp", srv.ApprovalsLinkAddr())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	lines := bufio.NewScanner(conn)
	read := func() map[string]json.RawMessage {
		_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
		for lines.Scan() {
			var m map[string]json.RawMessage
			_ = json.Unmarshal(lines.Bytes(), &m)
			if string(m["op"]) != `"ping"` {
				return m
			}
		}
		t.Fatalf("link read: %v", lines.Err())
		return nil
	}
	send := func(m any) {
		data, _ := json.Marshal(m)
		_, _ = conn.Write(append(data, '\n'))
	}
	var linkHello struct {
		Nonce wire.Bytes `json:"nonce"`
	}
	_ = json.Unmarshal(mustRaw(read(), "nonce"), &linkHello.Nonce)
	linkAuth, _ := wire.Sign(target, "link", wire.LinkAuth{V: 1, Broker: b.ID(), Target: target.ID(), Nonce: linkHello.Nonce, Issued: time.Now().Unix()})
	send(map[string]any{"op": "auth", "auth": linkAuth})
	if m := read(); string(m["op"]) != `"ready"` {
		t.Fatalf("link: %s", m["op"])
	}

	ask := func(kind, secret string) (string, *wire.Envelope) {
		now := time.Now().Unix()
		id := wire.RandomID()
		a, _ := wire.Sign(target, "ask", wire.Ask{V: 1, ID: id, Target: target.ID(), Kind: kind, Title: "test", Secret: secret,
			Nonce: wire.Nonce(32), Issued: now, Expires: now + 60})
		send(map[string]any{"op": "ask", "ask": a})
		var req wire.Envelope
		_ = json.Unmarshal(mustRaw(read(), "request"), &req)
		return id, &req
	}
	approve := func(reqEnv *wire.Envelope, secret string) {
		var req wire.Request
		_ = reqEnv.Peek(&req)
		d := wire.Decision{V: 1, Request: reqEnv.DigestHex(), Ask: req.Ask.DigestHex(), Decision: wire.Approve,
			Approver: presence.ID(), Issued: time.Now().Unix()}
		if secret != "" {
			d.Secret, _ = wire.SealSecret(req.Seal, reqEnv.Digest(), []byte(secret))
		}
		dec, _ := wire.Sign(presence, "decision", d)
		msg, _ := json.Marshal(map[string]any{"op": "decision", "decision": dec})
		box, _ := wire.SealBox(b.Identity().Seal, msg)
		_ = ws.WriteJSON(map[string]any{"op": "box", "box": wire.Bytes(box)})
	}

	_, reqEnv := ask(wire.KindSudo, wire.SecretNone)
	next("request")
	approve(reqEnv, "")
	if m := read(); string(m["op"]) != `"decision"` {
		t.Fatalf("daemon got %s", m["op"])
	}

	id, reqEnv := ask(wire.KindOnePassword, wire.SecretOnePassword)
	next("request")
	approve(reqEnv, "ab")
	read() // decision
	// The daemon waits for each step's answer before the next.
	for i, step := range []wire.Step{{Click: &wire.Point{X: 0.75, Y: 0.6}},
		{Secret: &wire.KeyMap{Map: map[string][]wire.Stroke{"a": {{0x04, 0}}, "b": {{0x05, 0}}}}}} {
		send(map[string]any{"op": "step", "id": id, "seq": i, "step": step})
		if m := read(); string(m["ok"]) != "true" {
			t.Fatalf("step: %s", m["error"])
		}
	}
	var got []string
	for _, in := range srv.Inputs() {
		if in.Channel == "approvals" {
			got = append(got, in.Type+" "+in.Data)
		}
	}
	if strings.Join(got, "|") != "click 0.7500,0.6000|stroke 04:00|stroke 05:00" {
		t.Fatalf("inputs %v", got)
	}
}

func mustRaw(m map[string]json.RawMessage, key string) json.RawMessage { return m[key] }
