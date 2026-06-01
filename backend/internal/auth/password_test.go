package auth

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

// Admin-login credential path. VerifyPassword must (a) accept the correct
// password across all three stored formats, (b) reject wrong passwords, and
// (c) signal needsRehash for the two legacy formats so callers upgrade them.

func TestHashPasswordRoundTrip(t *testing.T) {
	const pw = "correct horse battery staple"
	hash, err := HashPassword(pw)
	if err != nil {
		t.Fatalf("HashPassword: %v", err)
	}
	if !isArgon2Hash(hash) {
		t.Fatalf("HashPassword did not produce an argon2 hash: %q", hash)
	}

	matches, needsRehash := VerifyPassword(pw, hash)
	if !matches {
		t.Error("correct password did not match its argon2 hash")
	}
	if needsRehash {
		t.Error("a fresh argon2 hash must not request a rehash")
	}

	if m, _ := VerifyPassword("wrong", hash); m {
		t.Error("wrong password matched the argon2 hash")
	}
}

func TestVerifyPasswordBcryptLegacy(t *testing.T) {
	const pw = "s3cret-pw"
	b, err := bcrypt.GenerateFromPassword([]byte(pw), bcrypt.MinCost)
	if err != nil {
		t.Fatalf("bcrypt.GenerateFromPassword: %v", err)
	}
	hash := string(b)

	matches, needsRehash := VerifyPassword(pw, hash)
	if !matches {
		t.Error("correct password did not match its bcrypt hash")
	}
	if !needsRehash {
		t.Error("bcrypt is legacy — must request a rehash")
	}
	if m, _ := VerifyPassword("nope", hash); m {
		t.Error("wrong password matched the bcrypt hash")
	}
}

func TestVerifyPasswordSHA256Legacy(t *testing.T) {
	const pw = "legacy-sha-pw"
	sum := sha256.Sum256([]byte(pw))
	hash := hex.EncodeToString(sum[:])

	matches, needsRehash := VerifyPassword(pw, hash)
	if !matches {
		t.Error("correct password did not match its sha256 hash")
	}
	if !needsRehash {
		t.Error("sha256 is legacy — must request a rehash")
	}
	if m, _ := VerifyPassword("nope", hash); m {
		t.Error("wrong password matched the sha256 hash")
	}
}

func TestVerifyPasswordUnknownFormat(t *testing.T) {
	matches, needsRehash := VerifyPassword("x", "not-a-known-hash-format")
	if matches || needsRehash {
		t.Errorf("unknown hash format: want (false,false), got (%v,%v)", matches, needsRehash)
	}
}

func TestHashFormatDetectors(t *testing.T) {
	tests := []struct {
		name string
		fn   func(string) bool
		in   string
		want bool
	}{
		{"argon2 prefix", isArgon2Hash, "$argon2id$v=19$m=65536,t=3,p=4$abc$def", true},
		{"argon2 vs bcrypt", isArgon2Hash, "$2a$10$abc", false},
		{"bcrypt 2a", isBcryptHash, "$2a$10$abc", true},
		{"bcrypt 2b", isBcryptHash, "$2b$10$abc", true},
		{"bcrypt 2y", isBcryptHash, "$2y$10$abc", true},
		{"bcrypt vs argon2", isBcryptHash, "$argon2id$...", false},
		{"sha256 64 hex", isSHA256Hash, strings.Repeat("a", 64), true},
		{"sha256 wrong length", isSHA256Hash, "abcd", false},
		{"sha256 64 non-hex", isSHA256Hash, strings.Repeat("z", 64), false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.fn(tc.in); got != tc.want {
				t.Errorf("got %v, want %v for %q", got, tc.want, tc.in)
			}
		})
	}
}
