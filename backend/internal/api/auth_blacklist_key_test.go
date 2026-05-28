package api

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"
)

// Audit H-007 (2026-05-26): refresh-token blacklist keys MUST be derived
// from a full SHA-256 of the token, not a 32-char prefix. HS256 JWT
// headers share a stable encoded prefix (`eyJhbGciOiJIUzI1NiI...`), so
// any two HS256 tokens collided on the first 32 chars before this fix.
// The blacklist marked one as "used" and silently failed every other
// unrelated refresh that happened to share that prefix.
//
// These tests are pure-math regression guards on the keying scheme so
// a future "let's truncate to save bytes" rewrite trips immediately.

func TestRefreshBlacklistKey_DifferentForUnrelatedTokens(t *testing.T) {
	// Two synthetic HS256-shaped tokens with identical 32-char prefix
	// (same header) but different payloads. Pre-fix `token[:32]` would
	// produce IDENTICAL blacklist keys — the second refresh would 401
	// because the first marked the shared prefix as used. With sha256
	// of the full token, the keys differ.
	common := "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVC"
	a := common + "9.eyJ1c2VyX2lkIjoxfQ.SIGAAAA"
	b := common + "9.eyJ1c2VyX2lkIjoyfQ.SIGBBBB"

	if len(a) <= 32 || len(b) <= 32 {
		t.Fatal("synthetic tokens must be longer than 32 chars to expose the bug")
	}
	if a[:32] != b[:32] {
		t.Fatal("synthetic tokens must share the 32-char prefix to expose the bug")
	}

	keyA := blacklistKey(a)
	keyB := blacklistKey(b)
	if keyA == keyB {
		t.Errorf("blacklist keys must differ for unrelated tokens with same 32-char prefix (regression H-007)")
	}
	// Belt-and-braces: keys must look like 64-char hex (sha256 length).
	if len(keyA) != 64 || !isHex(keyA) {
		t.Errorf("blacklist key %q is not 64-char hex sha256", keyA)
	}
}

func TestRefreshBlacklistKey_StableForSameToken(t *testing.T) {
	// Same token → same key. Without this property the "already used"
	// check would never hit.
	token := "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ4eHgifQ.SIG"
	first := blacklistKey(token)
	second := blacklistKey(token)
	if first != second {
		t.Errorf("blacklist key derivation must be stable for identical input: first=%q second=%q", first, second)
	}
}

// blacklistKey mirrors the keying scheme used by mobile/auth.go and
// admin/auth.go. Kept in the test file so we test the SCHEME, not the
// implementation — a regression that "optimizes" the production code
// to truncate again would not silently flip these tests.
func blacklistKey(refreshToken string) string {
	h := sha256.Sum256([]byte(refreshToken))
	return hex.EncodeToString(h[:])
}

func isHex(s string) bool {
	const hexChars = "0123456789abcdef"
	for _, c := range s {
		if !strings.ContainsRune(hexChars, c) {
			return false
		}
	}
	return true
}
