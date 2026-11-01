package wire

import (
	"errors"
	"fmt"
	"slices"
)

// MaxApprovers is the most a roster lists (the relay's allow list too).
const MaxApprovers = 64

// Roster is a broker's trust state (PROTOCOL.md, Roster).
type Roster struct {
	V         int        `json:"v"`
	Seq       uint64     `json:"seq"`
	Issued    int64      `json:"issued"`
	Broker    Broker     `json:"broker"`
	Relay     string     `json:"relay,omitempty"`
	Owners    []string   `json:"owners"`
	Approvers []Approver `json:"approvers"`
	Targets   []Target   `json:"targets"`
}

type Broker struct {
	ID   string `json:"id"`
	Key  Bytes  `json:"key"`
	Seal Bytes  `json:"seal"`
}

type Approver struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Platform  string `json:"platform"`
	Presence  Bytes  `json:"presence"`
	Transport Bytes  `json:"transport"`
	Seal      Bytes  `json:"seal"`
}

type Target struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Key  Bytes  `json:"key"`
}

// Approver returns the approver with id, or nil.
func (r *Roster) Approver(id string) *Approver {
	for i := range r.Approvers {
		if r.Approvers[i].ID == id {
			return &r.Approvers[i]
		}
	}
	return nil
}

// Target returns the target with id, or nil.
func (r *Roster) Target(id string) *Target {
	for i := range r.Targets {
		if r.Targets[i].ID == id {
			return &r.Targets[i]
		}
	}
	return nil
}

// IsOwner reports whether id is one of the owners.
func (r *Roster) IsOwner(id string) bool { return slices.Contains(r.Owners, id) }

// Check validates the roster's own consistency.
func (r *Roster) Check() error {
	if r.V != 1 {
		return fmt.Errorf("roster version %d", r.V)
	}
	if r.Seq == 0 {
		return errors.New("roster seq 0")
	}
	if r.Broker.ID != KID(r.Broker.Key) {
		return errors.New("roster broker id doesn't match its key")
	}
	if _, err := PublicKey(r.Broker.Key); err != nil {
		return fmt.Errorf("broker key: %w", err)
	}
	if _, err := PublicKey(r.Broker.Seal); err != nil {
		return fmt.Errorf("broker seal key: %w", err)
	}
	if len(r.Owners) == 0 {
		return errors.New("roster without owners")
	}
	if len(r.Approvers) > MaxApprovers {
		return fmt.Errorf("more than %d approvers", MaxApprovers)
	}
	seen := map[string]bool{}
	for _, a := range r.Approvers {
		if a.ID != KID(a.Presence) {
			return fmt.Errorf("approver %q: id doesn't match its presence key", a.Name)
		}
		if seen[a.ID] {
			return fmt.Errorf("approver %q twice", a.ID)
		}
		seen[a.ID] = true
		for _, k := range [][]byte{a.Presence, a.Transport, a.Seal} {
			if _, err := PublicKey(k); err != nil {
				return fmt.Errorf("approver %q: %w", a.Name, err)
			}
		}
		if a.Platform != "ios" && a.Platform != "macos" {
			return fmt.Errorf("approver %q: platform %q", a.Name, a.Platform)
		}
	}
	for _, o := range r.Owners {
		if !seen[o] {
			return fmt.Errorf("owner %q isn't an approver", o)
		}
	}
	targets := map[string]bool{}
	for _, t := range r.Targets {
		if t.ID != KID(t.Key) {
			return fmt.Errorf("target %q: id doesn't match its key", t.Name)
		}
		if targets[t.ID] {
			return fmt.Errorf("target %q twice", t.ID)
		}
		targets[t.ID] = true
		if _, err := PublicKey(t.Key); err != nil {
			return fmt.Errorf("target %q: %w", t.Name, err)
		}
	}
	return nil
}

// Errors from AcceptRoster.
var (
	ErrRosterStale  = errors.New("roster isn't newer")
	ErrRosterSigner = errors.New("roster isn't signed by an owner")
	ErrRosterBroker = errors.New("roster is for another broker")
)

// AcceptRoster checks a roster envelope against the current roster (nil for
// a genesis roster, which must be signed by one of its own owners) and
// returns it decoded.
func AcceptRoster(current *Roster, env *Envelope) (*Roster, error) {
	if env == nil || env.Type != "roster" {
		return nil, ErrType
	}
	var next Roster
	if err := env.Peek(&next); err != nil {
		return nil, fmt.Errorf("roster payload: %w", err)
	}
	trust := current
	if trust == nil {
		trust = &next
	}
	signer := trust.Approver(env.Key)
	if signer == nil || !trust.IsOwner(signer.ID) {
		return nil, ErrRosterSigner
	}
	if err := env.Verify("roster", signer.Presence, &next); err != nil {
		return nil, err
	}
	if err := next.Check(); err != nil {
		return nil, err
	}
	if current != nil {
		if next.Seq <= current.Seq {
			return nil, ErrRosterStale
		}
		if next.Broker.ID != current.Broker.ID {
			return nil, ErrRosterBroker
		}
	}
	return &next, nil
}
