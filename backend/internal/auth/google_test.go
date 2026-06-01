package auth

import (
	"context"
	"crypto/rsa"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Google Sign-In ID-token verification. The JWKS test harness (newJWKSTestServer,
// mustGenKey, mustJWKSBody) lives in apple_test.go — same package, reused here.
// googleJWKSURL is a package var so we can point it at the httptest server.

const testGoogleClientID = "test-client.apps.googleusercontent.com"

func withGoogleJWKSURL(t *testing.T, url string) {
	t.Helper()
	orig := googleJWKSURL
	googleJWKSURL = url
	t.Cleanup(func() { googleJWKSURL = orig })
}

func signGoogleToken(t *testing.T, priv *rsa.PrivateKey, kid string, claims jwt.MapClaims) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	tok.Header["kid"] = kid
	s, err := tok.SignedString(priv)
	if err != nil {
		t.Fatalf("sign google token: %v", err)
	}
	return s
}

func validGoogleClaims() jwt.MapClaims {
	return jwt.MapClaims{
		"iss":            googleIssuer1,
		"aud":            testGoogleClientID,
		"sub":            "google-sub-123",
		"email":          "user@example.com",
		"email_verified": true,
		"name":           "Test User",
		"iat":            time.Now().Add(-time.Minute).Unix(),
		"exp":            time.Now().Add(time.Hour).Unix(),
	}
}

func TestGoogleVerifyIDToken_HappyPath(t *testing.T) {
	priv := mustGenKey(t)
	jts := newJWKSTestServer(t, "g-kid-1", &priv.PublicKey)
	withGoogleJWKSURL(t, jts.srv.URL)

	v := NewGoogleVerifier(testGoogleClientID)
	tok := signGoogleToken(t, priv, "g-kid-1", validGoogleClaims())

	claims, err := v.VerifyIDToken(context.Background(), tok)
	if err != nil {
		t.Fatalf("VerifyIDToken: %v", err)
	}
	if claims.Sub != "google-sub-123" {
		t.Errorf("Sub = %q, want google-sub-123", claims.Sub)
	}
	if claims.Email != "user@example.com" {
		t.Errorf("Email = %q", claims.Email)
	}
	if !claims.EmailVerified {
		t.Error("EmailVerified = false, want true")
	}
	if claims.Name != "Test User" {
		t.Errorf("Name = %q", claims.Name)
	}
}

func TestGoogleVerifyIDToken_BothIssuerForms(t *testing.T) {
	priv := mustGenKey(t)
	jts := newJWKSTestServer(t, "g-kid-1", &priv.PublicKey)
	withGoogleJWKSURL(t, jts.srv.URL)
	v := NewGoogleVerifier(testGoogleClientID)

	for _, iss := range []string{googleIssuer1, googleIssuer2} {
		c := validGoogleClaims()
		c["iss"] = iss
		tok := signGoogleToken(t, priv, "g-kid-1", c)
		if _, err := v.VerifyIDToken(context.Background(), tok); err != nil {
			t.Errorf("issuer %q rejected: %v", iss, err)
		}
	}
}

func TestGoogleVerifyIDToken_Rejections(t *testing.T) {
	priv := mustGenKey(t)
	jts := newJWKSTestServer(t, "g-kid-1", &priv.PublicKey)
	withGoogleJWKSURL(t, jts.srv.URL)
	v := NewGoogleVerifier(testGoogleClientID)

	mk := func(mut func(jwt.MapClaims)) string {
		c := validGoogleClaims()
		mut(c)
		return signGoogleToken(t, priv, "g-kid-1", c)
	}

	tests := []struct {
		name    string
		token   string
		wantErr string
	}{
		{"wrong audience", mk(func(c jwt.MapClaims) { c["aud"] = "someone-else" }), "audience mismatch"},
		{"wrong issuer", mk(func(c jwt.MapClaims) { c["iss"] = "https://evil.example" }), "unexpected issuer"},
		{"missing sub", mk(func(c jwt.MapClaims) { delete(c, "sub") }), "missing sub"},
		{"expired", mk(func(c jwt.MapClaims) { c["exp"] = time.Now().Add(-time.Hour).Unix() }), "verify token"},
		{"malformed token", "not.a.jwt", "extract kid"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := v.VerifyIDToken(context.Background(), tc.token)
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("want error containing %q, got %v", tc.wantErr, err)
			}
		})
	}
}

func TestGoogleVerifyIDToken_WrongSigningKeyRejected(t *testing.T) {
	priv := mustGenKey(t)
	other := mustGenKey(t)
	jts := newJWKSTestServer(t, "g-kid-1", &priv.PublicKey)
	withGoogleJWKSURL(t, jts.srv.URL)
	v := NewGoogleVerifier(testGoogleClientID)

	// Signed with `other`, but JWKS publishes priv's public key under g-kid-1.
	tok := signGoogleToken(t, other, "g-kid-1", validGoogleClaims())
	if _, err := v.VerifyIDToken(context.Background(), tok); err == nil {
		t.Fatal("token signed with the wrong key was accepted")
	}
}

func TestGoogleVerifyIDToken_NonRSAMethodRejected(t *testing.T) {
	priv := mustGenKey(t)
	jts := newJWKSTestServer(t, "g-kid-1", &priv.PublicKey)
	withGoogleJWKSURL(t, jts.srv.URL)
	v := NewGoogleVerifier(testGoogleClientID)

	// An HS256 token must be rejected (alg-confusion guard).
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, validGoogleClaims())
	tok.Header["kid"] = "g-kid-1"
	s, err := tok.SignedString([]byte("symmetric-secret"))
	if err != nil {
		t.Fatalf("sign HS256: %v", err)
	}
	if _, err := v.VerifyIDToken(context.Background(), s); err == nil {
		t.Fatal("HS256 token was accepted (alg confusion)")
	}
}

func TestGoogleVerifierDisabled(t *testing.T) {
	v := NewGoogleVerifier() // no client IDs
	if v.IsEnabled() {
		t.Error("verifier with no client IDs should be disabled")
	}
	_, err := v.VerifyIDToken(context.Background(), "x.y.z")
	if err == nil || !strings.Contains(err.Error(), "not configured") {
		t.Fatalf("want not-configured error, got %v", err)
	}

	if NewGoogleVerifier("", "").IsEnabled() {
		t.Error("verifier with only empty client IDs should be disabled")
	}
}

func TestGoogleAudienceAllowedMultiple(t *testing.T) {
	v := NewGoogleVerifier("ios-client", "mac-client")
	if !v.audienceAllowed("ios-client") || !v.audienceAllowed("mac-client") {
		t.Error("configured audiences should be allowed")
	}
	if v.audienceAllowed("other") {
		t.Error("unconfigured audience must not be allowed")
	}
}
