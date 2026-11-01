package wire

import (
	"crypto/ecdh"
	"crypto/rand"
	"errors"
	"fmt"

	"github.com/cloudflare/circl/hpke"
)

var suite = hpke.NewSuite(hpke.KEM_P256_HKDF_SHA256, hpke.KDF_HKDF_SHA256, hpke.AEAD_AES256GCM)

const (
	infoBox    = "BKA1 box"
	infoSecret = "BKA1 secret"
	encSize    = 65
)

// SealKey is a P-256 key-agreement key that opens boxes.
type SealKey struct{ Private *ecdh.PrivateKey }

// NewSealKey makes a random key.
func NewSealKey() (*SealKey, error) {
	k, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	return &SealKey{k}, nil
}

// SealKeyFromScalar loads a key from its 32-byte scalar.
func SealKeyFromScalar(d []byte) (*SealKey, error) {
	k, err := ecdh.P256().NewPrivateKey(d)
	if err != nil {
		return nil, err
	}
	return &SealKey{k}, nil
}

// Scalar is the key's 32-byte scalar, for storage.
func (k *SealKey) Scalar() []byte { return k.Private.Bytes() }

// Public is the X9.63 public key.
func (k *SealKey) Public() []byte { return k.Private.PublicKey().Bytes() }

// ID is the public key's kid.
func (k *SealKey) ID() string { return KID(k.Public()) }

func seal(to []byte, info string, aad, plaintext []byte) ([]byte, error) {
	pub, err := hpke.KEM_P256_HKDF_SHA256.Scheme().UnmarshalBinaryPublicKey(to)
	if err != nil {
		return nil, fmt.Errorf("seal key: %w", err)
	}
	sender, err := suite.NewSender(pub, []byte(info))
	if err != nil {
		return nil, err
	}
	enc, sealer, err := sender.Setup(rand.Reader)
	if err != nil {
		return nil, err
	}
	ct, err := sealer.Seal(plaintext, aad)
	if err != nil {
		return nil, err
	}
	return append(enc, ct...), nil
}

// ErrOpen means a box didn't open: another recipient, other aad, tampered.
var ErrOpen = errors.New("box doesn't open")

func (k *SealKey) open(box []byte, info string, aad []byte) ([]byte, error) {
	if len(box) < encSize+16 {
		return nil, ErrOpen
	}
	priv, err := hpke.KEM_P256_HKDF_SHA256.Scheme().UnmarshalBinaryPrivateKey(k.Private.Bytes())
	if err != nil {
		return nil, err
	}
	receiver, err := suite.NewReceiver(priv, []byte(info))
	if err != nil {
		return nil, err
	}
	opener, err := receiver.Setup(box[:encSize])
	if err != nil {
		return nil, ErrOpen
	}
	plaintext, err := opener.Open(box[encSize:], aad)
	if err != nil {
		return nil, ErrOpen
	}
	return plaintext, nil
}

// SealBox seals a message to the seal key to (X9.63).
func SealBox(to, message []byte) ([]byte, error) {
	return seal(to, infoBox, []byte(KID(to)), message)
}

// OpenBox opens a box sealed to k.
func (k *SealKey) OpenBox(box []byte) ([]byte, error) {
	return k.open(box, infoBox, []byte(k.ID()))
}

// SealSecret seals a secret to a request's seal key, bound to the request.
func SealSecret(to []byte, requestDigest [32]byte, secret []byte) ([]byte, error) {
	return seal(to, infoSecret, requestDigest[:], secret)
}

// OpenSecret opens a secret sealed to k for the request.
func (k *SealKey) OpenSecret(box []byte, requestDigest [32]byte) ([]byte, error) {
	return k.open(box, infoSecret, requestDigest[:])
}
