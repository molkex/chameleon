// Package asc is a minimal App Store Connect API client.
//
// Apple's ASC API requires ES256-signed JWTs in every request. Tokens
// expire in 20 minutes; we cache a single in-memory token and refresh
// when it has <2 minutes left. Audience must be "appstoreconnect-v1".
//
// Why custom and not a third-party lib: the existing go-iap dependency
// is StoreKit-Server only (transaction verification + ASN v2), not ASC.
// All the existing ASC clients in Go are either abandoned or pull a
// huge dependency footprint. We need exactly four read-only endpoints
// (apps, appStoreVersions, inAppPurchases, builds) — easier to ship the
// raw HTTP than vendor a maintenance burden.
//
// Credentials come from env vars (already loaded by config.go):
//   - ASC_KEY_ID
//   - ASC_ISSUER_ID
//   - ASC_KEY_PATH  → path to the .p8 file
package asc

import (
	"context"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	baseURL      = "https://api.appstoreconnect.apple.com"
	audience     = "appstoreconnect-v1"
	tokenTTL     = 20 * time.Minute
	tokenRefresh = 2 * time.Minute // refresh when < this much time left
)

// Client signs and dispatches ASC requests. Safe for concurrent use.
type Client struct {
	keyID    string
	issuerID string
	key      *ecdsa.PrivateKey
	http     *http.Client

	mu        sync.Mutex
	token     string
	expiresAt time.Time
}

// New constructs a client from env vars. Returns nil + nil error if the
// ASC credentials are not configured — the admin Status page should
// render an "ASC not configured" placeholder rather than 500.
func New() (*Client, error) {
	keyID := os.Getenv("ASC_KEY_ID")
	issuerID := os.Getenv("ASC_ISSUER_ID")
	keyPath := os.Getenv("ASC_KEY_PATH")
	if keyID == "" || issuerID == "" || keyPath == "" {
		return nil, nil //nolint:nilnil // intentional: "not configured" sentinel
	}

	pemBytes, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("asc: read key file: %w", err)
	}

	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("asc: PEM decode failed (no block)")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("asc: parse PKCS8: %w", err)
	}
	pkey, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("asc: key is not ECDSA")
	}

	return &Client{
		keyID:    keyID,
		issuerID: issuerID,
		key:      pkey,
		http:     &http.Client{Timeout: 10 * time.Second},
	}, nil
}

// signedToken returns a cached or freshly minted ES256 JWT.
func (c *Client) signedToken() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.token != "" && time.Until(c.expiresAt) > tokenRefresh {
		return c.token, nil
	}

	now := time.Now()
	exp := now.Add(tokenTTL)
	claims := jwt.MapClaims{
		"iss": c.issuerID,
		"iat": now.Unix(),
		"exp": exp.Unix(),
		"aud": audience,
	}
	t := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
	t.Header["kid"] = c.keyID
	t.Header["typ"] = "JWT"

	signed, err := t.SignedString(c.key)
	if err != nil {
		return "", fmt.Errorf("asc: sign JWT: %w", err)
	}
	c.token = signed
	c.expiresAt = exp
	return signed, nil
}

// get issues a signed GET request and decodes JSON into out. Returns the
// HTTP status code so callers can distinguish "not configured" (we returned
// nil from New) vs "Apple is rate-limiting us" (429) vs "real error".
func (c *Client) get(ctx context.Context, path string, query url.Values, out any) (int, error) {
	tok, err := c.signedToken()
	if err != nil {
		return 0, err
	}

	full := baseURL + path
	if len(query) > 0 {
		full += "?" + query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, full, nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Accept", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return 0, fmt.Errorf("asc: http: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return resp.StatusCode, fmt.Errorf("asc: HTTP %d: %s", resp.StatusCode, string(body))
	}

	if out != nil {
		if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
			return resp.StatusCode, fmt.Errorf("asc: decode: %w", err)
		}
	}
	return resp.StatusCode, nil
}

// ── Domain types (only the fields we actually surface) ────────────────────

// AppStoreVersion is one row from /v1/apps/{id}/appStoreVersions.
type AppStoreVersion struct {
	ID            string `json:"id"`
	VersionString string `json:"versionString"`
	Platform      string `json:"platform"`
	AppStoreState string `json:"appStoreState"`
	ReleaseType   string `json:"releaseType"`
	CreatedDate   string `json:"createdDate"`
}

// InAppPurchase is one row from /v1/apps/{id}/inAppPurchasesV2.
type InAppPurchase struct {
	ID                string `json:"id"`
	ProductID         string `json:"productId"`
	Name              string `json:"name"`
	Type              string `json:"inAppPurchaseType"`
	State             string `json:"state"`
}

// Build is one row from /v1/builds (filtered by app).
type Build struct {
	ID                string `json:"id"`
	Version           string `json:"version"`           // CFBundleVersion (e.g. "89")
	ProcessingState   string `json:"processingState"`   // PROCESSING / VALID
	Expired           bool   `json:"expired"`
	UploadedDate      string `json:"uploadedDate"`
	ExpirationDate    string `json:"expirationDate"`
	PreReleaseVersion string `json:"preReleaseVersion"` // CFBundleShortVersionString
}

// ── Endpoint wrappers ─────────────────────────────────────────────────────

// AppStoreVersions returns versions for the given app, newest first by
// createdDate.
//
// Sorting note: Apple's ASC API on /v1/apps/{id}/appStoreVersions only
// accepts `sort` values "versionString" and "appStoreState" — passing
// `createdDate` returns HTTP 400 PARAMETER_ERROR.ILLEGAL (caught live
// on 2026-05-27 in the admin Status page). `-versionString` would
// almost work but breaks the moment we cross 1.0.10 (lex sort puts
// "1.0.9" after "1.0.10"). So we don't sort server-side, fetch with a
// generous limit, then sort client-side by createdDate. With <50
// versions per app over the app's lifetime this is cheap.
func (c *Client) AppStoreVersions(ctx context.Context, appID string, limit int) ([]AppStoreVersion, error) {
	if limit <= 0 {
		limit = 5
	}
	// Fetch a wider window than the caller asked for so the post-sort
	// trim catches the actually-newest N. ASC limit cap is 200.
	fetchLimit := limit * 4
	if fetchLimit > 200 {
		fetchLimit = 200
	}
	if fetchLimit < limit {
		fetchLimit = limit
	}

	type wireResp struct {
		Data []struct {
			ID         string          `json:"id"`
			Attributes AppStoreVersion `json:"attributes"`
		} `json:"data"`
	}
	q := url.Values{}
	q.Set("limit", fmt.Sprintf("%d", fetchLimit))
	q.Set("fields[appStoreVersions]", "versionString,platform,appStoreState,releaseType,createdDate")
	var raw wireResp
	if _, err := c.get(ctx, "/v1/apps/"+appID+"/appStoreVersions", q, &raw); err != nil {
		return nil, err
	}
	out := make([]AppStoreVersion, 0, len(raw.Data))
	for _, d := range raw.Data {
		v := d.Attributes
		v.ID = d.ID
		out = append(out, v)
	}
	// Newest createdDate first. Lexicographic compare is safe — Apple
	// returns RFC3339-with-tz format which sorts correctly as strings
	// (e.g. "2026-05-27T19:18:26-07:00" > "2026-05-15T..."). Empty
	// createdDate strings sort to the end which is the right "stale
	// rows last" behaviour.
	sort.SliceStable(out, func(i, j int) bool {
		return out[i].CreatedDate > out[j].CreatedDate
	})
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// InAppPurchases returns the IAP catalog (NON_RENEWING + CONSUMABLE).
// Auto-renewable subscriptions live under a different relationship that
// we don't currently sell.
func (c *Client) InAppPurchases(ctx context.Context, appID string, limit int) ([]InAppPurchase, error) {
	if limit <= 0 {
		limit = 20
	}
	type wireResp struct {
		Data []struct {
			ID         string        `json:"id"`
			Attributes InAppPurchase `json:"attributes"`
		} `json:"data"`
	}
	q := url.Values{}
	q.Set("limit", fmt.Sprintf("%d", limit))
	q.Set("fields[inAppPurchases]", "name,productId,inAppPurchaseType,state")
	var raw wireResp
	if _, err := c.get(ctx, "/v1/apps/"+appID+"/inAppPurchasesV2", q, &raw); err != nil {
		return nil, err
	}
	out := make([]InAppPurchase, 0, len(raw.Data))
	for _, d := range raw.Data {
		iap := d.Attributes
		iap.ID = d.ID
		out = append(out, iap)
	}
	return out, nil
}

// Builds returns the newest N TestFlight builds for the app.
func (c *Client) Builds(ctx context.Context, appID string, limit int) ([]Build, error) {
	if limit <= 0 {
		limit = 5
	}
	type wireResp struct {
		Data []struct {
			ID         string `json:"id"`
			Attributes Build  `json:"attributes"`
		} `json:"data"`
	}
	q := url.Values{}
	q.Set("filter[app]", appID)
	q.Set("sort", "-uploadedDate")
	q.Set("limit", fmt.Sprintf("%d", limit))
	q.Set("fields[builds]", "version,processingState,expired,uploadedDate,expirationDate")
	var raw wireResp
	if _, err := c.get(ctx, "/v1/builds", q, &raw); err != nil {
		return nil, err
	}
	out := make([]Build, 0, len(raw.Data))
	for _, d := range raw.Data {
		b := d.Attributes
		b.ID = d.ID
		out = append(out, b)
	}
	return out, nil
}
