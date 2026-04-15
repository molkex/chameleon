package freekassa

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// Payment IDs encode the source system plus enough metadata to route the webhook
// back to the right user without a separate orders table lookup. Format:
//
//	app_{plan_id}_{user_id}_{nonce}
//
// Example: "app_m3_42_1712345678".
//
// The "app_" prefix is reserved for the Chameleon iOS app. If the same FreeKassa
// merchant shop is ever reused for the Telegram bot, its payment ids should
// start with "bot_" so the webhook handler can distinguish them.

const (
	prefixApp = "app_"
	prefixBot = "bot_"
)

// AppPaymentID builds a payment id for an iOS app purchase.
func AppPaymentID(planID string, userID int64, nonce int64) string {
	return fmt.Sprintf("%s%s_%d_%d", prefixApp, planID, userID, nonce)
}

// ParsedAppPayment holds the decoded fields of an "app_*" payment id.
type ParsedAppPayment struct {
	PlanID string
	UserID int64
	Nonce  int64
}

// IsAppPayment returns true for payment ids produced by AppPaymentID.
func IsAppPayment(id string) bool { return strings.HasPrefix(id, prefixApp) }

// IsBotPayment returns true for the legacy Telegram bot payment format.
// Handled by the proxy path (forwarded to the bot backend).
func IsBotPayment(id string) bool { return strings.HasPrefix(id, prefixBot) }

// ParseAppPayment decodes an "app_*" payment id into its components. Returns an
// error for anything that does not match the expected shape — the caller should
// reject the webhook rather than guessing.
func ParseAppPayment(id string) (ParsedAppPayment, error) {
	if !IsAppPayment(id) {
		return ParsedAppPayment{}, errors.New("freekassa: not an app payment id")
	}
	rest := strings.TrimPrefix(id, prefixApp)
	// plan ids may contain letters/digits but no "_", so we can split safely.
	parts := strings.Split(rest, "_")
	if len(parts) != 3 {
		return ParsedAppPayment{}, fmt.Errorf("freekassa: invalid app payment id %q", id)
	}
	userID, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return ParsedAppPayment{}, fmt.Errorf("freekassa: invalid user id in %q: %w", id, err)
	}
	nonce, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil {
		return ParsedAppPayment{}, fmt.Errorf("freekassa: invalid nonce in %q: %w", id, err)
	}
	return ParsedAppPayment{PlanID: parts[0], UserID: userID, Nonce: nonce}, nil
}
