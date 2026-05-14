import Foundation
import Network

/// Pre-connect TCP race against the candidate VPN leg endpoints. Run BEFORE
/// `startTunnel` to discover which leg the OS can actually reach right now —
/// crucial on networks that block specific ASNs (e.g. RU LTE blocking OVH
/// while MSK relays still resolve & handshake fine).
///
/// Why pre-connect, not in-tunnel:
/// - Sing-box's urltest probes via TCP+TLS HEAD *through the leg's
///   transport*. On a partially-broken path (TLS handshake passes, data
///   path drops) the probe falsely succeeds and urltest picks a leg that
///   silently fails for real traffic. By probing TCP directly from the OS
///   stack we get a yes/no answer about reachability the same way the
///   user's browser would experience it.
/// - The race result feeds the config patcher: the winning leaf's tag is
///   pushed to position 0 of the country urltest's `outbounds` list.
///   Sing-box's URLTestGroup.Select returns that leg until its own
///   internal probe completes.
///
/// Protocol scope: TCP only. VLESS Reality and Hysteria2-as-h2 over TLS
/// are TCP. Pure UDP protocols (TUIC, native Hysteria2 UDP) are excluded
/// from the race — UDP probes don't get reliable handshake feedback when
/// the destination doesn't speak the wire protocol. They remain selectable
/// via the urltest fallback path.
struct LegRaceProbe {
    struct Candidate: Equatable {
        let tag: String      // sing-box outbound tag, e.g. "de-via-msk"
        let host: String     // server host or IP
        let port: Int
    }

    struct Result {
        let winnerTag: String?
        let probedTags: [String]
        let elapsedSeconds: Double
    }

    let perCandidateTimeout: TimeInterval
    let totalTimeout: TimeInterval

    init(perCandidateTimeout: TimeInterval = 3.0, totalTimeout: TimeInterval = 4.0) {
        self.perCandidateTimeout = perCandidateTimeout
        self.totalTimeout = totalTimeout
    }

    /// Race the given candidates in parallel. The first to complete a TCP
    /// handshake wins. If `preferred` is provided and it appears in
    /// `candidates`, it is given a 1-second head-start with a 1.2s timeout
    /// — this lets a remembered-good leg short-circuit a full race when
    /// it still works, matching the perceived UX of "warm reconnect ≤ 1s".
    func race(candidates: [Candidate], preferred: String? = nil) async -> Result {
        let start = Date()
        // Pure planning (ordering / fast-path / empty cases) lives in
        // `LegRacePlan` so it's unit-testable; this method keeps the
        // socket probing.
        let step = LegRacePlan.firstStep(candidateTags: candidates.map(\.tag), preferred: preferred)
        guard step != .noCandidates else {
            return Result(winnerTag: nil, probedTags: [], elapsedSeconds: 0)
        }

        // Fast path — try the remembered leg first with a tight timeout.
        if case .tryPreferredFirst(let tag, let timeout) = step,
           let preferredCand = candidates.first(where: { $0.tag == tag }) {
            if await probe(preferredCand, timeout: timeout) {
                return Result(
                    winnerTag: preferredCand.tag,
                    probedTags: [preferredCand.tag],
                    elapsedSeconds: Date().timeIntervalSince(start)
                )
            }
        }

        // Full race over remaining candidates — every candidate whose
        // tag isn't `preferred`, in original order (mirrors
        // `LegRacePlan.poolAfterPreferredMiss`).
        let pool = candidates.filter { $0.tag != preferred }
        guard !pool.isEmpty else {
            return Result(winnerTag: nil, probedTags: candidates.map(\.tag), elapsedSeconds: Date().timeIntervalSince(start))
        }

        let winner = await raceConcurrent(pool, perCandidateTimeout: perCandidateTimeout, totalTimeout: totalTimeout)
        return Result(
            winnerTag: winner,
            probedTags: candidates.map(\.tag),
            elapsedSeconds: Date().timeIntervalSince(start)
        )
    }

    private func raceConcurrent(
        _ pool: [Candidate],
        perCandidateTimeout: TimeInterval,
        totalTimeout: TimeInterval
    ) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            for candidate in pool {
                group.addTask {
                    if await probe(candidate, timeout: perCandidateTimeout) {
                        return candidate.tag
                    }
                    return nil
                }
            }
            // Total cap: even if every probe hangs, we don't block startup.
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(totalTimeout * 1_000_000_000))
                return nil
            }
            for await result in group {
                if let tag = result {
                    group.cancelAll()
                    return tag
                }
            }
            return nil
        }
    }

    /// Single-shot TCP-handshake probe. Returns true iff `.ready` was
    /// reached within the timeout. We use plain TCP (no TLS) — TLS doesn't
    /// add information for our blocked-vs-reachable check and roughly
    /// doubles handshake time on cellular.
    private func probe(_ candidate: Candidate, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let host = NWEndpoint.Host(candidate.host)
            let port = NWEndpoint.Port(integerLiteral: UInt16(candidate.port))
            let connection = NWConnection(host: host, port: port, using: .tcp)

            let store = ProbeOneShot()
            let queue = DispatchQueue(label: "LegRaceProbe.\(candidate.tag)")

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                guard store.tryResume() else { return }
                connection.cancel()
                continuation.resume(returning: false)
            }
            timer.resume()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard store.tryResume() else { return }
                    timer.cancel()
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    guard store.tryResume() else { return }
                    timer.cancel()
                    connection.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
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

/// Extracts `(tag, host, port)` triples from the sing-box config JSON for
/// a given list of leg tags. Skips outbounds whose protocol we don't probe
/// (tuic, anything UDP-only).
enum LegRaceConfigParser {
    /// Set of outbound `type` values we treat as TCP-probable.
    static let tcpProbableTypes: Set<String> = ["vless", "trojan", "vmess", "shadowsocks", "shadowtls"]

    static func candidates(forLegTags tags: [String], inConfigJSON config: [String: Any]) -> [LegRaceProbe.Candidate] {
        guard let outbounds = config["outbounds"] as? [[String: Any]] else { return [] }
        let byTag: [String: [String: Any]] = Dictionary(uniqueKeysWithValues: outbounds.compactMap { ob in
            guard let tag = ob["tag"] as? String else { return nil }
            return (tag, ob)
        })
        var result: [LegRaceProbe.Candidate] = []
        for tag in tags {
            guard let ob = byTag[tag] else { continue }
            guard let type = ob["type"] as? String, tcpProbableTypes.contains(type) else { continue }
            guard let server = ob["server"] as? String,
                  let port = ob["server_port"] as? Int else { continue }
            result.append(LegRaceProbe.Candidate(tag: tag, host: server, port: port))
        }
        return result
    }
}
