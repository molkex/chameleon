package middleware

import (
	"github.com/labstack/echo/v4"
)

// SecurityHeaders returns Echo middleware that sets standard security headers
// on every response to protect against common web vulnerabilities.
//
// Headers set:
//   - X-Content-Type-Options: nosniff — prevents MIME type sniffing
//   - X-Frame-Options: DENY — prevents clickjacking via iframes
//   - X-XSS-Protection: 1; mode=block — legacy XSS filter (still useful for older browsers)
//   - Strict-Transport-Security: max-age=63072000; includeSubDomains — enforce HTTPS for 2 years
//   - Content-Security-Policy: default-src 'none' — strict CSP baseline for API responses
//   - Referrer-Policy: strict-origin-when-cross-origin — limit referrer leakage
//   - Permissions-Policy: camera=(), microphone=(), geolocation=() — disable dangerous browser features
func SecurityHeaders() echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			h := c.Response().Header()

			h.Set("X-Content-Type-Options", "nosniff")
			h.Set("X-Frame-Options", "DENY")
			h.Set("X-XSS-Protection", "1; mode=block")
			h.Set("Strict-Transport-Security", "max-age=63072000; includeSubDomains")
			h.Set("Content-Security-Policy", "default-src 'none'")
			h.Set("Referrer-Policy", "strict-origin-when-cross-origin")
			h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")

			return next(c)
		}
	}
}
