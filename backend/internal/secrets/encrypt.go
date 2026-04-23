// Package secrets provides AES-256-GCM encryption for sensitive fields
// stored in the DB (provider passwords, API keys). The key (KEK) is loaded
// from config / env so it never enters the DB or repo. Format on disk:
//
//	"v1:" + base64(nonce || ciphertext || tag)
//
// The "v1:" prefix lets us tell encrypted values apart from plaintext during
// migration and lets future versions co-exist. Decrypting an unprefixed
// value passes it through unchanged — operators can drop a KEK on an
// existing DB and watch values get re-encrypted lazily on the next write.
package secrets

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
)

// Cipher encrypts/decrypts short opaque blobs (DB columns).
type Cipher struct {
	aead cipher.AEAD
}

// New returns a Cipher built from a 32-byte key. The key may be passed as
// 64-char hex or base64-std (44 chars including padding); both forms decode
// to 32 bytes. Empty key returns (nil, nil) — callers can treat nil as
// "encryption disabled" and pass values through.
func New(key string) (*Cipher, error) {
	key = strings.TrimSpace(key)
	if key == "" {
		return nil, nil
	}
	raw, err := decodeKey(key)
	if err != nil {
		return nil, fmt.Errorf("decode KEK: %w", err)
	}
	if len(raw) != 32 {
		return nil, fmt.Errorf("KEK must be 32 bytes (got %d) — use 64 hex chars or base64-std of 32 bytes", len(raw))
	}
	block, err := aes.NewCipher(raw)
	if err != nil {
		return nil, fmt.Errorf("aes.NewCipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("cipher.NewGCM: %w", err)
	}
	return &Cipher{aead: gcm}, nil
}

const prefix = "v1:"

// Encrypt wraps plaintext as "v1:" + base64(nonce || ciphertext || tag).
// Empty input returns empty (no point encrypting nothing, and lets DB upserts
// keep their COALESCE(NULLIF(...)) "preserve on empty" semantics).
func (c *Cipher) Encrypt(plaintext string) (string, error) {
	if c == nil || plaintext == "" {
		return plaintext, nil
	}
	nonce := make([]byte, c.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", fmt.Errorf("nonce: %w", err)
	}
	sealed := c.aead.Seal(nonce, nonce, []byte(plaintext), nil)
	return prefix + base64.StdEncoding.EncodeToString(sealed), nil
}

// Decrypt unwraps a "v1:"-prefixed value. Anything without the prefix is
// returned unchanged — that covers legacy plaintext rows during migration
// and survives a misconfigured KEK on read paths that don't strictly need
// the value (e.g. the admin UI that just doesn't display the password).
func (c *Cipher) Decrypt(ciphertext string) (string, error) {
	if !strings.HasPrefix(ciphertext, prefix) {
		return ciphertext, nil
	}
	if c == nil {
		return "", errors.New("encrypted value found but no KEK configured")
	}
	body := strings.TrimPrefix(ciphertext, prefix)
	raw, err := base64.StdEncoding.DecodeString(body)
	if err != nil {
		return "", fmt.Errorf("base64 decode: %w", err)
	}
	ns := c.aead.NonceSize()
	if len(raw) < ns {
		return "", errors.New("ciphertext shorter than nonce")
	}
	nonce, sealed := raw[:ns], raw[ns:]
	plain, err := c.aead.Open(nil, nonce, sealed, nil)
	if err != nil {
		return "", fmt.Errorf("aead.Open: %w", err)
	}
	return string(plain), nil
}

func decodeKey(s string) ([]byte, error) {
	// Try hex first (most common for "openssl rand -hex 32"), then base64.
	if raw, err := hex.DecodeString(s); err == nil {
		return raw, nil
	}
	return base64.StdEncoding.DecodeString(s)
}
