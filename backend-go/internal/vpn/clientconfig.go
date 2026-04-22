package vpn

import (
	"encoding/json"
	"fmt"
)

// generateClientConfig creates a sing-box client config JSON for iOS/macOS.
//
// The generated config includes:
//   - TUN inbound with stack=system, MTU=1400
//   - FakeIP DNS + DoH via 1.1.1.1
//   - VLESS Reality TCP outbound for each server
//   - Selector "Proxy" + urltest "Auto"
//   - QUIC reject with no_drop: true
//   - interrupt_exist_connections: false in urltest and selector
//   - config_version timestamp for cache busting
func generateClientConfig(engineCfg EngineConfig, user VPNUser, servers []ServerEntry) ([]byte, error) {
	if len(servers) == 0 {
		return nil, fmt.Errorf("generate client config: no servers provided")
	}

	// Build outbounds: VLESS Reality per server + optional Hysteria2/TUIC per server.
	var serverOutbounds []clientOutbound
	var serverTags []string

	for _, srv := range servers {
		sni := srv.SNI
		if sni == "" {
			sni = engineCfg.Reality.SNI
		}
		if sni == "" {
			sni = "ads.adfox.ru"
		}

		// Per-server Reality public key; fallback to engine config (local node's key).
		publicKey := srv.RealityPublicKey
		if publicKey == "" {
			publicKey = engineCfg.Reality.PublicKey
		}

		shortID := user.ShortID
		if shortID == "" && len(engineCfg.Reality.ShortIDs) > 0 {
			shortID = engineCfg.Reality.ShortIDs[0]
		}

		tag := fmt.Sprintf("VLESS %s %s", srv.Flag, srv.Name)
		outbound := clientOutbound{
			Type:       "vless",
			Tag:        tag,
			Server:     srv.Host,
			ServerPort: srv.Port,
			UUID:       user.UUID,
			Flow:       "xtls-rprx-vision",
			TLS: &clientTLS{
				Enabled:    true,
				ServerName: sni,
				UTLS: &clientUTLS{
					Enabled:     true,
					Fingerprint: "chrome",
				},
				Reality: &clientReality{
					Enabled:   true,
					PublicKey: publicKey,
					ShortID:   shortID,
				},
			},
			PacketEncoding: "xudp",
		}
		serverOutbounds = append(serverOutbounds, outbound)
		serverTags = append(serverTags, tag)

		// Hysteria2 outbound (UDP) — only when server advertises a Hysteria2 port.
		if srv.Hysteria2Port > 0 {
			h2tag := fmt.Sprintf("H2 %s %s", srv.Flag, srv.Name)
			serverOutbounds = append(serverOutbounds, clientOutbound{
				Type:     "hysteria2",
				Tag:      h2tag,
				Server:   srv.Host,
				ServerPort: srv.Hysteria2Port,
				Password: user.UUID,
				TLS: &clientTLS{
					Enabled:    true,
					ServerName: sni,
					Insecure:   boolPtr(true),
				},
			})
			serverTags = append(serverTags, h2tag)
		}

		// TUIC v5 outbound (UDP) — only when server advertises a TUIC port.
		if srv.TUICPort > 0 {
			tuicTag := fmt.Sprintf("TUIC %s %s", srv.Flag, srv.Name)
			serverOutbounds = append(serverOutbounds, clientOutbound{
				Type:               "tuic",
				Tag:                tuicTag,
				Server:             srv.Host,
				ServerPort:         srv.TUICPort,
				UUID:               user.UUID,
				Password:           user.UUID,
				CongestionControl:  "bbr",
				TLS: &clientTLS{
					Enabled:    true,
					ServerName: sni,
					Insecure:   boolPtr(true),
				},
			})
			serverTags = append(serverTags, tuicTag)
		}
	}

	// urltest "Auto" — automatically selects best server.
	urltestInterval := engineCfg.UrltestInterval
	if urltestInterval == "" {
		urltestInterval = "3m"
	}

	autoOutbound := clientOutbound{
		Type:       "urltest",
		Tag:        "Auto",
		Outbounds:  serverTags,
		URL:        "https://cp.cloudflare.com",
		Interval:   urltestInterval,
		Tolerance:  100,
		InterruptExistConnections: boolPtr(false),
	}

	// selector "Proxy" — allows manual server selection.
	proxyOutbound := clientOutbound{
		Type:      "selector",
		Tag:       "Proxy",
		Outbounds: append([]string{"Auto"}, serverTags...),
		Default:   "Auto",
		InterruptExistConnections: boolPtr(false),
	}

	// Three-way routing mode is implemented via three selectors. The iOS app
	// flips all three together via Clash API to switch modes without
	// reconnecting. See ExtensionProvider.applyRoutingMode().
	//
	//   Mode       | RU Traffic | Blocked Traffic | Default Route
	//   smart      | direct     | Proxy           | direct         ← default
	//   ru-direct  | direct     | Proxy           | Proxy
	//   full-vpn   | Proxy      | Proxy           | Proxy
	//
	// In "smart" mode only RKN-blocked resources go through the tunnel —
	// everything else stays on the native connection, minimising both the
	// VPN-detection signal and bandwidth usage.
	// InterruptExistConnections: true on the three mode selectors.
	// When the user flips Smart↔RU Direct↔Full VPN, sing-box by default
	// only routes *new* connections through the new outbound; existing
	// sockets (e.g. a Safari keep-alive to whoer.net) stay on the old path
	// and the user thinks the switch didn't work. Interrupting forces
	// in-flight connections to re-establish via the new selector target.
	ruTrafficOutbound := clientOutbound{
		Type:                      "selector",
		Tag:                       "RU Traffic",
		Outbounds:                 []string{"direct", "Proxy"},
		Default:                   "direct",
		InterruptExistConnections: boolPtr(true),
	}
	blockedTrafficOutbound := clientOutbound{
		Type:                      "selector",
		Tag:                       "Blocked Traffic",
		Outbounds:                 []string{"Proxy", "direct"},
		Default:                   "Proxy",
		InterruptExistConnections: boolPtr(true),
	}
	defaultRouteOutbound := clientOutbound{
		Type:                      "selector",
		Tag:                       "Default Route",
		Outbounds:                 []string{"direct", "Proxy"},
		Default:                   "direct",
		InterruptExistConnections: boolPtr(true),
	}

	// System outbounds.
	directOutbound := clientOutbound{
		Type: "direct",
		Tag:  "direct",
	}
	blockOutbound := clientOutbound{
		Type: "block",
		Tag:  "block",
	}
	// Assemble all outbounds in correct order.
	// Note: dns outbound removed in sing-box 1.13 — use route action hijack-dns instead.
	// Routing selectors must be defined AFTER "Proxy" since they reference it.
	allOutbounds := []clientOutbound{
		proxyOutbound,
		autoOutbound,
		ruTrafficOutbound,
		blockedTrafficOutbound,
		defaultRouteOutbound,
	}
	allOutbounds = append(allOutbounds, serverOutbounds...)
	allOutbounds = append(allOutbounds, directOutbound, blockOutbound)

	// Resolve configurable values with defaults.
	clientMTU := engineCfg.ClientMTU
	if clientMTU == 0 {
		clientMTU = 1400
	}

	dnsRemote := engineCfg.DNSRemote
	if dnsRemote == "" {
		dnsRemote = "https://1.1.1.1/dns-query"
	}

	dnsDirect := engineCfg.DNSDirect
	if dnsDirect == "" {
		// Yandex DNS — resolves .ru zones faster and more reliably than Google.
		dnsDirect = "https://77.88.8.8/dns-query"
	}

	config := clientConfig{
		Log: clientLog{
			Level: "info",
		},
		DNS: clientDNSConfig{
			Servers: []clientDNSServer{
				{
					Tag:    "dns-remote",
					Type:   "https",
					Server: "1.1.1.1",
				},
				{
					// Yandex DNS — faster/cleaner resolution for .ru zones than Google.
					Tag:    "dns-direct",
					Type:   "https",
					Server: "77.88.8.8",
				},
				{
					Tag:        "dns-fakeip",
					Type:       "fakeip",
					Inet4Range: "198.18.0.0/15",
				},
			},
			Rules: []clientDNSRule{
				// Always-direct curated list (banks, gov, Yandex, VK, markets).
				// Resolved locally via Yandex DNS so bank CDNs return the
				// correct regional IP.
				{
					DomainSuffix: ruAlwaysDirectDomains,
					Server:       "dns-direct",
				},
				// .ru zones resolve via Yandex DNS locally — keeps RU DNS answers
				// accurate (CDN-aware) and saves a proxy round-trip.
				{
					DomainSuffix: []string{".ru"},
					Server:       "dns-direct",
				},
			},
			IndependentCache: true,
		},
		Inbounds: []clientInbound{
			{
				Type:      "tun",
				Tag:       "tun-in",
				Address:   []string{"172.19.0.1/30"},
				MTU:       clientMTU,
				AutoRoute: true,
				Stack:     "system",
			},
		},
		Outbounds: allOutbounds,
		Route: clientRoute{
			Final: "Default Route",
			RuleSet: []clientRuleSet{
				// Remote geoip-ru rule-set — downloaded through the proxy on first
				// connect and cached. Used for RU split tunneling.
				{
					Tag:            "geoip-ru",
					Type:           "remote",
					Format:         "binary",
					URL:            "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs",
					DownloadDetour: "direct",
					UpdateInterval: "168h",
				},
				// RKN-blocked domains — comprehensive list maintained by teidesu.
				// Used in "smart" mode to route only blocked resources (YouTube,
				// Instagram, Twitter, Facebook, LinkedIn, etc.) through the VPN.
				// Direct raw URL (bypasses github.com → raw redirect).
				{
					Tag:            "refilter",
					Type:           "remote",
					Format:         "binary",
					URL:            "https://raw.githubusercontent.com/teidesu/rkn-singbox/ruleset/rkn-ruleset.srs",
					DownloadDetour: "direct",
					UpdateInterval: "168h",
				},
			},
			Rules: []clientRouteRule{
				// 1. Sniff MUST be first — enables protocol detection for hijack-dns.
				//    In sing-box 1.13 sniff was removed from inbound and became a route action.
				{
					Action: "sniff",
				},
				// 2. Hijack DNS — intercepts DNS queries, routes to DNS module.
				{
					Protocol: "dns",
					Action:   "hijack-dns",
				},
				// 3. Clash Direct mode → bypass proxy.
				{
					ClashMode: "Direct",
					Outbound:  "direct",
				},
				// 4. Block QUIC (UDP 443) — iOS prefers QUIC which hangs through TCP relay.
				{
					Network: "udp",
					Port:    443,
					Action:  "reject",
					NoDrop:  boolPtr(true),
				},
				// 5. Private IPs → direct (no proxy for LAN traffic).
				{
					IPIsPrivate: boolPtr(true),
					Outbound:    "direct",
				},
				// 6. Always-direct domains → direct. Banks / gov / Yandex / VK /
				//    marketplaces MUST bypass the tunnel regardless of the
				//    user's selector state. This rule sits BEFORE the blocked
				//    and geoip rules so selectors can never override it.
				{
					DomainSuffix: ruAlwaysDirectDomains,
					Outbound:     "direct",
				},
				// 7. RKN-blocked resources (refilter list) → "Blocked Traffic"
				//    selector. In "smart" and "ru-direct" modes this = Proxy;
				//    "full-vpn" inherits via "Default Route".
				//    BEFORE the .ru and geoip-ru rules because a blocked
				//    domain might be a .ru zone or resolve to a RU IP (CDN).
				{
					RuleSet:  "refilter",
					Outbound: "Blocked Traffic",
				},
				// 8. Any *.ru domain → "RU Traffic" selector.
				//    Intentionally domain-based, not IP-based: many .ru sites
				//    sit behind CloudFlare/anycast CDNs whose IPs don't show
				//    up in geoip-ru, so they'd otherwise fall through to the
				//    default route. "РФ напрямую" only makes sense if any
				//    .ru zone is treated as Russian regardless of hosting.
				{
					DomainSuffix: []string{".ru"},
					Outbound:     "RU Traffic",
				},
				// 9. RU geoip → "RU Traffic" selector.
				//    Catches non-.ru domains served from Russian IPs
				//    (.com sites, Yandex CDNs, etc.).
				{
					RuleSet:  "geoip-ru",
					Outbound: "RU Traffic",
				},
			},
			DefaultDomainResolver: &clientDomainResolver{
				Server:   "dns-direct",
				Strategy: "ipv4_only",
			},
		},
	}

	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("generate client config: marshal: %w", err)
	}

	return data, nil
}

func boolPtr(v bool) *bool { return &v }

// ---------------------------------------------------------------------------
// Client config JSON structures
// ---------------------------------------------------------------------------

type clientConfig struct {
	Log           clientLog           `json:"log"`
	DNS           clientDNSConfig     `json:"dns"`
	Inbounds      []clientInbound     `json:"inbounds"`
	Outbounds     []clientOutbound    `json:"outbounds"`
	Route         clientRoute         `json:"route"`
	Experimental  *clientExperimental `json:"experimental,omitempty"`
	ConfigVersion int64               `json:"config_version,omitempty"`
}

type clientLog struct {
	Level string `json:"level"`
}

type clientDNSConfig struct {
	Servers          []clientDNSServer `json:"servers"`
	Rules            []clientDNSRule   `json:"rules,omitempty"`
	FakeIP           *clientFakeIP     `json:"fakeip,omitempty"`
	IndependentCache bool              `json:"independent_cache,omitempty"`
}

type clientDNSServer struct {
	Tag             string `json:"tag"`
	Type            string `json:"type"`
	Server          string `json:"server,omitempty"`
	ServerName      string `json:"server_name,omitempty"`
	AddressResolver string `json:"address_resolver,omitempty"`
	Strategy        string `json:"strategy,omitempty"`
	Detour          string `json:"detour,omitempty"`
	Inet4Range      string `json:"inet4_range,omitempty"`
}

type clientDNSRule struct {
	ClashMode    string   `json:"clash_mode,omitempty"`
	QueryType    []string `json:"query_type,omitempty"`
	Outbound     []string `json:"outbound,omitempty"`
	DomainSuffix []string `json:"domain_suffix,omitempty"`
	RuleSet      string   `json:"rule_set,omitempty"`
	Server       string   `json:"server"`
}

type clientFakeIP struct {
	Enabled    bool   `json:"enabled"`
	Inet4Range string `json:"inet4_range"`
}

type clientInbound struct {
	Type      string   `json:"type"`
	Tag       string   `json:"tag"`
	Address   []string `json:"address,omitempty"`
	MTU       int      `json:"mtu,omitempty"`
	AutoRoute bool     `json:"auto_route,omitempty"`
	Stack     string   `json:"stack,omitempty"`
}

type clientOutbound struct {
	Type                      string           `json:"type"`
	Tag                       string           `json:"tag"`
	Server                    string           `json:"server,omitempty"`
	ServerPort                int              `json:"server_port,omitempty"`
	UUID                      string           `json:"uuid,omitempty"`
	Password                  string           `json:"password,omitempty"`
	Flow                      string           `json:"flow,omitempty"`
	TLS                       *clientTLS       `json:"tls,omitempty"`
	Multiplex                 *clientMultiplex `json:"multiplex,omitempty"`
	PacketEncoding            string           `json:"packet_encoding,omitempty"`
	CongestionControl         string           `json:"congestion_control,omitempty"`
	Outbounds                 []string         `json:"outbounds,omitempty"`
	URL                       string           `json:"url,omitempty"`
	Interval                  string           `json:"interval,omitempty"`
	Tolerance                 int              `json:"tolerance,omitempty"`
	Default                   string           `json:"default,omitempty"`
	InterruptExistConnections *bool            `json:"interrupt_exist_connections,omitempty"`
}

type clientTLS struct {
	Enabled    bool           `json:"enabled"`
	ServerName string         `json:"server_name"`
	Insecure   *bool          `json:"insecure,omitempty"`
	UTLS       *clientUTLS    `json:"utls,omitempty"`
	Reality    *clientReality `json:"reality,omitempty"`
}

type clientUTLS struct {
	Enabled     bool   `json:"enabled"`
	Fingerprint string `json:"fingerprint"`
}

type clientReality struct {
	Enabled   bool   `json:"enabled"`
	PublicKey string `json:"public_key"`
	ShortID   string `json:"short_id"`
}

type clientMultiplex struct {
	Enabled    bool   `json:"enabled"`
	Protocol   string `json:"protocol"`
	MaxStreams int    `json:"max_streams"`
	Padding    bool   `json:"padding"`
}

type clientRoute struct {
	RuleSet               []clientRuleSet       `json:"rule_set,omitempty"`
	Rules                 []clientRouteRule     `json:"rules"`
	Final                 string                `json:"final,omitempty"`
	AutoDetectInterface   bool                  `json:"auto_detect_interface,omitempty"`
	DefaultDomainResolver *clientDomainResolver `json:"default_domain_resolver,omitempty"`
}

type clientRuleSet struct {
	Tag            string `json:"tag"`
	Type           string `json:"type"`
	Format         string `json:"format,omitempty"`
	URL            string `json:"url,omitempty"`
	DownloadDetour string `json:"download_detour,omitempty"`
	UpdateInterval string `json:"update_interval,omitempty"`
}

type clientRouteRule struct {
	ClashMode    string   `json:"clash_mode,omitempty"`
	Protocol     string   `json:"protocol,omitempty"`
	Network      string   `json:"network,omitempty"`
	Port         int      `json:"port,omitempty"`
	IPIsPrivate  *bool    `json:"ip_is_private,omitempty"`
	DomainSuffix []string `json:"domain_suffix,omitempty"`
	RuleSet      string   `json:"rule_set,omitempty"`
	Action       string   `json:"action,omitempty"`
	Outbound     string   `json:"outbound,omitempty"`
	NoDrop       *bool    `json:"no_drop,omitempty"`
}

type clientDomainResolver struct {
	Server   string `json:"server"`
	Strategy string `json:"strategy"`
}

type clientExperimental struct {
	ClashAPI *clientClashAPI `json:"clash_api,omitempty"`
}

type clientClashAPI struct {
	ExternalController string `json:"external_controller"`
}
