package admin

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/db"
)

// TestRequireAdminMiddleware locks down the privilege gate added in e8449af.
// Any role other than "admin" — including operator/viewer — must be denied
// for destructive endpoints. Missing claims are also denied (defense in depth
// in case CookieOrBearerAuth is ever forgotten upstream).
func TestRequireAdminMiddleware(t *testing.T) {
	cases := []struct {
		name       string
		claims     *auth.Claims // nil means "no claims set on context"
		wantStatus int
		wantNext   bool
	}{
		{"no claims", nil, http.StatusForbidden, false},
		{"admin role allowed", &auth.Claims{Role: "admin"}, http.StatusOK, true},
		{"operator role denied", &auth.Claims{Role: "operator"}, http.StatusForbidden, false},
		{"viewer role denied", &auth.Claims{Role: "viewer"}, http.StatusForbidden, false},
		{"empty role denied", &auth.Claims{Role: ""}, http.StatusForbidden, false},
		{"random role denied", &auth.Claims{Role: "superadmin"}, http.StatusForbidden, false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			e := echo.New()
			req := httptest.NewRequest(http.MethodPost, "/api/admin/admins", nil)
			rec := httptest.NewRecorder()
			c := e.NewContext(req, rec)
			if tc.claims != nil {
				c.Set("auth_claims", tc.claims)
			}

			var nextCalled bool
			h := RequireAdmin()(func(c echo.Context) error {
				nextCalled = true
				return c.NoContent(http.StatusOK)
			})
			err := h(c)

			// RequireAdmin returns echo.NewHTTPError on rejection, which
			// echo's default error handler turns into the right status.
			// Run it manually so the recorder captures the response.
			if err != nil {
				e.HTTPErrorHandler(err, c)
			}
			if rec.Code != tc.wantStatus {
				t.Errorf("status: want %d, got %d (body=%s)", tc.wantStatus, rec.Code, rec.Body.String())
			}
			if nextCalled != tc.wantNext {
				t.Errorf("nextCalled: want %v, got %v", tc.wantNext, nextCalled)
			}
		})
	}
}

// TestCookieOrBearerAuthRejects: ensure unauthenticated requests are 401
// and that valid roles other than admin/operator/viewer are 403.
func TestCookieOrBearerAuthRejects(t *testing.T) {
	jwtMgr := auth.NewJWTManager("test-secret", time.Hour, time.Hour)

	makeToken := func(role string) string {
		pair, err := jwtMgr.CreateTokenPair(1, "u", role)
		if err != nil {
			t.Fatalf("CreateTokenPair: %v", err)
		}
		return pair.AccessToken
	}

	cases := []struct {
		name       string
		authHeader string
		cookie     *http.Cookie
		wantStatus int
	}{
		{
			name:       "no credentials",
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "garbage bearer",
			authHeader: "Bearer not-a-jwt",
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "valid admin bearer",
			authHeader: "Bearer " + makeToken("admin"),
			wantStatus: http.StatusOK,
		},
		{
			name:       "valid operator bearer",
			authHeader: "Bearer " + makeToken("operator"),
			wantStatus: http.StatusOK,
		},
		{
			name:       "valid viewer bearer",
			authHeader: "Bearer " + makeToken("viewer"),
			wantStatus: http.StatusOK,
		},
		{
			// "user" is the role we issue to mobile clients; it must NOT be
			// allowed through the admin middleware.
			name:       "user role forbidden",
			authHeader: "Bearer " + makeToken("user"),
			wantStatus: http.StatusForbidden,
		},
		{
			name:       "valid admin via cookie",
			cookie:     &http.Cookie{Name: "access_token", Value: makeToken("admin")},
			wantStatus: http.StatusOK,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			e := echo.New()
			req := httptest.NewRequest(http.MethodGet, "/api/admin/whoami", nil)
			if tc.authHeader != "" {
				req.Header.Set("Authorization", tc.authHeader)
			}
			if tc.cookie != nil {
				req.AddCookie(tc.cookie)
			}
			rec := httptest.NewRecorder()
			c := e.NewContext(req, rec)

			h := CookieOrBearerAuth(jwtMgr)(func(c echo.Context) error {
				return c.NoContent(http.StatusOK)
			})
			if err := h(c); err != nil {
				e.HTTPErrorHandler(err, c)
			}
			if rec.Code != tc.wantStatus {
				t.Errorf("status: want %d, got %d (body=%s)",
					tc.wantStatus, rec.Code, rec.Body.String())
			}
		})
	}
}

// TestCreateAdminValidation covers the input-validation branches of
// CreateAdmin that bail out *before* touching the DB. We pass a nil DB —
// any test that reaches a DB call will panic, which is the canary that
// catches regressions where validation is removed or reordered.
func TestCreateAdminValidation(t *testing.T) {
	cases := []struct {
		name       string
		body       string
		wantStatus int
		wantSubstr string // must appear in response body for context
	}{
		{
			name:       "malformed json",
			body:       `not-json`,
			wantStatus: http.StatusBadRequest,
			wantSubstr: "invalid request body",
		},
		{
			name:       "missing username",
			body:       `{"username":"","password":"longenoughpwd1","role":"admin"}`,
			wantStatus: http.StatusBadRequest,
			wantSubstr: "username and password",
		},
		{
			name:       "missing password",
			body:       `{"username":"alice","password":"","role":"admin"}`,
			wantStatus: http.StatusBadRequest,
			wantSubstr: "username and password",
		},
		{
			name:       "password too short (11 chars)",
			body:       `{"username":"alice","password":"shortpwd123","role":"admin"}`,
			wantStatus: http.StatusBadRequest,
			wantSubstr: "12 characters",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := &Handler{
				DB:     nil, // canary: must not be touched on validation failure
				Logger: zap.NewNop(),
			}

			e := echo.New()
			req := httptest.NewRequest(http.MethodPost, "/api/admin/admins",
				bytes.NewReader([]byte(tc.body)))
			req.Header.Set("Content-Type", "application/json")
			rec := httptest.NewRecorder()
			c := e.NewContext(req, rec)

			err := h.CreateAdmin(c)
			// Validation paths return echo.NewHTTPError; route through the
			// default error handler so the recorder captures a real response.
			if err != nil {
				e.HTTPErrorHandler(err, c)
			}

			if rec.Code != tc.wantStatus {
				t.Errorf("status: want %d, got %d (body=%s)",
					tc.wantStatus, rec.Code, rec.Body.String())
			}
			if tc.wantSubstr != "" && !strings.Contains(rec.Body.String(), tc.wantSubstr) {
				t.Errorf("body missing %q: got %s", tc.wantSubstr, rec.Body.String())
			}
		})
	}
}

// TestDeleteAdminBadID covers the parse-int branch that bails before the DB.
func TestDeleteAdminBadID(t *testing.T) {
	h := &Handler{DB: nil, Logger: zap.NewNop()}

	e := echo.New()
	req := httptest.NewRequest(http.MethodDelete, "/api/admin/admins/not-a-number", nil)
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)
	c.SetParamNames("id")
	c.SetParamValues("not-a-number")

	err := h.DeleteAdmin(c)
	if err != nil {
		e.HTTPErrorHandler(err, c)
	}
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status: want 400, got %d (body=%s)", rec.Code, rec.Body.String())
	}
}

// TestToAdminResponse exercises the field mapping used by the list/create
// responses. Locks down the date format because the SPA depends on it.
func TestToAdminResponse(t *testing.T) {
	now := time.Date(2026, 1, 15, 9, 30, 0, 0, time.UTC)
	last := time.Date(2026, 4, 1, 12, 0, 0, 0, time.UTC)

	u := db.AdminUser{
		ID:        42,
		Username:  "alice",
		Role:      "admin",
		IsActive:  true,
		CreatedAt: now,
		LastLogin: &last,
	}

	r := toAdminResponse(u)
	if r.ID != 42 || r.Username != "alice" || r.Role != "admin" || !r.IsActive {
		t.Errorf("basic fields wrong: %+v", r)
	}
	if r.CreatedAt == nil || *r.CreatedAt != "2026-01-15 09:30" {
		t.Errorf("CreatedAt: want 2026-01-15 09:30, got %v", r.CreatedAt)
	}
	if r.LastLogin == nil || *r.LastLogin != "2026-04-01 12:00" {
		t.Errorf("LastLogin: want 2026-04-01 12:00, got %v", r.LastLogin)
	}

	// Zero CreatedAt → response omits it (current behavior).
	u2 := db.AdminUser{ID: 1, Username: "bob", Role: "viewer", IsActive: false}
	r2 := toAdminResponse(u2)
	if r2.CreatedAt != nil {
		t.Errorf("CreatedAt should be nil for zero time, got %v", *r2.CreatedAt)
	}
	if r2.LastLogin != nil {
		t.Errorf("LastLogin should be nil for nil pointer, got %v", *r2.LastLogin)
	}
}
