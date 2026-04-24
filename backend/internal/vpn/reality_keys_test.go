package vpn

import (
	"strings"
	"testing"
)

// Keys from production servers, captured 2026-04-25 — verified x25519
// pairs before we ever checked. Using real data keeps these tests tied
// to how sing-box actually generates them; synthetic fixtures might miss
// edge cases like leading-bit masking quirks.
var realityPairs = []struct {
	name    string
	priv    string
	pub     string
	comment string
}{
	{
		name: "DE",
		priv: "mMQQZciNtcjfln0jBddIclm_HM8M3C8KALzHPfR0WVQ",
		pub:  "ug2jX3uFFdLXih4t0O-PTRElQpAkO6v74RiRVJVvpzE",
	},
	{
		name: "NL2",
		priv: "4OVfYYCUb4s_ajjRTO1BuH-fJklTG4o3T8utU9yW3kU",
		pub:  "99tZNtOBXlY4XhbHrmdXuXmZ7DBzRV0m5GKVlXaNOR8",
	},
	{
		name: "MSK-relay",
		priv: "kMQAnrm9vUHhPfBLA9OW7bCqnpZy6mSKqyBo_cxWFWY",
		pub:  "OJSR6FJytgohcFEUU4YD_IBdc3X83SUuez0n5tskTUs",
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
	// Swap DE private with NL public — valid keys, wrong pair.
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
