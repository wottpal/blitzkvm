package wire

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"time"
	"unicode/utf8"
)

// Ask kinds.
const (
	KindSudo          = "sudo"
	KindConfirm       = "confirm"
	KindOnePassword   = "onepassword"
	KindSecurityAgent = "securityagent"
	KindUnlock        = "unlock"
)

// Secrets an ask can need.
const (
	SecretNone        = "none"
	SecretMac         = "mac"
	SecretOnePassword = "onepassword"
)

// Typing reports whether the broker acts on the screen for this kind.
func Typing(kind string) bool {
	return kind == KindOnePassword || kind == KindSecurityAgent || kind == KindUnlock
}

// Limits.
const (
	MaxAskLifetime = 120 * time.Second
	// maxTime bounds Unix times in asks (the year 3000), so their arithmetic can't overflow.
	maxTime   = 32503680000
	ClockSkew = 60 * time.Second
	MaxGrant  = 10
	maxChain  = 8
	maxText   = 2048
)

// Ask is what the target wants approved.
type Ask struct {
	V         int        `json:"v"`
	ID        string     `json:"id"`
	Target    string     `json:"target"`
	Kind      string     `json:"kind"`
	Title     string     `json:"title"`
	Detail    string     `json:"detail,omitempty"`
	Requester *Requester `json:"requester,omitempty"`
	Evidence  *Evidence  `json:"evidence,omitempty"`
	Secret    string     `json:"secret"`
	Grantable bool       `json:"grantable,omitempty"`
	// RequestedBy is the approver whose signed unlock request raised an
	// unlock ask (unlock asks only, and always).
	RequestedBy string `json:"requestedBy,omitempty"`
	Nonce       Bytes  `json:"nonce"`
	Issued      int64  `json:"issued"`
	Expires     int64  `json:"expires"`
}

type Requester struct {
	UID   int       `json:"uid"`
	User  string    `json:"user"`
	TTY   string    `json:"tty,omitempty"`
	Chain []Process `json:"chain"`
}

type Process struct {
	PID    int      `json:"pid"`
	Name   string   `json:"name"`
	Path   string   `json:"path,omitempty"`
	Args   []string `json:"args,omitempty"`
	Signer string   `json:"signer,omitempty"`
}

// Evidence is what the target saw on its screen.
type Evidence struct {
	Locked      bool         `json:"locked"`
	SecureInput *SecureInput `json:"secureInput,omitempty"`
	Window      *Rect        `json:"window,omitempty"`
	Display     *Size        `json:"display,omitempty"`
}

type SecureInput struct {
	PID    int    `json:"pid"`
	Bundle string `json:"bundle"`
	Team   string `json:"team,omitempty"`
}

type Rect struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
	W float64 `json:"w"`
	H float64 `json:"h"`
}

type Size struct {
	W float64 `json:"w"`
	H float64 `json:"h"`
}

// Check validates an ask's fields (not its signature).
func (a *Ask) Check(now time.Time) error {
	switch {
	case a.V != 1:
		return fmt.Errorf("ask version %d", a.V)
	case len(a.ID) != 32 || !isHex(a.ID):
		return errors.New("ask id")
	case a.Kind != KindSudo && a.Kind != KindConfirm && !Typing(a.Kind):
		return fmt.Errorf("ask kind %q", a.Kind)
	case a.Secret != SecretNone && a.Secret != SecretMac && a.Secret != SecretOnePassword:
		return fmt.Errorf("ask secret %q", a.Secret)
	case a.Secret != SecretNone && !Typing(a.Kind):
		return errors.New("only typing asks carry a secret")
	case a.Grantable && Typing(a.Kind):
		return errors.New("typing asks aren't grantable")
	case len(a.Nonce) != 32:
		return errors.New("ask nonce")
	case a.Title == "" || len(a.Title) > maxText || len(a.Detail) > maxText:
		return errors.New("ask text")
	case a.Issued <= 0 || a.Issued > maxTime || a.Expires <= a.Issued || a.Expires-a.Issued > int64(MaxAskLifetime/time.Second):
		return errors.New("ask lifetime")
	case a.Requester != nil && len(a.Requester.Chain) > maxChain:
		return errors.New("ask chain too long")
	case (a.Kind == KindUnlock) != (a.RequestedBy != ""):
		return errors.New("an unlock ask names who requested it, and only it")
	}
	if !now.IsZero() && now.Unix() >= a.Expires {
		return ErrExpired
	}
	return nil
}

// ErrExpired means the ask's time is up.
var ErrExpired = errors.New("expired")

// Code is the ask's matching code.
func Code(askDigest [32]byte) string {
	return fmt.Sprintf("%02d", (int(askDigest[0])<<8|int(askDigest[1]))%100)
}

// Request is the broker's offer of an ask to the approvers.
type Request struct {
	V       int       `json:"v"`
	Ask     *Envelope `json:"ask"`
	Seal    Bytes     `json:"seal"`
	Issued  int64     `json:"issued"`
	Expires int64     `json:"expires"`
}

// Decision values.
const (
	Approve = "approve"
	Deny    = "deny"
)

// Decision is an approver's answer.
type Decision struct {
	V        int    `json:"v"`
	Request  string `json:"request"`
	Ask      string `json:"ask"`
	Decision string `json:"decision"`
	Grant    int    `json:"grant,omitempty"`
	Approver string `json:"approver"`
	Issued   int64  `json:"issued"`
	Secret   Bytes  `json:"secret,omitempty"`
}

// Verified is a request whose ask and broker signatures checked out.
type Verified struct {
	Request       Request
	Ask           Ask
	RequestDigest [32]byte
	AskDigest     [32]byte
}

// VerifyRequest checks a request envelope against the roster: the broker's
// signature, the target's signature on the ask, and the ask's fields.
func VerifyRequest(roster *Roster, env *Envelope, now time.Time) (*Verified, error) {
	var v Verified
	if err := env.Verify("request", roster.Broker.Key, &v.Request); err != nil {
		return nil, fmt.Errorf("request: %w", err)
	}
	if v.Request.V != 1 || v.Request.Ask == nil {
		return nil, errors.New("request payload")
	}
	var peek Ask
	if err := v.Request.Ask.Peek(&peek); err != nil {
		return nil, err
	}
	target := roster.Target(peek.Target)
	if target == nil {
		return nil, errors.New("ask from an unknown target")
	}
	if err := v.Request.Ask.Verify("ask", target.Key, &v.Ask); err != nil {
		return nil, fmt.Errorf("ask: %w", err)
	}
	if err := v.Ask.Check(now); err != nil {
		return nil, err
	}
	if _, err := PublicKey(v.Request.Seal); err != nil {
		return nil, fmt.Errorf("request seal key: %w", err)
	}
	v.RequestDigest = env.Digest()
	v.AskDigest = v.Request.Ask.Digest()
	return &v, nil
}

// Errors from VerifyDecision.
var (
	ErrUnknownApprover = errors.New("decision from an unknown approver")
	ErrStale           = errors.New("decision outside the allowed clock skew")
	ErrMismatch        = errors.New("decision is for another request")
)

// VerifyDecision checks a decision envelope for the verified request. now is
// the checker's clock.
func VerifyDecision(roster *Roster, req *Verified, env *Envelope, now time.Time) (*Decision, error) {
	if env == nil || env.Type != "decision" {
		return nil, ErrType
	}
	var peek Decision
	if err := env.Peek(&peek); err != nil {
		return nil, err
	}
	approver := roster.Approver(peek.Approver)
	if approver == nil {
		return nil, ErrUnknownApprover
	}
	signer := approver.Presence
	if env.Key == KID(approver.Transport) && peek.Decision == Deny {
		signer = approver.Transport // a denial needs no presence
	}
	var d Decision
	if err := env.Verify("decision", signer, &d); err != nil {
		return nil, err
	}
	if d.V != 1 || d.Approver != approver.ID {
		return nil, errors.New("decision payload")
	}
	if !hexEqual(d.Request, req.RequestDigest) || !hexEqual(d.Ask, req.AskDigest) {
		return nil, ErrMismatch
	}
	switch d.Decision {
	case Approve:
		if env.Key != KID(approver.Presence) {
			return nil, errors.New("an approval needs the presence key")
		}
	case Deny:
		if d.Grant != 0 || len(d.Secret) > 0 {
			return nil, errors.New("a denial carries no grant or secret")
		}
	default:
		return nil, fmt.Errorf("decision %q", d.Decision)
	}
	if d.Grant != 0 && (d.Grant != MaxGrant || !req.Ask.Grantable) {
		return nil, errors.New("decision grant")
	}
	if len(d.Secret) > 0 && req.Ask.Secret == SecretNone {
		return nil, errors.New("decision secret for an ask without one")
	}
	skew := now.Sub(time.Unix(d.Issued, 0))
	if skew > ClockSkew || skew < -ClockSkew {
		return nil, ErrStale
	}
	if now.Unix() >= req.Ask.Expires {
		return nil, ErrExpired
	}
	return &d, nil
}

// hexEqual compares with the digest's lowercase hex exactly (Swift does too).
func hexEqual(s string, digest [32]byte) bool {
	return subtle.ConstantTimeCompare([]byte(s), []byte(hex.EncodeToString(digest[:]))) == 1
}

func isHex(s string) bool {
	_, err := hex.DecodeString(s)
	return err == nil
}

// LinkAuth is a target's answer to the broker's link hello.
type LinkAuth struct {
	V      int    `json:"v"`
	Broker string `json:"broker"`
	Target string `json:"target"`
	Nonce  Bytes  `json:"nonce"`
	Issued int64  `json:"issued"`
}

// HelloAuth is an approver's answer to a hello (direct or relay).
type HelloAuth struct {
	V        int    `json:"v"`
	Broker   string `json:"broker"`
	Approver string `json:"approver"`
	Nonce    Bytes  `json:"nonce"`
	Issued   int64  `json:"issued"`
}

// RelayAuth authenticates the broker or an approver to the relay.
// Endpoint binds it to one use: "socket", "inbox", "devices", "outbox".
type RelayAuth struct {
	V        int    `json:"v"`
	Role     string `json:"role"`
	Broker   string `json:"broker"`
	Key      Bytes  `json:"key,omitempty"`
	Approver string `json:"approver,omitempty"`
	Endpoint string `json:"endpoint"`
	Nonce    Bytes  `json:"nonce"`
	Issued   int64  `json:"issued"`
}

// UnlockRequest asks the target to raise an unlock ask: only an approver
// can, signed with its transport key (the approval that follows needs its
// presence key). The relay and the JetKVM can't forge one, so a locked Mac
// never asks for its password unless one of the owner's devices asked.
type UnlockRequest struct {
	V        int    `json:"v"`
	Broker   string `json:"broker"`
	Target   string `json:"target"`
	Approver string `json:"approver"`
	Nonce    Bytes  `json:"nonce"`
	Issued   int64  `json:"issued"`
}

// VerifyUnlock checks an unlock request for target against the roster and
// clock (the target daemon decides; the broker filters).
func VerifyUnlock(roster *Roster, env *Envelope, target string, now time.Time) (*UnlockRequest, error) {
	if env == nil {
		return nil, errors.New("no unlock request")
	}
	var peek UnlockRequest
	if err := env.Peek(&peek); err != nil {
		return nil, err
	}
	a := roster.Approver(peek.Approver)
	if a == nil {
		return nil, ErrUnknownApprover
	}
	var u UnlockRequest
	if err := env.Verify("unlock", a.Transport, &u); err != nil {
		return nil, err
	}
	if u.V != 1 || u.Approver != a.ID || u.Broker != roster.Broker.ID || u.Target != target || len(u.Nonce) != 32 {
		return nil, errors.New("unlock request for another broker or target")
	}
	skew := now.Sub(time.Unix(u.Issued, 0))
	if skew > ClockSkew || skew < -ClockSkew {
		return nil, ErrStale
	}
	return &u, nil
}

// Pairing announces an owner's one-time pairing token to the broker by its
// hash only: the token itself travels in the QR code, so the broker (or
// the relay) can't enroll a device of its own with it.
type Pairing struct {
	V       int   `json:"v"`
	Hash    Bytes `json:"hash"` // SHA-256 of the token
	Expires int64 `json:"expires"`
}

// Enroll is a new device's request to become an approver: the pairing's
// hash (for the broker) and a MAC with the token (for the inviting owner,
// who alone knows it besides the device).
type Enroll struct {
	V        int      `json:"v"`
	Pairing  Bytes    `json:"pairing"`
	Approver Approver `json:"approver"`
	MAC      Bytes    `json:"mac"`
}

// PairingHash is what the broker learns of a pairing token.
func PairingHash(token []byte) []byte {
	sum := sha256.Sum256(token)
	return sum[:]
}

// EnrollMAC binds an enrolling approver's keys and name to the token:
// HMAC-SHA256 keyed with the token over "BKA1 enroll\n" and the presence,
// transport and seal keys, the name and the platform, each preceded by its
// length (4 bytes, big-endian).
func EnrollMAC(token []byte, a Approver) []byte {
	m := hmac.New(sha256.New, token)
	m.Write([]byte("BKA1 enroll\n"))
	for _, part := range [][]byte{a.Presence, a.Transport, a.Seal, []byte(a.Name), []byte(a.Platform)} {
		n := len(part)
		m.Write([]byte{byte(n >> 24), byte(n >> 16), byte(n >> 8), byte(n)})
		m.Write(part)
	}
	return m.Sum(nil)
}

// CheckEnrollMAC verifies an enrollment against the owner's token.
func CheckEnrollMAC(token []byte, e *Enroll) bool {
	return bytes.Equal(e.Pairing, PairingHash(token)) && hmac.Equal(e.MAC, EnrollMAC(token, e.Approver))
}

// Secrets are padded to a multiple of SecretBlock (at least one block), so
// a box's size doesn't tell a password's length; the padding is zeros.
const SecretBlock = 64

// PadSecret pads a secret for sealing.
func PadSecret(secret []byte) []byte {
	out := make([]byte, (len(secret)/SecretBlock+1)*SecretBlock)
	copy(out, secret)
	return out
}

// UnpadSecret strips the padding (a password has no zero byte).
func UnpadSecret(padded []byte) []byte { return bytes.TrimRight(padded, "\x00") }

// Step is one action of the broker on the target's screen.
type Step struct {
	Click  *Point   `json:"click,omitempty"`
	Keys   []Stroke `json:"keys,omitempty"`
	Secret *KeyMap  `json:"secret,omitempty"`
	Erase  int      `json:"erase,omitempty"`
}

type Point struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
}

// Stroke is a HID usage and a modifier byte: [usage, mods] in JSON.
type Stroke [2]byte

// KeyMap types each character of a secret: the active input source's
// strokes per character.
type KeyMap struct {
	Map map[string][]Stroke `json:"map"`
}

// HID usages a Keys step may press: no character can travel this way.
var SafeKeys = map[byte]string{0x28: "Return", 0x29: "Escape", 0x2B: "Tab", 0x2A: "Backspace",
	0x39: "Caps Lock", 0: "none"}

// CheckKeys accepts only SafeKeys with Shift at most.
func CheckKeys(strokes []Stroke) error {
	for _, s := range strokes {
		if _, ok := SafeKeys[s[0]]; !ok {
			return fmt.Errorf("key 0x%02x isn't allowed in a keys step", s[0])
		}
		if s[1]&^0x22 != 0 { // left/right Shift only
			return errors.New("only Shift may accompany a keys step")
		}
	}
	return nil
}

// CharStroke reports whether a stroke types a character: a character key
// (letters and digits 0x04-0x27, space and punctuation 0x2C-0x38, the ISO
// key 0x64; not Return, Escape, Backspace or Tab) with Shift and Option at
// most. A secret
// step carries nothing else: a ⌘Tab there would send the rest of a
// password elsewhere.
func CharStroke(s Stroke) bool {
	k := s[0]
	return (k >= 0x04 && k <= 0x27 || k >= 0x2C && k <= 0x38 || k == 0x64) && s[1]&^0x66 == 0
}

// Chars maps a secret to strokes per character (one, or a dead key and its
// base); it fails before anything is typed if a character has none, or the
// map has a stroke that isn't a CharStroke.
// Check reports how many characters secret has when the map can type
// each of them, without copying it.
func (m *KeyMap) Check(secret []byte) (int, error) {
	n := 0
	for rest := secret; len(rest) > 0; n++ {
		strokes, size := m.Next(rest)
		if strokes == nil {
			return 0, errors.New("the secret has a character the target's input source can't type")
		}
		for _, s := range strokes {
			if !CharStroke(s) {
				return 0, fmt.Errorf("the key map has a stroke that types no character (0x%02x, modifiers 0x%02x)", s[0], s[1])
			}
		}
		rest = rest[size:]
	}
	return n, nil
}

// Next returns the strokes of the first character of rest and its length
// in bytes; nil strokes when the map can't type it.
func (m *KeyMap) Next(rest []byte) ([]Stroke, int) {
	r, size := utf8.DecodeRune(rest)
	if r == utf8.RuneError && size <= 1 {
		return nil, 1
	}
	strokes, ok := m.Map[string(r)]
	if !ok || len(strokes) == 0 || len(strokes) > 2 {
		return nil, size
	}
	return strokes, size
}

func (m *KeyMap) Chars(secret string) ([][]Stroke, error) {
	var out [][]Stroke
	for _, r := range secret {
		strokes, ok := m.Map[string(r)]
		if !ok || len(strokes) == 0 || len(strokes) > 2 {
			return nil, errors.New("the secret has a character the target's input source can't type")
		}
		for _, s := range strokes {
			if !CharStroke(s) {
				return nil, fmt.Errorf("the key map has a stroke that types no character (0x%02x, modifiers 0x%02x)", s[0], s[1])
			}
		}
		out = append(out, strokes)
	}
	return out, nil
}
