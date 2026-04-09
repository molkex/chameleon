package vpn

import (
	"encoding/json"
	"fmt"
	"time"
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

	// Build outbounds: one VLESS outbound per server.
	var serverOutbounds []clientOutbound
	var serverTags []string

	for _, srv := range servers {
		sni := srv.SNI
		if sni == "" {
			sni = engineCfg.Reality.SNI
		}
		if sni == "" {
			sni = "www.microsoft.com"
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
					PublicKey: engineCfg.Reality.PublicKey,
					ShortID:   shortID,
				},
			},
			PacketEncoding: "xudp",
		}

		serverOutbounds = append(serverOutbounds, outbound)
		serverTags = append(serverTags, tag)
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
	allOutbounds := []clientOutbound{proxyOutbound, autoOutbound}
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
		dnsDirect = "https://8.8.8.8/dns-query"
	}

	clashAPIPort := engineCfg.ClashAPIPort
	if clashAPIPort == 0 {
		clashAPIPort = 9091 // client-side clash API uses 9091 by default
	}

	config := clientConfig{
		Log: clientLog{
			Level: "info",
		},
		DNS: clientDNSConfig{
			Servers: []clientDNSServer{
				{
					Tag:             "dns-remote",
					Type:            "https",
					Server:          "1.1.1.1",
					ServerName:      "cloudflare-dns.com",
					AddressResolver: "dns-direct",
					Strategy:        "ipv4_only",
				},
				{
					Tag:      "dns-direct",
					Type:     "https",
					Server:   "8.8.8.8",
					Strategy: "ipv4_only",
					Detour:   "direct",
				},
				{
					Tag:  "dns-fakeip",
					Type: "fakeip",
				},
				{
					Tag:  "dns-block",
					Type: "block",
				},
			},
			Rules: []clientDNSRule{
				{
					ClashMode: "Direct",
					Server:    "dns-direct",
				},
				{
					QueryType: []string{"AAAA"},
					Server:    "dns-block",
				},
				{
					Outbound: []string{"any"},
					Server:   "dns-direct",
				},
			},
			FakeIP: &clientFakeIP{
				Enabled:    true,
				Inet4Range: "198.18.0.0/15",
			},
			IndependentCache: true,
		},
		Inbounds: []clientInbound{
			{
				Type:              "tun",
				Tag:               "tun-in",
				Inet4Address:      "172.19.0.1/30",
				MTU:               clientMTU,
				AutoRoute:         true,
				StrictRoute:       true,
				Stack:             "system",
				Sniff:             boolPtr(true),
				SniffOverrideDestination: boolPtr(false),
			},
		},
		Outbounds: allOutbounds,
		Route: clientRoute{
			Rules: []clientRouteRule{
				{
					ClashMode: "Direct",
					Outbound:  "direct",
				},
				{
					Protocol: "dns",
					Action:   "hijack-dns",
				},
				{
					Protocol: "quic",
					Outbound: "block",
				},
			},
			AutoDetectInterface: true,
			DefaultDomainResolver: &clientDomainResolver{
				Server:   "dns-remote",
				Strategy: "ipv4_only",
			},
		},
		Experimental: &clientExperimental{
			ClashAPI: &clientClashAPI{
				ExternalController: fmt.Sprintf("127.0.0.1:%d", clashAPIPort),
			},
		},
		ConfigVersion: time.Now().Unix(),
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
	Rules            []clientDNSRule   `json:"rules"`
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
}

type clientDNSRule struct {
	ClashMode string   `json:"clash_mode,omitempty"`
	QueryType []string `json:"query_type,omitempty"`
	Outbound  []string `json:"outbound,omitempty"`
	Server    string   `json:"server"`
}

type clientFakeIP struct {
	Enabled    bool   `json:"enabled"`
	Inet4Range string `json:"inet4_range"`
}

type clientInbound struct {
	Type                     string `json:"type"`
	Tag                      string `json:"tag"`
	Inet4Address             string `json:"inet4_address,omitempty"`
	MTU                      int    `json:"mtu,omitempty"`
	AutoRoute                bool   `json:"auto_route,omitempty"`
	StrictRoute              bool   `json:"strict_route,omitempty"`
	Stack                    string `json:"stack,omitempty"`
	Sniff                    *bool  `json:"sniff,omitempty"`
	SniffOverrideDestination *bool  `json:"sniff_override_destination,omitempty"`
}

type clientOutbound struct {
	Type                      string           `json:"type"`
	Tag                       string           `json:"tag"`
	Server                    string           `json:"server,omitempty"`
	ServerPort                int              `json:"server_port,omitempty"`
	UUID                      string           `json:"uuid,omitempty"`
	Flow                      string           `json:"flow,omitempty"`
	TLS                       *clientTLS       `json:"tls,omitempty"`
	Multiplex                 *clientMultiplex `json:"multiplex,omitempty"`
	PacketEncoding            string           `json:"packet_encoding,omitempty"`
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
	Rules                []clientRouteRule     `json:"rules"`
	AutoDetectInterface  bool                  `json:"auto_detect_interface,omitempty"`
	DefaultDomainResolver *clientDomainResolver `json:"default_domain_resolver,omitempty"`
}

type clientRouteRule struct {
	ClashMode string `json:"clash_mode,omitempty"`
	Protocol  string `json:"protocol,omitempty"`
	Outbound  string `json:"outbound,omitempty"`
	Action    string `json:"action,omitempty"`
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
