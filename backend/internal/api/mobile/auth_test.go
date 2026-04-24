package mobile

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"
)

// TestRegisterValidation covers the validation branches of POST
// /api/mobile/auth/register that bail out before any DB call. We pass a
// nil DB pool — any test that reaches a DB call will panic, which is the
// canary that catches regressions where validation is removed/reordered.
func TestRegisterValidation(t *testing.T) {
	cases := []struct {
		name       string
		body       string
		wantStatus int
		wantSubstr string
	}{
		{
			name:       "malformed json",
			body:       `not-json`,
			wantStatus: http.StatusBadRequest,
			wantSubstr: "invalid request body",
		},
		{
			name:       "missing device_id",
			body:       `{}`,
			wantStatus: http.StatusBadRequest,
			wantSubstr: "device_id is required",
		},
		{
			name:       "empty device_id",
			body:       `{"device_id":""}`,
			wantStatus: http.StatusBadRequest,
			wantSubstr: "device_id is required",
		},
		{
			name:       "whitespace device_id",
			body:       `{"device_id":"   "}`,
			wantStatus: http.StatusBadRequest,
			wantSubstr: "device_id is required",
		},
		{
			// 257 chars — one over the documented cap (256). Anything
			// longer than a UUID is hostile input; reject before sha256.
			name:       "device_id too long (257 chars)",
			body:       `{"device_id":"` + strings.Repeat("x", 257) + `"}`,
			wantStatus: http.StatusBadRequest,
			wantSubstr: "device_id too long",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := &Handler{
				DB:     nil, // canary
				Logger: zap.NewNop(),
			}

			e := echo.New()
			req := httptest.NewRequest(http.MethodPost, "/api/mobile/auth/register",
				bytes.NewReader([]byte(tc.body)))
			req.Header.Set("Content-Type", "application/json")
			rec := httptest.NewRecorder()
			c := e.NewContext(req, rec)

			if err := h.Register(c); err != nil {
				t.Fatalf("Register returned unexpected error: %v", err)
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

// TestRegisterDeviceIDLengthBoundary pins the exact off-by-one: 256 chars
// is allowed (passes validation, would proceed to DB and panic on nil), 257
// is not. We check 256 by intercepting the panic at the DB call.
func TestRegisterDeviceIDLengthBoundary(t *testing.T) {
	body := `{"device_id":"` + strings.Repeat("x", 256) + `"}`

	h := &Handler{
		DB:     nil, // 256 should pass validation and panic when hitting DB
		Logger: zap.NewNop(),
	}

	e := echo.New()
	req := httptest.NewRequest(http.MethodPost, "/api/mobile/auth/register",
		bytes.NewReader([]byte(body)))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)

	defer func() {
		if r := recover(); r == nil {
			// If no panic, the validation is now stricter than 256 — that
			// is a behavior change worth flagging.
			t.Errorf("expected panic from nil DB on 256-char device_id (validation accepted), got body=%s status=%d",
				rec.Body.String(), rec.Code)
		}
	}()
	_ = h.Register(c)
}

// TestGenerateVPNUsernameFromUUID pins the username derivation contract: a
// deterministic, 15-char "device_" + sha256[:8] of the vpn_uuid. The hash
// input was switched from device_id to vpn_uuid to fix the collision bug
// where two installs on the same device generated the same username and
// crashed cluster sync (see comment on the production function).
func TestGenerateVPNUsernameFromUUID(t *testing.T) {
	const uuid = "abcdef12-3456-4890-abcd-ef1234567890"
	got := generateVPNUsernameFromUUID(uuid)

	expectedHash := sha256.Sum256([]byte(uuid))
	want := "device_" + hex.EncodeToString(expectedHash[:])[:8]
	if got != want {
		t.Errorf("generateVPNUsernameFromUUID: want %q, got %q", want, got)
	}
	if len(got) != 15 {
		t.Errorf("length: want 15, got %d (%q)", len(got), got)
	}
	if !strings.HasPrefix(got, "device_") {
		t.Errorf("must start with 'device_', got %q", got)
	}

	// Determinism: same uuid → same username.
	if again := generateVPNUsernameFromUUID(uuid); again != got {
		t.Errorf("non-deterministic: %q vs %q", got, again)
	}

	// Different uuids → different usernames (with overwhelming probability).
	if other := generateVPNUsernameFromUUID("00000000-0000-4000-8000-000000000000"); other == got {
		t.Errorf("collision on distinct inputs: both %q", got)
	}
}

// TestGenerateUUID pins the v4 UUID output format and the version/variant
// bits. Used as the VPN UUID — the sing-box/Reality config rejects malformed
// UUIDs at parse time so a regression here breaks every new signup.
func TestGenerateUUID(t *testing.T) {
	uuidPattern := regexp.MustCompile(
		`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

	seen := make(map[string]struct{}, 100)
	for i := 0; i < 100; i++ {
		got, err := generateUUID()
		if err != nil {
			t.Fatalf("generateUUID: %v", err)
		}
		if !uuidPattern.MatchString(got) {
			t.Fatalf("malformed UUID: %q", got)
		}
		if _, dup := seen[got]; dup {
			t.Fatalf("collision after %d iterations: %q", i, got)
		}
		seen[got] = struct{}{}
	}
}

// TestGenerateShortID pins the helper used for sing-box short_id. Although
// production currently generates an empty short_id (see auth.go comment),
// the helper is still exported via tests in case it gets reused.
func TestGenerateShortID(t *testing.T) {
	for i := 0; i < 20; i++ {
		got, err := generateShortID()
		if err != nil {
			t.Fatalf("generateShortID: %v", err)
		}
		if len(got) != 8 {
			t.Errorf("length: want 8, got %d (%q)", len(got), got)
		}
		// Must be lowercase hex.
		for _, ch := range got {
			if !((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')) {
				t.Errorf("non-hex char %q in %q", ch, got)
				break
			}
		}
	}
}

// TestRefreshTokenValidation: empty refresh_token should be rejected with
// 400 before the manager sees it. Same nil-DB canary as Register.
func TestRefreshTokenValidation(t *testing.T) {
	cases := []struct {
		name       string
		body       string
		wantStatus int
		wantSubstr string
	}{
		{"malformed json", `not-json`, http.StatusBadRequest, "invalid request body"},
		{"empty refresh_token", `{"refresh_token":""}`, http.StatusBadRequest, "required"},
		{"missing field", `{}`, http.StatusBadRequest, "required"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := &Handler{
				DB:     nil,
				Logger: zap.NewNop(),
			}
			e := echo.New()
			req := httptest.NewRequest(http.MethodPost, "/api/mobile/auth/refresh",
				bytes.NewReader([]byte(tc.body)))
			req.Header.Set("Content-Type", "application/json")
			rec := httptest.NewRecorder()
			c := e.NewContext(req, rec)

			if err := h.RefreshToken(c); err != nil {
				t.Fatalf("RefreshToken: unexpected error: %v", err)
			}
			if rec.Code != tc.wantStatus {
				t.Errorf("status: want %d, got %d (body=%s)",
					tc.wantStatus, rec.Code, rec.Body.String())
			}
			if !strings.Contains(rec.Body.String(), tc.wantSubstr) {
				t.Errorf("body missing %q: got %s", tc.wantSubstr, rec.Body.String())
			}
		})
	}
}
