package auth

import (
	"context"
	"crypto/rsa"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	googleIssuer1 = "https://accounts.google.com"
	googleIssuer2 = "accounts.google.com"
	googleJWKSTTL = 24 * time.Hour
)

// googleJWKSURL is a var (not const) so tests can point it at httptest.NewServer.
var googleJWKSURL = "https://www.googleapis.com/oauth2/v3/certs"

// GoogleClaims is the subset of the Google ID token payload we care about.
// https://developers.google.com/identity/openid-connect/openid-connect
type GoogleClaims struct {
	Sub           string `json:"sub"`            // stable Google user ID
	Email         string `json:"email,omitempty"`
	EmailVerified bool   `json:"email_verified,omitempty"`
	Name          string `json:"name,omitempty"`
}

// GoogleVerifier validates Google ID tokens from the iOS/macOS Google Sign-In
// SDK. Shape mirrors AppleVerifier intentionally.
type GoogleVerifier struct {
	// The iOS OAuth client ID registered in Google Cloud. Used as expected
	// `aud`. Multiple IDs are supported if we ever publish a separate macOS
	// client; pass all of them.
	clientIDs   []string
	jwks        atomic.Pointer[cachedJWKS]
	fetchMu     sync.Mutex
	lastFetchAt atomic.Int64 // throttles kid-miss refetches; see AppleVerifier
}

// NewGoogleVerifier returns a verifier that accepts any of the provided
// client IDs as valid audience. Pass "" to get a disabled verifier that
// always refuses — callers can check IsEnabled().
func NewGoogleVerifier(clientIDs ...string) *GoogleVerifier {
	filtered := clientIDs[:0]
	for _, c := range clientIDs {
		if c != "" {
			filtered = append(filtered, c)
		}
	}
	return &GoogleVerifier{clientIDs: filtered}
}

// IsEnabled returns false when no client IDs are configured, so callers
// can surface a clear 503 rather than a cryptic verification error.
func (v *GoogleVerifier) IsEnabled() bool {
	return len(v.clientIDs) > 0
}

func (v *GoogleVerifier) audienceAllowed(aud string) bool {
	for _, c := range v.clientIDs {
		if aud == c {
			return true
		}
	}
	return false
}

// VerifyIDToken validates a Google ID token (JWT from client SDK).
// Returns parsed claims on success.
func (v *GoogleVerifier) VerifyIDToken(ctx context.Context, idToken string) (*GoogleClaims, error) {
	if !v.IsEnabled() {
		return nil, fmt.Errorf("auth/google: not configured")
	}

	kid, err := extractKID(idToken)
	if err != nil {
		return nil, fmt.Errorf("auth/google: extract kid: %w", err)
	}

	pubKey, err := v.getPublicKey(ctx, kid)
	if err != nil {
		return nil, fmt.Errorf("auth/google: get public key: %w", err)
	}

	claims := jwt.MapClaims{}
	token, err := jwt.ParseWithClaims(idToken, claims, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodRSA); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
		}
		return pubKey, nil
	},
		jwt.WithValidMethods([]string{"RS256"}),
	)
	if err != nil {
		return nil, fmt.Errorf("auth/google: verify token: %w", err)
	}
	if !token.Valid {
		return nil, fmt.Errorf("auth/google: token is not valid")
	}

	// Google uses one of two issuer strings. Check manually since
	// jwt.WithIssuer accepts only a single value.
	iss, _ := claims["iss"].(string)
	if iss != googleIssuer1 && iss != googleIssuer2 {
		return nil, fmt.Errorf("auth/google: unexpected issuer %q", iss)
	}

	aud, _ := claims["aud"].(string)
	if !v.audienceAllowed(aud) {
		return nil, fmt.Errorf("auth/google: audience mismatch: got %q", aud)
	}

	out := &GoogleClaims{
		Sub:   strValue(claims, "sub"),
		Email: strValue(claims, "email"),
		Name:  strValue(claims, "name"),
	}
	if out.Sub == "" {
		return nil, fmt.Errorf("auth/google: missing sub claim")
	}
	if v, ok := claims["email_verified"].(bool); ok {
		out.EmailVerified = v
	}
	return out, nil
}

func strValue(m jwt.MapClaims, k string) string {
	if s, ok := m[k].(string); ok {
		return s
	}
	return ""
}

// getPublicKey is an exact mirror of AppleVerifier.getPublicKey — different
// JWKS URL, same fetch/cache pattern, same stale-while-revalidate behavior.
func (v *GoogleVerifier) getPublicKey(_ context.Context, kid string) (*rsa.PublicKey, error) {
	if cached := v.jwks.Load(); cached != nil && time.Since(cached.fetchedAt) < googleJWKSTTL {
		if key, err := findAndParseKey(cached.keys, kid); err == nil {
			return key, nil
		}
	}

	fetchErr := v.fetchJWKS(kid)

	if cached := v.jwks.Load(); cached != nil {
		if key, err := findAndParseKey(cached.keys, kid); err == nil {
			return key, nil
		}
	}

	if fetchErr != nil {
		return nil, fetchErr
	}
	return nil, fmt.Errorf("auth/google: no key found for kid %q", kid)
}

// fetchJWKS uses a context.Background-derived context (not the request ctx)
// so a single client cancel doesn't poison the cache for everyone else. See
// AppleVerifier.fetchJWKS for the full rationale, including the kid-miss
// refetch throttle.
func (v *GoogleVerifier) fetchJWKS(wantKID string) error {
	v.fetchMu.Lock()
	defer v.fetchMu.Unlock()

	cached := v.jwks.Load()
	cacheFresh := cached != nil && time.Since(cached.fetchedAt) < googleJWKSTTL
	if cacheFresh {
		if wantKID == "" {
			return nil
		}
		if _, err := findAndParseKey(cached.keys, wantKID); err == nil {
			return nil
		}
		if last := v.lastFetchAt.Load(); last != 0 && time.Since(time.Unix(0, last)) < kidMissCooldown {
			return nil
		}
	}

	v.lastFetchAt.Store(time.Now().UnixNano())

	fetchCtx, cancel := context.WithTimeout(context.Background(), jwksFetchTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(fetchCtx, http.MethodGet, googleJWKSURL, nil)
	if err != nil {
		return fmt.Errorf("auth/google: create request: %w", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("auth/google: fetch JWKS: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("auth/google: JWKS status %d", resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return fmt.Errorf("auth/google: read JWKS: %w", err)
	}

	var parsed struct {
		Keys []appleJWK `json:"keys"` // reuse apple.go's shape; fields match
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return fmt.Errorf("auth/google: parse JWKS: %w", err)
	}

	v.jwks.Store(&cachedJWKS{keys: parsed.Keys, fetchedAt: time.Now()})
	return nil
}
