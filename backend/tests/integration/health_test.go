//go:build integration

// Integration tests run against real Postgres + Redis containers via
// testcontainers-go. They are gated behind the `integration` build tag so
// they don't run during the normal `go test ./...` cycle. Trigger:
//
//	go test -tags=integration ./tests/integration/...
package integration

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/labstack/echo/v4"
)

// TestHealthEndpoint is a smoke test that the test harness can spin up an
// HTTP server, send a request, and parse the response. It establishes the
// test infrastructure pattern; real handlers will be wired through
// api.NewServer once testcontainers Postgres+Redis are added.
func TestHealthEndpoint(t *testing.T) {
	e := echo.New()
	e.GET("/health", func(c echo.Context) error {
		return c.JSON(http.StatusOK, map[string]string{"status": "ok"})
	})

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d (body=%q)", rec.Code, rec.Body.String())
	}
}

// Placeholder for the next round: bring up real DB+Redis with testcontainers,
// instantiate api.NewServer, exercise register → get-config → cluster sync.
var _ = context.Background
