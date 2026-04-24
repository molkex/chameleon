package cluster

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/config"
)

// TestClusterAuth covers the bearer-token gate that fronts every
// /api/cluster endpoint. Layered table:
//   - no secret configured           -> 403 (fail closed by design)
//   - missing Authorization header   -> 401
//   - wrong secret                   -> 403
//   - correct secret                 -> 200 (next handler runs)
func TestClusterAuth(t *testing.T) {
	const secret = "shared-cluster-secret"

	cases := []struct {
		name         string
		serverSecret string
		header       string
		wantStatus   int
		wantNext     bool
	}{
		{"no secret configured", "", "Bearer " + secret, http.StatusForbidden, false},
		{"missing header", secret, "", http.StatusUnauthorized, false},
		{"wrong secret", secret, "Bearer not-the-secret", http.StatusForbidden, false},
		{"valid secret", secret, "Bearer " + secret, http.StatusOK, true},
		// Bare token (no Bearer prefix) should still match because TrimPrefix
		// is a no-op when the prefix is missing — pin the current behavior.
		{"bare token (legacy)", secret, secret, http.StatusOK, true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			e := echo.New()
			var nextCalled bool
			h := ClusterAuth(tc.serverSecret)(func(c echo.Context) error {
				nextCalled = true
				return c.NoContent(http.StatusOK)
			})

			req := httptest.NewRequest(http.MethodGet, "/api/cluster/pull", nil)
			if tc.header != "" {
				req.Header.Set("Authorization", tc.header)
			}
			rec := httptest.NewRecorder()
			c := e.NewContext(req, rec)

			_ = h(c)

			if rec.Code != tc.wantStatus {
				t.Errorf("status: want %d, got %d (body=%s)", tc.wantStatus, rec.Code, rec.Body.String())
			}
			if nextCalled != tc.wantNext {
				t.Errorf("nextCalled: want %v, got %v", tc.wantNext, nextCalled)
			}
		})
	}
}

// TestHandlePushPayloadTooLarge ensures the cap on /api/cluster/push fires
// before the request reaches the database. We can exercise this without a
// real DB because the size check runs immediately after c.Bind.
func TestHandlePushPayloadTooLarge(t *testing.T) {
	const maxUsersPerPush = 10000

	// Build a payload that overflows the user cap by exactly one.
	users := make([]SyncUser, maxUsersPerPush+1)
	for i := range users {
		// minimal valid SyncUser payload (Bind will accept any JSON shape,
		// missing fields default to zero values).
		users[i] = SyncUser{}
	}
	body, err := json.Marshal(PushRequest{NodeID: "test-node", Users: users})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	h := &clusterHandler{
		// db intentionally nil — the size check must fire before any DB call.
		// If the handler ever calls db.* before the size guard, the test
		// will panic with a nil-pointer deref, which is the canary we want.
		db:     nil,
		config: config.ClusterConfig{NodeID: "test-node"},
		logger: zap.NewNop(),
	}

	e := echo.New()
	req := httptest.NewRequest(http.MethodPost, "/api/cluster/push", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)

	if err := h.handlePush(c); err != nil {
		t.Fatalf("handlePush returned unexpected error: %v", err)
	}
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("status: want %d, got %d (body=%s)",
			http.StatusRequestEntityTooLarge, rec.Code, rec.Body.String())
	}
}

// TestHandlePushBadJSON ensures malformed bodies are rejected with 400
// before any DB call. Same nil-DB canary as above.
func TestHandlePushBadJSON(t *testing.T) {
	h := &clusterHandler{
		db:     nil,
		config: config.ClusterConfig{NodeID: "test-node"},
		logger: zap.NewNop(),
	}

	e := echo.New()
	req := httptest.NewRequest(http.MethodPost, "/api/cluster/push",
		bytes.NewReader([]byte("not-json")))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)

	if err := h.handlePush(c); err != nil {
		t.Fatalf("handlePush returned unexpected error: %v", err)
	}
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status: want 400, got %d (body=%s)", rec.Code, rec.Body.String())
	}
}

// TestHandlePullBadSinceParam: invalid ?since param must yield 400 before
// the handler hits the DB.
func TestHandlePullBadSinceParam(t *testing.T) {
	h := &clusterHandler{
		db:     nil,
		config: config.ClusterConfig{NodeID: "test-node"},
		logger: zap.NewNop(),
	}

	e := echo.New()
	req := httptest.NewRequest(http.MethodGet, "/api/cluster/pull?since=not-a-time", nil)
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)

	if err := h.handlePull(c); err != nil {
		t.Fatalf("handlePull returned unexpected error: %v", err)
	}
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status: want 400, got %d (body=%s)", rec.Code, rec.Body.String())
	}
}
