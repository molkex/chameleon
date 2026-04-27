package mobile

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/labstack/echo/v4"
)

func TestHealthcheckReturnsExactlyConfiguredSize(t *testing.T) {
	e := echo.New()
	req := httptest.NewRequest(http.MethodGet, "/healthcheck", nil)
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)
	h := &Handler{}

	if err := h.Healthcheck(c); err != nil {
		t.Fatalf("Healthcheck: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Errorf("status=%d, want 200", rec.Code)
	}
	if got := rec.Body.Len(); got != healthcheckBodySize {
		t.Errorf("body size=%d, want %d", got, healthcheckBodySize)
	}
	if cc := rec.Header().Get("Cache-Control"); cc == "" {
		t.Errorf("Cache-Control header missing")
	}
}
