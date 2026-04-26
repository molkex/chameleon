package middleware

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/labstack/echo/v4"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

const (
	// IdempotencyKeyHeader is the inbound header iOS build-36+ clients set on
	// every mutating request. Same UUID flows to all hedged race legs so
	// duplicate arrivals collapse into one logical effect.
	IdempotencyKeyHeader = "Idempotency-Key"

	// IdempotencyReplayedHeader is set on responses served from the cache so
	// clients (and humans reading curl output) can tell the difference.
	IdempotencyReplayedHeader = "Idempotency-Replayed"

	// idempotencyTTL must outlive any reasonable client retry budget. iOS
	// hedged legs all fire within a few seconds, but watchdog reconnects and
	// future API-level retries can re-issue the same key minutes later.
	// 24h is the same default as Stripe and is well above what we need.
	idempotencyTTL = 24 * time.Hour

	// idempotencyMaxResponseBytes — guard against a runaway handler filling
	// Redis with megabytes per request. Mobile API responses are JSON and
	// stay well under this in practice (largest is /config at ~14KB).
	idempotencyMaxResponseBytes = 256 * 1024

	idempotencyKeyPrefix = "idemp:"
)

type idempotencyEntry struct {
	Status      int    `json:"s"`
	ContentType string `json:"ct,omitempty"`
	Body        []byte `json:"b,omitempty"`
}

// Idempotency caches successful responses (status < 500) to mutating
// requests, keyed by the client-supplied Idempotency-Key header. Duplicate
// requests with the same key — typically arriving from hedged client legs
// racing the same logical operation — receive the cached response instead
// of running the handler again, so the user doesn't end up with two
// charges, two registrations, two magic-link emails.
//
// Bypass conditions: GET/HEAD/OPTIONS, missing header, response status >= 500
// (don't pin transient errors), Redis unreachable (log + pass through).
func Idempotency(rdb *redis.Client, logger *zap.Logger) echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			switch c.Request().Method {
			case http.MethodGet, http.MethodHead, http.MethodOptions:
				return next(c)
			}

			key := c.Request().Header.Get(IdempotencyKeyHeader)
			if key == "" {
				return next(c)
			}

			redisKey := idempotencyKeyPrefix + key
			ctx := c.Request().Context()

			// Fast path: serve from cache.
			cached, err := rdb.Get(ctx, redisKey).Bytes()
			switch {
			case err == nil:
				var entry idempotencyEntry
				jerr := json.Unmarshal(cached, &entry)
				if jerr == nil {
					c.Response().Header().Set(IdempotencyReplayedHeader, "true")
					ct := entry.ContentType
					if ct == "" {
						ct = echo.MIMEApplicationJSON
					}
					logger.Info("idempotency: cache hit",
						zap.String("key", key),
						zap.Int("status", entry.Status),
					)
					return c.Blob(entry.Status, ct, entry.Body)
				}
				logger.Warn("idempotency: cached entry decode failed, falling through",
					zap.String("key", key),
					zap.Error(jerr),
				)
			case errors.Is(err, redis.Nil):
				// Cache miss — proceed to handler below.
			default:
				logger.Warn("idempotency: redis GET failed, bypassing",
					zap.String("key", key),
					zap.Error(err),
				)
				return next(c)
			}

			// Capture the response body via a tee so we can stash it in Redis
			// after the handler returns.
			tee := &captureWriter{
				ResponseWriter: c.Response().Writer,
				buf:            &bytes.Buffer{},
				max:            idempotencyMaxResponseBytes,
			}
			c.Response().Writer = tee

			handlerErr := next(c)

			status := c.Response().Status
			if status >= 500 {
				return handlerErr
			}
			if tee.overflowed {
				logger.Info("idempotency: response exceeds cache ceiling, skipping",
					zap.String("key", key),
					zap.Int("ceiling", idempotencyMaxResponseBytes),
				)
				return handlerErr
			}

			payload, jerr := json.Marshal(&idempotencyEntry{
				Status:      status,
				ContentType: c.Response().Header().Get(echo.HeaderContentType),
				Body:        tee.buf.Bytes(),
			})
			if jerr != nil {
				logger.Warn("idempotency: response encode failed",
					zap.String("key", key),
					zap.Error(jerr),
				)
				return handlerErr
			}

			// SetNX guarantees that if two siblings race past the GET miss,
			// only the first to finish populates the cache. The other's
			// SETNX silently no-ops; both clients still get a valid response.
			if _, serr := rdb.SetNX(ctx, redisKey, payload, idempotencyTTL).Result(); serr != nil {
				logger.Warn("idempotency: redis SETNX failed",
					zap.String("key", key),
					zap.Error(serr),
				)
			}

			return handlerErr
		}
	}
}

// captureWriter tees writes into a buffer up to `max` bytes. Once the
// ceiling is breached we drop the buffer and stop recording — the
// downstream client still gets the full response.
type captureWriter struct {
	http.ResponseWriter
	buf        *bytes.Buffer
	max        int
	overflowed bool
}

func (w *captureWriter) Write(b []byte) (int, error) {
	if !w.overflowed {
		if w.buf.Len()+len(b) > w.max {
			w.overflowed = true
			w.buf.Reset()
		} else {
			_, _ = w.buf.Write(b)
		}
	}
	return w.ResponseWriter.Write(b)
}
