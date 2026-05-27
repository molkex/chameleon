package vpn

import (
	"strings"
	"testing"
)

// Synthetic Reality x25519 keypairs generated for test fixtures only.
// 2026-05-26 (audit CRIT-001): the prior version of this file shipped
// production keys verbatim — those have been rotated; these are fresh
// pairs created via `sing-box generate reality-keypair` purely so the
// tests can exercise DerivePublicKey / ValidateRealityKeyPair against
// known-good math. No deployed node uses any of these. Treat as test
// data, not credentials.
var realityPairs = []struct {
	name string
	priv string
	pub  string
}{
	{
		name: "synthetic-A",
		priv: "KNNykKLLBlq7Jj_wO4UF8OTMJn3whOm4yvqXPgy6b1Y",
		pub:  "YFdu6tIo4524vI0q3eSXLJdySAwBJ2toXbr_NSKYQQs",
	},
	{
		name: "synthetic-B",
		priv: "UKBoOUNAKuIsnzhATzuqawFJ8rbMgALS-wWfYJZuZ3M",
		pub:  "QTC2XRuUaiWO2A1CNbps_9wJp-vaQ2zMYu0VPrS65QM",
	},
	{
		name: "synthetic-C",
		priv: "uGvlHG6EearUAUG-5OqbtEegZ4ttuP2Xiad4eqRfMVg",
		pub:  "I84vSWkXXJGJU3KreRsR1ztmy1u6PyeYXCKMrYXX_zY",
	},
}

func TestDerivePublicKeyMatchesProductionPairs(t *testing.T) {
	for _, tc := range realityPairs {
		t.Run(tc.name, func(t *testing.T) {
			got, err := DerivePublicKeyBase64URL(tc.priv)
			if err != nil {
				t.Fatalf("derive: %v", err)
			}
			if got != tc.pub {
				t.Errorf("derived pubkey mismatch\n  have %s\n  want %s", got, tc.pub)
			}
		})
	}
}

func TestValidateRealityKeyPairAcceptsMatchingPairs(t *testing.T) {
	for _, tc := range realityPairs {
		t.Run(tc.name, func(t *testing.T) {
			if err := ValidateRealityKeyPair(tc.priv, tc.pub); err != nil {
				t.Errorf("expected pair to validate, got %v", err)
			}
		})
	}
}

func TestValidateRealityKeyPairRejectsMismatchedPair(t *testing.T) {
	// Swap synthetic-A private with synthetic-B public — valid keys,
	// wrong pair.
	err := ValidateRealityKeyPair(realityPairs[0].priv, realityPairs[1].pub)
	if err == nil {
		t.Fatal("expected mismatch error, got nil")
	}
	// Error message must include BOTH keys so ops can diff without tools.
	if !strings.Contains(err.Error(), "derived=") ||
		!strings.Contains(err.Error(), "expected=") {
		t.Errorf("error message should include derived/expected keys, got: %s", err)
	}
}

func TestValidateRealityKeyPairRejectsEmptyInputs(t *testing.T) {
	if err := ValidateRealityKeyPair("", "abc"); err == nil {
		t.Error("empty private should be rejected")
	}
	if err := ValidateRealityKeyPair("abc", ""); err == nil {
		t.Error("empty public should be rejected")
	}
}

func TestDeriveAcceptsPaddedBase64URL(t *testing.T) {
	// Sanity: the same key encoded with '=' padding must still work —
	// some older tooling (including some openssl wrappers) emit padded.
	priv := realityPairs[0].priv
	padded := priv
	// Add padding to nearest 4-char boundary.
	for len(padded)%4 != 0 {
		padded += "="
	}
	got, err := DerivePublicKeyBase64URL(padded)
	if err != nil {
		t.Fatalf("padded input: %v", err)
	}
	if got != realityPairs[0].pub {
		t.Errorf("padded derivation returned %s, want %s", got, realityPairs[0].pub)
	}
}

func TestDeriveRejectsInvalidInput(t *testing.T) {
	// Not base64 at all.
	if _, err := DerivePublicKeyBase64URL("!@#$not_base64$#@!"); err == nil {
		t.Error("expected decode error, got nil")
	}
	// Wrong key length (16 bytes instead of 32).
	short := "AAAAAAAAAAAAAAAAAAAAAQ" // 16 zero bytes + 1 = 22 b64 chars
	if _, err := DerivePublicKeyBase64URL(short); err == nil {
		t.Error("expected length-check error for short key, got nil")
	}
}
