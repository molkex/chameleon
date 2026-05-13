package vpn

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"
)

// fixture assembles a minimal but realistic EngineConfig + user + server set
// for exercising generateClientConfig. Mirrors the 2026-04-25 production shape
// (DE as standard exit with h2/tuic, NL as same, SPB relays as whitelist_bypass,
// MSK as relay that produces de-via-msk + nl-via-msk chains).
func fixture() (EngineConfig, VPNUser, []ServerEntry, []ChainedEntry) {
	engine := EngineConfig{
		ListenPort: 443,
		Reality: RealityConfig{
			PrivateKey: "mMQQZciNtcjfln0jBddIclm_HM8M3C8KALzHPfR0WVQ",
			PublicKey:  "ug2jX3uFFdLXih4t0O-PTRElQpAkO6v74RiRVJVvpzE",
			ShortIDs:   []string{""},
			SNI:        "ads.adfox.ru",
		},
		UrltestInterval: "3m",
	}
	user := VPNUser{
		Username: "device_testuser",
		UUID:     "68ba1e44-74ab-425b-b12d-1cfae8348325",
	}
	servers := []ServerEntry{
		{
			Key:              "de",
			Name:             "Germany",
			Host:             "162.19.242.30",
			Port:             443,
			Hysteria2Port:    443,
			TUICPort:         8443,
			RealityPublicKey: "ug2jX3uFFdLXih4t0O-PTRElQpAkO6v74RiRVJVvpzE",
			Role:             "exit",
			CountryCode:      "DE",
			Category:         "standard",
		},
		{
			Key:              "nl2",
			Name:             "Netherlands",
			Host:             "147.45.252.234",
			Port:             443,
			Hysteria2Port:    443,
			TUICPort:         8443,
			RealityPublicKey: "99tZNtOBXlY4XhbHrmdXuXmZ7DBzRV0m5GKVlXaNOR8",
			Role:             "exit",
			CountryCode:      "NL",
			Category:         "standard",
		},
		{
			Key:              "relay-de",
			Name:             "SPB-DE",
			Host:             "185.218.0.43",
			Port:             443,
			RealityPublicKey: "ug2jX3uFFdLXih4t0O-PTRElQpAkO6v74RiRVJVvpzE",
			Role:             "exit",
			Category:         "whitelist_bypass",
		},
		{
			Key:              "relay-nl",
			Name:             "SPB-NL",
			Host:             "185.218.0.43",
			Port:             2098,
			RealityPublicKey: "99tZNtOBXlY4XhbHrmdXuXmZ7DBzRV0m5GKVlXaNOR8",
			Role:             "exit",
			Category:         "whitelist_bypass",
		},
	}
	chains := []ChainedEntry{
		{
			RelayKey:        "msk",
			RelayHost:       "217.198.5.52",
			RelayListenPort: 2096,
			RelayRealityPub: "OJSR6FJytgohcFEUU4YD_IBdc3X83SUuez0n5tskTUs",
			RelaySNI:        "music.yandex.ru",
			ExitKey:         "de",
			ExitCountryCode: "DE",
		},
		{
			RelayKey:        "msk",
			RelayHost:       "217.198.5.52",
			RelayListenPort: 2097,
			RelayRealityPub: "OJSR6FJytgohcFEUU4YD_IBdc3X83SUuez0n5tskTUs",
			RelaySNI:        "music.yandex.ru",
			ExitKey:         "nl2",
			ExitCountryCode: "NL",
		},
	}
	return engine, user, servers, chains
}

// parseGenerated renders the fixture through generateClientConfig with default
// (empty) opts and returns the parsed JSON. Test helpers below query this shape.
func parseGenerated(t *testing.T) map[string]any {
	t.Helper()
	return parseGeneratedWithOpts(t, ClientConfigOpts{})
}

// parseGeneratedWithOpts renders the fixture with explicit ClientConfigOpts —
// used by tests that exercise per-request hints (RecommendedFirst, etc.).
func parseGeneratedWithOpts(t *testing.T, opts ClientConfigOpts) map[string]any {
	t.Helper()
	engine, user, servers, chains := fixture()
	raw, err := generateClientConfig(engine, user, servers, chains, opts)
	if err != nil {
		t.Fatalf("generateClientConfig: %v", err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return out
}

// outboundByTag returns the outbound dict for a given tag, or nil if absent.
func outboundByTag(cfg map[string]any, tag string) map[string]any {
	obs, _ := cfg["outbounds"].([]any)
	for _, o := range obs {
		m, ok := o.(map[string]any)
		if !ok {
			continue
		}
		if m["tag"] == tag {
			return m
		}
	}
	return nil
}

// outboundMembers returns the "outbounds" list of a group by tag.
func outboundMembers(cfg map[string]any, tag string) []string {
	g := outboundByTag(cfg, tag)
	if g == nil {
		return nil
	}
	raw, _ := g["outbounds"].([]any)
	var out []string
	for _, m := range raw {
		if s, ok := m.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

// TestProxySelectorContainsAutoAndCountryGroups verifies the Proxy selector
// (build 39+ return-to-urltest): top-level user choice has Auto, per-country
// urltest groups, and every leaf as a direct member. sing-box's `urltest`
// outbound runs end-to-end HTTP HEAD probes through each leaf and pins to
// the lowest-latency working one — it correctly identifies broken paths
// (e.g., RKN-blocked direct on RU LTE: TCP handshake succeeds but Reality
// data dies after) which a TCP-only probe in the iOS host process cannot.
func TestProxySelectorContainsAutoAndCountryGroups(t *testing.T) {
	cfg := parseGenerated(t)
	members := outboundMembers(cfg, "Proxy")
	if len(members) == 0 {
		t.Fatal("Proxy selector has no members")
	}

	// Must contain Auto urltest at index 0 (so the cold-start tunnel without
	// a UI selection lands on it via Proxy.default).
	if len(members) == 0 || members[0] != "Auto" {
		t.Errorf("Proxy first member must be \"Auto\"; got %v", members)
	}

	// Country urltest groups must be members so the user can pick a country.
	for _, group := range []string{"🇩🇪 Германия", "🇳🇱 Нидерланды"} {
		if !slices.Contains(members, group) {
			t.Errorf("Proxy missing country urltest group %q; got %v", group, members)
		}
	}

	// Standard leaves — every protocol × country combination — also listed
	// so power-mode pins (specific leaf override via Clash API) work.
	expectedLeaves := []string{
		"de-direct-de", "de-h2-de", "de-tuic-de", "de-via-msk",
		"nl-direct-nl2", "nl-h2-nl2", "nl-tuic-nl2", "nl-via-msk",
	}
	for _, leaf := range expectedLeaves {
		if !slices.Contains(members, leaf) {
			t.Errorf("Proxy missing standard leaf %q; got %v", leaf, members)
		}
	}

	// Whitelist-bypass group tag present (for manual override).
	if !slices.Contains(members, "🇷🇺 Россия (обход белых списков)") {
		t.Errorf("Proxy missing whitelist-bypass group tag; got %v", members)
	}

	// Whitelist-bypass leaves also exposed directly for manual pinning.
	for _, leaf := range []string{"ru-spb-de", "ru-spb-nl"} {
		if !slices.Contains(members, leaf) {
			t.Errorf("Proxy missing whitelist-bypass leaf %q; got %v", leaf, members)
		}
	}
}

// TestUrltestGroupsHaveProbeURL asserts that Auto and per-country urltest
// groups have probe URL + interval set. Without these sing-box won't probe
// at all and the group degrades to "always pick the first member" — losing
// the auto-failover behaviour we rely on for RU-LTE-blocked paths.
func TestUrltestGroupsHaveProbeURL(t *testing.T) {
	cfg := parseGenerated(t)
	for _, tag := range []string{"Auto", "🇩🇪 Германия", "🇳🇱 Нидерланды"} {
		g := outboundByTag(cfg, tag)
		if g == nil {
			t.Errorf("urltest group %q not emitted", tag)
			continue
		}
		if g["type"] != "urltest" {
			t.Errorf("group %q type=%v, want urltest", tag, g["type"])
		}
		if u, _ := g["url"].(string); u == "" {
			t.Errorf("group %q has empty probe URL", tag)
		}
		if iv, _ := g["interval"].(string); iv == "" {
			t.Errorf("group %q has empty interval", tag)
		}
	}
}

// TestUrltestGroupsRecoverFast asserts the build-39+40 fast-recovery values:
// interval=10s, tolerance=0, AND interrupt_exist_connections=true on the
// LEAF-level urltest groups (Auto + per-country inner _<cc>_leaves).
//
// interval/tolerance: old defaults (5m / 50ms) left users on a dead leaf for
// up to 5 minutes when RKN started throttling DE direct post-handshake on RU
// LTE — sing-box invalidates leaf history on dial error, but the tiny gstatic
// 204 probe re-stamps "OK" histories within seconds, masking the stall.
// Aggressive 10s reprobe + zero tolerance ensures any latency degradation
// triggers an immediate reselect.
//
// interrupt_exist_connections (build 40 fix, 2026-04-26): without this flag,
// when urltest re-elects to a healthy leaf the existing TCP sockets stay
// glued to the old (dead) outbound and time out at the OS TCP layer (75s+).
// User-visible: pages stuck for 1m+, "open new tab" required to recover.
// Field log 2026-04-26 confirmed 1m23s/1m24s/1m41s stuck connections to
// dead 162.19.242.30 after urltest had already switched to de-via-msk.
//
// Build-41 split: outer country groups (🇩🇪 Германия / 🇳🇱 Нидерланды) now
// use different parameters (interval=15s, tolerance=65000) — see
// TestCountryGroupsHaveCrossCountryFallback. The leaf-level fast-recovery
// rules tested here apply to Auto and the inner _<cc>_leaves groups.
func TestUrltestGroupsRecoverFast(t *testing.T) {
	cfg := parseGenerated(t)
	for _, tag := range []string{"Auto", "_de_leaves", "_nl_leaves"} {
		g := outboundByTag(cfg, tag)
		if g == nil {
			t.Errorf("urltest group %q not emitted", tag)
			continue
		}
		if iv, _ := g["interval"].(string); iv != "10s" {
			t.Errorf("group %q interval=%q, want %q", tag, iv, "10s")
		}
		// Build-56: tolerance was 0 (pseudo-load-balance, see TestRecommendedFirst*
		// for cold-start hint context), now 150ms. tolerance=0 caused thrashing
		// between near-equal leaves and made the RecommendedFirst hint useless
		// after first probe — urltest would reselect on every 5ms RTT drift,
		// frequently landing back on DPI-blocked DE on RU networks.
		tol, ok := g["tolerance"]
		if !ok {
			t.Errorf("group %q missing tolerance — must be 150ms (build 56)", tag)
			continue
		}
		if n, _ := tol.(float64); n != 150 {
			t.Errorf("group %q tolerance=%v, want 150 (build 56)", tag, n)
		}
		// Build-40: interrupt_exist_connections MUST be true on urltest
		// groups, else stuck TCP sockets through dead outbound persist 75s+.
		iec, ok := g["interrupt_exist_connections"]
		if !ok {
			t.Errorf("group %q missing interrupt_exist_connections — must be true (build 40)", tag)
			continue
		}
		b, _ := iec.(bool)
		if !b {
			t.Errorf("group %q interrupt_exist_connections=%v, want true (build 40)", tag, b)
		}
	}
}

// TestCountryGroupsHaveCrossCountryFallback asserts the build-41 nested-urltest
// architecture: the user-visible country group "🇩🇪 Германия" is itself a
// urltest whose members are the per-country inner urltests, with own-country
// first and other countries listed as fallback. The outer tolerance is high
// (65000) so the urltest sticks to the user's chosen country and only
// switches when that country's inner group returns "no member available" —
// e.g. RU LTE + OVH ASN block where all 4 DE leaves time out simultaneously
// (field log 2026-04-26 23:58 confirmed 4/4 DE leaves dead, only de-via-msk
// crawling at 4500ms probe). With tolerance=65000, switching to the NL
// inner is triggered ONLY by full-DE-failure, never by latency drift.
func TestCountryGroupsHaveCrossCountryFallback(t *testing.T) {
	cfg := parseGenerated(t)

	// Inner per-country urltest groups must exist with `_<cc>_leaves` tag
	// (the leading underscore lets iOS UI filter them from the picker).
	for _, innerTag := range []string{"_de_leaves", "_nl_leaves"} {
		g := outboundByTag(cfg, innerTag)
		if g == nil {
			t.Errorf("inner urltest %q not emitted", innerTag)
			continue
		}
		if g["type"] != "urltest" {
			t.Errorf("inner %q type=%v, want urltest", innerTag, g["type"])
		}
	}

	// Outer "🇩🇪 Германия": members must be [_de_leaves, _nl_leaves] in that
	// order — own country first, others as fallback in alpha order.
	deOuter := outboundByTag(cfg, "🇩🇪 Германия")
	if deOuter == nil {
		t.Fatal("outer country group 🇩🇪 Германия not emitted")
	}
	if deOuter["type"] != "urltest" {
		t.Errorf("🇩🇪 Германия type=%v, want urltest", deOuter["type"])
	}
	deMembers := outboundMembers(cfg, "🇩🇪 Германия")
	wantDE := []string{"_de_leaves", "_nl_leaves"}
	if !slices.Equal(deMembers, wantDE) {
		t.Errorf("🇩🇪 Германия members=%v, want %v (own country first, others as fallback)", deMembers, wantDE)
	}
	if iv, _ := deOuter["interval"].(string); iv != "15s" {
		t.Errorf("🇩🇪 Германия interval=%q, want 15s (build-41 outer)", iv)
	}
	if tol, _ := deOuter["tolerance"].(float64); tol != 65000 {
		t.Errorf("🇩🇪 Германия tolerance=%v, want 65000 (sticky country pin)", tol)
	}
	if iec, _ := deOuter["interrupt_exist_connections"].(bool); !iec {
		t.Errorf("🇩🇪 Германия missing interrupt_exist_connections=true (build 40 chain rule)")
	}

	// Outer "🇳🇱 Нидерланды": members must be [_nl_leaves, _de_leaves] —
	// NL first because it's own country.
	nlOuter := outboundByTag(cfg, "🇳🇱 Нидерланды")
	if nlOuter == nil {
		t.Fatal("outer country group 🇳🇱 Нидерланды not emitted")
	}
	nlMembers := outboundMembers(cfg, "🇳🇱 Нидерланды")
	wantNL := []string{"_nl_leaves", "_de_leaves"}
	if !slices.Equal(nlMembers, wantNL) {
		t.Errorf("🇳🇱 Нидерланды members=%v, want %v (own country first, others as fallback)", nlMembers, wantNL)
	}
	if iv, _ := nlOuter["interval"].(string); iv != "15s" {
		t.Errorf("🇳🇱 Нидерланды interval=%q, want 15s (build-41 outer)", iv)
	}
	if tol, _ := nlOuter["tolerance"].(float64); tol != 65000 {
		t.Errorf("🇳🇱 Нидерланды tolerance=%v, want 65000 (sticky country pin)", tol)
	}
	if iec, _ := nlOuter["interrupt_exist_connections"].(bool); !iec {
		t.Errorf("🇳🇱 Нидерланды missing interrupt_exist_connections=true (build 40 chain rule)")
	}

	// Inner _de_leaves must contain all DE leaves (direct + via + h2 + tuic),
	// none from other countries. Same shape for _nl_leaves.
	deInner := outboundMembers(cfg, "_de_leaves")
	for _, want := range []string{"de-direct-de", "de-h2-de", "de-tuic-de", "de-via-msk"} {
		if !slices.Contains(deInner, want) {
			t.Errorf("_de_leaves missing %q; got %v", want, deInner)
		}
	}
	for _, leaf := range deInner {
		if !startsWith(leaf, "de-") {
			t.Errorf("_de_leaves contains non-DE leaf %q", leaf)
		}
	}
	nlInner := outboundMembers(cfg, "_nl_leaves")
	for _, want := range []string{"nl-direct-nl2", "nl-h2-nl2", "nl-tuic-nl2", "nl-via-msk"} {
		if !slices.Contains(nlInner, want) {
			t.Errorf("_nl_leaves missing %q; got %v", want, nlInner)
		}
	}
	for _, leaf := range nlInner {
		if !startsWith(leaf, "nl-") {
			t.Errorf("_nl_leaves contains non-NL leaf %q", leaf)
		}
	}
}

// TestWhitelistBypassGroupIsSelectorNotUrltest — the isolated group where
// SPB-via-DE and SPB-via-NL live MUST be a selector so the user's explicit
// pick between them is honoured. If this regresses to urltest, urltest's
// RTT probe would silently swap the two on every probe cycle, flipping
// the exit country behind the user's back.
func TestWhitelistBypassGroupIsSelectorNotUrltest(t *testing.T) {
	cfg := parseGenerated(t)
	g := outboundByTag(cfg, "🇷🇺 Россия (обход белых списков)")
	if g == nil {
		t.Fatal("whitelist-bypass group not emitted")
	}
	if g["type"] != "selector" {
		t.Errorf("whitelist-bypass must be selector, got %v", g["type"])
	}
	// Default must be set so a fresh tunnel has a deterministic leg.
	if g["default"] == nil || g["default"] == "" {
		t.Errorf("whitelist-bypass selector missing default")
	}
}

// TestProxySelectorDefault asserts Proxy.Default = "Auto" so a fresh
// tunnel without an explicit UI pick lands on the Auto urltest group, which
// in turn picks the lowest-latency working leaf via end-to-end HTTP HEAD
// probes.
//
// Also asserts Proxy.interrupt_exist_connections=true (build 40 evening fix):
// the urltest auto-recovery chain only works end-to-end when EVERY selector
// in the path TUN→Mode→Proxy→Auto→leaf has interrupt=true. Field log
// 2026-04-26 22:52 confirmed: with Proxy.interrupt=false the inbound from
// upstream Mode selector keeps the user connection alive, glued to the dead
// path even after Auto urltest already re-elected.
func TestProxySelectorDefault(t *testing.T) {
	cfg := parseGenerated(t)
	proxy := outboundByTag(cfg, "Proxy")
	if proxy == nil {
		t.Fatal("Proxy selector not found")
	}
	def, _ := proxy["default"].(string)
	if def != "Auto" {
		t.Errorf("Proxy.default = %q — must be \"Auto\" (build 39+ return-to-urltest)", def)
	}
	if outboundByTag(cfg, def) == nil {
		t.Errorf("Proxy.default = %q does not exist as an outbound", def)
	}
	// Build-40 evening: Proxy MUST also propagate interrupt-on-switch so the
	// urltest re-election kills user-facing connections through the dead leaf.
	iec, ok := proxy["interrupt_exist_connections"]
	if !ok {
		t.Errorf("Proxy missing interrupt_exist_connections — must be true (build 40 chain fix)")
	} else if b, _ := iec.(bool); !b {
		t.Errorf("Proxy.interrupt_exist_connections=%v, want true (build 40 chain fix)", b)
	}
}

// TestUserUUIDWiredIntoEveryLeaf — a regression here means some users get
// a config with a stale or mismatched UUID and all their probes REALITY-
// reject or VLESS-auth-reject on the server side.
func TestUserUUIDWiredIntoEveryLeaf(t *testing.T) {
	cfg := parseGenerated(t)
	_, user, _, _ := fixture()
	obs, _ := cfg["outbounds"].([]any)
	for _, o := range obs {
		m, ok := o.(map[string]any)
		if !ok {
			continue
		}
		tag, _ := m["tag"].(string)
		t_, _ := m["type"].(string)
		switch t_ {
		case "vless", "tuic":
			if m["uuid"] != user.UUID {
				t.Errorf("%s leaf %q has wrong uuid %v", t_, tag, m["uuid"])
			}
		case "hysteria2":
			if m["password"] != user.UUID {
				t.Errorf("hysteria2 leaf %q has wrong password %v", tag, m["password"])
			}
		}
	}
}

// TestHysteria2AndTUICOmittedWhenPortsZero — if a server row has no
// hysteria2_port / tuic_port set, the corresponding leaf must not appear
// in the client config. A stray leaf would send the client's first
// selectOutbound call at a dead port.
func TestHysteria2AndTUICOmittedWhenPortsZero(t *testing.T) {
	engine, user, servers, chains := fixture()
	// Disable h2/tuic on DE only.
	for i := range servers {
		if servers[i].Key == "de" {
			servers[i].Hysteria2Port = 0
			servers[i].TUICPort = 0
		}
	}
	raw, err := generateClientConfig(engine, user, servers, chains, ClientConfigOpts{})
	if err != nil {
		t.Fatalf("generateClientConfig: %v", err)
	}
	var cfg map[string]any
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatal(err)
	}
	if outboundByTag(cfg, "de-h2-de") != nil {
		t.Error("de-h2-de emitted despite Hysteria2Port=0")
	}
	if outboundByTag(cfg, "de-tuic-de") != nil {
		t.Error("de-tuic-de emitted despite TUICPort=0")
	}
	// NL still has them.
	if outboundByTag(cfg, "nl-h2-nl2") == nil {
		t.Error("nl-h2-nl2 missing — NL h2 shouldn't have been affected")
	}
}

// TestDisableQUICOutboundsEnvSuppressesH2AndTUIC — when
// CHAMELEON_DISABLE_QUIC_OUTBOUNDS=true is set, no hysteria2 / tuic leaves
// are emitted regardless of server-row port columns. This is the memory-
// saving flag for cellular-heavy nodes where QUIC outbounds reliably time
// out yet still occupy ~2-3 MiB each of Go heap.
func TestDisableQUICOutboundsEnvSuppressesH2AndTUIC(t *testing.T) {
	t.Setenv("CHAMELEON_DISABLE_QUIC_OUTBOUNDS", "true")
	cfg := parseGenerated(t)

	for _, tag := range []string{"de-h2-de", "de-tuic-de", "nl-h2-nl2", "nl-tuic-nl2"} {
		if outboundByTag(cfg, tag) != nil {
			t.Errorf("leaf %q emitted despite CHAMELEON_DISABLE_QUIC_OUTBOUNDS=true", tag)
		}
	}

	// VLESS leaves + relay chains must still be present — only QUIC is suppressed.
	for _, tag := range []string{"de-direct-de", "nl-direct-nl2", "de-via-msk", "nl-via-msk"} {
		if outboundByTag(cfg, tag) == nil {
			t.Errorf("non-QUIC leaf %q missing — flag should only affect h2/tuic", tag)
		}
	}

	// Auto urltest members must not contain any QUIC leaves either.
	members := outboundMembers(cfg, "Auto")
	for _, m := range members {
		if strings.Contains(m, "-h2-") || strings.Contains(m, "-tuic-") {
			t.Errorf("Auto urltest still references QUIC leaf %q after flag set", m)
		}
	}
}

// TestDisableQUICOutboundsEnvOffKeepsQUIC — sanity check: the flag is
// strictly opt-in. Without the env var (or with any value != "true") QUIC
// leaves are emitted as before. Guards against accidentally flipping
// default behaviour during refactors.
func TestDisableQUICOutboundsEnvOffKeepsQUIC(t *testing.T) {
	t.Setenv("CHAMELEON_DISABLE_QUIC_OUTBOUNDS", "")
	cfg := parseGenerated(t)

	for _, tag := range []string{"de-h2-de", "de-tuic-de", "nl-h2-nl2", "nl-tuic-nl2"} {
		if outboundByTag(cfg, tag) == nil {
			t.Errorf("QUIC leaf %q missing with flag unset — default behaviour regressed", tag)
		}
	}
}

// TestProxySelectorLeafOrder asserts that standard leaves appear in
// legSortKey order (direct before via before h2 before tuic) within the
// section of Proxy members that lists them as direct children. Auto and
// country group tags appear before the leaf section and are skipped.
func TestProxySelectorLeafOrder(t *testing.T) {
	cfg := parseGenerated(t)
	members := outboundMembers(cfg, "Proxy")
	// Collect only standard leaves: exclude Auto, country group tags
	// (🇩🇪/🇳🇱/🇷🇺-prefixed), and whitelist ru-spb-* leaves.
	var leaves []string
	for _, m := range members {
		if m == "Auto" || startsWith(m, "🇩🇪") || startsWith(m, "🇳🇱") || startsWith(m, "🇷🇺") {
			continue
		}
		if startsWith(m, "ru-spb-") {
			continue
		}
		leaves = append(leaves, m)
	}
	for i := 1; i < len(leaves); i++ {
		if legSortKey(leaves[i]) < legSortKey(leaves[i-1]) {
			t.Errorf("Proxy leaves out of legSortKey order at index %d: %q before %q", i, leaves[i-1], leaves[i])
		}
	}
}

func startsWith(s, prefix string) bool {
	if len(s) < len(prefix) {
		return false
	}
	return s[:len(prefix)] == prefix
}

// TestRecommendedFirstReordersAutoLeaves asserts that when ClientConfigOpts.
// RecommendedFirst is set to a known leaf tag, that leaf appears first in the
// Auto urltest group. urltest with tolerance=0 picks the lowest-RTT outbound,
// but on a tie (and on the very first probe before any history) it sticks to
// the first member in the list — so ordering directly controls cold-start
// outbound preference. The hint is a per-request signal from the backend's
// geo logic: e.g. RU users tend to get blocked on DE OVH, so we steer them
// to NL Timeweb on connect. Without the hint, the urltest probes all leaves
// equally and may pick a leaf the user's ISP/DPI breaks.
func TestRecommendedFirstReordersAutoLeaves(t *testing.T) {
	cfg := parseGeneratedWithOpts(t, ClientConfigOpts{RecommendedFirst: "nl-direct-nl2"})
	members := outboundMembers(cfg, "Auto")
	if len(members) == 0 {
		t.Fatal("Auto urltest has no members")
	}
	if members[0] != "nl-direct-nl2" {
		t.Errorf("Auto[0]=%q, want first member = RecommendedFirst leaf %q; full list: %v",
			members[0], "nl-direct-nl2", members)
	}
	// All other leaves must still be present (no leaf is dropped by the hint).
	for _, leaf := range []string{"de-direct-de", "de-h2-de", "de-tuic-de", "de-via-msk",
		"nl-direct-nl2", "nl-h2-nl2", "nl-tuic-nl2", "nl-via-msk"} {
		if !slices.Contains(members, leaf) {
			t.Errorf("Auto missing leaf %q after RecommendedFirst applied; got %v", leaf, members)
		}
	}
}

// TestRecommendedFirstReordersInnerCountryGroup asserts that the hint also
// influences the per-country inner urltest (_<cc>_leaves) when the hinted
// leaf belongs to that country. A user who picks "🇳🇱 Нидерланды" manually
// still benefits from cold-start preference — the inner urltest tries the
// hinted nl-* leaf first. This matches the Auto behaviour symmetrically and
// avoids the bug where Auto goes through nl-direct but country-picker goes
// through nl-h2 first because the hint was forgotten.
func TestRecommendedFirstReordersInnerCountryGroup(t *testing.T) {
	cfg := parseGeneratedWithOpts(t, ClientConfigOpts{RecommendedFirst: "nl-direct-nl2"})
	nlInner := outboundMembers(cfg, "_nl_leaves")
	if len(nlInner) == 0 {
		t.Fatal("_nl_leaves urltest has no members")
	}
	if nlInner[0] != "nl-direct-nl2" {
		t.Errorf("_nl_leaves[0]=%q, want %q; full list: %v",
			nlInner[0], "nl-direct-nl2", nlInner)
	}
	// _de_leaves must NOT be polluted by an NL hint — it keeps its default order.
	deInner := outboundMembers(cfg, "_de_leaves")
	for _, leaf := range deInner {
		if !startsWith(leaf, "de-") {
			t.Errorf("_de_leaves contains non-DE leaf %q after NL hint; got %v", leaf, deInner)
		}
	}
}

// TestRecommendedFirstIgnoredIfUnknown asserts that a hint referring to a
// non-existent leaf is silently ignored — config still generates, and Auto
// falls back to legSortKey ordering. This guards against config corruption
// if the backend ships a hint for a leaf that's been removed/renamed.
func TestRecommendedFirstIgnoredIfUnknown(t *testing.T) {
	cfg := parseGeneratedWithOpts(t, ClientConfigOpts{RecommendedFirst: "ghost-leaf-does-not-exist"})
	members := outboundMembers(cfg, "Auto")
	if len(members) == 0 {
		t.Fatal("Auto urltest has no members with unknown hint")
	}
	// First leaf should match the default legSortKey ordering (-direct- leaves
	// sort first, see legSortKey). Either de-direct-de or nl-direct-nl2 — both
	// are -direct- and alpha-stable, de comes first alphabetically.
	if members[0] != "de-direct-de" {
		t.Errorf("Auto[0]=%q with unknown hint, want legSortKey default %q; full list: %v",
			members[0], "de-direct-de", members)
	}
}

// TestRecommendedFirstEmptyKeepsDefaultOrder asserts that empty opts preserve
// the pre-existing legSortKey ordering — back-compat guarantee for callers
// that don't yet plumb the hint.
func TestRecommendedFirstEmptyKeepsDefaultOrder(t *testing.T) {
	cfg := parseGeneratedWithOpts(t, ClientConfigOpts{})
	members := outboundMembers(cfg, "Auto")
	if len(members) == 0 {
		t.Fatal("Auto urltest has no members")
	}
	// Default order: legSortKey puts -direct- first, then alpha-stable by tag.
	if members[0] != "de-direct-de" {
		t.Errorf("Auto[0]=%q with empty opts, want legSortKey default %q; full list: %v",
			members[0], "de-direct-de", members)
	}
}
