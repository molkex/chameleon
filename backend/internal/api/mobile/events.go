package mobile

import (
	"io"
	"net/http"
	"regexp"
	"time"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/auth"
	"github.com/chameleonvpn/chameleon/internal/db"
	"github.com/chameleonvpn/chameleon/internal/useragent"
)

// POST /api/v1/mobile/events/batch — iOS client telemetry sink.
//
// USR-09 Phase 2 (2026-05-28). The mobile EventTracker queues events
// in-process and flushes them in batches on foreground/background. This
// handler is the receive side: it validates each event, drops malformed
// ones silently (an event-tracking endpoint should never poison a user's
// session by returning 4xx), enriches with server-side context, and
// inserts the survivors in a single SQL statement.
//
// Contract with the client:
//   - Request body is JSON: {"events": [{"name", "occurred_at", "properties"}]}
//   - JWT auth required. Pre-signup analytics will need a separate
//     anonymous endpoint; we don't have those events today.
//   - The endpoint always responds 200 if the JSON parses, with the
//     number of rows actually written. iOS treats a 200 as "drop the
//     batch from the queue" — we don't want a partial-failure to keep
//     the queue growing.
//   - Body capped at 64KB (echo's default RouterAllowOverwritingRoute
//     does not gate this — we read+limit explicitly).

const (
	maxEventsPerBatch  = 100
	maxBatchBodyBytes  = 64 * 1024
	maxEventNameLen    = 64
	maxPropertiesBytes = 2048
	maxDeviceIDLen     = 64
)

// eventNamePattern restricts event names to a small ASCII subset so a
// client cannot smuggle ANSI/control characters into structured logs
// or admin tooltips. Subject.verb.qualifier is the established
// convention.
var eventNamePattern = regexp.MustCompile(`^[a-z][a-z0-9._-]{0,63}$`)

type eventBatchRequest struct {
	Events []clientEvent `json:"events"`
}

type clientEvent struct {
	Name       string                 `json:"name"`
	OccurredAt string                 `json:"occurred_at"` // ISO8601 / RFC3339 client clock
	Properties map[string]any         `json:"properties,omitempty"`
	DeviceID   string                 `json:"device_id,omitempty"`
}

// PostEvents handles POST /api/v1/mobile/events/batch.
func (h *Handler) PostEvents(c echo.Context) error {
	claims := auth.GetUserFromContext(c)
	if claims == nil {
		return c.JSON(http.StatusUnauthorized, ErrorResponse{Error: "unauthorized"})
	}

	// Read body with a hard cap so a hostile client cannot DoS by
	// sending a multi-megabyte JSON document. echo.Bind would happily
	// allocate the entire body before parsing.
	body, err := io.ReadAll(io.LimitReader(c.Request().Body, maxBatchBodyBytes+1))
	if err != nil {
		return c.JSON(http.StatusBadRequest, ErrorResponse{Error: "read body"})
	}
	if len(body) > maxBatchBodyBytes {
		return c.JSON(http.StatusRequestEntityTooLarge, ErrorResponse{Error: "body too large"})
	}

	var req eventBatchRequest
	if err := unmarshalBatch(body, &req); err != nil {
		// Malformed JSON. Accept 0 events — this matches diagnostic.go's
		// "silent on malformed" stance: a 400 storm would look like an
		// outage to a client whose payload schema drifted.
		h.Logger.Warn("mobile.events.batch malformed body",
			zap.Error(err),
			zap.Int64("user_id", claims.UserID),
		)
		return c.JSON(http.StatusOK, map[string]int{"accepted": 0})
	}

	if len(req.Events) == 0 {
		return c.JSON(http.StatusOK, map[string]int{"accepted": 0})
	}
	if len(req.Events) > maxEventsPerBatch {
		req.Events = req.Events[:maxEventsPerBatch]
	}

	// Convert + validate each event. Bad ones are dropped, not rejected.
	now := time.Now().UTC()
	inserts := make([]db.AppEventInsert, 0, len(req.Events))
	for _, ev := range req.Events {
		if !eventNamePattern.MatchString(ev.Name) {
			continue
		}
		if len(ev.Name) > maxEventNameLen {
			continue
		}
		// Parse client clock. RFC3339 is what `JSONEncoder.encode(Date)`
		// emits in Swift Foundation by default.
		occurred, err := time.Parse(time.RFC3339Nano, ev.OccurredAt)
		if err != nil {
			// Tolerate the second-precision form too.
			occurred, err = time.Parse(time.RFC3339, ev.OccurredAt)
			if err != nil {
				continue
			}
		}
		// Sanity-clamp the timestamp so a misconfigured client clock
		// (1970 or 2099) cannot poison time-window queries. ±90 days
		// is the conservative bound — any legitimate batched flush
		// should fit inside that.
		if occurred.Before(now.AddDate(0, 0, -90)) || occurred.After(now.AddDate(0, 0, 1)) {
			continue
		}

		// Cap properties payload — JSON encode and reject if too large.
		// We re-encode anyway in InsertAppEvents so the size check is
		// cheap and gives a deterministic bound on a single row.
		if ev.Properties != nil {
			encoded, err := marshalProperties(ev.Properties)
			if err != nil || len(encoded) > maxPropertiesBytes {
				continue
			}
		}

		deviceID := ev.DeviceID
		if len(deviceID) > maxDeviceIDLen {
			deviceID = deviceID[:maxDeviceIDLen]
		}

		inserts = append(inserts, db.AppEventInsert{
			EventName:  ev.Name,
			OccurredAt: occurred.UTC(),
			Properties: ev.Properties,
			DeviceID:   deviceID,
		})
		// MON-04: bump the funnel counter for every accepted event.
		// AppEventName() bounds cardinality to a fixed whitelist + "other".
		if h.Metrics != nil {
			h.Metrics.CountAppEvent(ev.Name)
		}
	}

	// Server-enriched context — same conventions as touchDevice in
	// config.go: real IP from echo's X-Forwarded-For-aware resolver,
	// country from Cloudflare's CF-IPCountry header (no external
	// lookup, no privacy disclosure burden).
	req2 := c.Request()
	ua := req2.UserAgent()
	parsed := useragent.Parse(ua)
	appVersion := parsed.AppVersion
	if hv := req2.Header.Get("X-App-Version"); hv != "" {
		appVersion = firstValue(hv, 32)
	}
	platform := "ios"
	if hp := req2.Header.Get("X-Platform"); hp != "" {
		platform = firstValue(hp, 16)
	} else if parsed.OSName != "" {
		platform = parsed.OSName
	}
	ip := c.RealIP()
	country := cfCountryCode(req2.Header.Get("CF-IPCountry"))

	uid := claims.UserID
	ctx := req2.Context()
	accepted, err := h.DB.InsertAppEvents(ctx, &uid, appVersion, platform, ip, country, inserts)
	if err != nil {
		h.Logger.Error("mobile.events insert",
			zap.Error(err),
			zap.Int64("user_id", uid),
			zap.Int("batch_size", len(inserts)),
		)
		// Still report 200 to the client; iOS will retry on next flush
		// only if it gets a non-2xx. We deliberately swallow the DB
		// blip so the iOS queue doesn't grow during a backend incident.
		// Ops sees the error in the structured log.
		return c.JSON(http.StatusOK, map[string]int{"accepted": 0})
	}

	h.Logger.Info("mobile.events.batch",
		zap.Int64("user_id", uid),
		zap.Int("submitted", len(req.Events)),
		zap.Int("inserted", int(accepted)),
		zap.String("platform", platform),
		zap.String("app_version", appVersion),
	)

	return c.JSON(http.StatusOK, map[string]int{"accepted": int(accepted)})
}
