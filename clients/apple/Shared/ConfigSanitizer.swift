import Foundation

/// Sanitizes sing-box JSON config for the iOS PacketTunnel extension.
///
/// Two jobs:
/// 1. Strip fields deprecated in sing-box 1.11+ so `LibboxCheckConfig` doesn't reject.
/// 2. Cap / disable things that inflate the Go runtime's resident memory inside
///    the 50 MB iOS NetworkExtension jetsam limit.
///
/// Rules here are intentionally defensive — we override the backend even when
/// the backend does the right thing, because a stale backend + a fresh client
/// shouldn't be able to push the extension over the cliff.
enum ConfigSanitizer {
    static func sanitizeForIOS(_ configJSON: String) -> String {
        guard let data = configJSON.data(using: .utf8),
              var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return configJSON
        }

        // 0. Remove custom metadata fields sing-box doesn't understand.
        config.removeValue(forKey: "config_version")

        // 1. Force log level to ERROR in Release and drop file output —
        //    log buffering is one of the largest transient allocations inside
        //    libbox. `logMaxLines` is set separately in ExtensionProvider.
        var log = (config["log"] as? [String: Any]) ?? [:]
        #if DEBUG
        log["level"] = log["level"] ?? "info"
        #else
        log["level"] = "error"
        #endif
        log.removeValue(forKey: "output")           // no file output from extension — use TunnelFileLogger
        log.removeValue(forKey: "timestamp")        // redundant — iOS syslog stamps for us
        config["log"] = log

        // 2. Remove deprecated inbound fields (sniff, sniff_override_destination,
        //    domain_strategy) — moved to route actions in 1.11+.
        if var inbounds = config["inbounds"] as? [[String: Any]] {
            for i in inbounds.indices {
                inbounds[i].removeValue(forKey: "sniff")
                inbounds[i].removeValue(forKey: "sniff_override_destination")
                inbounds[i].removeValue(forKey: "domain_strategy")
            }
            config["inbounds"] = inbounds
        }

        // 3. DNS hardening.
        //    - Cap cache to 512 entries (default 4096 — each holds RR lists,
        //      easily hundreds of KB with IPv6 AAAA + TXT lookups).
        //    - Disable independent_cache (per-server cache duplication).
        //    - Remove deprecated top-level strategy (moved to rule-scope in 1.11+).
        if var dns = config["dns"] as? [String: Any] {
            dns.removeValue(forKey: "strategy")
            dns["cache_capacity"] = 512
            dns["independent_cache"] = false
            // `disable_cache` stays whatever backend set — we want caching, just bounded.
            config["dns"] = dns
        }

        // 4. Experimental section: clash_api binds a TCP port the NE sandbox
        //    blocks, and cache_file balloons on first run as it geolocates
        //    every outbound. Both unused by the extension — LibboxCommandServer
        //    gives stats via UDS, not HTTP.
        if var experimental = config["experimental"] as? [String: Any] {
            experimental.removeValue(forKey: "clash_api")
            experimental.removeValue(forKey: "cache_file")
            if experimental.isEmpty {
                config.removeValue(forKey: "experimental")
            } else {
                config["experimental"] = experimental
            }
        }

        // 5. auto_detect_interface doesn't exist on iOS — NE owns interface selection.
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
