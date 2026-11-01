// Package wire is approval protocol v1 (PROTOCOL.md): keys, signed
// envelopes, HPKE boxes, rosters and the messages built from them.
package wire

import (
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
)

// B64 is the protocol's base64: URL alphabet, no padding.
var B64 = base64.RawURLEncoding

// Bytes marshals as b64.
type Bytes []byte

func (b Bytes) MarshalJSON() ([]byte, error) { return json.Marshal(B64.EncodeToString(b)) }

func (b *Bytes) UnmarshalJSON(data []byte) error {
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return err
	}
	v, err := B64.Strict().DecodeString(s)
	if err != nil {
		return fmt.Errorf("b64: %w", err)
	}
	*b = v
	return nil
}

// KID is a key's id: hex of the first 12 bytes of SHA-256 of its X9.63 bytes.
func KID(x963 []byte) string {
	sum := sha256.Sum256(x963)
	return hex.EncodeToString(sum[:12])
}

// PublicKey parses an X9.63 uncompressed P-256 public key.
func PublicKey(x963 []byte) (*ecdsa.PublicKey, error) {
	key, err := ecdh.P256().NewPublicKey(x963)
	if err != nil {
		return nil, fmt.Errorf("public key: %w", err)
	}
	raw := key.Bytes()
	return &ecdsa.PublicKey{Curve: elliptic.P256(),
		X: new(big.Int).SetBytes(raw[1:33]), Y: new(big.Int).SetBytes(raw[33:])}, nil
}

// SigningKey is a P-256 key that signs envelopes.
type SigningKey struct{ Private *ecdsa.PrivateKey }

// NewSigningKey makes a random key.
func NewSigningKey() (*SigningKey, error) {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	return &SigningKey{k}, nil
}

// SigningKeyFromScalar loads a key from its 32-byte scalar.
func SigningKeyFromScalar(d []byte) (*SigningKey, error) {
	priv, err := ecdh.P256().NewPrivateKey(d)
	if err != nil {
		return nil, err
	}
	pub := priv.PublicKey().Bytes()
	return &SigningKey{&ecdsa.PrivateKey{
		PublicKey: ecdsa.PublicKey{Curve: elliptic.P256(),
			X: new(big.Int).SetBytes(pub[1:33]), Y: new(big.Int).SetBytes(pub[33:])},
		D: new(big.Int).SetBytes(d),
	}}, nil
}

// Scalar is the key's 32-byte scalar, for storage.
func (k *SigningKey) Scalar() []byte { return k.Private.D.FillBytes(make([]byte, 32)) }

// Public is the X9.63 public key.
func (k *SigningKey) Public() []byte { return marshalPublic(&k.Private.PublicKey) }

// ID is the public key's kid.
func (k *SigningKey) ID() string { return KID(k.Public()) }

func marshalPublic(pub *ecdsa.PublicKey) []byte {
	out := make([]byte, 65)
	out[0] = 4
	pub.X.FillBytes(out[1:33])
	pub.Y.FillBytes(out[33:])
	return out
}

// Envelope is a signed JSON payload.
type Envelope struct {
	Type    string `json:"t"`
	Key     string `json:"k"`
	Payload Bytes  `json:"p"`
	Sig     Bytes  `json:"s"`
}

func signedMessage(typ string, payload []byte) []byte {
	msg := make([]byte, 0, len(typ)+6+len(payload))
	msg = append(msg, "BKA1 "...)
	msg = append(msg, typ...)
	msg = append(msg, '\n')
	return append(msg, payload...)
}

// Digest is SHA-256 of the signed message.
func (e *Envelope) Digest() [32]byte { return sha256.Sum256(signedMessage(e.Type, e.Payload)) }

// DigestHex is Digest in lowercase hex, as JSON refers to it.
func (e *Envelope) DigestHex() string {
	d := e.Digest()
	return hex.EncodeToString(d[:])
}

// Sign marshals payload and signs it as typ.
func Sign(key *SigningKey, typ string, payload any) (*Envelope, error) {
	data, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	return SignBytes(key, typ, data)
}

// SignBytes signs payload bytes as they are.
func SignBytes(key *SigningKey, typ string, payload []byte) (*Envelope, error) {
	digest := sha256.Sum256(signedMessage(typ, payload))
	r, s, err := ecdsa.Sign(rand.Reader, key.Private, digest[:])
	if err != nil {
		return nil, err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return &Envelope{Type: typ, Key: key.ID(), Payload: payload, Sig: sig}, nil
}

// Errors from Verify.
var (
	ErrType      = errors.New("unexpected envelope type")
	ErrSignature = errors.New("bad signature")
	ErrSigner    = errors.New("signed by an unexpected key")
)

// Verify checks that e is a typ envelope signed by pub (X9.63) and decodes
// its payload into out (when not nil).
func (e *Envelope) Verify(typ string, pub []byte, out any) error {
	if e == nil {
		return errors.New("no envelope")
	}
	if e.Type != typ {
		return fmt.Errorf("%w: %q, want %q", ErrType, e.Type, typ)
	}
	if e.Key != KID(pub) {
		return ErrSigner
	}
	key, err := PublicKey(pub)
	if err != nil {
		return err
	}
	if len(e.Sig) != 64 {
		return ErrSignature
	}
	digest := sha256.Sum256(signedMessage(e.Type, e.Payload))
	r, s := new(big.Int).SetBytes(e.Sig[:32]), new(big.Int).SetBytes(e.Sig[32:])
	if !ecdsa.Verify(key, digest[:], r, s) {
		return ErrSignature
	}
	if out != nil {
		if err := json.Unmarshal(e.Payload, out); err != nil {
			return fmt.Errorf("%s payload: %w", typ, err)
		}
	}
	return nil
}

// Peek decodes the payload without checking the signature: only to find
// which key to check it with.
func (e *Envelope) Peek(out any) error { return json.Unmarshal(e.Payload, out) }

// Nonce returns n random bytes.
func Nonce(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}

// RandomID is 16 random bytes in hex.
func RandomID() string { return hex.EncodeToString(Nonce(16)) }
