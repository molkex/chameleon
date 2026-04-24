package auth

import (
	"strings"
	"testing"
	"time"
)

// TestCreateAndVerifyTokenPair pins the JWT roundtrip: a token issued by
// CreateTokenPair must verify back to the same user_id/username/role with
// VerifyToken. Catches signature drift and claim-shape regressions.
func TestCreateAndVerifyTokenPair(t *testing.T) {
	mgr := NewJWTManager("test-secret-please-rotate", time.Hour, 24*time.Hour)

	pair, err := mgr.CreateTokenPair(42, "device_abcd1234", "user")
	if err != nil {
		t.Fatalf("CreateTokenPair: unexpected error: %v", err)
	}
	if pair.AccessToken == "" || pair.RefreshToken == "" {
		t.Fatal("CreateTokenPair: empty tokens")
	}
	if pair.AccessToken == pair.RefreshToken {
		t.Fatal("access and refresh tokens must differ")
	}
	if pair.ExpiresAt <= time.Now().Unix() {
		t.Fatalf("ExpiresAt %d should be in the future", pair.ExpiresAt)
	}

	claims, err := mgr.VerifyToken(pair.AccessToken)
	if err != nil {
		t.Fatalf("VerifyToken: %v", err)
	}
	if claims.UserID != 42 {
		t.Errorf("UserID: want 42, got %d", claims.UserID)
	}
	if claims.Username != "device_abcd1234" {
		t.Errorf("Username: want device_abcd1234, got %q", claims.Username)
	}
	if claims.Role != "user" {
		t.Errorf("Role: want user, got %q", claims.Role)
	}
}

// TestVerifyExpiredToken ensures expired access tokens are rejected.
// Uses a 1-nanosecond TTL so expiry is immediate.
func TestVerifyExpiredToken(t *testing.T) {
	mgr := NewJWTManager("test-secret", time.Nanosecond, time.Hour)

	pair, err := mgr.CreateTokenPair(1, "u", "user")
	if err != nil {
		t.Fatalf("CreateTokenPair: %v", err)
	}

	// Sleep to guarantee the access token is past its ExpiresAt.
	time.Sleep(5 * time.Millisecond)

	if _, err := mgr.VerifyToken(pair.AccessToken); err == nil {
		t.Fatal("VerifyToken should reject expired token")
	}
}

// TestVerifyTokenInvalidSignature ensures a token signed with one secret
// fails verification under a different secret. This is the core security
// property of the JWT manager — it must fail closed.
func TestVerifyTokenInvalidSignature(t *testing.T) {
	signer := NewJWTManager("secret-A", time.Hour, time.Hour)
	verifier := NewJWTManager("secret-B-different", time.Hour, time.Hour)

	pair, err := signer.CreateTokenPair(1, "u", "user")
	if err != nil {
		t.Fatalf("CreateTokenPair: %v", err)
	}

	if _, err := verifier.VerifyToken(pair.AccessToken); err == nil {
		t.Fatal("VerifyToken should reject token with wrong signature")
	}
}

// TestVerifyTokenMalformed covers obviously broken tokens.
func TestVerifyTokenMalformed(t *testing.T) {
	mgr := NewJWTManager("secret", time.Hour, time.Hour)

	cases := []struct {
		name  string
		token string
	}{
		{"empty", ""},
		{"garbage", "not-a-jwt"},
		{"two-segment", "header.payload"},
		{"none-alg", "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiIxIn0."},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := mgr.VerifyToken(tc.token); err == nil {
				t.Errorf("VerifyToken(%q) should fail", tc.token)
			}
		})
	}
}

// TestVerifyRefreshTokenAcceptsRefresh checks that a refresh token issued
// by CreateTokenPair is accepted by VerifyRefreshToken with claims intact.
func TestVerifyRefreshTokenAcceptsRefresh(t *testing.T) {
	mgr := NewJWTManager("secret", time.Hour, 24*time.Hour)

	pair, err := mgr.CreateTokenPair(7, "user_seven", "admin")
	if err != nil {
		t.Fatalf("CreateTokenPair: %v", err)
	}

	claims, err := mgr.VerifyRefreshToken(pair.RefreshToken)
	if err != nil {
		t.Fatalf("VerifyRefreshToken: %v", err)
	}
	if claims.UserID != 7 {
		t.Errorf("UserID: want 7, got %d", claims.UserID)
	}
	if claims.Username != "user_seven" {
		t.Errorf("Username: want user_seven, got %q", claims.Username)
	}
	if claims.Role != "admin" {
		t.Errorf("Role: want admin, got %q", claims.Role)
	}
}

// TestVerifyRefreshTokenRejectsAccessToken guards against the type confusion
// vulnerability where an access token (no token_type=refresh) is presented to
// the refresh endpoint. The manager must reject it.
func TestVerifyRefreshTokenRejectsAccessToken(t *testing.T) {
	mgr := NewJWTManager("secret", time.Hour, time.Hour)

	pair, err := mgr.CreateTokenPair(1, "u", "user")
	if err != nil {
		t.Fatalf("CreateTokenPair: %v", err)
	}

	_, err = mgr.VerifyRefreshToken(pair.AccessToken)
	if err == nil {
		t.Fatal("VerifyRefreshToken must reject access tokens (no token_type=refresh)")
	}
	if !strings.Contains(err.Error(), "refresh") {
		// Soft-check: error should mention refresh; not load-bearing but useful.
		t.Logf("error message did not mention 'refresh': %v", err)
	}
}

// TestVerifyRefreshTokenExpired ensures expired refresh tokens are rejected.
func TestVerifyRefreshTokenExpired(t *testing.T) {
	mgr := NewJWTManager("secret", time.Hour, time.Nanosecond)

	pair, err := mgr.CreateTokenPair(1, "u", "user")
	if err != nil {
		t.Fatalf("CreateTokenPair: %v", err)
	}
	time.Sleep(5 * time.Millisecond)

	if _, err := mgr.VerifyRefreshToken(pair.RefreshToken); err == nil {
		t.Fatal("VerifyRefreshToken should reject expired refresh token")
	}
}

// TestNewJWTManagerDefaults verifies the documented fallback TTLs apply
// when zero/negative durations are passed.
func TestNewJWTManagerDefaults(t *testing.T) {
	mgr := NewJWTManager("s", 0, -1)
	if mgr.accessTTL != 24*time.Hour {
		t.Errorf("accessTTL default: want 24h, got %v", mgr.accessTTL)
	}
	if mgr.refreshTTL != 720*time.Hour {
		t.Errorf("refreshTTL default: want 720h, got %v", mgr.refreshTTL)
	}
}
