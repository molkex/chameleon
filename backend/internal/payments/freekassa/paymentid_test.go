package freekassa

import (
	"strings"
	"testing"
)

func TestAppPaymentIDRoundTrip(t *testing.T) {
	id := AppPaymentID("m3", 42, 1712345678)
	if id != "app_m3_42_1712345678" {
		t.Fatalf("AppPaymentID = %q, want app_m3_42_1712345678", id)
	}
	p, err := ParseAppPayment(id)
	if err != nil {
		t.Fatalf("ParseAppPayment(%q): %v", id, err)
	}
	if p.PlanID != "m3" || p.UserID != 42 || p.Nonce != 1712345678 {
		t.Errorf("parsed = %+v, want {m3 42 1712345678}", p)
	}
}

func TestIsAppPaymentAndBot(t *testing.T) {
	if !IsAppPayment("app_m1_1_2") {
		t.Error(`"app_..." should be an app payment`)
	}
	if IsAppPayment("bot_m1_1_2") {
		t.Error(`"bot_..." must not be an app payment`)
	}
	if !IsBotPayment("bot_x") {
		t.Error(`"bot_..." should be a bot payment`)
	}
	if IsBotPayment("app_x") {
		t.Error(`"app_..." must not be a bot payment`)
	}
}

func TestParseAppPaymentErrors(t *testing.T) {
	tests := []struct{ name, id, wantErr string }{
		{"not app prefix", "bot_m1_1_2", "not an app payment"},
		{"too few parts", "app_m3_42", "invalid app payment id"},
		{"too many parts (plan with underscore)", "app_m3_42_1_2", "invalid app payment id"},
		{"non-numeric user id", "app_m3_xx_5", "invalid user id"},
		{"non-numeric nonce", "app_m3_5_yy", "invalid nonce"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := ParseAppPayment(tc.id)
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("ParseAppPayment(%q): want error containing %q, got %v", tc.id, tc.wantErr, err)
			}
		})
	}
}
