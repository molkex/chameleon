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

        // 6. Bake the user's persisted routing mode into the selector defaults.
        //
        //    The extension used to start in whatever mode the backend baked in,
        //    and only the HOST APP applied the real mode afterwards, over the
        //    Clash command socket, on a best-effort retry that gives up after 5s
        //    (AppState.applyRoutingMode). So any tunnel start without a live
        //    foreground app — on-demand, after reboot, from the widget, or when
        //    the app had been jetsammed — silently ran the baked-in mode instead
        //    of the user's. Doing it here kills the race structurally: the config
        //    the engine starts with is already correct, no timing involved.
        //
        //    Only rewrites `default` when the target is an actual member of that
        //    selector, so a stale client can never select an outbound the current
        //    backend no longer emits.
        let mode = RoutingMode(
            rawValue: UserDefaults(suiteName: AppConstants.appGroupID)?
                .string(forKey: AppConstants.routingModeKey) ?? ""
        ) ?? .default
        if var outbounds = config["outbounds"] as? [[String: Any]] {
            let targets = Dictionary(
                uniqueKeysWithValues: mode.selectorTargets.map { ($0.selector, $0.target) }
            )
            for i in outbounds.indices {
                guard outbounds[i]["type"] as? String == "selector",
                      let tag = outbounds[i]["tag"] as? String,
                      let target = targets[tag],
                      let members = outbounds[i]["outbounds"] as? [String],
                      members.contains(target)
                else { continue }
                outbounds[i]["default"] = target
            }
            config["outbounds"] = outbounds
        }

        // 7. Pin the oom-killer into TIMER mode.
        //
        //    libbox appends a DEFAULT oom-killer service on iOS whenever the
        //    config declares none (sing-box-fork daemon/instance.go:90). That
        //    default has no options, which puts it in "pressure monitor" mode:
        //    every DISPATCH_MEMORYPRESSURE_CRITICAL calls router.ResetNetwork()
        //    unconditionally, without checking our own usage. iOS raises that
        //    signal for DEVICE-WIDE pressure — so an unrelated memory hog on the
        //    phone tore down every connection in OUR tunnel, in a loop (62,756
        //    resets in one exported device log, ~one per 20 ms).
        //
        //    Declaring it with an explicit `memory_limit` selects timer mode:
        //    poll actual usage, reset only when WE are really over. The backend
        //    now emits this too; doing it here as well means a stale cached
        //    config gets the fix without waiting for a fresh fetch.
        // OOM-THRESHOLD-COLLISION (2026-07-15): 48MB, not 45MB. The timer
        // measures whole-process phys_footprint, and libbox soft-caps the Go
        // heap at 45 MiB — a 45 MiB trip point sits BELOW the normal operating
        // footprint and ResetNetwork()-loops on every bulk transfer. 48 is the
        // backstop between the GC ceiling (45) and jetsam (~50). See clientconfig.go.
        var services = (config["services"] as? [[String: Any]]) ?? []
        if !services.contains(where: { $0["type"] as? String == "oom-killer" }) {
            services.append(["type": "oom-killer", "memory_limit": "48MB", "max_interval": "60s"])
        }
        config["services"] = services

        guard let sanitized = try? JSONSerialization.data(withJSONObject: config, options: []),
              let result = String(data: sanitized, encoding: .utf8) else {
            return configJSON
        }

        return result
    }
}
