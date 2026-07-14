import Foundation
import UserNotifications
import WidgetKit

/// Traffic-health monitoring + the automatic same-country fallback cascade.
/// Extracted 2026-07-11 (M1, Fable code review) from AppState.swift.
///
/// Several stored properties this file reads/writes (`deadLeavesInCurrentCascade`,
/// `deadCountriesInCurrentCascade`, `trafficHealthMonitor`, `pathPicker`,
/// `lastWorkingLegStore`, `currentNetworkFingerprint`,
/// `darwinStallObserverInstalled`) are declared in AppState.swift proper and
/// had to move from `private` to internal (module-default) access — Swift's
/// `private` is file-scoped, so a same-class extension in a different file
/// can't see a `private` member declared in the main file. Nothing outside
/// this app target can see them either way, so this doesn't change the real
/// encapsulation boundary, only which files within AppState's own
/// implementation may touch them.
extension AppState {
    // MARK: - Traffic health monitor + fallback chain

    /// Hook called by MadFrogVPNApp on `scenePhase` change.
    /// Build-39: gate removed from monitor lifetime — see
    /// `startTrafficHealthMonitorIfEligible`. We still observe the
    /// transition because:
    ///   1. Coming back to foreground is the canonical "user noticed
    ///      something stalled" moment, so we drain the extension's
    ///      stall-signal flag and immediately fire fallback if needed.
    ///   2. UI affordances (the stale-error banner) still need the
    ///      foreground edge.
    func handleScenePhaseActive(_ active: Bool) {
        let wasActive = isAppActive
        isAppActive = active
        // LAUNCH-08: foreground = no notifications; let the notifier know.
        disconnectNotifier.setAppActive(active)
        // Clear any in-flight banner when the user opens the app — by the
        // time they see the home view, the "VPN disconnected" alert is
        // redundant.
        if active {
            disconnectNotifier.dismissDelivered()
        }
        TunnelFileLogger.log("scene phase: active=\(active)", category: "ui")
        if active && !wasActive {
            // Build-38: clear stale error banner from a previous foreground
            // session for not-yet-signed-in users. AppState survives
            // background→foreground unchanged, so an errorMessage set during
            // a failed sign-in attempt yesterday would otherwise still be
            // showing over OnboardingView today — symptom user reported as
            // «не сразу вошло» in the 2026-04-26 build 36 field test.
            // Authenticated users see status/connection errors here that
            // are still meaningful, so leave those alone.
            if !isAuthenticated {
                errorMessage = nil
            }
            startTrafficHealthMonitorIfEligible()
            // Build-39: drain the extension's stall flag. If the extension
            // detected a stall while we were backgrounded, run the fallback
            // synchronously now so the very first user interaction (Safari
            // tap, refresh) lands on a working leg.
            Task { [weak self] in
                await self?.handleExtensionStallSignalIfAny()
            }
        }
    }

    /// Register a Darwin cross-process notification observer so the main app
    /// can react to a tunnel stall even when backgrounded (not suspended).
    /// The extension posts `tunnelStallDarwinNotification` after writing to
    /// shared UserDefaults. Safe to call multiple times — idempotent.
    func installDarwinStallObserverIfNeeded() {
        guard !darwinStallObserverInstalled else { return }
        darwinStallObserverInstalled = true
        let name = AppConstants.tunnelStallDarwinNotification as CFString
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            selfPtr,
            { _, ptr, _, _, _ in
                guard let ptr else { return }
                let state = Unmanaged<AppState>.fromOpaque(ptr).takeUnretainedValue()
                Task { @MainActor in
                    await state.handleExtensionStallSignalIfAny()
                }
            },
            name, nil, .deliverImmediately
        )
    }

    /// Build-39: read the `AppConstants.tunnelStallRequestedAtKey` flag
    /// the PacketTunnel extension's `TunnelStallProbe` writes when it
    /// detects 2 consecutive captive-portal probe misses. If a request is
    /// newer than the last one we serviced, run `performFallbackForCurrentLeg`
    /// and stamp the serviced timestamp so we don't re-fire.
    func handleExtensionStallSignalIfAny() async {
        // AUTO-RECOVER-GATE (truth audit 2026-07-14): this used to service
        // the extension's stall signal unconditionally — the toggle only
        // gated the separate (already-neutered) main-app monitor. Guard here
        // too, in addition to the extension no longer emitting the signal
        // when the preference is off (belt-and-suspenders: the extension and
        // main app are separate processes and can disagree transiently on
        // App Group read timing).
        guard configStore.autoRecoverEnabled else { return }
        guard let defaults = UserDefaults(suiteName: AppConstants.appGroupID) else { return }
        let requestedAt = defaults.double(forKey: AppConstants.tunnelStallRequestedAtKey)
        guard requestedAt > 0 else { return }
        let servicedAt = defaults.double(forKey: AppConstants.tunnelStallServicedAtKey)
        guard requestedAt > servicedAt else { return }
        guard vpnManager.isConnected else { return }

        TunnelFileLogger.log("ext-stall: signal received (requestedAt=\(requestedAt) servicedAt=\(servicedAt)), invoking fallback", category: "ui")
        await performFallbackForCurrentLeg()
        defaults.set(Date().timeIntervalSince1970, forKey: AppConstants.tunnelStallServicedAtKey)
        // Dismiss the stall notification if it's still showing (user didn't tap it).
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [AppConstants.tunnelStallNotificationID]
        )
    }

    func startTrafficHealthMonitorIfEligible() {
        // Lazy build. The monitor's lifetime tracks AppState so a single
        // instance survives across connect/disconnect cycles.
        if trafficHealthMonitor == nil {
            trafficHealthMonitor = TrafficHealthMonitor(dependencies: .init(
                isVPNConnected: { [weak self] in self?.vpnManager.isConnected ?? false },
                isCommandClientConnected: { [weak self] in self?.commandClient.isConnected ?? false },
                isAppActive: { [weak self] in self?.isAppActive ?? false },
                isUserEnabled: { [weak self] in self?.configStore.autoRecoverEnabled ?? true },
                probe: { url, timeout in
                    await HealthProbeURLSession.probe(url: url, timeout: timeout)
                },
                onStallDetected: { [weak self] in
                    // 2026-05-26 (audit P0-C): main-app monitor no longer
                    // performs a fallback. PacketTunnel's
                    // `RealTrafficStallDetector` is the sole authority for
                    // stall-triggered recovery — running two competing
                    // detectors created a `selectOutbound` storm that tore
                    // in-flight sockets. We still nudge the widget so any
                    // UI uptime/state stays fresh on observed stall.
                    TunnelFileLogger.log("ui.stall: TrafficHealthMonitor saw stall — deferring to extension (no fallback here)", category: "ui")
                    Task { @MainActor in
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                },
                onProbeSuccess: { [weak self] in
                    await MainActor.run {
                        self?.recordWorkingLegToMemory()
                    }
                    // Build-39: every successful main-app probe also drains
                    // the extension stall flag. Catches the case where
                    // background→foreground happened so fast we missed the
                    // scenePhase event but extension had flagged a stall.
                    await self?.handleExtensionStallSignalIfAny()
                },
                log: { msg in
                    TunnelFileLogger.log(msg, category: "ui")
                }
            ))
        }
        // Build-39: isAppActive gate removed. The PacketTunnel extension
        // hosts an identical probe (TunnelStallProbe) that runs even while
        // iOS suspends the main app — exactly when stall detection actually
        // matters (user is in Safari, MadFrog backgrounded). This main-app
        // monitor is now defense-in-depth for the foreground window plus a
        // place to react to the extension's cross-process stall flag.
        guard configStore.autoRecoverEnabled, vpnManager.isConnected else { return }
        trafficHealthMonitor?.start()
    }

    /// Smart fallback chain (build-33 cascade). Strategy modelled on what
    /// the user actually expects: stay close to their original choice for
    /// as long as possible, only escalating away from it when all options
    /// in that scope are exhausted. Order:
    ///
    ///   1. **Same country, different leaf** — try the next not-yet-tried
    ///      leaf inside the pinned country. Silent, no toast.
    ///   2. **Country exhausted** — mark country dead in the cascade, send
    ///      diagnostic to backend, pick the next-best country by ping and
    ///      pin it. Toast "Германия недоступна, переключено на NL".
    ///   3. **All direct countries dead (or `maxCascadeDepth` hit)** —
    ///      jump to SPB whitelist-bypass relays as last resort. Toast.
    ///   4. **SPB relays also dead** — toast "Сеть недоступна", log error,
    ///      fire diagnostic. Stop probing for the rest of the cooldown
    ///      window.
    ///
    /// Manual user pick clears the cascade state and resets the chain.
    func performFallbackForCurrentLeg() async {
        // AUTO-RECOVER-GATE: second gate on the same preference (the only
        // caller today is `handleExtensionStallSignalIfAny`, already guarded
        // above) — kept here too since this is the actual entry point that
        // does the switching, and future callers must not have to remember
        // to re-check the toggle themselves.
        guard configStore.autoRecoverEnabled else { return }
        guard vpnManager.isConnected else { return }
        let pinned = configStore.selectedServerTag
        let shape = ServerTagShape(pinned)
        guard let group = servers.first(where: { $0.type == "selector" && $0.selectable }) else {
            TunnelFileLogger.log("fallback: no selector group, skipping", category: "ui")
            return
        }

        switch shape {
        case .leaf:
            await fallbackFromLeaf(pinned: pinned!, group: group)
        case .countryUrltest:
            await fallbackFromCountry(pinned: pinned!, group: group)
        case .auto, .unknown:
            await fallbackOnAuto(group: group)
        }
    }

    private func fallbackFromLeaf(pinned: String, group: ServerGroup) async {
        deadLeavesInCurrentCascade.insert(pinned)
        TunnelFileLogger.log("fallback: leaf '\(pinned)' marked dead (cascade leaves=\(deadLeavesInCurrentCascade.count))", category: "ui")

        guard let country = group.countries.first(where: { $0.serverTags.contains(pinned) }) else {
            TunnelFileLogger.log("fallback: leaf '\(pinned)' has no country, escalating", category: "ui")
            await escalateBeyondCountry(group: group, exhaustedCountry: nil, reason: "leaf orphan")
            return
        }

        let candidates = country.serverTags.filter { !deadLeavesInCurrentCascade.contains($0) }
        if let next = candidates.first {
            TunnelFileLogger.log("fallback: leaf '\(pinned)' → leaf '\(next)' (same country '\(country.tag)')", category: "ui")
            selectServer(groupTag: group.tag, serverTag: next, clearCascade: false)
            fallbackToastMessage = L10n.Recovery.switchedLeg(country.name)
            return
        }

        TunnelFileLogger.log("fallback: all leaves in '\(country.tag)' tried, escalating", category: "ui")
        deadCountriesInCurrentCascade.insert(country.tag)
        reportDiagnostic(event: "country_dead", country: country.tag, deadLeaves: Array(deadLeavesInCurrentCascade))
        await escalateBeyondCountry(group: group, exhaustedCountry: country, reason: "country '\(country.name)' exhausted")
    }

    private func fallbackFromCountry(pinned: String, group: ServerGroup) async {
        // User pinned a country urltest. Build-35: try the next not-yet-tried
        // leaf inside the country *first* — sing-box's urltest can mis-pick
        // (HEAD passes on a path that drops real data), so cycling at our
        // layer reliably catches degraded paths even when sing-box's own
        // probe says everything is fine. Only escalate to the next country
        // when every leaf in this one has been tried this cascade.
        guard let country = group.countries.first(where: { $0.tag == pinned }) else {
            TunnelFileLogger.log("fallback: country tag '\(pinned)' not found, escalating", category: "ui")
            await escalateBeyondCountry(group: group, exhaustedCountry: nil, reason: "country tag '\(pinned)' missing")
            return
        }
        let activeLeaf = servers.first(where: { $0.tag == pinned })?.selected
        if let leaf = activeLeaf, !leaf.isEmpty {
            deadLeavesInCurrentCascade.insert(leaf)
            // Forget memory bias for this network+country — the remembered
            // leg is now dead under current conditions.
            if let fp = currentNetworkFingerprint, let cc = leafCountryCode(leaf) {
                lastWorkingLegStore.forget(fingerprint: fp, country: cc)
            }
        }
        let candidates = country.serverTags.filter { !deadLeavesInCurrentCascade.contains($0) }
        if let next = candidates.first {
            TunnelFileLogger.log("fallback: '\(pinned)' leaf '\(activeLeaf ?? "?")' → '\(next)' (same country)", category: "ui")
            // Audit P1-3 (2026-05-26): the previous version called
            // selectOutbound directly and left `configStore.selectedServerTag`
            // pointing at the country pin — `selectOutbound` is a live-tunnel
            // override that doesn't survive restart, so the live leaf and
            // the persisted intent diverged. Now both are written so a
            // cold start re-honors the same leaf.
            //
            // selectOutbound itself closes existing connections so in-flight
            // sockets get re-dialled through the new leaf.
            commandClient.selectOutbound(groupTag: group.tag, outboundTag: next)
            configStore.selectedServerTag = next
            selectedServerTag = next
            fallbackToastMessage = L10n.Recovery.switchedLeg(country.name)
            return
        }
        // Every leaf in the country has been tried — promote to country-dead
        // and escalate.
        deadCountriesInCurrentCascade.insert(pinned)
        for leaf in country.serverTags { deadLeavesInCurrentCascade.insert(leaf) }
        TunnelFileLogger.log("fallback: all leaves in '\(pinned)' tried, escalating", category: "ui")
        reportDiagnostic(event: "country_dead", country: pinned, deadLeaves: country.serverTags)
        await escalateBeyondCountry(group: group, exhaustedCountry: country, reason: "country '\(pinned)' unreachable")
    }

    /// Extract two-letter country code from a leaf tag like "de-via-msk" → "DE".
    func leafCountryCode(_ leaf: String) -> String? {
        let parts = leaf.split(separator: "-")
        guard let first = parts.first else { return nil }
        return first.uppercased()
    }

    /// build-85 testability extract (P1-3): the pure leaf-pick the
    /// `fallbackFromCountry` cascade uses. Given the country the user is
    /// pinned to and the set of leaves marked dead this cascade, return
    /// the next leaf the cascade should try (the first not-dead leaf in
    /// `country.serverTags`), or nil when every leaf has been tried.
    /// Free of CommandClient / ConfigStore / AppState references so it
    /// can be unit-tested without standing up the @MainActor object graph.
    static func nextLeafForCountry(country: CountryGroup,
                                   deadLeaves: Set<String>) -> String? {
        country.serverTags.first { !deadLeaves.contains($0) }
    }

    /// build-85 testability extract (audit P0-B): decides whether
    /// `performFallbackForCurrentLeg` should escalate beyond the pinned
    /// country. The architectural contract after the build-42 backend
    /// strict-country fix is "this country or fail" — at a single-country
    /// topology (only one country has any leaves) we must NOT auto-jump,
    /// because there is nowhere else to legitimately go. Likewise when
    /// every other country is already in the dead set.
    static func shouldEscalateBeyondCountry(group: ServerGroup,
                                            currentCountry: String,
                                            deadCountries: Set<String>) -> Bool {
        let alive = group.countries.filter { country in
            country.tag != currentCountry &&
            !deadCountries.contains(country.tag) &&
            !country.serverTags.isEmpty
        }
        return !alive.isEmpty
    }

    private func fallbackOnAuto(group: ServerGroup) async {
        // Build-39: ask PathPicker for the next-best leaf across the whole
        // pool, excluding any we've already given up on this cascade. The
        // pre-build-39 path called `commandClient.urlTest(...)` per group
        // which was a no-op once urltest groups were removed from the
        // config; now we directly re-probe via NWConnection in main app
        // and push the new winner via Clash API.
        let candidates = leafCandidates()
        guard !candidates.isEmpty else {
            TunnelFileLogger.log("fallback(auto): no candidates, skipping", category: "ui")
            return
        }
        let demote = computeDemoteClasses()
        guard let leaf = await pathPicker.bestLeaf(
            excluding: deadLeavesInCurrentCascade,
            for: nil,                           // Auto = no country filter
            candidates: candidates,
            demoteClasses: demote
        ) else {
            TunnelFileLogger.log("fallback(auto): all candidates dead, giving up", category: "ui")
            return
        }
        TunnelFileLogger.log("fallback(auto): re-pick leaf='\(leaf)' demote=\(demote.map { "\($0)" }.sorted())", category: "ui")
        commandClient.selectOutbound(groupTag: group.tag, outboundTag: leaf)
        // No toast — recovery on Auto is the expected silent path.
    }

    /// Build-39: derive the cascade demote set from the per-network record
    /// in `LastWorkingLegStore`. If we have any successful records on this
    /// network and NONE of them are direct, demote `.direct` so the next
    /// fallback skips it entirely. Returns empty set when we have no
    /// records or when direct has worked here at least once.
    private func computeDemoteClasses() -> Set<LeafClass> {
        guard let fp = currentNetworkFingerprint else { return [] }
        guard let workedClasses = lastWorkingLegStore.classesEverWorked(fingerprint: fp) else {
            return [] // never connected on this network — no signal
        }
        var demote: Set<LeafClass> = []
        if !workedClasses.contains("direct") {
            demote.insert(.direct)
        }
        return demote
    }

    /// 2026-05-26 (audit P0-B): the prior implementation silently switched
    /// COUNTRY and even promoted the user to SPB whitelist-bypass on a
    /// stall — that's the "переключилось куда-то, не знаю зачем" the
    /// user reports. After the backend strict-country build-42 fix the
    /// architectural contract is: picking a country means "this country
    /// or fail". Cross-country failover stays opt-in via the explicit
    /// "Auto" group.
    ///
    /// New behaviour: when the same-country leaf cycling in
    /// `fallbackFromLeaf` / `fallbackFromCountry` is exhausted, we report
    /// the country as unreachable and stop. The user sees a toast
    /// suggesting they pick another country manually. We never persist
    /// a different country into `configStore.selectedServerTag` behind
    /// the user's back, and we never auto-jump to whitelist-bypass.
    private func escalateBeyondCountry(
        group: ServerGroup,
        exhaustedCountry: CountryGroup?,
        reason: String
    ) async {
        if let from = exhaustedCountry {
            TunnelFileLogger.log("fallback: country '\(from.tag)' exhausted, NO cross-country jump (audit P0-B); reason=\(reason)", category: "ui")
            fallbackToastMessage = L10n.Error.selectedUnreachable(from.name)
        } else {
            TunnelFileLogger.log("fallback: leg exhausted, NO cross-country jump (audit P0-B); reason=\(reason)", category: "ui")
            fallbackToastMessage = L10n.Error.allServersUnreachable
        }
        reportDiagnostic(event: "country_exhausted_no_jump", country: exhaustedCountry?.tag ?? "*", deadLeaves: Array(deadLeavesInCurrentCascade))
    }

    /// Fire-and-forget diagnostic POST to backend. Catches network errors
    /// silently — the cascade decision must not depend on whether ops
    /// telemetry succeeded. Backend appends to a log file ops can grep
    /// when a user reports "country X stopped working".
    private func reportDiagnostic(event: String, country: String, deadLeaves: [String]) {
        Task.detached { [weak self] in
            guard let self else { return }
            let token = await self.configStore.accessToken
            let networkType = await self.currentNetworkTypeLabel()
            try? await self.apiClient.reportDiagnostic(
                event: event,
                country: country,
                deadLeaves: deadLeaves,
                networkType: networkType,
                accessToken: token
            )
        }
    }

    /// Best-effort label for the active network type — used in diagnostic
    /// payloads only, never in routing decisions. Returns "wifi", "cellular",
    /// "wired", or "unknown".
    private func currentNetworkTypeLabel() -> String {
        // ROADMAP iOS-22: hook NWPathMonitor into AppState. For now the
        // extension's pathUpdate logs already capture this on the support
        // side, so the diagnostic payload is informational only.
        return "unknown"
    }
}
