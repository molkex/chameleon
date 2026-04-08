package auth

import (
	"net/http"
	"strings"

	"github.com/labstack/echo/v4"
)

const (
	// contextKeyClaims is the echo.Context key where authenticated Claims are stored.
	contextKeyClaims = "auth_claims"
)

// RequireAuth returns Echo middleware that validates a JWT from the Authorization header
// and stores the Claims in the request context.
func RequireAuth(jwtManager *JWTManager) echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			token := extractBearerToken(c.Request())
			if token == "" {
				return echo.NewHTTPError(http.StatusUnauthorized, "unauthorized")
			}

			claims, err := jwtManager.VerifyToken(token)
			if err != nil {
				return echo.NewHTTPError(http.StatusUnauthorized, "unauthorized")
			}

			c.Set(contextKeyClaims, claims)
			return next(c)
		}
	}
}

// RequireAdmin returns Echo middleware that requires an authenticated user with the "admin" role.
// It must be placed after RequireAuth or it will independently verify the token.
func RequireAdmin(jwtManager *JWTManager) echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			// Try to get claims from context first (set by RequireAuth).
			claims := GetUserFromContext(c)

			// If not already set, verify the token ourselves.
			if claims == nil {
				token := extractBearerToken(c.Request())
				if token == "" {
					return echo.NewHTTPError(http.StatusUnauthorized, "unauthorized")
				}

				var err error
				claims, err = jwtManager.VerifyToken(token)
				if err != nil {
					return echo.NewHTTPError(http.StatusUnauthorized, "unauthorized")
				}

				c.Set(contextKeyClaims, claims)
			}

			if claims.Role != "admin" {
				return echo.NewHTTPError(http.StatusForbidden, "forbidden")
			}

			return next(c)
		}
	}
}

// GetUserFromContext extracts authenticated user Claims from an echo.Context.
// Returns nil if no authenticated user is present.
func GetUserFromContext(c echo.Context) *Claims {
	val := c.Get(contextKeyClaims)
	if val == nil {
		return nil
	}
	claims, ok := val.(*Claims)
	if !ok {
		return nil
	}
	return claims
}

// extractBearerToken extracts a bearer token from the Authorization header.
// Returns empty string if not present or malformed.
func extractBearerToken(r *http.Request) string {
	auth := r.Header.Get("Authorization")
	if auth == "" {
		return ""
	}

	// Case-insensitive "Bearer " prefix check.
	const prefix = "bearer "
	if len(auth) < len(prefix) {
		return ""
	}
	if !strings.EqualFold(auth[:len(prefix)], prefix) {
		return ""
	}

	token := strings.TrimSpace(auth[len(prefix):])
	if token == "" {
		return ""
	}

	return token
}
