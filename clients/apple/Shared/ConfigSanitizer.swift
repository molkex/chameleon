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
        // Local debugging wants verbose engine logs; force info even though the
        // backend now emits "error" by default (LOG-VERBOSITY 2026-07-15).
        log["level"] = "info"
        #else
        // Belt-and-suspenders: the backend already emits "error", but keep forcing
        // it here so a stale cached config (or a backend regression) can't put the
        // memory-tight NE back into per-packet INFO logging.
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

        // 6b. Bake the user's persisted SERVER pick into the Proxy default.
        //
        //    Same race as rule 6, different selector: AppState.selectServer
        //    persists the pick into startOptions immediately, but a tunnel
        //    started with no live host app (widget, Control Center, boot, or
        //    on-demand) runs whatever `default` the persisted config
        //    happened to already carry — the live Clash-API correction
        //    (AppState.applyServerSelectionIfLive) only runs once the app
        //    itself reconnects to CommandClient, which can be tens of
        //    seconds later. Device log 2026-07-16: picked "Auto", connected
        //    via the widget 4s later, and the tunnel came up on the OLD
        //    ("pl-via-msk") leg for ~58s until the app reopened and corrected
        //    it. Mirrors AppState.resolveChain's three cases exactly (kept
        //    duplicated rather than shared — AppState.swift isn't part of
        //    the PacketTunnel/PacketTunnelMac target, same reason
        //    VPNIntentSubscriptionGate duplicates AppState.mayConnect).
        //
        //    Defensive like rule 6: only ever rewrites `default` when the
        //    resolved target is an actual member of the selector being
        //    written — a stale/unknown tag leaves the existing default
        //    (whatever the backend or a previous rewrite already set)
        //    untouched.
        let savedServerTag = UserDefaults(suiteName: AppConstants.appGroupID)?
            .string(forKey: AppConstants.selectedServerTagKey)
        let serverTarget = (savedServerTag?.isEmpty == false) ? savedServerTag! : "Auto"
        if var outbounds = config["outbounds"] as? [[String: Any]] {
            var typeByTag: [String: String] = [:]
            var membersByTag: [String: [String]] = [:]
            var indexByTag: [String: Int] = [:]
            for i in outbounds.indices {
                guard let tag = outbounds[i]["tag"] as? String,
                      let type = outbounds[i]["type"] as? String else { continue }
                typeByTag[tag] = type
                indexByTag[tag] = i
                if let members = outbounds[i]["outbounds"] as? [String] {
                    membersByTag[tag] = members
                }
            }
            let proxyMembers = membersByTag["Proxy"] ?? []

            func pinProxyDefault(to target: String) {
                guard let pi = indexByTag["Proxy"] else { return }
                outbounds[pi]["default"] = target
            }
            // urltest groups (country groups, Auto) have no `default` field
            // in sing-box's schema — they self-select by probe RTT. Only a
            // `selector`-type parent (e.g. the whitelist-bypass group) can
            // be pinned to a specific member.
            func pinParentDefaultIfSelector(_ parent: String, to target: String) {
                guard typeByTag[parent] == "selector", let idx = indexByTag[parent] else { return }
                outbounds[idx]["default"] = target
            }

            if proxyMembers.contains(serverTarget) {
                // Case 1: direct Proxy member — Auto, a country group tag,
                // or an individual leaf pinned as a Proxy child.
                pinProxyDefault(to: serverTarget)
            } else if let parent = proxyMembers.first(where: { member in
                member != "Auto" && membersByTag[member]?.contains(serverTarget) == true
            }) {
                // Case 2: leaf nested one level down inside a non-Auto
                // urltest/selector member. Prefer this over Auto so a
                // deliberate country/group pick isn't stolen by the
                // meta-group.
                pinProxyDefault(to: parent)
                pinParentDefaultIfSelector(parent, to: serverTarget)
            } else if typeByTag["Auto"] == "urltest", membersByTag["Auto"]?.contains(serverTarget) == true {
                // Case 3: last resort — the leaf exists only inside Auto.
                pinProxyDefault(to: "Auto")
            }
            // else: unknown/stale tag (e.g. a lean-mode config with no
            // "Auto" member when the persisted pick was "Auto") — leave
            // whatever default was already there.
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
        // OOM saga (2026-07-15): emit the oom-killer service ONLY to select timer
        // mode and thereby disable libbox's default pressure-monitor mode (the
        // 62k-reset bug). The limit is deliberately ABOVE the ~50 MiB jetsam
        // ceiling so the timer never actually fires — "45MB"/"48MB" sat at/below
        // the operating footprint and caused reset loops and connect-time trips.
        // Jetsam is the honest backstop until the client oomkiller is rebased.
        // See clientconfig.go for the full rationale.
        var services = (config["services"] as? [[String: Any]]) ?? []
        if !services.contains(where: { $0["type"] as? String == "oom-killer" }) {
            services.append(["type": "oom-killer", "memory_limit": "512MB"])
        }
        config["services"] = services

        // 8. Rewrite the geoip-ru rule_set from remote to local.
        //
        //    The backend emits {type:"remote", url:"https://raw.githubusercontent.com/
        //    SagerNet/sing-geoip/rule-set/geoip-ru.srs", download_detour:"direct",
        //    update_interval:"168h"}. That downloads AND parses a ~50 KB .srs into RAM
        //    on EVERY tunnel start — rule 4 above strips experimental.cache_file, so
        //    there's no on-disk cache to skip the re-fetch. raw.githubusercontent.com
        //    is also RKN-blocked in Russia, so this was a reliability footgun on top
        //    of the memory cost. The .srs is now bundled straight into the extension
        //    (PacketTunnel/PacketTunnelMac target resources — see project.yml), so we
        //    can point sing-box at the file on disk: zero network, no parse-from-HTTP
        //    overhead.
        //
        //    Matched by tag, not url — so this is idempotent whether the entry
        //    arrives remote (fresh backend config) or already-local (a config this
        //    same rewrite already touched). `Bundle.main` resolves to whichever
        //    process is actually executing this file; the rewrite that matters is
        //    the one ExtensionProvider runs right before starting the tunnel, where
        //    Bundle.main is the extension's own .appex, which is where the resource
        //    is bundled. Fall back to a bundlePath-relative guess (never emitting a
        //    pathless local rule_set) for hosts that don't carry the resource —
        //    e.g. MadFrogVPNTests, injected into the main app bundle.
        if var route = config["route"] as? [String: Any],
           var ruleSets = route["rule_set"] as? [[String: Any]] {
            for i in ruleSets.indices {
                guard ruleSets[i]["tag"] as? String == "geoip-ru" else { continue }
                ruleSets[i]["type"] = "local"
                ruleSets[i].removeValue(forKey: "url")
                ruleSets[i].removeValue(forKey: "download_detour")
                ruleSets[i].removeValue(forKey: "update_interval")
                ruleSets[i]["path"] = Bundle.main.path(forResource: "geoip-ru", ofType: "srs")
                    ?? (Bundle.main.bundlePath as NSString).appendingPathComponent("geoip-ru.srs")
            }
            route["rule_set"] = ruleSets
            config["route"] = route
        }

        guard let sanitized = try? JSONSerialization.data(withJSONObject: config, options: []),
              let result = String(data: sanitized, encoding: .utf8) else {
            return configJSON
        }

        return result
    }
}
