package vpn

import (
	"crypto/ecdh"
	"encoding/base64"
	"fmt"
)

// DerivePublicKeyBase64URL derives the X25519 public key that corresponds to
// a given Reality private key and returns it as base64url (no padding) —
// the exact format clients expect in the `public_key` Reality field.
//
// sing-box generates Reality keypairs via x25519; a mismatch between
// `reality_private_key` and `reality_public_key` in the vpn_servers table
// silently breaks TLS handshakes for every client talking to that server.
// Call this on startup to validate the DB against physics.
func DerivePublicKeyBase64URL(privateKeyB64URL string) (string, error) {
	raw, err := base64.RawURLEncoding.DecodeString(privateKeyB64URL)
	if err != nil {
		// Tolerate legacy padded base64url (some tooling emits '='). Try
		// standard decoding before giving up — cheaper than rejecting a
		// valid key over a cosmetic separator.
		raw, err = base64.URLEncoding.DecodeString(privateKeyB64URL)
		if err != nil {
			return "", fmt.Errorf("decode reality private key: %w", err)
		}
	}
	if len(raw) != 32 {
		return "", fmt.Errorf("reality private key must be 32 bytes, got %d", len(raw))
	}
	priv, err := ecdh.X25519().NewPrivateKey(raw)
	if err != nil {
		return "", fmt.Errorf("construct x25519 key: %w", err)
	}
	pub := priv.PublicKey().Bytes()
	return base64.RawURLEncoding.EncodeToString(pub), nil
}

// ValidateRealityKeyPair checks that `publicKey` is the x25519-derived
// public key of `privateKey`. Both inputs are base64url-encoded (padded
// or unpadded — both accepted).
//
// Returns nil when they match. Returns a descriptive error on mismatch
// so callers can log and/or fail-fast. The error message is suitable
// for startup logs — it includes the expected vs actual pubkey strings
// so ops can `sed` the DB fix without further tooling.
func ValidateRealityKeyPair(privateKey, publicKey string) error {
	if privateKey == "" {
		return fmt.Errorf("reality private key is empty")
	}
	if publicKey == "" {
		return fmt.Errorf("reality public key is empty")
	}
	derived, err := DerivePublicKeyBase64URL(privateKey)
	if err != nil {
		return fmt.Errorf("derive public from private: %w", err)
	}
	// Accept both padded and unpadded base64url when comparing — the DB
	// row might have one and the engine config the other.
	normalize := func(s string) string {
		// Strip '=' padding for consistent comparison.
		for len(s) > 0 && s[len(s)-1] == '=' {
			s = s[:len(s)-1]
		}
		return s
	}
	if normalize(derived) != normalize(publicKey) {
		return fmt.Errorf(
			"reality public key does not match private key: derived=%s expected=%s",
			derived, normalize(publicKey),
		)
	}
	return nil
}
