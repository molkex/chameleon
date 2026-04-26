import Foundation
import Network

/// Build-39 architectural refactor: server selection moves out of the
/// NetworkExtension's sing-box `urltest` outbound and into the main app.
/// Industry standard for iOS VPNs (WireGuard / Mullvad / NordVPN Lynx /
/// ProtonVPN follow this pattern): the extension stays a dumb pipe under
/// Apple's 50MB jetsam cap, while the host process — which has memory to
/// spare — does the latency probing and decides which leaf carries traffic.
///
/// Why this matters for us specifically: the build-37 field test on WiFi
/// showed `internal` (Go heap) spiking from 22 → 34 MB at T+30s after
/// connect, with `os_proc_available_memory()` dropping to 5 MB — within
/// jetsam range. The spike correlated with the 4-way parallel sing-box
/// urltest (Auto + 3 country urltests, each running its own HTTP probe
/// stack inside libbox). Moving probes out of the extension removes the
/// spike entirely.
///
/// The picker probes each candidate leaf via plain TCP `NWConnection`
/// (no TLS, no HTTP) and ranks by `.ready` time. Successful probes are
/// persisted by `LeafRankingStore` so warm reconnects on the same network
/// can short-circuit the probe and return the cached winner instantly.
@MainActor
@Observable
final class PathPicker {

    /// Per-candidate TCP probe timeout. 1.5s is enough for typical TCP
    /// handshakes; longer paths are effectively unusable for VPN UX anyway.
    static let defaultProbeTimeout: TimeInterval = 1.5

    /// Cache TTL — re-probe if the latest measurement is older than this.
    /// 5 min matches typical VPN session length, so the cache stays warm
    /// for warm reconnects but won't claim "fastest = X" forever after a
    /// network switch.
    static let defaultCacheTTL: TimeInterval = 300

    private let store: LeafRankingStore
    private let probeFn: @Sendable (LeafCandidate, TimeInterval) async -> LeafProbeResult
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void

    /// Last picked leaf for the most recent connect. Surfaced via the home
    /// pill subtitle ("via de-via-msk") so the user can see what's actually
    /// carrying their traffic. nil before first pick.
    private(set) var currentLeaf: String?

    init(
        store: LeafRankingStore,
        probeFn: @escaping @Sendable (LeafCandidate, TimeInterval) async -> LeafProbeResult = PathPicker.tcpProbe(_:timeout:),
        now: @escaping @Sendable () -> Date = { Date() },
        log: @escaping @Sendable (String) -> Void = { TunnelFileLogger.log($0, category: "path_picker") }
    ) {
        self.store = store
        self.probeFn = probeFn
        self.now = now
        self.log = log
    }

    // MARK: - Public API

    /// Resolve a `selected` server tag (from `ConfigStore.selectedServerTag`)
    /// into the actual leaf to push to the extension's `Proxy` selector.
    ///
    /// Resolution order:
    /// 1. If `selected` matches a candidate tag exactly → power-mode pin,
    ///    return as-is (user explicitly chose a leaf, honour it).
    /// 2. Map `selected` to a country code via `countryCode(for:)`. nil =
    ///    Auto = no country filter.
    /// 3. Filter pool to candidates in that country.
    /// 4. Use `LeafRankingStore` cache if every candidate has a fresh
    ///    successful measurement; otherwise probe.
    /// 5. Pick lowest TCP-probe latency among successful results.
    /// 6. If all probes fail, fall back to a UDP-only candidate (TUIC) if
    ///    any — those can't be probed but may still work.
    /// 7. Last resort: return the first candidate alphabetically so the
    ///    extension at least has *something* to try.
    func bestLeaf(
        for selected: String?,
        candidates: [LeafCandidate],
        demoteClasses: Set<LeafClass> = []
    ) async -> String? {
        // 1. Power-mode pin.
        if let s = selected, candidates.contains(where: { $0.tag == s }) {
            log("bestLeaf: leaf-pin '\(s)'")
            currentLeaf = s
            return s
        }
        let country = Self.countryCode(forSelectedTag: selected)
        let pool = candidates.filter { country == nil || $0.country == country }
        guard !pool.isEmpty else {
            log("bestLeaf: empty pool for country='\(country ?? "any")'")
            return nil
        }
        let pick = await pickBest(in: pool, excluding: [], demoteClasses: demoteClasses)
        if let pick { currentLeaf = pick }
        if !demoteClasses.isEmpty {
            log("bestLeaf: selected='\(selected ?? "auto")' country='\(country ?? "any")' demote=\(demoteClasses.map { "\($0)" }.sorted()) winner='\(pick ?? "—")'")
        } else {
            log("bestLeaf: selected='\(selected ?? "auto")' country='\(country ?? "any")' winner='\(pick ?? "—")'")
        }
        return pick
    }

    /// Pick a fallback leaf, excluding `dead`. Used by `TrafficHealthMonitor`
    /// to hop off a stalling leaf to the next-best alternative inside the
    /// same country (or across all if Auto / no country filter applied).
    func bestLeaf(
        excluding dead: Set<String>,
        for selected: String?,
        candidates: [LeafCandidate],
        demoteClasses: Set<LeafClass> = []
    ) async -> String? {
        let country = Self.countryCode(forSelectedTag: selected)
        let pool = candidates.filter { country == nil || $0.country == country }
        let pick = await pickBest(in: pool, excluding: dead, demoteClasses: demoteClasses)
        if let pick { currentLeaf = pick }
        log("bestLeaf(excluding=\(dead.sorted())): selected='\(selected ?? "auto")' winner='\(pick ?? "—")'")
        return pick
    }

    /// Build-40 cache-only resolver. Returns the lowest-latency leaf with a
    /// fresh successful measurement in the country pool, or nil if no leaf
    /// has one. **Never probes.**
    ///
    /// Why we need a no-probe variant: post-connect, the OS routes every
    /// `NWConnection` from the main app through the just-established VPN
    /// tunnel. A TCP probe to a "dead" leaf's IP (e.g. `de-direct-de` over
    /// LTE on a network that ASN-blocks DE) tunnels via the *working* leaf
    /// to the dead leaf's server and reports a fast loopback-ish RTT — the
    /// dead leaf appears alive at ~5ms even though direct reach from the
    /// real network stack is impossible. Field-test 2026-04-26 Build 37
    /// caught this: pre-connect probe correctly picked `de-via-msk`, then
    /// post-connect re-probe picked `de-direct-de` and broke browsing.
    ///
    /// Cold-start callers (relaunch with active tunnel) should use this and
    /// fall back to "skip and let baked-in default stand" rather than
    /// `bestLeaf` which would probe through the tunnel.
    func cachedBestLeaf(
        for selected: String?,
        candidates: [LeafCandidate],
        demoteClasses: Set<LeafClass> = []
    ) -> String? {
        // Power-mode pin still wins — exact leaf chosen by the user.
        if let s = selected, candidates.contains(where: { $0.tag == s }) {
            currentLeaf = s
            return s
        }
        let country = Self.countryCode(forSelectedTag: selected)
        let pool = candidates.filter { country == nil || $0.country == country }
        guard !pool.isEmpty else { return nil }
        let cutoff = now().addingTimeInterval(-Self.defaultCacheTTL)
        let fresh = store.load().filter { $0.measuredAt > cutoff && $0.success }
        let freshByTag = Dictionary(uniqueKeysWithValues: fresh.map { ($0.tag, $0) })
        let aliveCands = pool.filter { freshByTag[$0.tag] != nil }
        guard let best = Self.cascadePick(
            aliveCands,
            latencyByTag: { freshByTag[$0]?.latencyMs },
            demoteClasses: demoteClasses
        ) else {
            return nil
        }
        currentLeaf = best.tag
        return best.tag
    }

    /// Mark `leaf` as alive after a successful health probe. Feeds the cache
    /// so subsequent connects on the same network skip the cold probe.
    func recordSuccess(leaf: String, latencyMs: Int) {
        store.update(tag: leaf, latencyMs: latencyMs, success: true, at: now())
    }

    /// Mark `leaf` as failing. Feeds the cache so the next pick deprioritises
    /// it (in addition to the explicit `excluding` set passed by callers).
    func recordFailure(leaf: String) {
        store.update(tag: leaf, latencyMs: 0, success: false, at: now())
    }

    // MARK: - Tag → country mapping

    /// Map `ConfigStore.selectedServerTag` (UI label or leaf tag) to the
    /// country code used by `LeafCandidate.country`. nil means "no country
    /// filter" — i.e. Auto / unset / unrecognised.
    ///
    /// Display labels are produced server-side by `clientconfig.go`'s
    /// `countryDisplay()`. They're stable strings (not localised on the
    /// client). Any future country additions need an entry here AND in
    /// the backend.
    static func countryCode(forSelectedTag tag: String?) -> String? {
        guard let tag, !tag.isEmpty, tag != "Auto" else { return nil }
        switch tag {
        case "🇩🇪 Германия": return "de"
        case "🇳🇱 Нидерланды": return "nl"
        case "🇷🇺 Россия (обход белых списков)", "🇷🇺 Россия": return "ru-spb"
        default:
            // Unknown label, or a leaf tag handled earlier as a power-mode
            // pin. Don't filter to empty — let the caller's pool be used as-is.
            return nil
        }
    }

    /// True when `leaf` is a valid choice for the given user `selection`:
    /// either an exact leaf-pin match, or the leaf's country matches the
    /// selection's country (`Auto` / nil ⇒ any leaf passes). Used by
    /// `applyServerSelectionIfLive` to decide whether the pre-connect
    /// `currentLeaf` is still applicable to the current selection (the user
    /// might have switched countries between toggleVPN and the post-connect
    /// re-apply). The leaf-must-be-in-`pool` requirement guards against a
    /// stale `currentLeaf` referencing a leaf that no longer exists in the
    /// fresh config.
    static func leaf(
        _ leaf: String,
        matchesSelection selection: String?,
        in pool: [LeafCandidate]
    ) -> Bool {
        guard let cand = pool.first(where: { $0.tag == leaf }) else { return false }
        if selection == leaf { return true }                       // power-mode pin
        guard let wanted = countryCode(forSelectedTag: selection) else {
            return true                                            // Auto / unset
        }
        return cand.country == wanted
    }

    // MARK: - Internals

    private func pickBest(
        in pool: [LeafCandidate],
        excluding dead: Set<String>,
        demoteClasses: Set<LeafClass> = []
    ) async -> String? {
        let alivePool = pool.filter { !dead.contains($0.tag) }
        guard !alivePool.isEmpty else { return nil }

        // Phase 1 — try cache. Cascade on classes: if any direct has a
        // fresh successful measurement, prefer it over relay/bypass even
        // if relay is faster. Within a class, lower latency wins.
        let cutoff = now().addingTimeInterval(-Self.defaultCacheTTL)
        let recent = store.load().filter { $0.measuredAt > cutoff && $0.success }
        let recentByTag = Dictionary(uniqueKeysWithValues: recent.map { ($0.tag, $0) })
        if alivePool.allSatisfy({ recentByTag[$0.tag] != nil }) {
            if let best = Self.cascadePick(
                alivePool,
                latencyByTag: { recentByTag[$0]?.latencyMs },
                demoteClasses: demoteClasses
            ) {
                log("pickBest: cache-hit winner='\(best.tag)' class=\(best.leafClass)")
                return best.tag
            }
        }

        // Phase 2 — probe. Split TLS-probable from UDP-only first; only
        // the TLS set carries useful health signal.
        let probable = alivePool.filter { $0.tcpProbable }
        let unprobable = alivePool.filter { !$0.tcpProbable }

        if probable.isEmpty {
            // Pool is all UDP-only (TUIC). Can't probe — return the first
            // by tag for determinism. The user explicitly drilling into
            // a TUIC leaf should land here.
            let pick = unprobable.sorted(by: { $0.tag < $1.tag }).first?.tag
            log("pickBest: udp-only pool, picking '\(pick ?? "—")'")
            return pick
        }

        let results = await probeConcurrent(probable)
        for r in results {
            store.update(tag: r.tag, latencyMs: r.latencyMs, success: r.success, at: r.probedAt)
        }

        let resultByTag = Dictionary(uniqueKeysWithValues: results.map { ($0.tag, $0) })
        let liveCands = probable.filter { resultByTag[$0.tag]?.success == true }
        if let best = Self.cascadePick(
            liveCands,
            latencyByTag: { resultByTag[$0]?.latencyMs },
            demoteClasses: demoteClasses
        ) {
            let ms = resultByTag[best.tag]?.latencyMs ?? 0
            log("pickBest: probed winner='\(best.tag)' \(ms)ms class=\(best.leafClass) (out of \(results.count))")
            return best.tag
        }

        // All TCP-probable candidates failed. Try a UDP-only as a graceful
        // fallback — it might still work even if our TCP probe couldn't
        // reach the same host. (Reality blocks TCP but TUIC lives.)
        if let udp = unprobable.first {
            log("pickBest: all TCP probes failed, falling back to UDP '\(udp.tag)'")
            return udp.tag
        }

        // Last resort. Better to give the extension something to try than
        // refuse to connect.
        let last = probable.first?.tag
        log("pickBest: everything failed, returning '\(last ?? "—")' anyway")
        return last
    }

    /// Cascade selection: walk classes in priority order
    /// (direct → relay → bypass), and within a class pick the lowest-
    /// latency candidate. Returns nil if `pool` is empty.
    ///
    /// `latencyByTag` returns the measured latency for a tag, or nil if
    /// the candidate has no successful measurement (caller should pre-
    /// filter to only live candidates).
    ///
    /// Why cascade and not pure latency: relay candidates (`*-via-msk`)
    /// have artificially low TCP/TLS first-hop RTT because the MSK relay
    /// is geographically closer than the actual exit. End-to-end latency
    /// through a relay is strictly higher than through a working direct
    /// path (extra hop, +RTT, +CPU on relay). The TLS probe's job is to
    /// answer "does this class actually work" — once we know direct works,
    /// we use it regardless of probe latency. Industry pattern (Tailscale
    /// DERP, Cloudflare WARP, ProtonVPN Smart Protocol).
    static func cascadePick(
        _ pool: [LeafCandidate],
        latencyByTag: (String) -> Int?,
        demoteClasses: Set<LeafClass> = []
    ) -> LeafCandidate? {
        // Build-39: callers can pass classes that should be SKIPPED in
        // priority order. We use this to demote `.direct` on networks
        // where prior history shows direct never works (RU LTE: TCP probe
        // is a false-positive, real VLESS Reality data dies post-handshake).
        // Skipping `.direct` makes cascade fall through to `.relay` from
        // the very first connect on this network — zero stall, zero
        // recovery delay.
        for cls: LeafClass in [.direct, .relay, .bypass] {
            if demoteClasses.contains(cls) { continue }
            let inClass = pool.filter { $0.leafClass == cls }
            let best = inClass.min(by: { lhs, rhs in
                let l = latencyByTag(lhs.tag) ?? .max
                let r = latencyByTag(rhs.tag) ?? .max
                if l != r { return l < r }
                return lhs.tag < rhs.tag
            })
            if let best, latencyByTag(best.tag) != nil {
                return best
            }
        }
        // All non-demoted classes empty/unmeasured → permit demoted classes
        // as last resort. Better to give the user SOMETHING that probably
        // works than refuse to connect.
        if !demoteClasses.isEmpty {
            for cls: LeafClass in [.direct, .relay, .bypass] {
                guard demoteClasses.contains(cls) else { continue }
                let inClass = pool.filter { $0.leafClass == cls }
                let best = inClass.min(by: { lhs, rhs in
                    let l = latencyByTag(lhs.tag) ?? .max
                    let r = latencyByTag(rhs.tag) ?? .max
                    if l != r { return l < r }
                    return lhs.tag < rhs.tag
                })
                if let best, latencyByTag(best.tag) != nil {
                    return best
                }
            }
        }
        return nil
    }

    /// Legacy comparator — preserved for tests; new code uses `cascadePick`.
    static func preferDirect(
        lhs: (cand: LeafCandidate, latencyMs: Int),
        rhs: (cand: LeafCandidate, latencyMs: Int)
    ) -> Bool {
        if lhs.cand.leafClass != rhs.cand.leafClass {
            return lhs.cand.leafClass < rhs.cand.leafClass
        }
        if lhs.latencyMs != rhs.latencyMs {
            return lhs.latencyMs < rhs.latencyMs
        }
        return lhs.cand.tag < rhs.cand.tag
    }

    private func probeConcurrent(_ candidates: [LeafCandidate]) async -> [LeafProbeResult] {
        await withTaskGroup(of: LeafProbeResult.self) { group in
            for c in candidates {
                let probe = self.probeFn
                group.addTask {
                    await probe(c, Self.defaultProbeTimeout)
                }
            }
            var out: [LeafProbeResult] = []
            for await r in group { out.append(r) }
            return out
        }
    }

    // MARK: - Default probe (NWConnection TCP)

    /// Default TCP probe. Replaceable in tests by injecting a different
    /// `probeFn`. Performs only TCP handshake (no TLS) — fast (~50-200ms),
    /// enough signal for "is this server reachable at all". Cascade by
    /// `LeafClass` is what gives the picker its accuracy: even if TCP
    /// probe is a false-positive on a Reality-blocked path, the cascade
    /// keeps direct as the priority and TrafficHealthMonitor catches any
    /// post-connect stalls and triggers fallback to relay.
    @Sendable
    static func tcpProbe(_ candidate: LeafCandidate, timeout: TimeInterval) async -> LeafProbeResult {
        let start = Date()
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let host = NWEndpoint.Host(candidate.host)
            let port = NWEndpoint.Port(integerLiteral: UInt16(candidate.port))
            let connection = NWConnection(host: host, port: port, using: .tcp)

            let oneShot = ProbeOneShot()
            let queue = DispatchQueue(label: "PathPicker.probe.\(candidate.tag)")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                guard oneShot.tryResume() else { return }
                connection.cancel()
                continuation.resume(returning: false)
            }
            timer.resume()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard oneShot.tryResume() else { return }
                    timer.cancel()
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    guard oneShot.tryResume() else { return }
                    timer.cancel()
                    connection.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        return LeafProbeResult(
            tag: candidate.tag,
            latencyMs: success ? max(elapsedMs, 1) : 0,
            success: success,
            probedAt: Date()
        )
    }

}

// MARK: - Value types

/// One probe-able leaf endpoint. Constructed from the parsed sing-box
/// config (see `ConfigStore.parseServersFromConfig`).
public struct LeafCandidate: Sendable, Equatable, Hashable {
    public let tag: String       // sing-box outbound tag, e.g. "de-via-msk"
    public let host: String
    public let port: Int
    public let type: String      // "vless" | "hysteria2" | "tuic" | ...

    public init(tag: String, host: String, port: Int, type: String) {
        self.tag = tag
        self.host = host
        self.port = port
        self.type = type
    }

    /// True iff a TCP probe gives a meaningful health signal. UDP-only
    /// transports (tuic, native hysteria2 UDP) don't pass — server doesn't
    /// listen on TCP, so probe always times out even when the leaf is up.
    /// We treat them as unprobeable and pick by deterministic order.
    public var tcpProbable: Bool {
        Self.tcpProbableTypes.contains(type)
    }

    public static let tcpProbableTypes: Set<String> = [
        "vless", "trojan", "vmess", "shadowsocks", "shadowtls"
    ]

    /// Country segment of the leaf tag. Backend tag format is
    /// `{cc}-{kind}-{key}` for standard exits and `ru-spb-{key}` for the
    /// whitelist-bypass group. We surface `ru-spb` as a single "country"
    /// because the iOS picker treats it as one logical entry.
    public var country: String {
        if tag.hasPrefix("ru-spb-") { return "ru-spb" }
        return tag.split(separator: "-").first.map(String.init) ?? ""
    }

    /// True for "first hop = exit server" leaves (`{cc}-direct-...`).
    /// Kept for backward compatibility; new code should use `leafClass`.
    public var isDirect: Bool {
        return leafClass == .direct
    }

    /// Cascade tier for leaf selection. Tiers are tried in order
    /// (direct → relay → bypass), and within a tier, lowest-latency wins.
    /// Matches the industry pattern (Tailscale: direct → DERP relay;
    /// Cloudflare WARP: direct → MASQUE relay; user mental model: try
    /// direct first, fall back to MSK relay, last resort SPB whitelist).
    ///
    /// The cascade is enforced ONLY when probes can distinguish the
    /// classes — that's why we use TLS probe (not TCP), so that a direct
    /// path which is TCP-reachable but Reality-broken (RKN packet-level
    /// block after TLS) is correctly classified as failed.
    public var leafClass: LeafClass {
        if tag.hasPrefix("ru-spb-") { return .bypass }
        if tag.contains("-via-") { return .relay }
        return .direct
    }
}

/// Cascade tier ordering for `LeafCandidate`. Lower rawValue = higher priority.
public enum LeafClass: Int, Sendable, Comparable {
    case direct = 0   // {cc}-direct-{srv}, {cc}-h2-{srv}, {cc}-tuic-{srv}
    case relay  = 1   // {cc}-via-msk
    case bypass = 2   // ru-spb-{srv} (whitelist bypass, last resort)

    public static func < (lhs: LeafClass, rhs: LeafClass) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Result of a single probe. `success=false` means we couldn't establish a
/// TCP connection within the timeout (or the candidate was unprobable).
public struct LeafProbeResult: Sendable, Equatable {
    public let tag: String
    public let latencyMs: Int
    public let success: Bool
    public let probedAt: Date

    public init(tag: String, latencyMs: Int, success: Bool, probedAt: Date) {
        self.tag = tag
        self.latencyMs = latencyMs
        self.success = success
        self.probedAt = probedAt
    }
}

private final class ProbeOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func tryResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
