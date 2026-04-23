// Package freekassa provides the FreeKassa payment gateway integration:
//   - Order creation via https://api.fk.life/v1/orders/create (HMAC-SHA256 signed)
//   - Webhook signature verification (MD5, secret word 2)
//   - Payment ID encoding/decoding so one shop can serve both the Telegram bot
//     and the iOS app without colliding on charge_ids.
//
// Signature formulas are taken from https://docs.freekassa.net. Unit tests pin
// both formulas to example values so drift is caught at build time.
package freekassa

import (
	"crypto/hmac"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sort"
	"strings"
)

// APISignature builds the HMAC-SHA256 signature required by the /orders/create
// endpoint. All values are sorted alphabetically by key, joined with "|", and
// the resulting string is HMAC-SHA256'd with the merchant API key.
//
// Example values from docs section 2.1:
//
//	params = {"amount":100,"currency":"RUB","email":"u@x","i":44,
//	          "ip":"1.2.3.4","nonce":1708000000000,
//	          "paymentId":"app_m1_42_7","shopId":"12345"}
//	message = "100|RUB|u@x|44|1.2.3.4|1708000000000|app_m1_42_7|12345"
//	signature = HMAC-SHA256(apiKey, message)
//
// All values are stringified via fmt.Sprint so ints, strings, and floats
// serialize the same way regardless of the source type.
func APISignature(params map[string]any, apiKey string) string {
	keys := make([]string, 0, len(params))
	for k := range params {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprint(params[k]))
	}
	message := strings.Join(parts, "|")

	mac := hmac.New(sha256.New, []byte(apiKey))
	mac.Write([]byte(message))
	return hex.EncodeToString(mac.Sum(nil))
}

// VerifyWebhookSignature returns true if the SIGN value posted by FreeKassa
// matches the expected MD5 hash derived from shopID:amount:secret2:orderID.
//
// FreeKassa sends AMOUNT as a string (e.g. "249.00") in the form payload — we
// use it verbatim, do NOT normalize or re-format, otherwise the hash will
// diverge from what FreeKassa computed on their side.
//
// Comparison uses hmac.Equal for constant-time safety.
func VerifyWebhookSignature(shopID, amount, orderID, sign, secret2 string) bool {
	message := fmt.Sprintf("%s:%s:%s:%s", shopID, amount, secret2, orderID)
	digest := md5.Sum([]byte(message))
	expected := hex.EncodeToString(digest[:])
	return hmac.Equal([]byte(expected), []byte(sign))
}
