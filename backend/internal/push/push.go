// Package push sends APNs (Apple Push Notification service) alerts over HTTP/2.
//
// SUPPORT-CHAT P4 (ADR 0011 follow-up): when a support AGENT replies, the
// client gets a push so it can surface the answer even when the app is
// backgrounded. The client registers its device token via the mobile
// /push/register endpoint; admin/support.go fans a reply out to every token of
// the thread's owner.
//
// Token-based auth (the modern APNs scheme): a single ES256-signed JWT, keyed
// by the .p8 download from the Apple Developer portal, authorises every push.
// The provider token is cached and rotated well inside Apple's 1-hour validity
// window. Go's net/http speaks HTTP/2 over TLS automatically, so a plain
// http.Client reaches api.push.apple.com with no extra dependency.
//
// Graceful disable: NewFromEnv returns (nil, nil) when the APNS_* env is unset
// (mirrors storage.NewFromEnv) so a box without Apple push creds simply skips
// the send rather than failing — callers nil-check the *Client.
package push

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// apnsProductionHost is the production APNs endpoint. We don't target the
// sandbox host: TestFlight + App Store builds both use production APNs, so a
// single host is correct for our distribution.
const apnsProductionHost = "https://api.push.apple.com"

// tokenRefresh is how stale a cached provider token may get before token()
// regenerates it. Apple rejects tokens older than 1h (and throttles tokens
// minted too often), so ~50 min keeps us comfortably inside the window with one
// token per ~50 min.
const tokenRefresh = 50 * time.Minute

// sendTimeout bounds a single push POST so one slow/hung request can't stall
// the background fan-out goroutine.
const sendTimeout = 3 * time.Second

// ErrBadToken signals that APNs has permanently rejected a device token
// (HTTP 410 Unregistered, or 400 BadDeviceToken). Callers should prune the
// token from the DB rather than retry.
var ErrBadToken = errors.New("push: device token rejected by APNs")

// Client sends APNs alerts using a cached ES256 provider token.
type Client struct {
	key    *ecdsa.PrivateKey
	keyID  string
	teamID string
	topic  string // the app bundle id (apns-topic)
	http   *http.Client

	mu          sync.Mutex
	cachedToken string
	tokenIssued time.Time
}

// NewFromEnv builds a Client from the APNS_* environment:
//
//	APNS_KEY_ID     — the 10-char Key ID of the .p8 key
//	APNS_TEAM_ID    — the Apple Developer team id (the JWT issuer)
//	APNS_BUNDLE_ID  — the app bundle id (the apns-topic header)
//	APNS_KEY_P8_B64 — base64 of the .p8 PEM (PKCS8 EC private key)
//
// It returns (nil, nil) when ANY of those is empty — the caller treats that as
// "push gracefully disabled" rather than an error (mirrors storage.NewFromEnv).
// A configured-but-malformed key IS an error (loud misconfiguration).
func NewFromEnv() (*Client, error) {
	keyID := os.Getenv("APNS_KEY_ID")
	teamID := os.Getenv("APNS_TEAM_ID")
	bundleID := os.Getenv("APNS_BUNDLE_ID")
	keyB64 := os.Getenv("APNS_KEY_P8_B64")
	if keyID == "" || teamID == "" || bundleID == "" || keyB64 == "" {
		return nil, nil
	}

	pemBytes, err := base64.StdEncoding.DecodeString(keyB64)
	if err != nil {
		return nil, fmt.Errorf("push: decode APNS_KEY_P8_B64: %w", err)
	}
	key, err := parseECKey(pemBytes)
	if err != nil {
		return nil, err
	}

	return &Client{
		key:    key,
		keyID:  keyID,
		teamID: teamID,
		topic:  bundleID,
		http:   &http.Client{Timeout: sendTimeout},
	}, nil
}

// parseECKey decodes a PEM-wrapped PKCS8 EC private key (the .p8 shape Apple
// ships) and asserts the *ecdsa.PrivateKey ES256 signing needs.
func parseECKey(pemBytes []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("push: APNS key is not valid PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("push: parse PKCS8 key: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("push: APNS key is %T, want *ecdsa.PrivateKey", parsed)
	}
	return key, nil
}

// token returns a cached ES256 provider token, regenerating it once it is older
// than tokenRefresh. Mutex-guarded so a burst of concurrent sends shares one
// token (and one signing op) rather than re-minting per request.
func (c *Client) token() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.cachedToken != "" && time.Since(c.tokenIssued) < tokenRefresh {
		return c.cachedToken, nil
	}

	now := time.Now()
	claims := jwt.MapClaims{
		"iss": c.teamID,
		"iat": now.Unix(),
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
	tok.Header["kid"] = c.keyID
	// jwt-go already sets alg=ES256 and typ=JWT in the header.
	signed, err := tok.SignedString(c.key)
	if err != nil {
		return "", fmt.Errorf("push: sign provider token: %w", err)
	}

	c.cachedToken = signed
	c.tokenIssued = now
	return signed, nil
}

// apnsErrorBody is the JSON APNs returns on a non-200 (the reason string drives
// the ErrBadToken classification).
type apnsErrorBody struct {
	Reason string `json:"reason"`
}

// Send delivers an alert push to one device token. title/body populate the
// alert; custom keys (e.g. {"type":"support_reply","thread_id":42}) are merged
// at the top level of the payload alongside "aps" so the client can route the
// tap.
//
// Returns ErrBadToken when APNs permanently rejects the token (410, or 400 with
// reason BadDeviceToken/Unregistered) so the caller can prune it. Other
// non-200s return an error carrying the status + APNs reason.
func (c *Client) Send(ctx context.Context, deviceToken, title, body string, custom map[string]any) error {
	payload := buildPayload(title, body, custom)
	raw, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("push: marshal payload: %w", err)
	}

	tok, err := c.token()
	if err != nil {
		return err
	}

	reqCtx, cancel := context.WithTimeout(ctx, sendTimeout)
	defer cancel()

	url := apnsProductionHost + "/3/device/" + deviceToken
	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, url, bytes.NewReader(raw))
	if err != nil {
		return fmt.Errorf("push: new request: %w", err)
	}
	req.Header.Set("authorization", "bearer "+tok)
	req.Header.Set("apns-topic", c.topic)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "10")
	req.Header.Set("content-type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("push: send: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode == http.StatusOK {
		return nil
	}

	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	var apnsErr apnsErrorBody
	_ = json.Unmarshal(respBody, &apnsErr)

	if resp.StatusCode == http.StatusGone ||
		(resp.StatusCode == http.StatusBadRequest &&
			(apnsErr.Reason == "BadDeviceToken" || apnsErr.Reason == "Unregistered")) {
		return ErrBadToken
	}
	return fmt.Errorf("push: APNs status %d reason %q", resp.StatusCode, apnsErr.Reason)
}

// buildPayload assembles the APNs JSON: the standard "aps" alert dictionary plus
// any custom top-level keys. Custom keys never overwrite "aps". Split out so the
// wire shape is unit-testable without a live APNs connection.
func buildPayload(title, body string, custom map[string]any) map[string]any {
	payload := make(map[string]any, len(custom)+1)
	for k, v := range custom {
		if k == "aps" {
			continue // reserved
		}
		payload[k] = v
	}
	payload["aps"] = map[string]any{
		"alert": map[string]any{
			"title": title,
			"body":  body,
		},
		"sound": "default",
		"badge": 1,
	}
	return payload
}
