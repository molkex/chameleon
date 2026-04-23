// Package middleware provides reusable Echo middleware for the Chameleon VPN backend.
package middleware

import (
	"context"
	"net/http"
	"sync"
	"time"

	"github.com/labstack/echo/v4"
)

// rateLimitEntry tracks request timestamps for a single IP using a sliding window.
type rateLimitEntry struct {
	mu         sync.Mutex
	timestamps []int64 // unix milliseconds
}

// rateLimiter stores per-IP rate limit state with periodic cleanup.
type rateLimiter struct {
	entries sync.Map // map[string]*rateLimitEntry
	limit   int
	window  time.Duration
}

// newRateLimiter creates a rate limiter and starts a background cleanup
// goroutine that removes expired entries every minute. The goroutine exits
// when ctx is cancelled, so passing the server's lifetime context here
// prevents the leak that prior versions had (cleanup never stopped).
func newRateLimiter(ctx context.Context, requestsPerMinute int) *rateLimiter {
	rl := &rateLimiter{
		limit:  requestsPerMinute,
		window: time.Minute,
	}

	go rl.cleanup(ctx)

	return rl
}

// allow checks whether the given IP is within the rate limit.
// Returns true if the request is allowed, false if it should be rejected.
func (rl *rateLimiter) allow(ip string) bool {
	now := time.Now().UnixMilli()
	windowStart := now - rl.window.Milliseconds()

	val, _ := rl.entries.LoadOrStore(ip, &rateLimitEntry{})
	entry := val.(*rateLimitEntry)

	entry.mu.Lock()
	defer entry.mu.Unlock()

	// Remove timestamps outside the current window (sliding window).
	validFrom := 0
	for i, ts := range entry.timestamps {
		if ts > windowStart {
			validFrom = i
			break
		}
		if i == len(entry.timestamps)-1 {
			// All entries are expired.
			validFrom = len(entry.timestamps)
		}
	}
	entry.timestamps = entry.timestamps[validFrom:]

	// Check if adding this request would exceed the limit.
	if len(entry.timestamps) >= rl.limit {
		return false
	}

	entry.timestamps = append(entry.timestamps, now)
	return true
}

// cleanup periodically removes IP entries that have no recent requests.
// Exits when ctx is cancelled (prevents goroutine leak on shutdown).
func (rl *rateLimiter) cleanup(ctx context.Context) {
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}

		windowStart := time.Now().UnixMilli() - rl.window.Milliseconds()

		rl.entries.Range(func(key, value interface{}) bool {
			entry := value.(*rateLimitEntry)

			entry.mu.Lock()
			allExpired := true
			for _, ts := range entry.timestamps {
				if ts > windowStart {
					allExpired = false
					break
				}
			}
			entry.mu.Unlock()

			if allExpired {
				rl.entries.Delete(key)
			}
			return true
		})
	}
}

// RateLimit returns Echo middleware that limits requests per IP address
// using a sliding window algorithm. Pass a context whose cancellation
// signals the cleanup goroutine to exit (typically the server lifetime).
//
// When the limit is exceeded, it returns HTTP 429 Too Many Requests
// with a JSON error body and a Retry-After header.
func RateLimit(ctx context.Context, requestsPerMinute int) echo.MiddlewareFunc {
	rl := newRateLimiter(ctx, requestsPerMinute)

	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			ip := c.RealIP()

			if !rl.allow(ip) {
				c.Response().Header().Set("Retry-After", "60")
				return c.JSON(http.StatusTooManyRequests, map[string]string{
					"error": "rate limit exceeded",
				})
			}

			return next(c)
		}
	}
}
