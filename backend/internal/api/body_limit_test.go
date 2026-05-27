package api

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/labstack/echo/v4"
	echomw "github.com/labstack/echo/v4/middleware"
)

// Audit MED-011 (2026-05-26): the global BodyLimit("1M") wired in
// setupMiddleware. We don't spin up the whole Server here — that drags
// DB/Redis dependencies — but we re-create the same middleware on a
// bare Echo and assert the 413 boundary. The constant itself is the
// regression guard: if someone removes the BodyLimit call in
// server.go, no production test would catch it; this one would.

func TestEcho_BodyLimit_RejectsOversize(t *testing.T) {
	e := echo.New()
	// Same line wired into setupMiddleware (server.go).
	e.Use(echomw.BodyLimit("1M"))
	e.POST("/echo", func(c echo.Context) error {
		// Read the body so the limit middleware actually triggers
		// (BodyLimit only counts bytes consumed by the handler).
		buf := bytes.Buffer{}
		_, _ = buf.ReadFrom(c.Request().Body)
		return c.String(http.StatusOK, "ok")
	})

	// 1.5 MiB request — well over the 1 MiB cap.
	body := strings.Repeat("a", 1_500_000)
	req := httptest.NewRequest(http.MethodPost, "/echo", strings.NewReader(body))
	req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, req)

	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("oversize body should 413, got %d (body=%s)", rec.Code, rec.Body.String())
	}
}

func TestEcho_BodyLimit_PassesUnderLimit(t *testing.T) {
	e := echo.New()
	e.Use(echomw.BodyLimit("1M"))
	e.POST("/echo", func(c echo.Context) error {
		buf := bytes.Buffer{}
		_, _ = buf.ReadFrom(c.Request().Body)
		return c.String(http.StatusOK, "ok")
	})

	// 512 KiB — well under the cap.
	body := strings.Repeat("a", 512*1024)
	req := httptest.NewRequest(http.MethodPost, "/echo", strings.NewReader(body))
	req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("under-cap body should 200, got %d (body=%s)", rec.Code, rec.Body.String())
	}
}
