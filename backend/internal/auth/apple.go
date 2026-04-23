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
	appleJWKSURL     = "https://appleid.apple.com/auth/keys"
	appleIssuer      = "https://appleid.apple.com"
	jwksCacheTTL     = 24 * time.Hour
	jwksFetchTimeout = 10 * time.Second
)

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
	bundleIDs []string
	jwks      atomic.Pointer[cachedJWKS]
	fetchMu   sync.Mutex // serializes JWKS fetches to prevent stampede
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
func (v *AppleVerifier) getPublicKey(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	// Try cached keys first.
	if cached := v.jwks.Load(); cached != nil && time.Since(cached.fetchedAt) < jwksCacheTTL {
		if key, err := findAndParseKey(cached.keys, kid); err == nil {
			return key, nil
		}
	}

	// Fetch fresh JWKS (serialized to prevent stampede).
	if err := v.fetchJWKS(ctx); err != nil {
		return nil, err
	}

	cached := v.jwks.Load()
	if cached == nil {
		return nil, fmt.Errorf("auth/apple: JWKS cache is empty after fetch")
	}

	return findAndParseKey(cached.keys, kid)
}

// fetchJWKS fetches Apple's JWKS endpoint. Only one goroutine fetches at a time.
func (v *AppleVerifier) fetchJWKS(ctx context.Context) error {
	v.fetchMu.Lock()
	defer v.fetchMu.Unlock()

	// Double-check after acquiring lock — another goroutine may have already fetched.
	if cached := v.jwks.Load(); cached != nil && time.Since(cached.fetchedAt) < jwksCacheTTL {
		return nil
	}

	fetchCtx, cancel := context.WithTimeout(ctx, jwksFetchTimeout)
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
