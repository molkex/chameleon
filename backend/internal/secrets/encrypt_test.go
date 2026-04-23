package secrets

import (
	"crypto/rand"
	"encoding/hex"
	"strings"
	"testing"
)

func mustKey(t *testing.T) string {
	t.Helper()
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		t.Fatalf("rand: %v", err)
	}
	return hex.EncodeToString(b)
}

func TestRoundTrip(t *testing.T) {
	c, err := New(mustKey(t))
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	cases := []string{"", "x", "hunter2", strings.Repeat("a", 4096), "юникод 🐸"}
	for _, p := range cases {
		ct, err := c.Encrypt(p)
		if err != nil {
			t.Fatalf("encrypt(%q): %v", p, err)
		}
		got, err := c.Decrypt(ct)
		if err != nil {
			t.Fatalf("decrypt(%q): %v", ct, err)
		}
		if got != p {
			t.Errorf("round-trip: got %q, want %q", got, p)
		}
	}
}

func TestEmptyKeyDisabled(t *testing.T) {
	c, err := New("")
	if err != nil {
		t.Fatalf("new(\"\"): %v", err)
	}
	if c != nil {
		t.Fatalf("expected nil cipher for empty key, got %#v", c)
	}
}

func TestPlaintextPassthrough(t *testing.T) {
	c, err := New(mustKey(t))
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	// Migration case: row was written before KEK existed.
	got, err := c.Decrypt("legacy plaintext")
	if err != nil {
		t.Fatalf("decrypt legacy: %v", err)
	}
	if got != "legacy plaintext" {
		t.Errorf("plaintext passthrough: got %q", got)
	}
}

func TestRejectsShortKey(t *testing.T) {
	if _, err := New(hex.EncodeToString([]byte("short"))); err == nil {
		t.Fatal("expected error for short key")
	}
}

func TestNonceUniqueness(t *testing.T) {
	c, err := New(mustKey(t))
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	a, _ := c.Encrypt("same")
	b, _ := c.Encrypt("same")
	if a == b {
		t.Error("expected distinct ciphertexts for same plaintext (random nonce)")
	}
}

func TestWrongKeyFailsDecrypt(t *testing.T) {
	c1, _ := New(mustKey(t))
	c2, _ := New(mustKey(t))
	ct, _ := c1.Encrypt("hello")
	if _, err := c2.Decrypt(ct); err == nil {
		t.Error("expected decrypt with wrong key to fail")
	}
}
