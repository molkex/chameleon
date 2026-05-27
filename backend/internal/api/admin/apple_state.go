package admin

import (
	"context"
	"net/http"
	"sync"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/asc"
)

// BE-01b: surface live Apple state (App Store versions, IAPs, TestFlight
// builds) on the admin Status page via Apple's App Store Connect API.
//
// Caching: 5 minutes in-memory. Apple rate-limits ASC at ~3500 req/h.
// We make 3 calls per fetch (versions / IAPs / builds), so an
// uncached refresh on every page open at 30s SPA refetch would burn
// 6 calls/min ≈ 360/h per admin — fine for one admin but adds up if
// multiple are watching. 5-min TTL keeps us comfortably under.

type appleStateResponse struct {
	Configured bool                 `json:"configured"`
	AppID      string               `json:"app_id,omitempty"`
	Versions   []appleVersionRow    `json:"versions,omitempty"`
	IAPs       []appleIAPRow        `json:"iaps,omitempty"`
	Builds     []appleBuildRow      `json:"builds,omitempty"`
	Error      string               `json:"error,omitempty"`
	FetchedAt  string               `json:"fetched_at,omitempty"`
}

type appleVersionRow struct {
	ID            string `json:"id"`
	VersionString string `json:"version_string"`
	Platform      string `json:"platform"`
	State         string `json:"state"`
	ReleaseType   string `json:"release_type"`
	CreatedDate   string `json:"created_date"`
}

type appleIAPRow struct {
	ID        string `json:"id"`
	ProductID string `json:"product_id"`
	Name      string `json:"name"`
	Type      string `json:"type"`
	State     string `json:"state"`
}

type appleBuildRow struct {
	ID              string `json:"id"`
	Version         string `json:"version"`
	ProcessingState string `json:"processing_state"`
	Expired         bool   `json:"expired"`
	UploadedDate    string `json:"uploaded_date"`
	ExpirationDate  string `json:"expiration_date"`
}

// Cache key is just "global" — we only ever query for our own ASC_APP_ID.
// Mutex guards both the cached payload and the in-flight singleflight
// behaviour: if 5 admins refresh the page at the same time, exactly one
// goroutine talks to Apple, the rest wait briefly and reuse the result.
type appleStateCache struct {
	mu       sync.Mutex
	at       time.Time
	payload  appleStateResponse
	inflight bool
	wait     chan struct{}
}

var appleStateCacheTTL = 5 * time.Minute

// Single package-level cache. The Handler is request-scoped per Echo
// design but the cache must be process-scoped so all admin requests
// share it. Plain global is fine — no test currently mutates this.
var apCache = &appleStateCache{} //nolint:gochecknoglobals

// GetAppleState handles GET /api/v1/admin/status/apple.
//
// Returns Apple state pulled from ASC API or, if not configured / Apple
// errored, a `configured=false` / `error` payload so the SPA can render
// a clear placeholder rather than going blank.
func (h *Handler) GetAppleState(c echo.Context) error {
	if h.ASC == nil || h.ASCAppID == "" {
		return c.JSON(http.StatusOK, appleStateResponse{
			Configured: false,
			Error:      "ASC credentials not configured (set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH / ASC_APP_ID)",
		})
	}

	apCache.mu.Lock()
	// Cache hit?
	if !apCache.at.IsZero() && time.Since(apCache.at) < appleStateCacheTTL {
		payload := apCache.payload
		apCache.mu.Unlock()
		return c.JSON(http.StatusOK, payload)
	}
	// In-flight elsewhere — wait on the broadcast channel, then return
	// whatever the leader stored.
	if apCache.inflight {
		ch := apCache.wait
		apCache.mu.Unlock()
		select {
		case <-ch:
		case <-c.Request().Context().Done():
			return c.JSON(http.StatusGatewayTimeout, appleStateResponse{
				Configured: true, Error: "ASC fetch timed out (request cancelled)",
			})
		}
		apCache.mu.Lock()
		payload := apCache.payload
		apCache.mu.Unlock()
		return c.JSON(http.StatusOK, payload)
	}
	// Leader: do the fetch.
	apCache.inflight = true
	apCache.wait = make(chan struct{})
	leaderCh := apCache.wait
	apCache.mu.Unlock()

	payload := h.fetchAppleState(c.Request().Context())

	apCache.mu.Lock()
	apCache.payload = payload
	apCache.at = time.Now()
	apCache.inflight = false
	apCache.mu.Unlock()
	close(leaderCh)

	return c.JSON(http.StatusOK, payload)
}

// fetchAppleState does the three ASC calls in parallel with a shared
// timeout. Partial success is allowed — if e.g. /builds 404s but
// /appStoreVersions returns, we still surface what we got and put the
// /builds error in the `error` field. Avoids the all-or-nothing
// behaviour where a single rate-limit hit blanks the whole panel.
func (h *Handler) fetchAppleState(parent context.Context) appleStateResponse {
	ctx, cancel := context.WithTimeout(parent, 8*time.Second)
	defer cancel()

	resp := appleStateResponse{
		Configured: true,
		AppID:      h.ASCAppID,
		FetchedAt:  time.Now().UTC().Format(time.RFC3339),
	}

	var (
		wg       sync.WaitGroup
		mu       sync.Mutex
		firstErr string
	)
	noteErr := func(label string, err error) {
		if err == nil {
			return
		}
		h.Logger.Warn("asc: "+label, zap.Error(err))
		mu.Lock()
		defer mu.Unlock()
		if firstErr == "" {
			firstErr = label + ": " + err.Error()
		}
	}

	wg.Add(3)
	go func() {
		defer wg.Done()
		versions, err := h.ASC.AppStoreVersions(ctx, h.ASCAppID, 5)
		if err != nil {
			noteErr("versions", err)
			return
		}
		out := make([]appleVersionRow, 0, len(versions))
		for _, v := range versions {
			out = append(out, appleVersionRow{
				ID:            v.ID,
				VersionString: v.VersionString,
				Platform:      v.Platform,
				State:         v.AppStoreState,
				ReleaseType:   v.ReleaseType,
				CreatedDate:   v.CreatedDate,
			})
		}
		mu.Lock()
		resp.Versions = out
		mu.Unlock()
	}()

	go func() {
		defer wg.Done()
		iaps, err := h.ASC.InAppPurchases(ctx, h.ASCAppID, 20)
		if err != nil {
			noteErr("iaps", err)
			return
		}
		out := make([]appleIAPRow, 0, len(iaps))
		for _, i := range iaps {
			out = append(out, appleIAPRow(i))
		}
		mu.Lock()
		resp.IAPs = out
		mu.Unlock()
	}()

	go func() {
		defer wg.Done()
		builds, err := h.ASC.Builds(ctx, h.ASCAppID, 5)
		if err != nil {
			noteErr("builds", err)
			return
		}
		out := make([]appleBuildRow, 0, len(builds))
		for _, b := range builds {
			out = append(out, appleBuildRow{
				ID:              b.ID,
				Version:         b.Version,
				ProcessingState: b.ProcessingState,
				Expired:         b.Expired,
				UploadedDate:    b.UploadedDate,
				ExpirationDate:  b.ExpirationDate,
			})
		}
		mu.Lock()
		resp.Builds = out
		mu.Unlock()
	}()

	wg.Wait()

	resp.Error = firstErr
	return resp
}

// Ensure the asc import is recognised even though we use it only via h.ASC.
var _ = asc.Client{}
