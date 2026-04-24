import Foundation
import Network
import Security

/// Out-of-band latency prober for VPN servers.
///
/// Measures raw TCP handshake RTT (SYN → SYN-ACK → ACK) to each server's
/// host:port using `NWConnection`. This runs **outside** the VPN tunnel, so
/// values are available before the user ever connects, and reflect real
/// network distance rather than proxying overhead.
///
/// Results are cached by server tag. Callers observe `results` (on main actor)
/// and re-render when values change.
@MainActor
@Observable
final class PingService {
    /// Ping results keyed by ServerItem.tag. Value is RTT in milliseconds,
    /// or 0 if the probe failed / timed out.
    var results: [String: Int] = [:]

    /// True while at least one probe is in flight.
    var isProbing = false

    private let timeout: TimeInterval = 2.0
    // Bump key when measurement semantics change so cached numbers from old
    // builds (which sometimes got stuck at sub-10ms localhost-relayed values)
    // are dropped and the UI shows real RTT after the next probe.
    // v3: TCP-vs-QUIC split — fake-low values for h2/tuic (TCP SYN hitting
    // closed UDP port, returning RST in <5ms) would otherwise persist.
    // v4: utun-bypass (prohibitedInterfaceTypes .other) — VPN-tainted
    // sub-10ms values from VPN-up measurements would otherwise persist.
    private let cacheKey = "PingService.cache.v4"
    // 24h: latency to a given server barely changes day-to-day, and showing
    // a slightly stale value is way better UX than showing "— ms" while a
    // fresh probe is in flight. Fresh probes run in the background on every
    // server list open and overwrite the stale values.
    private let cacheTTL: TimeInterval = 24 * 60 * 60

    init() {
        loadCache()
    }

    /// Probe all given servers in parallel. Safe to call repeatedly; later
    /// calls overwrite earlier results for the same tag. Each server is
    /// probed over the transport it actually uses — TCP handshake for VLESS,
    /// QUIC Initial for Hysteria2/TUIC. Using the wrong transport (e.g. TCP
    /// SYN against a UDP-only port) yields fake sub-10ms values from local
    /// RST/ICMP rejections, exactly the bug that motivated this split.
    func probe(_ servers: [ServerItem]) async {
        let targets = servers.filter { !$0.host.isEmpty && $0.port > 0 }
        guard !targets.isEmpty else { return }
        isProbing = true
        defer { isProbing = false }

        await withTaskGroup(of: (String, Int).self) { group in
            for server in targets {
                let transport = Self.transportFor(type: server.type)
                group.addTask { [timeout] in
                    let ms: Int
                    switch transport {
                    case .tcp:
                        ms = await Self.measureTCP(host: server.host, port: server.port, timeout: timeout)
                    case .quic:
                        // QUIC needs a bit more budget — Initial + CRYPTO + server's Initial reply
                        // can be >1 RTT, and on high-latency links the first Initial may be lost.
                        // TUIC v5 is especially slow to respond to probes because it negotiates
                        // auth before TLS completes.
                        let quicMs = await Self.measureQUIC(host: server.host, port: server.port, timeout: timeout + 3.0)
                        if quicMs > 0 {
                            ms = quicMs
                        } else {
                            // TUIC in particular silently drops unauthenticated QUIC Initials —
                            // no response means a timeout with no RTT signal. Fall back to
                            // measuring TCP :443 on the same host: it's the same physical
                            // path (our servers run VLESS Reality on :443 alongside the UDP
                            // protocol), so it's a faithful host-level RTT proxy. Better UX
                            // to show the real ~host RTT than a blank pill.
                            ms = await Self.measureTCP(host: server.host, port: 443, timeout: timeout)
                        }
                    }
                    return (server.tag, ms)
                }
            }
            for await (tag, ms) in group {
                // Preserve last-good value on transient failure so the UI
                // doesn't flicker back to "— мс" on a single dropped probe.
                if ms > 0 {
                    results[tag] = ms
                } else if results[tag] == nil {
                    results[tag] = 0
                }
            }
        }
        saveCache()
    }

    /// Transport class for a sing-box outbound type. QUIC-based protocols
    /// (hysteria2, tuic) must be probed with a QUIC Initial; TCP handshake
    /// to their UDP port yields false-positive low values (RST from the
    /// closed TCP port arrives in <10ms regardless of real network RTT).
    ///
    /// Exposed `internal` (not private) so unit tests can assert the
    /// classification without network I/O.
    enum Transport { case tcp, quic }

    nonisolated static func transportFor(type: String) -> Transport {
        switch type.lowercased() {
        case "hysteria2", "tuic":
            return .quic
        default:
            return .tcp
        }
    }

    /// Latency for a given server tag, or 0 if not yet measured / failed.
    func latency(for tag: String) -> Int {
        results[tag] ?? 0
    }

    // MARK: - Persistence

    private struct CacheEntry: Codable {
        let ms: Int
        let ts: TimeInterval
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data)
        else { return }
        let cutoff = Date().timeIntervalSince1970 - cacheTTL
        var fresh: [String: Int] = [:]
        for (tag, entry) in decoded where entry.ts >= cutoff && entry.ms > 0 {
            fresh[tag] = entry.ms
        }
        results = fresh
    }

    private func saveCache() {
        let now = Date().timeIntervalSince1970
        let entries = results.compactMapValues { ms -> CacheEntry? in
            guard ms > 0 else { return nil }
            return CacheEntry(ms: ms, ts: now)
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    // MARK: - Probe implementation

    /// Public one-shot TCP probe. Does not mutate cache or `results`.
    /// Returns RTT in ms, or 0 on timeout/failure. Safe to call from any actor.
    nonisolated static func probeTCP(host: String, port: Int, timeout: TimeInterval = 2.0) async -> Int {
        await measureTCP(host: host, port: port, timeout: timeout)
    }

    /// Measure TCP handshake RTT in milliseconds. Returns 0 on failure/timeout.
    ///
    /// We use `NWConnection` with a dedicated concurrent queue so many probes
    /// can run without blocking each other. The connection is torn down as
    /// soon as it transitions to `.ready` — we don't need to send any bytes.
    nonisolated private static func measureTCP(host: String, port: Int, timeout: TimeInterval) async -> Int {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return 0 }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)

        let params = NWParameters.tcp
        // Bypass the VPN tunnel when measuring — when OUR tunnel is up, the
        // default route points at utun and NWConnection would otherwise go
        // through it, reporting the tunnel's own sub-10ms local loopback
        // latency instead of real internet RTT. `.other` = utun and similar
        // virtual interfaces. Physical paths (wifi/cellular/wired) remain.
        params.prohibitedInterfaceTypes = [.other]

        let connection = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "ping.probe.\(host):\(port)")

        return await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
            let start = DispatchTime.now()
            let finished = ManagedAtomic(false)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if finished.exchange(true) { return }
                    let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                    let ms = Int(elapsed / 1_000_000)
                    connection.cancel()
                    cont.resume(returning: ms)
                case .failed, .cancelled:
                    if finished.exchange(true) { return }
                    connection.cancel()
                    cont.resume(returning: 0)
                default:
                    break
                }
            }

            connection.start(queue: queue)

            // Timeout watchdog.
            queue.asyncAfter(deadline: .now() + timeout) {
                if finished.exchange(true) { return }
                connection.cancel()
                cont.resume(returning: 0)
            }
        }
    }

    /// Measure QUIC handshake RTT in milliseconds. Returns 0 on failure/timeout.
    ///
    /// Used for Hysteria2 and TUIC outbounds which run over QUIC/UDP. A TCP
    /// probe against their UDP port returns fake sub-10ms values from local
    /// port-unreachable rejection — the bug this method avoids.
    ///
    /// Strategy: open an `NWConnection` with `NWProtocolQUIC.Options` and ALPN
    /// "h3", bypass cert verification (our self-signed UDP certs plus
    /// Hysteria2/TUIC wrap their own auth — Network.framework would otherwise
    /// reject the self-signed cert and return `.failed` immediately with no
    /// RTT). Measure time from `.start()` until the connection transitions
    /// out of `.preparing`:
    ///   - `.ready`   → full QUIC + TLS + ALPN negotiated OK.
    ///   - `.failed`  → server replied (handshake rejected, version nego,
    ///                  stateless reset, or ALPN mismatch). Time-to-failure
    ///                  equals the real RTT, which is what we want; we
    ///                  treat it as a valid RTT value.
    /// Timeout (no server response at all) still returns 0.
    nonisolated private static func measureQUIC(host: String, port: Int, timeout: TimeInterval) async -> Int {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return 0 }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)

        // Multiple ALPNs — sing-box Hysteria2 accepts "h3", TUIC v5 inbound
        // defaults to no-ALPN but negotiates "h3" if offered, Xray accepts
        // "h3-29"/"hq-interop". Offering a bundle maximises chance at least
        // one gets a server Initial back, which is all we need for RTT.
        let quicOpts = NWProtocolQUIC.Options(alpn: ["h3", "h3-29", "hq-interop"])
        // Self-signed server certs on Hysteria2/TUIC inbounds — same rationale
        // as the client's `insecure:true` in the sing-box outbound config.
        // Without this block, every probe ends in `.failed` in <10ms from
        // certificate validation failure, producing fake-low RTT identical
        // to the TCP-against-UDP bug we're fixing.
        sec_protocol_options_set_verify_block(
            quicOpts.securityProtocolOptions,
            { _, _, completion in completion(true) },
            DispatchQueue.global(qos: .utility)
        )

        let params = NWParameters(quic: quicOpts)
        // Same utun-bypass rationale as measureTCP: without this, QUIC probes
        // while our VPN is up would tunnel over the already-established sing-box
        // session, reporting single-digit ms loopback RTT.
        params.prohibitedInterfaceTypes = [.other]
        let connection = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "quic.probe.\(host):\(port)")

        return await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
            let start = DispatchTime.now()
            let finished = ManagedAtomic(false)

            // We want the time to the *first* response from the server.
            // `.preparing` fires as soon as we start sending; `.ready`,
            // `.failed`, or `.cancelled` fire after server's reply (or a
            // non-response timeout). Accept .failed as a valid measurement
            // because ALPN rejection and version negotiation still yield a
            // real-RTT server packet.
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed:
                    if finished.exchange(true) { return }
                    let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                    let ms = Int(elapsed / 1_000_000)
                    connection.cancel()
                    // Clamp tiny local-reject artefacts (e.g. immediate ICMP
                    // port unreachable on UDP) to 0 — real QUIC RTT is
                    // always >= single-digit ms plus at least one round trip.
                    cont.resume(returning: ms < 5 ? 0 : ms)
                case .cancelled:
                    if finished.exchange(true) { return }
                    cont.resume(returning: 0)
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                if finished.exchange(true) { return }
                connection.cancel()
                cont.resume(returning: 0)
            }
        }
    }
}

/// Tiny atomic bool wrapper — avoids pulling in swift-atomics just for this.
/// Uses NSLock which is cheap and enough for single-flag coordination.
private final class ManagedAtomic {
    private var value: Bool
    private let lock = NSLock()
    init(_ initial: Bool) { self.value = initial }
    /// Set to true; returns the PREVIOUS value. If true, the caller should bail.
    func exchange(_ newValue: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = newValue
        return old
    }
}
