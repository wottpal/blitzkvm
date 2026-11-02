// Package broker is the approval broker that runs on the JetKVM (firmware
// D20) and in the emulator: it takes asks from the target daemon over the
// host link, offers them to the approvers (directly and through the relay),
// checks their decisions and, for screen asks, presses what the daemon asks
// for. PROTOCOL.md is the contract; this package holds no device code: the
// firmware and the emulator provide the keyboard and pointer (HID), the
// storage and the transports.
package broker

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/wottpal/blitzkvm/approval/wire"
)

// HID presses keys and clicks on the target and returns once the device has
// sent the reports. Hold(true) blocks every other input (the session's) from
// the approval of a screen request until Hold(false), when the last such
// request ended: nothing may land between its steps or characters.
type HID interface {
	Click(ctx context.Context, x, y float64) error
	Type(ctx context.Context, strokes []wire.Stroke) error
	Hold(on bool)
}

// Store keeps the broker's files. Load returns os.ErrNotExist for a missing
// file; Save replaces a file atomically.
type Store interface {
	Load(name string) ([]byte, error)
	Save(name string, data []byte) error
	Remove(name string) error
}

// Conn carries one JSON message per Read and Write (a WebSocket).
type Conn interface {
	Read(ctx context.Context) ([]byte, error)
	Write(ctx context.Context, data []byte) error
	Close() error
}

// Config wires the broker to its device.
type Config struct {
	Store Store
	HID   HID
	// Now is the broker's clock and Synced reports whether it has been set
	// from the network: the broker takes no asks before that.
	Now    func() time.Time
	Synced func() bool
	Logf   func(format string, args ...any)
	// DialRelay opens the relay's broker WebSocket at url (nil: no relay).
	DialRelay func(ctx context.Context, url string) (Conn, error)
}

const (
	keyFile    = "broker.key"
	rosterFile = "roster.json"

	maxMessage      = 64 << 10
	maxPending      = 8
	asksPerMinute   = 20
	stepWindow      = 60 * time.Second
	pairingLifetime = 5 * time.Minute
	keepDecided     = 2 * time.Minute
	pingEvery       = 15 * time.Second
	idleTimeout     = 45 * time.Second
	authTimeout     = 5 * time.Second
	auditSize       = 50
	// What one approver id (or the relay on its behalf) may send: each box
	// costs an HPKE open on the JetKVM's single core.
	boxesPerWindow = 40
	boxWindow      = 10 * time.Second
	syncEvery      = 5 * time.Second
	unlockEvery    = 30 * time.Second

	// An open request is pushed to iPhones again until it's answered: a
	// 1Password prompt closes after about a minute, so every 10 s, other
	// requests every 20 s; none in a request's last seconds.
	repeatOnePassword = 10 * time.Second
	repeatOther       = 20 * time.Second
	repeatMinLeft     = 5 * time.Second
)

// Broker is one JetKVM's approval broker.
type Broker struct {
	cfg  Config
	key  *wire.SigningKey
	seal *wire.SealKey

	// rosterMu serializes roster changes: check, save and swap as one.
	rosterMu  sync.Mutex
	mu        sync.Mutex
	roster    *wire.Roster
	rosterEnv *wire.Envelope
	rosterCh  chan struct{} // closed and replaced when the roster changes
	link      *linkConn
	direct    map[string]map[*approverConn]bool
	relay     *relayConn
	pending   map[string]*pending
	asks      []time.Time          // recent asks, for the rate limit
	pairings  map[string]time.Time // pairing hash -> until
	used      map[string]time.Time // spent pairing hashes, until they'd have expired
	audit     []Event
	// typing is one step at a time; a step waits its turn with its context,
	// so an abort reaches it while it waits too.
	typing chan struct{}
	// holding counts approved screen requests that haven't ended; holdMu
	// orders the HID.Hold calls that follow it.
	holding int
	holdMu  sync.Mutex
	held    bool
	// Rate limits on what approvers (or the relay, on their behalf) send.
	boxes      map[string]*window
	unlocks    map[string]time.Time // nonce -> until
	lastUnlock map[string]time.Time
	lastSync   map[string]time.Time
}

// window counts events in a fixed window.
type window struct {
	start time.Time
	n     int
}

type pending struct {
	link      *linkConn // the daemon connection that asked
	verified  *wire.Verified
	env       *wire.Envelope
	sealKey   *wire.SealKey
	state     string // pending, approved, denied, done, failed, expired, cancelled
	by        string
	decided   time.Time
	secret    []byte
	secretSet bool
	ended     time.Time
	// stepCancel stops the step running for this request (abort).
	stepCancel context.CancelFunc
	// pushed is when iPhones last got it, repeats how often again.
	pushed  time.Time
	repeats int
	// holds: an approved screen request keeps the session's input blocked.
	holds bool
}

// Event is one line of the broker's recent history (no secrets).
type Event struct {
	At    int64  `json:"at"`
	ID    string `json:"id"`
	Kind  string `json:"kind"`
	Title string `json:"title"`
	State string `json:"state"`
	By    string `json:"by,omitempty"`
	Note  string `json:"note,omitempty"`
}

type storedKeys struct {
	Sign wire.Bytes `json:"sign"`
	Seal wire.Bytes `json:"seal"`
}

// New loads the broker's keys and roster from the store, making keys the
// first time.
func New(cfg Config) (*Broker, error) {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Synced == nil {
		cfg.Synced = func() bool { return true }
	}
	if cfg.Logf == nil {
		cfg.Logf = func(string, ...any) {}
	}
	b := &Broker{cfg: cfg, rosterCh: make(chan struct{}), direct: map[string]map[*approverConn]bool{},
		pending: map[string]*pending{}, pairings: map[string]time.Time{}, used: map[string]time.Time{},
		typing: make(chan struct{}, 1), boxes: map[string]*window{}, unlocks: map[string]time.Time{},
		lastUnlock: map[string]time.Time{}, lastSync: map[string]time.Time{}}
	if err := b.loadKeys(); err != nil {
		return nil, err
	}
	data, err := cfg.Store.Load(rosterFile)
	switch {
	case errors.Is(err, os.ErrNotExist):
	case err != nil:
		return nil, err
	default:
		var env wire.Envelope
		if err := json.Unmarshal(data, &env); err != nil {
			return nil, fmt.Errorf("stored roster: %w", err)
		}
		roster, err := wire.AcceptRoster(nil, &env)
		if err != nil {
			return nil, fmt.Errorf("stored roster: %w", err)
		}
		if b.ownRoster(roster) != nil {
			// Keys made anew (lost or reset) next to an old roster: the
			// broker isn't the one that roster names, so it starts off.
			cfg.Logf("approvals: the stored roster names another broker; approvals are off")
			return b, nil
		}
		b.roster, b.rosterEnv = roster, &env
	}
	return b, nil
}

// ownRoster checks that a roster names this broker: its id and both keys.
func (b *Broker) ownRoster(roster *wire.Roster) error {
	if roster.Broker.ID != b.ID() || string(roster.Broker.Key) != string(b.key.Public()) ||
		string(roster.Broker.Seal) != string(b.seal.Public()) {
		return wire.ErrRosterBroker
	}
	return nil
}

func (b *Broker) loadKeys() error {
	data, err := b.cfg.Store.Load(keyFile)
	if errors.Is(err, os.ErrNotExist) {
		if b.key, err = wire.NewSigningKey(); err != nil {
			return err
		}
		if b.seal, err = wire.NewSealKey(); err != nil {
			return err
		}
		data, _ = json.Marshal(storedKeys{Sign: b.key.Scalar(), Seal: b.seal.Scalar()})
		return b.cfg.Store.Save(keyFile, data)
	}
	if err != nil {
		return err
	}
	var k storedKeys
	if err := json.Unmarshal(data, &k); err != nil {
		return fmt.Errorf("stored keys: %w", err)
	}
	if b.key, err = wire.SigningKeyFromScalar(k.Sign); err != nil {
		return err
	}
	b.seal, err = wire.SealKeyFromScalar(k.Seal)
	return err
}

// ID is the broker's kid.
func (b *Broker) ID() string { return b.key.ID() }

// Identity is what a genesis roster must name as its broker.
func (b *Broker) Identity() wire.Broker {
	return wire.Broker{ID: b.key.ID(), Key: b.key.Public(), Seal: b.seal.Public()}
}

// Enable installs a roster through the device's authenticated session: a
// genesis roster when there is none, otherwise an owner-signed update.
func (b *Broker) Enable(env *wire.Envelope) error {
	b.rosterMu.Lock()
	defer b.rosterMu.Unlock()
	b.mu.Lock()
	current := b.roster
	b.mu.Unlock()
	roster, err := wire.AcceptRoster(current, env)
	if err != nil {
		return err
	}
	if err := b.ownRoster(roster); err != nil {
		return err
	}
	return b.setRoster(roster, env)
}

// Disable forgets the roster (the keys stay, so the broker's identity does).
func (b *Broker) Disable() error {
	b.rosterMu.Lock()
	defer b.rosterMu.Unlock()
	b.mu.Lock()
	b.roster, b.rosterEnv = nil, nil
	link := b.link
	var conns []*approverConn
	for _, set := range b.direct {
		for c := range set {
			conns = append(conns, c)
		}
	}
	for _, p := range b.pending {
		b.stopLocked(p)
	}
	b.signalRoster()
	b.mu.Unlock()
	b.applyHold()
	// Closing may wait on a peer: never under b.mu.
	for _, c := range conns {
		c.close()
	}
	if link != nil {
		link.close()
	}
	return b.cfg.Store.Remove(rosterFile)
}

// stopLocked ends what an approved screen request still does: its running
// step and its hold on the session's input (b.mu held; applyHold after).
func (b *Broker) stopLocked(p *pending) {
	if p.stepCancel != nil {
		p.stepCancel()
	}
	if p.holds {
		p.holds = false
		b.holding--
	}
}

// applyHold makes the HID's hold follow b.holding.
func (b *Broker) applyHold() {
	b.holdMu.Lock()
	defer b.holdMu.Unlock()
	b.mu.Lock()
	on := b.holding > 0
	b.mu.Unlock()
	if on != b.held {
		b.held = on
		b.cfg.HID.Hold(on)
	}
}

// Enabled reports whether the broker has a roster.
func (b *Broker) Enabled() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.roster != nil
}

// setRoster saves and installs a checked roster (b.rosterMu held).
func (b *Broker) setRoster(roster *wire.Roster, env *wire.Envelope) error {
	data, err := json.Marshal(env)
	if err != nil {
		return err
	}
	if err := b.cfg.Store.Save(rosterFile, data); err != nil {
		return err
	}
	b.mu.Lock()
	b.roster, b.rosterEnv = roster, env
	// Approvers that left lose their connections, a target that left its link.
	var gone []*approverConn
	for id, conns := range b.direct {
		if roster.Approver(id) == nil {
			for c := range conns {
				gone = append(gone, c)
			}
		}
	}
	link := b.link
	var dropLink *linkConn
	if link != nil && roster.Target(link.target) == nil {
		dropLink, link = link, nil
	}
	b.signalRoster()
	// The allow list goes out under the lock, so a relay session starting
	// meanwhile can't send an older one after it.
	if b.relay != nil {
		b.relay.sendAllow(roster)
	}
	b.mu.Unlock()
	for _, c := range gone {
		c.close()
	}
	if dropLink != nil {
		dropLink.close()
	}
	b.cfg.Logf("approvals: roster %d (%d approvers, %d targets)", roster.Seq, len(roster.Approvers), len(roster.Targets))
	if link != nil {
		link.send(map[string]any{"op": "roster", "roster": env})
	}
	for _, a := range roster.Approvers {
		b.deliver(a.ID, map[string]any{"op": "roster", "roster": env}, nil)
	}
	return nil
}

// signalRoster wakes whoever waits for a roster change (b.mu held).
func (b *Broker) signalRoster() {
	close(b.rosterCh)
	b.rosterCh = make(chan struct{})
}

// acceptRoster takes a newer roster from the daemon or an approver.
func (b *Broker) acceptRoster(env *wire.Envelope) error {
	b.rosterMu.Lock()
	defer b.rosterMu.Unlock()
	b.mu.Lock()
	current := b.roster
	b.mu.Unlock()
	if current == nil {
		return errors.New("approvals aren't enabled")
	}
	roster, err := wire.AcceptRoster(current, env)
	if err != nil {
		return err
	}
	// An update can't move approvers to another seal key: they would seal
	// to a key this broker doesn't hold.
	if err := b.ownRoster(roster); err != nil {
		return err
	}
	return b.setRoster(roster, env)
}

// State is getApprovalsState's answer.
type State struct {
	Enabled   bool            `json:"enabled"`
	Broker    wire.Broker     `json:"broker"`
	Seq       uint64          `json:"seq,omitempty"`
	Synced    bool            `json:"synced"`
	Relay     string          `json:"relay,omitempty"`
	RelayUp   bool            `json:"relayConnected"`
	Target    string          `json:"target,omitempty"` // the connected daemon's target id
	Approvers []ApproverState `json:"approvers,omitempty"`
	Pending   int             `json:"pending"`
	Recent    []Event         `json:"recent,omitempty"`
}

type ApproverState struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Platform string `json:"platform"`
	Owner    bool   `json:"owner"`
	Direct   bool   `json:"direct"`
}

// State reports the broker for the device's RPC.
func (b *Broker) State() State {
	b.mu.Lock()
	defer b.mu.Unlock()
	s := State{Broker: b.Identity(), Synced: b.cfg.Synced(), Recent: append([]Event(nil), b.audit...)}
	if b.roster == nil {
		return s
	}
	s.Enabled, s.Seq, s.Relay = true, b.roster.Seq, b.roster.Relay
	s.RelayUp = b.relay != nil
	if b.link != nil {
		s.Target = b.link.target
	}
	for _, a := range b.roster.Approvers {
		s.Approvers = append(s.Approvers, ApproverState{ID: a.ID, Name: a.Name, Platform: a.Platform,
			Owner: b.roster.IsOwner(a.ID), Direct: len(b.direct[a.ID]) > 0})
	}
	for _, p := range b.pending {
		if p.state == "pending" {
			s.Pending++
		}
	}
	return s
}

func (b *Broker) record(p *pending, note string) {
	ask := p.verified.Ask
	e := Event{At: b.cfg.Now().Unix(), ID: ask.ID, Kind: ask.Kind, Title: ask.Title, State: p.state, By: p.by, Note: note}
	b.audit = append(b.audit, e)
	if len(b.audit) > auditSize {
		b.audit = b.audit[len(b.audit)-auditSize:]
	}
}

// Run keeps the relay connection up and expires requests until ctx ends.
func (b *Broker) Run(ctx context.Context) {
	if b.cfg.DialRelay != nil {
		go b.runRelay(ctx)
	}
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			b.expire()
			b.repeat()
		}
	}
}

func (b *Broker) expire() {
	now := b.cfg.Now()
	var expired []*pending
	b.mu.Lock()
	for id, p := range b.pending {
		switch {
		case p.state == "pending" && now.Unix() >= p.verified.Ask.Expires:
			p.state, p.ended = "expired", now
			b.record(p, "")
			expired = append(expired, p)
		case p.state == "approved" && wire.Typing(p.verified.Ask.Kind) && now.Sub(p.decided) > stepWindow:
			p.state, p.ended = "failed", now
			wipe(p.secret)
			p.secret = nil
			b.stopLocked(p)
			b.record(p, "no steps in time")
			expired = append(expired, p)
		case p.state != "pending" && p.state != "approved" && now.Sub(p.ended) > keepDecided:
			delete(b.pending, id)
		}
	}
	for hash, until := range b.pairings {
		if now.After(until) {
			delete(b.pairings, hash)
		}
	}
	for hash, until := range b.used {
		if now.After(until) {
			delete(b.used, hash)
		}
	}
	b.mu.Unlock()
	b.applyHold()
	for _, p := range expired {
		// Only an expiry leaves pending here; a typing ask that got no
		// steps was approved, and its notification replaced then.
		b.status(p.verified.Ask.ID, map[string]any{"op": "status", "id": p.verified.Ask.ID, "state": p.state},
			p.state == "expired")
	}
}

// repeat pushes open requests to iPhones again until they're answered, each
// time as a notification of its own (its own collapse id: a notification
// replaced under the same id may not alert again); the app takes the copies
// as the request it has, and its extension clears the earlier ones.
func (b *Broker) repeat() {
	now := b.cfg.Now()
	type resend struct {
		id     string
		env    *wire.Envelope
		n      int
		phones []string
	}
	var due []resend
	b.mu.Lock()
	phones := b.phones()
	for _, p := range b.pending {
		if len(phones) == 0 || p.state != "pending" {
			continue
		}
		every := repeatOther
		if p.verified.Ask.Kind == wire.KindOnePassword {
			every = repeatOnePassword
		}
		if now.Sub(p.pushed) < every || time.Unix(p.verified.Ask.Expires, 0).Sub(now) < repeatMinLeft {
			continue
		}
		p.pushed = now
		p.repeats++
		due = append(due, resend{p.verified.Ask.ID, p.env, p.repeats, phones})
	}
	b.mu.Unlock()
	for _, r := range due {
		for _, id := range r.phones {
			b.deliver(id, map[string]any{"op": "request", "request": r.env, "repeat": r.n},
				&push{collapse: fmt.Sprintf("%s.%d", r.id, r.n), repeat: true})
		}
	}
}

// phones are the roster's iPhones (b.mu held).
func (b *Broker) phones() []string {
	var ids []string
	if b.roster != nil {
		for _, a := range b.roster.Approvers {
			if a.Platform == "ios" {
				ids = append(ids, a.ID)
			}
		}
	}
	return ids
}

func wipe(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

// push asks the relay to notify the approver's iPhones of a box: one
// notification per collapse id; a quiet one replaces what a request showed
// without a sound.
type push struct {
	collapse string
	quiet    bool
	repeat   bool // the relay may drop repeats first
}

// deliver seals msg to one approver and sends it directly when it is
// connected, else through the relay (pushing when p is set).
func (b *Broker) deliver(approverID string, msg any, p *push) {
	b.mu.Lock()
	var seal []byte
	if b.roster != nil {
		if a := b.roster.Approver(approverID); a != nil {
			seal = a.Seal
		}
	}
	var direct []*approverConn
	for c := range b.direct[approverID] {
		direct = append(direct, c)
	}
	relay := b.relay
	b.mu.Unlock()
	if seal == nil {
		return
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return
	}
	box, err := wire.SealBox(seal, data)
	if err != nil {
		b.cfg.Logf("approvals: seal for %s: %v", approverID, err)
		return
	}
	if len(direct) > 0 {
		for _, c := range direct {
			c.send(map[string]any{"op": "box", "box": wire.Bytes(box)})
		}
		return
	}
	if relay != nil {
		out := map[string]any{"op": "send", "to": approverID, "box": wire.Bytes(box)}
		if p != nil {
			spec := map[string]any{"collapse": p.collapse}
			if p.quiet {
				spec["quiet"] = true
			}
			if p.repeat {
				spec["repeat"] = true
			}
			out["push"] = spec
		}
		relay.send(out)
	}
}

// status tells every approver how request id went. When it just left
// pending, iPhones also get a quiet push that replaces its notification
// (approved elsewhere, denied, expired, withdrawn): nothing keeps asking.
func (b *Broker) status(id string, msg map[string]any, leftPending bool) {
	b.mu.Lock()
	var approvers []wire.Approver
	if b.roster != nil {
		approvers = append(approvers, b.roster.Approvers...)
	}
	b.mu.Unlock()
	for _, a := range approvers {
		var p *push
		if leftPending && a.Platform == "ios" {
			p = &push{collapse: id + ".end", quiet: true}
		}
		b.deliver(a.ID, msg, p)
	}
}
