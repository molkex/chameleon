package mobile

import (
	"testing"

	"github.com/chameleonvpn/chameleon/internal/payments/apple"
)

// TestAppleChargeID locks in the rule that auto-renewing products use the
// per-event transactionId as payments.charge_id, while non-renewing products
// (including unknown ids) use the stable originalTransactionId.
//
// Why we care: auto-renewing renewals share originalTransactionId. If the
// charge_id were originalTransactionId for them, renewal #2 would collide
// on UNIQUE(source, charge_id) inside CreditDays, silently no-op the
// credit, and ReconcileFromLedger would cap subscription_expiry at the
// original purchase date. Users would lose access after their first month.
func TestAppleChargeID(t *testing.T) {
	cases := []struct {
		name        string
		productID   string
		txID        string
		origTxID    string
		wantCharge  string
		description string
	}{
		{
			name:        "auto-renewing monthly uses transactionId",
			productID:   "com.madfrog.vpn.sub.month",
			txID:        "1000000050000001",
			origTxID:    "1000000050000000",
			wantCharge:  "1000000050000001",
			description: "auto-renewing → per-event id so renewals don't collide",
		},
		{
			name:        "auto-renewing yearly uses transactionId",
			productID:   "com.madfrog.vpn.sub.year",
			txID:        "1000000060000002",
			origTxID:    "1000000060000000",
			wantCharge:  "1000000060000002",
			description: "auto-renewing → per-event id",
		},
		{
			name:        "legacy non-renewing 30days uses originalTransactionId",
			productID:   "com.madfrog.vpn.sub.30days",
			txID:        "1000000070000001",
			origTxID:    "1000000070000000",
			wantCharge:  "1000000070000000",
			description: "non-renewing → stable id (idempotent against duplicate Restore)",
		},
		{
			name:        "legacy non-renewing 365days uses originalTransactionId",
			productID:   "com.madfrog.vpn.sub.365days",
			txID:        "1000000080000001",
			origTxID:    "1000000080000000",
			wantCharge:  "1000000080000000",
			description: "non-renewing → stable id",
		},
		{
			name:        "unknown productId falls back to originalTransactionId",
			productID:   "com.madfrog.vpn.sub.something_new",
			txID:        "1000000090000001",
			origTxID:    "1000000090000000",
			wantCharge:  "1000000090000000",
			description: "unknown → safe default of stable id (idempotent)",
		},
		{
			name:        "auto-renewing with empty transactionId falls back",
			productID:   "com.madfrog.vpn.sub.month",
			txID:        "",
			origTxID:    "1000000095000000",
			wantCharge:  "1000000095000000",
			description: "defensive: never return empty charge_id",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tx := &apple.Transaction{
				ProductID:             tc.productID,
				TransactionID:         tc.txID,
				OriginalTransactionID: tc.origTxID,
			}
			got := appleChargeID(tx)
			if got != tc.wantCharge {
				t.Fatalf("%s: appleChargeID = %q, want %q", tc.description, got, tc.wantCharge)
			}
		})
	}
}

// TestIsAutoRenewing covers the membership test that backs appleChargeID.
// Lock in the four auto-renewing ids explicitly so accidental renames don't
// silently regress to the originalTransactionId path.
func TestIsAutoRenewing(t *testing.T) {
	autoRenewing := []string{
		"com.madfrog.vpn.sub.month",
		"com.madfrog.vpn.sub.3month",
		"com.madfrog.vpn.sub.6month",
		"com.madfrog.vpn.sub.year",
	}
	for _, id := range autoRenewing {
		if !isAutoRenewing(id) {
			t.Errorf("isAutoRenewing(%q) = false, want true", id)
		}
	}
	nonRenewing := []string{
		"com.madfrog.vpn.sub.30days",
		"com.madfrog.vpn.sub.90days",
		"com.madfrog.vpn.sub.180days",
		"com.madfrog.vpn.sub.365days",
		"com.madfrog.vpn.sub.unknown",
		"",
	}
	for _, id := range nonRenewing {
		if isAutoRenewing(id) {
			t.Errorf("isAutoRenewing(%q) = true, want false", id)
		}
	}
}
