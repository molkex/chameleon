package mobile

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"
)

// diagnosticRequest is the body of POST /api/v1/mobile/diagnostic.
//
// Schema is intentionally permissive: clients are expected to evolve faster
// than the server, and ops only ever greps these by event/country anyway.
// The server treats this as opaque telemetry — we never dispatch routing
// decisions off it.
type diagnosticRequest struct {
	Event       string   `json:"event"`        // e.g. "country_dead", "all_dead", "crash", "hang"
	Country     string   `json:"country"`      // urltest tag the cascade chose to mark dead
	DeadLeaves  []string `json:"dead_leaves"`  // leaf tags tried before giving up
	NetworkType string   `json:"network_type"` // "wifi" / "cellular" / "wired" / "unknown"
	TS          string   `json:"ts"`           // ISO8601 client-side timestamp

	// Crash diagnostics (launch-03, MetricKit). All optional — present
	// only when Event is "crash" / "hang" / "cpu" / "disk", reported by
	// the iOS CrashDiagnosticReporter from an MXDiagnosticPayload. We
	// take a SUMMARY, never the full call-stack tree: offsets are
	// privacy-safe (no user data) and small enough to keep this a
	// log-line, not a DB table.
	CrashSignal      string   `json:"crash_signal,omitempty"`      // SIGSEGV / EXC_BAD_ACCESS / hang-duration / ...
	CrashTermination string   `json:"crash_termination,omitempty"` // MXCrashDiagnostic.terminationReason
	AppBuild         string   `json:"app_build,omitempty"`         // CFBundleVersion at crash time
	OSVersion        string   `json:"os_version,omitempty"`        // e.g. "17.4.1"
	DeviceType       string   `json:"device_type,omitempty"`       // e.g. "iPhone15,2"
	CallStackTop     []string `json:"call_stack_top,omitempty"`    // top frames "binaryName+offset"
}

// PostDiagnostic accepts a single best-effort diagnostic event from the iOS
// client's TrafficHealthMonitor cascade. Rate-limited at the mobile group's
// per-minute limit (server.go); ops can grep "diagnostic" in the structured
// log to triage "this country stopped working" reports.
//
// Auth is optional — we accept anonymous reports too so a user with an
// expired JWT still surfaces real-world breakage. Whatever device sends a
// JSON body that parses gets logged.
func (h *Handler) PostDiagnostic(c echo.Context) error {
	var req diagnosticRequest
	if err := c.Bind(&req); err != nil {
		// Malformed body — accept silently. We don't want a 400 storm to
		// look like an outage when a client ships a bad payload.
		return c.NoContent(http.StatusNoContent)
	}

	// Defence-in-depth: cap the array sizes and string lengths so a
	// runaway client can't blow up our log lines.
	if len(req.Event) > 64 {
		req.Event = req.Event[:64]
	}
	if len(req.Country) > 128 {
		req.Country = req.Country[:128]
	}
	if len(req.DeadLeaves) > 32 {
		req.DeadLeaves = req.DeadLeaves[:32]
	}
	for i := range req.DeadLeaves {
		if len(req.DeadLeaves[i]) > 128 {
			req.DeadLeaves[i] = req.DeadLeaves[i][:128]
		}
	}
	if len(req.NetworkType) > 32 {
		req.NetworkType = req.NetworkType[:32]
	}
	// Crash-field caps — same defence-in-depth as above.
	if len(req.CrashSignal) > 64 {
		req.CrashSignal = req.CrashSignal[:64]
	}
	if len(req.CrashTermination) > 256 {
		req.CrashTermination = req.CrashTermination[:256]
	}
	if len(req.AppBuild) > 32 {
		req.AppBuild = req.AppBuild[:32]
	}
	if len(req.OSVersion) > 32 {
		req.OSVersion = req.OSVersion[:32]
	}
	if len(req.DeviceType) > 32 {
		req.DeviceType = req.DeviceType[:32]
	}
	if len(req.CallStackTop) > 16 {
		req.CallStackTop = req.CallStackTop[:16]
	}
	for i := range req.CallStackTop {
		if len(req.CallStackTop[i]) > 128 {
			req.CallStackTop[i] = req.CallStackTop[i][:128]
		}
	}

	// Identify the user where possible — the route is registered without
	// requireAuth so this may be empty. When non-empty, ops can correlate
	// across multiple events from the same install.
	var userID int64
	if claims := getClaimsFromContext(c); claims != nil {
		userID = claims.UserID
	}

	// Crash / hang / resource-exception events get their own log key so
	// `grep mobile.crash` triages stability separately from routing
	// telemetry. Everything else stays on mobile.diagnostic.
	isCrash := req.Event == "crash" || req.Event == "hang" ||
		req.Event == "cpu" || req.Event == "disk"
	if isCrash {
		h.Logger.Warn("mobile.crash",
			zap.String("event", req.Event),
			zap.String("crash_signal", req.CrashSignal),
			zap.String("crash_termination", req.CrashTermination),
			zap.String("app_build", req.AppBuild),
			zap.String("os_version", req.OSVersion),
			zap.String("device_type", req.DeviceType),
			zap.Strings("call_stack_top", req.CallStackTop),
			zap.String("client_ts", req.TS),
			zap.Time("server_ts", time.Now().UTC()),
			zap.Int64("user_id", userID),
			zap.String("remote_ip", clientIP(c)),
			zap.String("user_agent", c.Request().Header.Get("User-Agent")),
		)
		return c.NoContent(http.StatusNoContent)
	}

	// Single structured log line per event. We keep the payload denormalised
	// so a `grep diagnostic /var/log/chameleon/*.log` is enough — no DB
	// schema, no migration, no ops complexity. Fields are explicit so
	// future fields don't break existing greps.
	h.Logger.Info("mobile.diagnostic",
		zap.String("event", req.Event),
		zap.String("country", req.Country),
		zap.Strings("dead_leaves", req.DeadLeaves),
		zap.String("network_type", req.NetworkType),
		zap.String("client_ts", req.TS),
		zap.Time("server_ts", time.Now().UTC()),
		zap.Int64("user_id", userID),
		zap.String("remote_ip", clientIP(c)),
		zap.String("user_agent", c.Request().Header.Get("User-Agent")),
	)

	return c.NoContent(http.StatusNoContent)
}

// getClaimsFromContext is a soft-auth helper: returns parsed JWT claims if
// the request has a valid Bearer token, nil otherwise. Not an error — the
// diagnostic endpoint is intentionally permissive.
func getClaimsFromContext(c echo.Context) *softClaims {
	authHeader := c.Request().Header.Get("Authorization")
	const prefix = "Bearer "
	if !strings.HasPrefix(authHeader, prefix) {
		return nil
	}
	token := strings.TrimSpace(authHeader[len(prefix):])
	if token == "" {
		return nil
	}
	// Decode without verifying — the diagnostic event is not security-
	// sensitive, and we already accept anonymous events. We only want
	// the user_id field for log correlation when present.
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil
	}
	// JWT segments are base64url without padding. We rely on the standard
	// library JSON decoder for the payload only.
	payload, err := decodeJWTPayload(parts[1])
	if err != nil {
		return nil
	}
	var c2 softClaims
	if err := json.Unmarshal(payload, &c2); err != nil {
		return nil
	}
	return &c2
}

type softClaims struct {
	UserID int64 `json:"user_id"`
}

func decodeJWTPayload(seg string) ([]byte, error) {
	// JWT uses URL-safe base64 without padding. Use the URL encoder with
	// raw (no-padding) mode — encoding/base64 handles the alphabet.
	return base64.RawURLEncoding.DecodeString(seg)
}

// clientIP returns the most plausible IP for the client given proxy
// headers. Single source of truth — when ops greps for an IP we want a
// stable answer.
func clientIP(c echo.Context) string {
	if xff := c.Request().Header.Get("X-Forwarded-For"); xff != "" {
		if comma := strings.Index(xff, ","); comma > 0 {
			return strings.TrimSpace(xff[:comma])
		}
		return strings.TrimSpace(xff)
	}
	if xrip := c.Request().Header.Get("X-Real-IP"); xrip != "" {
		return strings.TrimSpace(xrip)
	}
	return c.RealIP()
}
