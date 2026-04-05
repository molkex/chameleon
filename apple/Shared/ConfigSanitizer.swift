import Foundation

/// Sanitizes sing-box JSON config for iOS compatibility (sing-box 1.11.x).
/// Strips deprecated fields that cause LibboxCheckConfig to reject the config.
enum ConfigSanitizer {
    static func sanitizeForIOS(_ configJSON: String) -> String {
        guard let data = configJSON.data(using: .utf8),
              var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return configJSON
        }

        // 1. Remove "dns" type outbound (deprecated in 1.11, removed in 1.13)
        if var outbounds = config["outbounds"] as? [[String: Any]] {
            outbounds.removeAll { ($0["type"] as? String) == "dns" }
            config["outbounds"] = outbounds
        }

        // 2. Remove route rules that reference dns-out outbound
        if var route = config["route"] as? [String: Any],
           var rules = route["rules"] as? [[String: Any]] {
            rules.removeAll { ($0["outbound"] as? String) == "dns-out" }
            route["rules"] = rules
            config["route"] = route
        }

        // 3. Remove deprecated sniff_override_destination from TUN inbound
        if var inbounds = config["inbounds"] as? [[String: Any]] {
            for i in inbounds.indices {
                if inbounds[i]["type"] as? String == "tun" {
                    inbounds[i].removeValue(forKey: "sniff_override_destination")
                }
            }
            config["inbounds"] = inbounds
        }

        // 4. Remove deprecated top-level dns.strategy
        if var dns = config["dns"] as? [String: Any] {
            dns.removeValue(forKey: "strategy")
            config["dns"] = dns
        }

        // 5. Remove clash_api (sandbox blocks TCP bind in extension)
        if var experimental = config["experimental"] as? [String: Any] {
            experimental.removeValue(forKey: "clash_api")
            if experimental.isEmpty {
                config.removeValue(forKey: "experimental")
            } else {
                config["experimental"] = experimental
            }
        }

        // 6. Remove auto_detect_interface from route (not valid on iOS)
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
