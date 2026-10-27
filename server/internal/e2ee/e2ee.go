// Package e2ee implements the v1 "fanout" envelope scheme from docs/PROTOCOL.md.
//
// The server never calls Open or Unwrap for user traffic. It is used by
// server-side bots (webhooks) and by tests that pin the wire format so the
// Swift and Kotlin implementations can be checked against it.
package e2ee

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"io"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/hkdf"
)

const (
	WrapInfo       = "asgard-wrap-v1"
	WrappedKeySize = 32 + chacha20poly1305.NonceSize + 32 + chacha20poly1305.Overhead // 92
)

var ErrDecrypt = errors.New("e2ee: decryption failed")

// DeviceKeys is a device's long-term key material.
type DeviceKeys struct {
	IdentityPrivate [32]byte // X25519
	IdentityPublic  [32]byte
	SigningPrivate  ed25519.PrivateKey
	SigningPublic   ed25519.PublicKey
}

func GenerateDeviceKeys() (*DeviceKeys, error) {
	k := &DeviceKeys{}
	if _, err := rand.Read(k.IdentityPrivate[:]); err != nil {
		return nil, err
	}
	pub, err := curve25519.X25519(k.IdentityPrivate[:], curve25519.Basepoint)
	if err != nil {
		return nil, err
	}
	copy(k.IdentityPublic[:], pub)
	k.SigningPublic, k.SigningPrivate, err = ed25519.GenerateKey(rand.Reader)
	return k, err
}

// AAD binds a ciphertext to its conversation, sender device and client id.
func AAD(conversationID, senderDeviceID, clientID string) []byte {
	b := make([]byte, 0, len(conversationID)+len(senderDeviceID)+len(clientID)+2)
	b = append(b, conversationID...)
	b = append(b, 0)
	b = append(b, senderDeviceID...)
	b = append(b, 0)
	b = append(b, clientID...)
	return b
}

// Seal encrypts content with a fresh message key. Returns key, nonce||ciphertext.
func Seal(content, aad []byte) (key, ciphertext []byte, err error) {
	key = make([]byte, chacha20poly1305.KeySize)
	if _, err = rand.Read(key); err != nil {
		return nil, nil, err
	}
	ciphertext, err = sealWith(key, content, aad)
	return key, ciphertext, err
}

func Open(key, ciphertext, aad []byte) ([]byte, error) {
	return openWith(key, ciphertext, aad)
}

func Sign(priv ed25519.PrivateKey, aad, ciphertext []byte) []byte {
	return ed25519.Sign(priv, digest(aad, ciphertext))
}

func Verify(pub ed25519.PublicKey, aad, ciphertext, sig []byte) bool {
	return len(pub) == ed25519.PublicKeySize && ed25519.Verify(pub, digest(aad, ciphertext), sig)
}

// Wrap encrypts a message key to one recipient device identity key.
func Wrap(messageKey []byte, recipientIdentity []byte, clientID string) ([]byte, error) {
	if len(recipientIdentity) != 32 {
		return nil, errors.New("e2ee: bad identity key")
	}
	var eph [32]byte
	if _, err := rand.Read(eph[:]); err != nil {
		return nil, err
	}
	ephPub, err := curve25519.X25519(eph[:], curve25519.Basepoint)
	if err != nil {
		return nil, err
	}
	wk, err := wrapKey(eph[:], ephPub, recipientIdentity)
	if err != nil {
		return nil, err
	}
	sealed, err := sealWith(wk, messageKey, []byte(clientID))
	if err != nil {
		return nil, err
	}
	return append(ephPub, sealed...), nil
}

// Unwrap recovers a message key with the recipient's identity private key.
func Unwrap(wrapped []byte, identityPrivate, identityPublic [32]byte, clientID string) ([]byte, error) {
	if len(wrapped) != WrappedKeySize {
		return nil, ErrDecrypt
	}
	ephPub := wrapped[:32]
	shared, err := curve25519.X25519(identityPrivate[:], ephPub)
	if err != nil {
		return nil, ErrDecrypt
	}
	wk, err := derive(shared, ephPub, identityPublic[:])
	if err != nil {
		return nil, err
	}
	return openWith(wk, wrapped[32:], []byte(clientID))
}

func wrapKey(ephPriv, ephPub, recipient []byte) ([]byte, error) {
	shared, err := curve25519.X25519(ephPriv, recipient)
	if err != nil {
		return nil, err
	}
	return derive(shared, ephPub, recipient)
}

func derive(shared, ephPub, recipient []byte) ([]byte, error) {
	salt := append(append([]byte{}, ephPub...), recipient...)
	out := make([]byte, 32)
	if _, err := io.ReadFull(hkdf.New(sha256.New, shared, salt, []byte(WrapInfo)), out); err != nil {
		return nil, err
	}
	return out, nil
}

func sealWith(key, plaintext, aad []byte) ([]byte, error) {
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize(), aead.NonceSize()+len(plaintext)+aead.Overhead())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return aead.Seal(nonce, nonce, plaintext, aad), nil
}

func openWith(key, data, aad []byte) ([]byte, error) {
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return nil, err
	}
	if len(data) < aead.NonceSize()+aead.Overhead() {
		return nil, ErrDecrypt
	}
	pt, err := aead.Open(nil, data[:aead.NonceSize()], data[aead.NonceSize():], aad)
	if err != nil {
		return nil, ErrDecrypt
	}
	return pt, nil
}

func digest(aad, ciphertext []byte) []byte {
	h := sha256.New()
	h.Write(aad)
	h.Write(ciphertext)
	return h.Sum(nil)
}

// SealAtRest / OpenAtRest protect server-held secrets with the master key.
func SealAtRest(masterKey, plaintext []byte, label string) ([]byte, error) {
	return sealWith(masterKey, plaintext, []byte(label))
}

func OpenAtRest(masterKey, data []byte, label string) ([]byte, error) {
	return openWith(masterKey, data, []byte(label))
}
