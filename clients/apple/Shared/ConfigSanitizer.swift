import Foundation

/// Sanitizes sing-box JSON config for iOS compatibility (sing-box 1.11.x).
/// Strips deprecated fields that cause LibboxCheckConfig to reject the config.
enum ConfigSanitizer {
    static func sanitizeForIOS(_ configJSON: String) -> String {
        guard let data = configJSON.data(using: .utf8),
              var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return configJSON
        }

        // 0. Remove custom metadata fields that sing-box doesn't understand
        config.removeValue(forKey: "config_version")

        // 1. dns outbound is needed for DNS interception in sing-box 1.13
        // Do NOT remove it — route rule {"protocol": "dns", "outbound": "dns-out"} depends on it

        // 3. Remove ALL deprecated inbound fields (sniff, sniff_override_destination, domain_strategy)
        //    In 1.11+ these are handled by route actions instead
        if var inbounds = config["inbounds"] as? [[String: Any]] {
            for i in inbounds.indices {
                inbounds[i].removeValue(forKey: "sniff")
                inbounds[i].removeValue(forKey: "sniff_override_destination")
                inbounds[i].removeValue(forKey: "domain_strategy")
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
