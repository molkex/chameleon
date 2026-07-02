package mobile

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/labstack/echo/v4"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
)

// refreshRig builds a Handler wired to a real (in-memory) Redis + JWT manager
// and returns a freshly-minted, valid refresh token to exercise. DB is nil on
// purpose — RefreshToken must be nil-safe (the subscription lookup is optional).
func refreshRig(t *testing.T) (*Handler, *miniredis.Miniredis, string) {
	t.Helper()
	mr := miniredis.RunT(t)
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	jwtMgr := auth.NewJWTManager("test-secret-at-least-32-characters-long!!", time.Hour, 24*time.Hour)
	pair, err := jwtMgr.CreateTokenPair(12351, "device_test", "")
	if err != nil {
		t.Fatalf("create token pair: %v", err)
	}
	return &Handler{Redis: rdb, JWT: jwtMgr, Logger: zap.NewNop()}, mr, pair.RefreshToken
}

func doRefresh(t *testing.T, h *Handler, refreshToken string) *httptest.ResponseRecorder {
	t.Helper()
	e := echo.New()
	req := httptest.NewRequest(http.MethodPost, "/api/mobile/auth/refresh",
		strings.NewReader(`{"refresh_token":"`+refreshToken+`"}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	if err := h.RefreshToken(e.NewContext(req, rec)); err != nil {
		t.Fatalf("RefreshToken: %v", err)
	}
	return rec
}

// The iOS client fans one refresh over several transport legs, so the SAME
// token legitimately arrives 2–3× within milliseconds. Inside the grace window
// every duplicate must get the SAME rotated pair (200), not a session-killing
// 401 — this is the bug that logged users out after the WAW failover.
func TestRefreshTokenGraceWindowReplaysSamePair(t *testing.T) {
	h, _, rt := refreshRig(t)

	rec1 := doRefresh(t, h, rt)
	if rec1.Code != http.StatusOK {
		t.Fatalf("first refresh: want 200, got %d (%s)", rec1.Code, rec1.Body.String())
	}
	var first AuthResponse
	if err := json.Unmarshal(rec1.Body.Bytes(), &first); err != nil {
		t.Fatalf("unmarshal first: %v", err)
	}
	if first.RefreshToken == "" || first.AccessToken == "" {
		t.Fatalf("first refresh must return a token pair, got %+v", first)
	}
	// NOTE: the refresh JWT is a pure function of (user, iat-sec, exp-sec) — no
	// jti — so a rotation within the same wall-clock second yields a byte-
	// identical token. In production consecutive refreshes are minutes apart so
	// the token does change; here we only assert the grace-replay contract.

	rec2 := doRefresh(t, h, rt) // duplicate of the ORIGINAL token
	if rec2.Code != http.StatusOK {
		t.Fatalf("grace replay: want 200, got %d (%s)", rec2.Code, rec2.Body.String())
	}
	var second AuthResponse
	if err := json.Unmarshal(rec2.Body.Bytes(), &second); err != nil {
		t.Fatalf("unmarshal second: %v", err)
	}
	if second.AccessToken != first.AccessToken || second.RefreshToken != first.RefreshToken {
		t.Fatalf("grace window must replay the SAME pair; first=%q second=%q",
			first.RefreshToken, second.RefreshToken)
	}
}

// COMPAT (2026-07-02): a reuse AFTER the grace window is NOT rejected. Pre-114
// field builds re-present the same still-valid token indefinitely; a 401 traps them
// in a logout loop. As long as the refresh JWT is valid+unexpired we re-issue a fresh
// pair (and log the reuse as a soft signal), so the app keeps a working access token.
func TestRefreshTokenReuseAfterGraceWindowReissues(t *testing.T) {
	h, mr, rt := refreshRig(t)

	if rec := doRefresh(t, h, rt); rec.Code != http.StatusOK {
		t.Fatalf("first refresh: want 200, got %d (%s)", rec.Code, rec.Body.String())
	}

	// Expire the 30s grace cache but NOT the 30-day used-marker.
	mr.FastForward(31 * time.Second)

	rec := doRefresh(t, h, rt)
	if rec.Code != http.StatusOK {
		t.Fatalf("reuse after grace: want 200 (soft re-issue), got %d (%s)", rec.Code, rec.Body.String())
	}
	var out AuthResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if out.AccessToken == "" || out.RefreshToken == "" {
		t.Fatalf("reuse re-issue must return a fresh pair, got %+v", out)
	}
}

// The real re-login boundary: an invalid/expired refresh JWT is still rejected with
// 401 (the compat re-issue only applies to cryptographically valid, unexpired tokens).
func TestRefreshTokenInvalidTokenRejected(t *testing.T) {
	h, _, _ := refreshRig(t)

	rec := doRefresh(t, h, "not.a.valid.jwt")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("invalid token: want 401, got %d (%s)", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "invalid refresh token") {
		t.Errorf("want 'invalid refresh token', got %s", rec.Body.String())
	}
}
