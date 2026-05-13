package mobile

import (
	"slices"
	"testing"

	"github.com/chameleonvpn/chameleon/internal/vpn"
)

// availableLeaves matches the leaf tags emitted by clientconfig.go's
// fixture: standard country leaves DE and NL across all transports.
var availableLeaves = []string{
	"de-direct-de", "de-h2-de", "de-tuic-de", "de-via-msk",
	"nl-direct-nl2", "nl-h2-nl2", "nl-tuic-nl2", "nl-via-msk",
}

// TestResolveOutboundHint_ReturnsPreferredLeafWhenAvailable asserts the core
// invariant: when nl-direct-nl2 is in the available pool, we always
// recommend it as the cold-start first leaf. The hint is universal — no
// geo / locale / IP gating. See preferredFirstLeaf doc for rationale.
func TestResolveOutboundHint_ReturnsPreferredLeafWhenAvailable(t *testing.T) {
	got := resolveOutboundHint(availableLeaves)
	if got != "nl-direct-nl2" {
		t.Errorf("resolveOutboundHint(full pool)=%q, want %q", got, "nl-direct-nl2")
	}
}

// TestResolveOutboundHint_EmptyWhenPreferredAbsent asserts the config-drift
// safeguard: if the backend ships a hint for a leaf that's been removed or
// renamed, we return empty rather than emitting a hint that clientconfig.go
// would silently no-op on. Defends against a future operator removing the
// NL server.
func TestResolveOutboundHint_EmptyWhenPreferredAbsent(t *testing.T) {
	deOnly := []string{"de-direct-de", "de-h2-de", "de-via-msk"}
	got := resolveOutboundHint(deOnly)
	if got != "" {
		t.Errorf("resolveOutboundHint(no NL leaf)=%q, want empty", got)
	}
}

// TestResolveOutboundHint_EmptyOnEmptyInput asserts defensive handling of
// a pathological case (empty server list, e.g. DB temporarily empty).
func TestResolveOutboundHint_EmptyOnEmptyInput(t *testing.T) {
	got := resolveOutboundHint(nil)
	if got != "" {
		t.Errorf("resolveOutboundHint(nil)=%q, want empty", got)
	}
}

// TestAvailableLeafTags_MatchesClientconfigSynthesis asserts that the leaf
// tag pattern used here matches what clientconfig.go emits. Tag format is
// "{cc lowercase}-{kind}-{key}"; if clientconfig.go ever changes that, the
// hint will silently no-op and TestRecommendedFirstReordersAutoLeaves will
// fail. This test is the synthesis-side guard.
func TestAvailableLeafTags_MatchesClientconfigSynthesis(t *testing.T) {
	// Fixture mirrors clientconfig_test.go's fixture() so we know exactly
	// which leaves the generator would emit.
	servers := []vpn.ServerEntry{
		{Key: "de", CountryCode: "DE", Role: "exit", Category: "standard", Hysteria2Port: 443, TUICPort: 8443},
		{Key: "nl2", CountryCode: "NL", Role: "exit", Category: "standard", Hysteria2Port: 443, TUICPort: 8443},
		{Key: "relay-de", CountryCode: "", Role: "exit", Category: "whitelist_bypass"}, // must be skipped
	}
	chains := []vpn.ChainedEntry{
		{RelayKey: "msk", ExitCountryCode: "DE"},
		{RelayKey: "msk", ExitCountryCode: "NL"},
	}
	got := availableLeafTags(servers, chains)
	want := []string{
		"de-direct-de", "de-h2-de", "de-tuic-de",
		"nl-direct-nl2", "nl-h2-nl2", "nl-tuic-nl2",
		"de-via-msk", "nl-via-msk",
	}
	for _, tag := range want {
		if !slices.Contains(got, tag) {
			t.Errorf("availableLeafTags missing %q; got %v", tag, got)
		}
	}
	// Whitelist-bypass must be filtered out.
	if slices.Contains(got, "ru-direct-relay-de") || slices.Contains(got, "-direct-relay-de") {
		t.Errorf("availableLeafTags must skip whitelist_bypass servers; got %v", got)
	}
}

// TestAvailableLeafTags_SkipsServersWithoutCountry asserts defensive handling:
// a server row missing CountryCode would crash the tag template if we didn't
// skip it. Matches the same guard in clientconfig.go.
func TestAvailableLeafTags_SkipsServersWithoutCountry(t *testing.T) {
	servers := []vpn.ServerEntry{
		{Key: "de", CountryCode: "DE", Role: "exit"},
		{Key: "unknown", CountryCode: "", Role: "exit"}, // skipped
	}
	got := availableLeafTags(servers, nil)
	if slices.Contains(got, "-direct-unknown") {
		t.Errorf("availableLeafTags emitted leaf for country-less server: %v", got)
	}
	if !slices.Contains(got, "de-direct-de") {
		t.Errorf("availableLeafTags missing de-direct-de: %v", got)
	}
}
