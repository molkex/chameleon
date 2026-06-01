package auth

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/labstack/echo/v4"
)

func newTestEchoCtx(authHeader string) (echo.Context, *httptest.ResponseRecorder) {
	e := echo.New()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	if authHeader != "" {
		req.Header.Set("Authorization", authHeader)
	}
	rec := httptest.NewRecorder()
	return e.NewContext(req, rec), rec
}

func okHandler(c echo.Context) error { return c.String(http.StatusOK, "ok") }

func assertHTTPCode(t *testing.T, err error, want int) {
	t.Helper()
	if err == nil {
		t.Fatalf("want *echo.HTTPError with code %d, got nil", want)
	}
	he, ok := err.(*echo.HTTPError)
	if !ok {
		t.Fatalf("want *echo.HTTPError, got %T (%v)", err, err)
	}
	if he.Code != want {
		t.Errorf("HTTP code = %d, want %d", he.Code, want)
	}
}

func TestExtractBearerToken(t *testing.T) {
	tests := []struct{ name, header, want string }{
		{"empty", "", ""},
		{"no prefix", "abc123", ""},
		{"wrong scheme", "Basic abc", ""},
		{"bearer lowercase", "bearer tok1", "tok1"},
		{"bearer mixed case", "BeArEr tok2", "tok2"},
		{"bearer trims spaces", "Bearer   tok3  ", "tok3"},
		{"bearer empty token", "Bearer    ", ""},
		{"too short", "Bear", ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/", nil)
			if tc.header != "" {
				req.Header.Set("Authorization", tc.header)
			}
			if got := ExtractBearerToken(req); got != tc.want {
				t.Errorf("ExtractBearerToken(%q) = %q, want %q", tc.header, got, tc.want)
			}
		})
	}
}

func TestGetUserFromContext(t *testing.T) {
	c, _ := newTestEchoCtx("")
	if GetUserFromContext(c) != nil {
		t.Error("want nil for empty context")
	}

	c.Set(contextKeyClaims, &Claims{UserID: 7, Role: "admin"})
	if got := GetUserFromContext(c); got == nil || got.UserID != 7 {
		t.Errorf("got %+v, want UserID=7", got)
	}

	c2, _ := newTestEchoCtx("")
	c2.Set(contextKeyClaims, "not-a-claims-value")
	if GetUserFromContext(c2) != nil {
		t.Error("want nil when the context value is the wrong type")
	}
}

func TestRequireAuth(t *testing.T) {
	mgr := NewJWTManager("test-secret-please-rotate", time.Hour, 24*time.Hour)
	pair, err := mgr.CreateTokenPair(1, "u", "user")
	if err != nil {
		t.Fatalf("CreateTokenPair: %v", err)
	}

	c, _ := newTestEchoCtx("")
	assertHTTPCode(t, RequireAuth(mgr)(okHandler)(c), http.StatusUnauthorized)

	c, _ = newTestEchoCtx("Bearer garbage.token.here")
	assertHTTPCode(t, RequireAuth(mgr)(okHandler)(c), http.StatusUnauthorized)

	c, rec := newTestEchoCtx("Bearer " + pair.AccessToken)
	called := false
	err = RequireAuth(mgr)(func(c echo.Context) error {
		called = true
		return okHandler(c)
	})(c)
	if err != nil {
		t.Fatalf("valid token rejected: %v", err)
	}
	if !called {
		t.Error("next handler was not called for a valid token")
	}
	if rec.Code != http.StatusOK {
		t.Errorf("response code = %d, want 200", rec.Code)
	}
	if GetUserFromContext(c) == nil {
		t.Error("claims were not stored in the context")
	}
}

func TestRequireAdmin(t *testing.T) {
	mgr := NewJWTManager("test-secret-please-rotate", time.Hour, 24*time.Hour)
	adminTok, _ := mgr.CreateTokenPair(1, "admin", "admin")
	userTok, _ := mgr.CreateTokenPair(2, "user", "user")

	// No token, no preset claims → 401.
	c, _ := newTestEchoCtx("")
	assertHTTPCode(t, RequireAdmin(mgr)(okHandler)(c), http.StatusUnauthorized)

	// Self-verify path: valid non-admin token → 403.
	c, _ = newTestEchoCtx("Bearer " + userTok.AccessToken)
	assertHTTPCode(t, RequireAdmin(mgr)(okHandler)(c), http.StatusForbidden)

	// Self-verify path: valid admin token → pass.
	c, rec := newTestEchoCtx("Bearer " + adminTok.AccessToken)
	if err := RequireAdmin(mgr)(okHandler)(c); err != nil {
		t.Fatalf("admin token rejected: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Errorf("admin response code = %d, want 200", rec.Code)
	}

	// Preset-claims path (RequireAuth ran first): admin → pass without a header.
	c, _ = newTestEchoCtx("")
	c.Set(contextKeyClaims, &Claims{UserID: 1, Role: "admin"})
	if err := RequireAdmin(mgr)(okHandler)(c); err != nil {
		t.Fatalf("preset admin claims rejected: %v", err)
	}

	// Preset-claims path: non-admin → 403.
	c, _ = newTestEchoCtx("")
	c.Set(contextKeyClaims, &Claims{UserID: 2, Role: "user"})
	assertHTTPCode(t, RequireAdmin(mgr)(okHandler)(c), http.StatusForbidden)
}
