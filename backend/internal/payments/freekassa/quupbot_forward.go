package freekassa

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// QuupbotOrderPrefix marks a FreeKassa MERCHANT_ORDER_ID as belonging to quupbot, a
// separate Telegram-bot shop sharing this project's FreeKassa shopId. chameleon and
// quupbot each have their own notification-URL-free integration: FreeKassa's merchant
// panel only allows ONE notification URL per shopId, which is chameleon's — so quupbot
// orders are recognized by this prefix and relayed over HTTPS to quupbot's own webhook
// receiver instead of being processed here.
const QuupbotOrderPrefix = "qb_"

// IsQuupbotPayment reports whether a MERCHANT_ORDER_ID belongs to quupbot rather than
// to this project's own "app_" family.
func IsQuupbotPayment(merchantOrderID string) bool {
	return strings.HasPrefix(merchantOrderID, QuupbotOrderPrefix)
}

// ErrForwardRejected marks a permanent rejection by quupbot (bad signature on its side,
// unknown order, amount mismatch) — the caller should NOT tell FreeKassa to retry.
// Any other error from Forward is transient (network, quupbot down, 5xx) and the caller
// should let FreeKassa retry.
var ErrForwardRejected = errors.New("quupbot rejected payment")

// QuupbotForwarder relays an already-signature-verified FreeKassa notification to
// quupbot's webhook receiver. It does NOT re-derive or forward FreeKassa's own
// secret2 — authentication between chameleon and quupbot uses a separate shared
// secret (QuupbotForwardSecret), so a compromise of one system's secret can't be
// used to forge the other's signature.
type QuupbotForwarder struct {
	URL    string // e.g. https://pay.madfrog.online/webhook/freekassa
	Secret string
	Client *http.Client
}

// NewQuupbotForwarder returns nil if url or secret is empty — the feature is meant to be
// off by default; callers must nil-check before use (see Handler.QuupbotForwarder).
func NewQuupbotForwarder(rawURL, secret string) *QuupbotForwarder {
	if rawURL == "" || secret == "" {
		return nil
	}
	return &QuupbotForwarder{
		URL:    rawURL,
		Secret: secret,
		Client: &http.Client{Timeout: 10 * time.Second},
	}
}

// Forward re-sends the raw FreeKassa form to quupbot, HMAC-signed over (timestamp + body).
func (f *QuupbotForwarder) Forward(ctx context.Context, form url.Values) error {
	body := form.Encode()
	ts := strconv.FormatInt(time.Now().Unix(), 10)

	mac := hmac.New(sha256.New, []byte(f.Secret))
	mac.Write([]byte(ts))
	mac.Write([]byte("\n"))
	mac.Write([]byte(body))
	sig := hex.EncodeToString(mac.Sum(nil))

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, f.URL, bytes.NewReader([]byte(body)))
	if err != nil {
		return fmt.Errorf("quupbot forward: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("X-Forward-Timestamp", ts)
	req.Header.Set("X-Forward-Signature", sig)

	resp, err := f.Client.Do(req)
	if err != nil {
		return fmt.Errorf("quupbot forward: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return nil
	case resp.StatusCode >= 400 && resp.StatusCode < 500:
		return fmt.Errorf("%w: status %d", ErrForwardRejected, resp.StatusCode)
	default:
		return fmt.Errorf("quupbot forward: status %d", resp.StatusCode)
	}
}
