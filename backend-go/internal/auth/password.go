package auth

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/alexedwards/argon2id"
	"golang.org/x/crypto/bcrypt"
)

// Argon2id parameters — banking-grade defaults.
var argon2Params = &argon2id.Params{
	Memory:      64 * 1024, // 64 MB
	Iterations:  3,
	Parallelism: 4,
	SaltLength:  16,
	KeyLength:   32,
}

// HashPassword creates an argon2id hash of the given plaintext password.
func HashPassword(password string) (string, error) {
	hash, err := argon2id.CreateHash(password, argon2Params)
	if err != nil {
		return "", fmt.Errorf("auth: hash password: %w", err)
	}
	return hash, nil
}

// VerifyPassword checks a plaintext password against a stored hash.
//
// Returns:
//   - matches: true if the password is correct.
//   - needsRehash: true if the hash uses a legacy algorithm (bcrypt or SHA-256)
//     and the caller should re-hash with argon2id.
func VerifyPassword(password, hash string) (matches bool, needsRehash bool) {
	switch {
	case isArgon2Hash(hash):
		return verifyArgon2(password, hash), false

	case isBcryptHash(hash):
		return verifyBcrypt(password, hash), true

	case isSHA256Hash(hash):
		return verifySHA256(password, hash), true

	default:
		return false, false
	}
}

// isArgon2Hash returns true if the hash starts with the argon2 prefix.
func isArgon2Hash(hash string) bool {
	return strings.HasPrefix(hash, "$argon2")
}

// isBcryptHash returns true if the hash starts with a bcrypt prefix ($2a$, $2b$, $2y$).
func isBcryptHash(hash string) bool {
	return strings.HasPrefix(hash, "$2")
}

// isSHA256Hash returns true if the hash is a 64-character hex string (SHA-256).
func isSHA256Hash(hash string) bool {
	if len(hash) != 64 {
		return false
	}
	_, err := hex.DecodeString(hash)
	return err == nil
}

// verifyArgon2 checks password against an argon2id hash.
func verifyArgon2(password, hash string) bool {
	match, err := argon2id.ComparePasswordAndHash(password, hash)
	if err != nil {
		return false
	}
	return match
}

// verifyBcrypt checks password against a bcrypt hash.
func verifyBcrypt(password, hash string) bool {
	err := bcrypt.CompareHashAndPassword([]byte(hash), []byte(password))
	return err == nil
}

// verifySHA256 checks password against a SHA-256 hex digest.
// Uses constant-time comparison to prevent timing attacks.
func verifySHA256(password, hash string) bool {
	computed := sha256.Sum256([]byte(password))
	computedHex := hex.EncodeToString(computed[:])
	return subtle.ConstantTimeCompare([]byte(computedHex), []byte(hash)) == 1
}
