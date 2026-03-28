import Foundation

/// Sanitizes sing-box JSON config for iOS compatibility.
///
/// Server configs target desktop/Android. We fix:
/// 1. clash_api — sandbox blocks TCP bind in extension process
/// 2. strict_route — iOS manages routes via NEPacketTunnelNetworkSettings
/// 3. empty direct outbound — sing-box 1.13+ rejects detour to empty direct
/// 4. deprecated domain_strategy on DNS servers — moved to domain_resolver
/// 5. deprecated "outbound: any" DNS rule — replaced by domain_resolver
/// 6. missing route.default_domain_resolver — outbounds need it to resolve server hostnames
/// 7. deprecated dns.strategy top-level field — moved to default_domain_resolver
/// 8. deprecated sniff/sniff_override_destination on TUN — handled by route action
enum ConfigSanitizer {
    static func sanitizeForIOS(_ configJSON: String) -> String {
        guard let data = configJSON.data(using: .utf8),
              var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return configJSON
        }

        // 0. Set log level + file output (relative to working dir = sharedContainer/sing-box/)
        if var log = config["log"] as? [String: Any] {
            #if DEBUG
            log["level"] = "info"
            #else
            log["level"] = "warn"
            #endif
            log["output"] = "box.log"
            config["log"] = log
        }

        // 1. Remove clash_api — sandbox blocks TCP bind
        if var experimental = config["experimental"] as? [String: Any] {
            experimental.removeValue(forKey: "clash_api")
            if experimental.isEmpty {
                config.removeValue(forKey: "experimental")
            } else {
                config["experimental"] = experimental
            }
        }

        // 2. TUN inbound fixes
        if var inbounds = config["inbounds"] as? [[String: Any]] {
            for i in inbounds.indices {
                if inbounds[i]["type"] as? String == "tun" {
                    inbounds[i]["strict_route"] = false
                    // Remove deprecated sniff fields — handled by route action {"action": "sniff"}
                    inbounds[i].removeValue(forKey: "sniff")
                    inbounds[i].removeValue(forKey: "sniff_override_destination")
                }
            }
            config["inbounds"] = inbounds
        }

        // 3. Fix direct outbound — sing-box 1.13+ isEmpty check
        if var outbounds = config["outbounds"] as? [[String: Any]] {
            for i in outbounds.indices {
                if outbounds[i]["type"] as? String == "direct" {
                    if outbounds[i]["udp_fragment"] == nil {
                        outbounds[i]["udp_fragment"] = true
                    }
                }
            }
            config["outbounds"] = outbounds
        }

        // 4. Remove deprecated domain_strategy from DNS servers
        if var dns = config["dns"] as? [String: Any],
           var servers = dns["servers"] as? [[String: Any]] {
            for i in servers.indices {
                servers[i].removeValue(forKey: "domain_strategy")
            }
            dns["servers"] = servers
            config["dns"] = dns
        }

        // 5. Remove deprecated "outbound: any" DNS rules
        if var dns = config["dns"] as? [String: Any],
           var rules = dns["rules"] as? [[String: Any]] {
            rules.removeAll { $0["outbound"] as? String == "any" }
            dns["rules"] = rules
            config["dns"] = dns
        }

        // 6. Add route.default_domain_resolver so outbounds can resolve server hostnames
        if var route = config["route"] as? [String: Any] {
            if route["default_domain_resolver"] == nil {
                route["default_domain_resolver"] = [
                    "server": "dns-resolver",
                    "strategy": "ipv4_only"
                ] as [String: Any]
            }
            config["route"] = route
        }

        // 7. Remove deprecated top-level dns.strategy — now in default_domain_resolver
        if var dns = config["dns"] as? [String: Any] {
            dns.removeValue(forKey: "strategy")
            config["dns"] = dns
        }

        // 8. Remove auto_detect_interface from route — not valid on iOS
        if var route = config["route"] as? [String: Any] {
            route.removeValue(forKey: "auto_detect_interface")
            config["route"] = route
        }

        guard let sanitized = try? JSONSerialization.data(withJSONObject: config, options: []),
              let result = String(data: sanitized, encoding: .utf8) else {
            return configJSON
        }

        return result
    }
}
