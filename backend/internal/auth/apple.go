package auth

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	appleIssuer      = "https://appleid.apple.com"
	jwksCacheTTL     = 24 * time.Hour
	jwksFetchTimeout = 10 * time.Second
)

// kidMissCooldown caps how often we refetch JWKS in response to a kid
// the cache doesn't know about. Prevents a forged-token attacker from
// hammering Apple via our backend. Var (not const) so tests can shrink it.
var kidMissCooldown = 1 * time.Minute

// appleJWKSURL is a var (not const) so tests can point it at httptest.NewServer.
var appleJWKSURL = "https://appleid.apple.com/auth/keys"

// appleJWK represents a single key from Apple's JWKS.
type appleJWK struct {
	KTY string `json:"kty"`
	KID string `json:"kid"`
	Use string `json:"use"`
	Alg string `json:"alg"`
	N   string `json:"n"`
	E   string `json:"e"`
}

// cachedJWKS holds the fetched JWKS keys and the time they were fetched.
type cachedJWKS struct {
	keys      []appleJWK
	fetchedAt time.Time
}

// AppleVerifier handles Apple Sign-In identity token verification.
//
// Accepts multiple bundle IDs so the same backend can authenticate tokens
// from both the iOS app and the macOS app (which have distinct bundle IDs
// for separate App Store listings — `com.madfrog.vpn` and
// `com.madfrog.vpn.mac`).
type AppleVerifier struct {
	bundleIDs    []string
	jwks         atomic.Pointer[cachedJWKS]
	fetchMu      sync.Mutex   // serializes JWKS fetches to prevent stampede
	lastFetchAt  atomic.Int64 // unix nano of last fetch attempt (success or failure); throttles kid-miss refetches
}

// NewAppleVerifier creates a verifier that accepts any of the provided
// bundle IDs as a valid audience. Pass the iOS and macOS bundle IDs together.
func NewAppleVerifier(bundleIDs ...string) *AppleVerifier {
	filtered := bundleIDs[:0]
	for _, b := range bundleIDs {
		if b != "" {
			filtered = append(filtered, b)
		}
	}
	return &AppleVerifier{
		bundleIDs: filtered,
	}
}

func (v *AppleVerifier) audienceAllowed(aud string) bool {
	for _, b := range v.bundleIDs {
		if aud == b {
			return true
		}
	}
	return false
}

// AppleClaims carries the parts of an Apple ID token our auth flow needs.
type AppleClaims struct {
	Sub           string // stable Apple user ID
	Email         string // hidden/relay or real, depending on user choice
	EmailVerified bool
}

// VerifyIdentityToken validates an Apple Sign-In identity token (JWT).
// Returns the Apple user ID (the "sub" claim) on success.
//
// Kept for backward compatibility. New code should use VerifyAndExtract
// which returns the full claims including email.
func (v *AppleVerifier) VerifyIdentityToken(ctx context.Context, tokenString string) (string, error) {
	claims, err := v.VerifyAndExtract(ctx, tokenString)
	if err != nil {
		return "", err
	}
	return claims.Sub, nil
}

// VerifyAndExtract validates the token and returns both sub and email info.
// Apple may omit the email field entirely once the user has signed in before
// — the policy is "email sent only on first sign-in unless user revokes". So
// callers should gracefully handle an empty Email.
func (v *AppleVerifier) VerifyAndExtract(ctx context.Context, tokenString string) (*AppleClaims, error) {
	kid, err := extractKID(tokenString)
	if err != nil {
		return nil, fmt.Errorf("auth/apple: extract kid: %w", err)
	}

	pubKey, err := v.getPublicKey(ctx, kid)
	if err != nil {
		return nil, fmt.Errorf("auth/apple: get public key: %w", err)
	}

	claims := jwt.MapClaims{}
	token, err := jwt.ParseWithClaims(tokenString, claims, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodRSA); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
		}
		return pubKey, nil
	},
		jwt.WithIssuer(appleIssuer),
		jwt.WithValidMethods([]string{"RS256"}),
	)
	if err != nil {
		return nil, fmt.Errorf("auth/apple: verify token: %w", err)
	}
	if !token.Valid {
		return nil, fmt.Errorf("auth/apple: token is not valid")
	}

	aud, _ := claims["aud"].(string)
	if !v.audienceAllowed(aud) {
		return nil, fmt.Errorf("auth/apple: audience mismatch: got %q, want one of %v", aud, v.bundleIDs)
	}

	sub, _ := claims["sub"].(string)
	if sub == "" {
		return nil, fmt.Errorf("auth/apple: missing sub claim")
	}

	out := &AppleClaims{Sub: sub}
	if s, ok := claims["email"].(string); ok {
		out.Email = s
	}
	// Apple uses "true"/"false" strings here — sometimes bools. Handle both.
	switch v := claims["email_verified"].(type) {
	case bool:
		out.EmailVerified = v
	case string:
		out.EmailVerified = v == "true"
	}
	return out, nil
}

// getPublicKey returns the RSA public key matching the given kid.
// It fetches and caches JWKS from Apple, refreshing after jwksCacheTTL.
//
// On fetch failure it falls back to a stale cache entry if one is available
// (stale-while-revalidate). This protects against a transient outage of
// Apple's JWKS endpoint causing every sign-in to fail.
func (v *AppleVerifier) getPublicKey(_ context.Context, kid string) (*rsa.PublicKey, error) {
	// Fast path: fresh cache hit for this kid.
	if cached := v.jwks.Load(); cached != nil && time.Since(cached.fetchedAt) < jwksCacheTTL {
		if key, err := findAndParseKey(cached.keys, kid); err == nil {
			return key, nil
		}
		// kid not in cache — Apple may have rotated, fall through to fetch.
	}

	fetchErr := v.fetchJWKS(kid)

	// Try whatever cache we have now — fresh fetch result, or stale entry
	// surviving a fetch failure.
	if cached := v.jwks.Load(); cached != nil {
		if key, err := findAndParseKey(cached.keys, kid); err == nil {
			return key, nil
		}
	}

	if fetchErr != nil {
		return nil, fetchErr
	}
	return nil, fmt.Errorf("auth/apple: no key found for kid %q", kid)
}

// fetchJWKS fetches Apple's JWKS endpoint. Only one goroutine fetches at a time.
//
// `wantKID` is the kid the caller is looking for — used so a fresh-but-rotated
// cache (cache is within TTL but doesn't have this kid) triggers a refetch.
// To prevent forged-token DoS via repeated kid misses, refetches in this
// case are throttled by kidMissCooldown.
//
// The HTTP request runs on a context.Background-derived context, NOT the
// inbound request context. Otherwise a single client cancellation (e.g. iOS
// hitting its request timeout) would abort an in-flight fetch shared by every
// concurrent sign-in, leaving the cache empty and the next attempt to fail
// the same way. See: 2026-04-26 incident — 2× consecutive 400s on Apple
// sign-in resolved only when one fetch finally outran the iOS timeout.
func (v *AppleVerifier) fetchJWKS(wantKID string) error {
	v.fetchMu.Lock()
	defer v.fetchMu.Unlock()

	// Double-check after acquiring lock — another goroutine may have already fetched.
	cached := v.jwks.Load()
	cacheFresh := cached != nil && time.Since(cached.fetchedAt) < jwksCacheTTL
	if cacheFresh {
		// Cache is fresh — skip fetch unless caller is looking for a kid
		// that's missing from it (likely Apple key rotation).
		if wantKID == "" {
			return nil
		}
		if _, err := findAndParseKey(cached.keys, wantKID); err == nil {
			return nil
		}
		// kid missing — refetch unless we just tried recently (throttle).
		if last := v.lastFetchAt.Load(); last != 0 && time.Since(time.Unix(0, last)) < kidMissCooldown {
			return nil
		}
	}

	v.lastFetchAt.Store(time.Now().UnixNano())

	fetchCtx, cancel := context.WithTimeout(context.Background(), jwksFetchTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(fetchCtx, http.MethodGet, appleJWKSURL, nil)
	if err != nil {
		return fmt.Errorf("auth/apple: create request: %w", err)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("auth/apple: fetch JWKS: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("auth/apple: JWKS endpoint returned status %d", resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20)) // 1 MB limit
	if err != nil {
		return fmt.Errorf("auth/apple: read JWKS body: %w", err)
	}

	var jwksResponse struct {
		Keys []appleJWK `json:"keys"`
	}
	if err := json.Unmarshal(body, &jwksResponse); err != nil {
		return fmt.Errorf("auth/apple: parse JWKS: %w", err)
	}

	v.jwks.Store(&cachedJWKS{
		keys:      jwksResponse.Keys,
		fetchedAt: time.Now(),
	})

	return nil
}

// findAndParseKey finds a key by kid in the JWKS and converts it to an RSA public key.
func findAndParseKey(keys []appleJWK, kid string) (*rsa.PublicKey, error) {
	for _, k := range keys {
		if k.KID == kid && k.KTY == "RSA" {
			return parseRSAPublicKey(k)
		}
	}
	return nil, fmt.Errorf("auth/apple: no key found for kid %q", kid)
}

// parseRSAPublicKey converts a JWK to an *rsa.PublicKey.
func parseRSAPublicKey(k appleJWK) (*rsa.PublicKey, error) {
	nBytes, err := base64.RawURLEncoding.DecodeString(k.N)
	if err != nil {
		return nil, fmt.Errorf("auth/apple: decode N: %w", err)
	}

	eBytes, err := base64.RawURLEncoding.DecodeString(k.E)
	if err != nil {
		return nil, fmt.Errorf("auth/apple: decode E: %w", err)
	}

	n := new(big.Int).SetBytes(nBytes)
	e := new(big.Int).SetBytes(eBytes)

	if !e.IsInt64() {
		return nil, fmt.Errorf("auth/apple: exponent too large")
	}

	return &rsa.PublicKey{
		N: n,
		E: int(e.Int64()),
	}, nil
}

// extractKID reads the "kid" from a JWT header without verifying the signature.
func extractKID(tokenString string) (string, error) {
	parts := strings.SplitN(tokenString, ".", 3)
	if len(parts) != 3 {
		return "", fmt.Errorf("malformed JWT: expected 3 parts, got %d", len(parts))
	}

	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return "", fmt.Errorf("decode header: %w", err)
	}

	var header struct {
		KID string `json:"kid"`
		Alg string `json:"alg"`
	}
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return "", fmt.Errorf("parse header: %w", err)
	}

	if header.KID == "" {
		return "", fmt.Errorf("missing kid in token header")
	}

	return header.KID, nil
}
