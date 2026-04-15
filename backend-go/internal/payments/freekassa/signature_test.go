package freekassa

import "testing"

// TestAPISignature pins the HMAC-SHA256 formula against a hand-computed example.
// If this breaks, verify the joining order (alphabetical) and separator ("|")
// before touching the implementation.
func TestAPISignature(t *testing.T) {
	params := map[string]any{
		"shopId":    "12345",
		"nonce":     int64(1708000000000),
		"paymentId": "app_m1_42_7",
		"i":         44,
		"email":     "u@x",
		"ip":        "1.2.3.4",
		"amount":    100,
		"currency":  "RUB",
	}
	// Alphabetical order of keys:
	//   amount, currency, email, i, ip, nonce, paymentId, shopId
	// Joined values:
	//   "100|RUB|u@x|44|1.2.3.4|1708000000000|app_m1_42_7|12345"
	// HMAC-SHA256 with key "test-api-key".
	got := APISignature(params, "test-api-key")
	want := "5bfdb2015064376361a9ce7aebea79f0fd5e55c8e1e7b17abe534eb9e363294b"
	if got != want {
		t.Errorf("APISignature mismatch:\n  got:  %s\n  want: %s", got, want)
	}
}

// TestVerifyWebhookSignature pins the MD5 formula for notification hooks.
// Formula: md5("{shopId}:{amount}:{secret2}:{orderId}")
func TestVerifyWebhookSignature(t *testing.T) {
	shopID := "12345"
	amount := "249.00"
	secret2 := "secretTwoValue"
	orderID := "app_m1_42_7"

	// md5("12345:249.00:secretTwoValue:app_m1_42_7") — computed offline.
	validSign := "2421b83138405a2bb1e2d8ddc96ec8fe"

	if !VerifyWebhookSignature(shopID, amount, orderID, validSign, secret2) {
		t.Errorf("VerifyWebhookSignature rejected a valid signature")
	}

	if VerifyWebhookSignature(shopID, amount, orderID, "wrong", secret2) {
		t.Error("VerifyWebhookSignature accepted a wrong signature")
	}

	// Amount must match verbatim — "249" vs "249.00" is a mismatch, which is
	// intentional: FreeKassa computes against the string they sent us, so any
	// normalization on our side would diverge.
	if VerifyWebhookSignature(shopID, "249", orderID, validSign, secret2) {
		t.Error("VerifyWebhookSignature accepted mismatched amount format")
	}
}
