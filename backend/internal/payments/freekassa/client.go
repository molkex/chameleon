package freekassa

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"
)

// Config holds everything the Client needs. All fields are required; the
// constructor validates them up front so misconfiguration fails loudly at
// startup instead of at the first payment attempt.
type Config struct {
	ShopID  string
	APIKey  string
	Secret2 string // for webhook verification (not used here, kept for symmetry)
	BaseURL string // e.g. "https://api.fk.life/v1"
}

// Client talks to the FreeKassa REST API. Safe for concurrent use.
type Client struct {
	cfg Config
	hc  *http.Client
}

// New returns a Client. Fails fast on missing fields.
func New(cfg Config) (*Client, error) {
	if cfg.ShopID == "" {
		return nil, fmt.Errorf("freekassa: shop_id required")
	}
	if cfg.APIKey == "" {
		return nil, fmt.Errorf("freekassa: api_key required")
	}
	if cfg.BaseURL == "" {
		cfg.BaseURL = "https://api.fk.life/v1"
	}
	return &Client{
		cfg: cfg,
		hc: &http.Client{
			Timeout: 15 * time.Second,
		},
	}, nil
}

// CreateOrderInput is the caller-facing input. The client fills in nonce,
// shop id and signature internally.
type CreateOrderInput struct {
	PaymentID string        // our order id (see paymentid.go)
	Method    PaymentMethod // sbp / card / sberpay
	Email     string        // real email — required for 54-FZ receipt
	IP        string        // client IP; MUST NOT be 127.0.0.1 (FreeKassa rejects it)
	Amount    int           // rubles (whole number)
}

// CreateOrder builds the signed request, POSTs it to /orders/create, and
// returns the payment location URL that should be handed to the user.
func (c *Client) CreateOrder(ctx context.Context, in CreateOrderInput) (*CreateOrderResponse, error) {
	if !in.Method.IsSupported() {
		return nil, fmt.Errorf("freekassa: unsupported method %d", in.Method)
	}
	if in.PaymentID == "" {
		return nil, fmt.Errorf("freekassa: payment_id required")
	}
	if in.Email == "" {
		return nil, fmt.Errorf("freekassa: email required")
	}
	if in.IP == "" || in.IP == "127.0.0.1" || in.IP == "::1" {
		return nil, fmt.Errorf("freekassa: client ip must be a public address, got %q", in.IP)
	}
	if in.Amount <= 0 {
		return nil, fmt.Errorf("freekassa: amount must be positive")
	}

	nonce := time.Now().UnixMilli() // MUST be milliseconds, not seconds×1000

	// NB: signature must see the same values (and same serialization) as the JSON body.
	params := map[string]any{
		"shopId":    c.cfg.ShopID,
		"nonce":     nonce,
		"paymentId": in.PaymentID,
		"i":         int(in.Method),
		"email":     in.Email,
		"ip":        in.IP,
		"amount":    in.Amount,
		"currency":  "RUB",
	}
	sig := APISignature(params, c.cfg.APIKey)

	body := CreateOrderRequest{
		ShopID:    c.cfg.ShopID,
		Nonce:     nonce,
		PaymentID: in.PaymentID,
		I:         in.Method,
		Email:     in.Email,
		IP:        in.IP,
		Amount:    in.Amount,
		Currency:  "RUB",
		Signature: sig,
	}

	raw, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("freekassa: marshal: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.cfg.BaseURL+"/orders/create", bytes.NewReader(raw))
	if err != nil {
		return nil, fmt.Errorf("freekassa: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("freekassa: call: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("freekassa: read response: %w", err)
	}

	var out CreateOrderResponse
	if err := json.Unmarshal(respBody, &out); err != nil {
		return nil, fmt.Errorf("freekassa: decode response (status=%d, body=%s): %w", resp.StatusCode, string(respBody), err)
	}

	if resp.StatusCode >= 400 || out.Type != "success" || out.Location == "" {
		msg := out.Message
		if msg == "" {
			msg = string(respBody)
		}
		return nil, fmt.Errorf("freekassa: create order failed (status=%d): %s", resp.StatusCode, msg)
	}
	return &out, nil
}

// IPAllowed returns true if remoteAddr (or the first X-Forwarded-For hop) is in
// the configured FreeKassa notification IP allowlist. An empty allowlist means
// allow everything — callers should log a loud warning in that mode.
func IPAllowed(remoteAddr string, allowlist []string) bool {
	if len(allowlist) == 0 {
		return true
	}
	// Trim possible "ip:port".
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		host = remoteAddr
	}
	for _, allowed := range allowlist {
		if host == allowed {
			return true
		}
	}
	return false
}
