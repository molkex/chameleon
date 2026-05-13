import Foundation

/// In-memory penalty record for outbounds that just got us throttled.
///
/// Phase 1.D (build 63+). Closes the throttle→fallback→same-outbound loop:
///
/// 1. Field log 2026-05-13 23:33 LTE on build 61: nl-via-msk throttles
///    at ~90 s; TunnelStallProbe detects, fires fallback in 9 ms — fine.
/// 2. Fallback calls `LibboxCommandClient.urlTest(group)` which re-probes
///    every member. The throttled leaf passes the small probe (DPI bulk-
///    throttle signature only trips on real flows) and gets re-elected.
/// 3. User feels another stall within seconds; repeats every ~90 s.
///
/// This store records `outbound tag → penalty-expires-at`. The probe's
/// fallback path consults `firstNonPenalised(among:)` to pick an
/// alternative urltest member and pins it via `selectOutbound(group,
/// outbound)` — bypassing urltest's small-probe re-election entirely.
/// After the penalty window expires the entry is reaped automatically;
/// urltest then resumes its normal cycle on the next interval.
///
/// All access on a serial queue so the probe (its own task) and the
/// CommandClient handler (libbox thread) can read/write concurrently.
final class OutboundPenaltyStore: @unchecked Sendable {

    /// Per-outbound penalty window. 60 s matches the rough DPI throttle
    /// memory window observed in field — by then the throttle on the
    /// retired outbound has typically lifted (DPI tracks per-flow, not
    /// per-leaf). Tuneable; field-log evidence wins over guesses.
    static let defaultWindow: TimeInterval = 60

    private let queue = DispatchQueue(label: "outbound.penalty.store", attributes: [])
    private var penalties: [String: Date] = [:]

    /// Mark an outbound as penalised for `window` seconds. If the outbound
    /// already has a longer penalty, keeps the longer expiry (don't
    /// shorten a penalty by re-marking).
    func penalise(_ outboundTag: String, window: TimeInterval = OutboundPenaltyStore.defaultWindow) {
        let expiresAt = Date().addingTimeInterval(window)
        queue.sync {
            if let existing = penalties[outboundTag], existing > expiresAt {
                return
            }
            penalties[outboundTag] = expiresAt
        }
    }

    /// True if the tag has an active penalty record.
    func isPenalised(_ outboundTag: String) -> Bool {
        queue.sync {
            guard let expiresAt = penalties[outboundTag] else { return false }
            if expiresAt <= Date() {
                penalties.removeValue(forKey: outboundTag)
                return false
            }
            return true
        }
    }

    /// First member of `candidates` that has no active penalty. Returns
    /// nil if EVERY candidate is currently penalised — caller should fall
    /// back to the old urlTest nudge in that case (something is better
    /// than nothing).
    func firstNonPenalised(among candidates: [String]) -> String? {
        queue.sync {
            let now = Date()
            penalties = penalties.filter { $0.value > now }
            return candidates.first { penalties[$0] == nil }
        }
    }

    /// Snapshot of current penalty state — for tests and field-log
    /// diagnostics. Filters expired entries on read.
    func snapshot() -> [String: Date] {
        queue.sync {
            let now = Date()
            penalties = penalties.filter { $0.value > now }
            return penalties
        }
    }

    /// Clear all penalties. Wired to tunnel stop so a new session starts
    /// with a clean slate.
    func reset() {
        queue.sync { penalties.removeAll() }
    }
}
