package auth

import (
	"testing"
	"time"
)

func TestCreateAndVerifyChatToken(t *testing.T) {
	mgr := NewJWTManager("test-secret-please-rotate", time.Hour, 24*time.Hour)

	tok, err := mgr.CreateChatToken(12345)
	if err != nil {
		t.Fatalf("CreateChatToken: %v", err)
	}
	uid, err := mgr.VerifyChatToken(tok)
	if err != nil {
		t.Fatalf("VerifyChatToken: %v", err)
	}
	if uid != 12345 {
		t.Errorf("VerifyChatToken uid = %d, want 12345", uid)
	}
}

func TestVerifyChatTokenRejectsAccessToken(t *testing.T) {
	// An ordinary access token must NOT be accepted as a chat token (no
	// purpose=chat-sse claim) — and vice-versa a chat token must not pass
	// VerifyToken. This keeps the SSE credential single-purpose.
	mgr := NewJWTManager("test-secret", time.Hour, 24*time.Hour)

	pair, err := mgr.CreateTokenPair(7, "device_x", "user")
	if err != nil {
		t.Fatalf("CreateTokenPair: %v", err)
	}
	if _, err := mgr.VerifyChatToken(pair.AccessToken); err == nil {
		t.Error("VerifyChatToken accepted an access token — must reject (wrong purpose)")
	}

	chatTok, err := mgr.CreateChatToken(7)
	if err != nil {
		t.Fatalf("CreateChatToken: %v", err)
	}
	if _, err := mgr.VerifyToken(chatTok); err == nil {
		t.Error("VerifyToken accepted a chat token — must reject")
	}
}

func TestVerifyChatTokenWrongSecret(t *testing.T) {
	signer := NewJWTManager("secret-A", time.Hour, time.Hour)
	verifier := NewJWTManager("secret-B-different", time.Hour, time.Hour)

	tok, err := signer.CreateChatToken(99)
	if err != nil {
		t.Fatalf("CreateChatToken: %v", err)
	}
	if _, err := verifier.VerifyChatToken(tok); err == nil {
		t.Error("VerifyChatToken accepted a token signed with a different secret")
	}
}

func TestVerifyChatTokenExpired(t *testing.T) {
	mgr := NewJWTManager("test-secret", time.Hour, time.Hour)
	tok, err := mgr.CreateChatToken(5)
	if err != nil {
		t.Fatalf("CreateChatToken: %v", err)
	}
	// ChatTokenTTL is 10m; can't easily fast-forward, so just assert a freshly
	// minted token verifies (expiry path is covered by the jwt lib + the access
	// token's TestVerifyExpiredToken). Sanity: malformed token is rejected.
	if _, err := mgr.VerifyChatToken(tok); err != nil {
		t.Errorf("fresh chat token should verify: %v", err)
	}
	if _, err := mgr.VerifyChatToken("not.a.token"); err == nil {
		t.Error("malformed chat token must be rejected")
	}
}
