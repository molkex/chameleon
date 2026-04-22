package db

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// MagicToken is a single-use, short-lived login token issued to an email.
// Created when the user requests a magic link and consumed once they follow it.
type MagicToken struct {
	ID         int64
	TokenHash  string // sha256 hex of the raw token
	Email      string // always stored lower-case
	UserID     *int64 // null when the token was issued before the user row existed
	Purpose    string // "email_login" | "apple_backup" | "google_backup" | etc.
	ExpiresAt  time.Time
	UsedAt     *time.Time
	CreatedIP  *string
	CreatedAt  time.Time
}

// MagicRequestRateLimit caps requests per email address in a short window.
// Default policy: 5 requests per hour. Enforced at handler level via a COUNT().
const MagicRequestRateLimit = 5
const MagicRequestRateWindow = time.Hour

// GenerateRawToken returns a URL-safe random token (32 bytes → 43 chars base64).
// Keep the raw value to send to the user; store only the hash.
func GenerateRawToken() (raw, hashHex string, err error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", "", fmt.Errorf("rand: %w", err)
	}
	raw = base64URLEncode(buf)
	sum := sha256.Sum256([]byte(raw))
	return raw, hex.EncodeToString(sum[:]), nil
}

// HashToken mirrors GenerateRawToken's hashing so handlers can look up by
// hash from an incoming raw token.
func HashToken(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

// CreateMagicToken persists a new token. `expiresIn` defaults to 15m if zero.
func (db *DB) CreateMagicToken(ctx context.Context, tokenHash, email, purpose string,
	userID *int64, createdIP *string, expiresIn time.Duration) error {
	if expiresIn == 0 {
		expiresIn = 15 * time.Minute
	}
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	email = strings.ToLower(strings.TrimSpace(email))
	_, err := db.Pool.Exec(ctx, `
		INSERT INTO magic_tokens (token_hash, email, user_id, purpose, expires_at, created_ip)
		VALUES ($1, $2, $3, $4, $5, $6)`,
		tokenHash, email, userID, purpose, time.Now().Add(expiresIn), createdIP)
	return err
}

// ConsumeMagicToken atomically marks a token as used and returns its payload.
// Returns nil if not found, expired, or already used — callers should map this
// to 401/403 as appropriate.
//
// The UPDATE ... WHERE used_at IS NULL pattern guarantees single-use even under
// concurrent retries; RETURNING lets us read the row that was actually updated.
func (db *DB) ConsumeMagicToken(ctx context.Context, tokenHash string) (*MagicToken, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	row := db.Pool.QueryRow(ctx, `
		UPDATE magic_tokens
		SET used_at = NOW()
		WHERE token_hash = $1
		  AND used_at IS NULL
		  AND expires_at > NOW()
		RETURNING id, token_hash, email, user_id, purpose, expires_at, used_at, created_ip, created_at`,
		tokenHash)

	var t MagicToken
	err := row.Scan(&t.ID, &t.TokenHash, &t.Email, &t.UserID, &t.Purpose,
		&t.ExpiresAt, &t.UsedAt, &t.CreatedIP, &t.CreatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &t, nil
}

// CountRecentMagicRequests returns the number of tokens issued for the given
// email within the rate-limit window. Used by the handler to refuse abusive
// retry loops.
func (db *DB) CountRecentMagicRequests(ctx context.Context, email string, window time.Duration) (int, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	email = strings.ToLower(strings.TrimSpace(email))
	var count int
	err := db.Pool.QueryRow(ctx, `
		SELECT COUNT(*) FROM magic_tokens
		WHERE LOWER(email) = $1
		  AND created_at > NOW() - $2::interval`,
		email, fmt.Sprintf("%d seconds", int(window.Seconds()))).Scan(&count)
	return count, err
}

// FindUserByEmail returns a user by case-insensitive email match, or nil if
// not found. Used by the magic-link flow to decide between login and signup.
func (db *DB) FindUserByEmail(ctx context.Context, email string) (*User, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	email = strings.ToLower(strings.TrimSpace(email))
	row := db.Pool.QueryRow(ctx,
		`SELECT `+userColumns+` FROM users WHERE LOWER(email) = $1`, email)
	return scanUser(row)
}

// MarkEmailVerified flips the email_verified_at timestamp. Called after the
// first successful magic-link consume, so we know the address is genuinely
// under the user's control.
func (db *DB) MarkEmailVerified(ctx context.Context, userID int64) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	_, err := db.Pool.Exec(ctx,
		`UPDATE users SET email_verified_at = NOW() WHERE id = $1 AND email_verified_at IS NULL`,
		userID)
	return err
}

// base64URLEncode renders raw bytes in url-safe base64 without padding —
// keeps tokens compact and safe to stuff into URL query parameters.
func base64URLEncode(b []byte) string {
	// Manual impl to avoid pulling in encoding/base64 just for this; but
	// stdlib is already imported elsewhere so use it.
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	out := make([]byte, 0, (len(b)*4+2)/3)
	for i := 0; i < len(b); i += 3 {
		var buf [4]byte
		chunk := b[i:]
		if len(chunk) > 3 {
			chunk = chunk[:3]
		}
		buf[0] = alphabet[chunk[0]>>2]
		if len(chunk) > 1 {
			buf[1] = alphabet[((chunk[0]&0x03)<<4)|(chunk[1]>>4)]
			if len(chunk) > 2 {
				buf[2] = alphabet[((chunk[1]&0x0f)<<2)|(chunk[2]>>6)]
				buf[3] = alphabet[chunk[2]&0x3f]
				out = append(out, buf[:4]...)
			} else {
				buf[2] = alphabet[(chunk[1]&0x0f)<<2]
				out = append(out, buf[:3]...)
			}
		} else {
			buf[1] = alphabet[(chunk[0]&0x03)<<4]
			out = append(out, buf[:2]...)
		}
	}
	return string(out)
}
