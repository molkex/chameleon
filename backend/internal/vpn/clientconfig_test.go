package vpn

import (
	"encoding/json"
	"slices"
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

// parseGenerated renders the fixture through generateClientConfig and
// returns the parsed JSON. Test helpers below query this shape.
func parseGenerated(t *testing.T) map[string]any {
	t.Helper()
	engine, user, servers, chains := fixture()
	raw, err := generateClientConfig(engine, user, servers, chains)
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

// TestProxySelectorContainsAllLeaves verifies the 2026-04-25 architectural
// fix: the top-level "Proxy" selector lists every leaf outbound as a
// direct child, not just Auto + country urltests. Without this, the iOS
// app's Clash-API `selectOutbound("Proxy", "de-tuic-de")` fails with
// "outbound is not a selector" on the country-group step and falls
// through to a 2-step chain that can't pin the specific leaf.
func TestProxySelectorContainsAllLeaves(t *testing.T) {
	cfg := parseGenerated(t)
	members := outboundMembers(cfg, "Proxy")
	if len(members) == 0 {
		t.Fatal("Proxy selector has no members")
	}

	// Category roots.
	for _, tag := range []string{"Auto", "🇩🇪 Германия", "🇳🇱 Нидерланды"} {
		if !slices.Contains(members, tag) {
			t.Errorf("Proxy missing required category root %q; got %v", tag, members)
		}
	}

	// Standard leaves — every protocol × country combination.
	expectedLeaves := []string{
		"de-direct-de", "de-h2-de", "de-tuic-de", "de-via-msk",
		"nl-direct-nl2", "nl-h2-nl2", "nl-tuic-nl2", "nl-via-msk",
	}
	for _, leaf := range expectedLeaves {
		if !slices.Contains(members, leaf) {
			t.Errorf("Proxy missing standard leaf %q; got %v", leaf, members)
		}
	}

	// Whitelist-bypass leaves also exposed directly for manual pinning.
	for _, leaf := range []string{"ru-spb-de", "ru-spb-nl"} {
		if !slices.Contains(members, leaf) {
			t.Errorf("Proxy missing whitelist-bypass leaf %q; got %v", leaf, members)
		}
	}
}

// TestCountryGroupsContainOnlyOwnCountryLegs guards against cross-country
// contamination — the bug the "pick Germany get NL IP" symptom would have
// indicated if it had been a backend issue (it wasn't; it was iOS-side).
// The urltest for 🇩🇪 Германия must not include any nl-* leg and vice versa.
func TestCountryGroupsContainOnlyOwnCountryLegs(t *testing.T) {
	cfg := parseGenerated(t)

	deLegs := outboundMembers(cfg, "🇩🇪 Германия")
	for _, l := range deLegs {
		if !startsWith(l, "de-") {
			t.Errorf("🇩🇪 Германия urltest contains non-DE leg %q", l)
		}
	}

	nlLegs := outboundMembers(cfg, "🇳🇱 Нидерланды")
	for _, l := range nlLegs {
		if !startsWith(l, "nl-") {
			t.Errorf("🇳🇱 Нидерланды urltest contains non-NL leg %q", l)
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

// TestAutoExcludesWhitelistBypass — Auto urltest must never include
// ru-spb-* legs: they intentionally exit from a country different from
// what the user picked in the main country list, and letting Auto
// RTT-select one would silently override the user's primary choice.
func TestAutoExcludesWhitelistBypass(t *testing.T) {
	cfg := parseGenerated(t)
	auto := outboundMembers(cfg, "Auto")
	for _, l := range auto {
		if startsWith(l, "ru-spb-") {
			t.Errorf("Auto urltest leaked whitelist-bypass leg %q", l)
		}
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
	raw, err := generateClientConfig(engine, user, servers, chains)
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

func startsWith(s, prefix string) bool {
	if len(s) < len(prefix) {
		return false
	}
	return s[:len(prefix)] == prefix
}
