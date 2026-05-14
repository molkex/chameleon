import Foundation

/// Pure decision cores extracted from the Cloudflare-RU connectivity
/// path — `LegRaceProbe`, `NetworkFingerprint` — so the branchy
/// winner-selection, fallback-ordering and fingerprint-derivation logic
/// is unit-testable without `NWConnection` / `NWPathMonitor` /
/// `NEHotspotNetwork` live I/O. The probe / path-snapshot socket parts
/// stay on-device-verified; only the pure routing decisions move here.
///
/// Every function is a behaviour-preserving extract: `LegRaceProbe.race`
/// and `NetworkFingerprint.current` keep their async socket plumbing and
/// just route through these.

// MARK: - LegRaceProbe — race planning + winner selection

/// The pure planning + result-shaping logic of `LegRaceProbe.race`,
/// lifted out of the async socket code so the branchy ordering
/// (preferred fast-path → full pool → empty cases) can be pinned.
enum LegRacePlan {

    /// What `race` does *before* it touches a socket. Mirrors the
    /// guard-chain at the top of `LegRaceProbe.race`.
    enum Step: Equatable {
        /// `candidates` was empty — return a nil-winner result immediately.
        case noCandidates
        /// `preferred` matched a candidate — probe just that one with a
        /// tight `timeout` first; if it succeeds it's the winner.
        case tryPreferredFirst(tag: String, timeout: TimeInterval)
        /// No preferred fast-path applicable — race `pool` concurrently.
        case racePool(poolTags: [String])
    }

    /// The 1.2 s tight timeout the preferred-leg fast-path uses — a
    /// remembered-good leg that still works should short-circuit a full
    /// race in well under the warm-reconnect budget.
    static let preferredProbeTimeout: TimeInterval = 1.2

    /// Decide the first step of a race given the candidate tags and an
    /// optional preferred (remembered-good) tag. Pure mirror of the
    /// `race` guard-chain — does not probe anything.
    static func firstStep(candidateTags: [String], preferred: String?) -> Step {
        guard !candidateTags.isEmpty else { return .noCandidates }
        if let preferred, candidateTags.contains(preferred) {
            return .tryPreferredFirst(tag: preferred, timeout: preferredProbeTimeout)
        }
        return .racePool(poolTags: candidateTags.filter { $0 != preferred })
    }

    /// The pool raced after a preferred fast-path *misses* (or when there
    /// was no preferred): all candidates except `preferred`, in order.
    /// Mirrors `let pool = candidates.filter { $0.tag != preferred }`.
    static func poolAfterPreferredMiss(candidateTags: [String], preferred: String?) -> [String] {
        candidateTags.filter { $0 != preferred }
    }
}

// MARK: - NetworkFingerprint — fingerprint derivation

/// The pure fingerprint-string derivation of `NetworkFingerprint.current`,
/// lifted out of the `NWPathMonitor` / `NEHotspotNetwork` plumbing.
enum NetworkFingerprintLogic {

    /// Derive the coarse network fingerprint from an already-snapshotted
    /// path. Mirrors the `if path.usesInterfaceType(...)` ladder in
    /// `NetworkFingerprint.current`:
    ///
    /// - WiFi with a known SSID → `"wifi:<ssid>"`
    /// - WiFi without SSID      → `"wifi:unknown"`
    /// - Cellular               → `"cellular"`
    /// - Wired ethernet         → `"ethernet"`
    /// - anything else          → nil (never-seen network)
    ///
    /// WiFi is checked before cellular before ethernet — exactly the
    /// original branch order, which matters when a path reports more
    /// than one usable interface type.
    static func fingerprint(
        usesWifi: Bool,
        wifiSSID: String?,
        usesCellular: Bool,
        usesWiredEthernet: Bool
    ) -> String? {
        if usesWifi {
            if let ssid = wifiSSID {
                return "wifi:\(ssid)"
            }
            return "wifi:unknown"
        }
        if usesCellular {
            return "cellular"
        }
        if usesWiredEthernet {
            return "ethernet"
        }
        return nil
    }
}
