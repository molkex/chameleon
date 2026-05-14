import Foundation

/// Pure decision cores extracted from `APIClient` so the branchy logic
/// (HTTP-status classification, the hedged-race planning rules, the
/// idempotency-key decision) is unit-testable without a live network.
///
/// Behaviour-preserving: every function here mirrors an inline conditional
/// that previously lived in `APIClient` / `dataWithFallback`. The live
/// `URLSession` / `DirectConnection` calls stay in `APIClient` and remain
/// on-device-verified.
enum APIResponseLogic {

    // MARK: - HTTP status classification

    /// How a per-endpoint handler should react to an HTTP status code.
    enum StatusOutcome: Equatable {
        case ok
        case unauthorized
        case serverError(Int)
        /// Endpoint-specific code that the generic mapper doesn't own
        /// (e.g. `activateCode` treats 404 as `.invalidCode`).
        case special(Int)
    }

    /// The classification shared by the "401 → unauthorized, non-2xx →
    /// serverError" handlers (`registerDevice`, `signInWith*`,
    /// `verifyMagicLink`, `fetchConfig`, …).
    ///
    /// `successCodes` lets a caller widen what counts as OK — `registerDevice`
    /// accepts 200 **and** 201, `deleteAccount` accepts 200 **and** 204.
    static func classify(
        status: Int,
        successCodes: Set<Int> = [200]
    ) -> StatusOutcome {
        if successCodes.contains(status) { return .ok }
        if status == 401 { return .unauthorized }
        return .serverError(status)
    }

    /// `activateCode`'s status table: 200 → ok, 404 → invalid code, else
    /// serverError. The 404 surfaces as `.special(404)` so the caller can
    /// map it to `APIError.invalidCode`.
    static func classifyActivateCode(status: Int) -> StatusOutcome {
        switch status {
        case 200: return .ok
        case 404: return .special(404)
        default:  return .serverError(status)
        }
    }

    /// `requestMagicLink`'s status table: 204/200 → ok, 429 → rate-limited
    /// (surfaced as `.special(429)`), else serverError.
    static func classifyMagicLinkRequest(status: Int) -> StatusOutcome {
        switch status {
        case 200, 204: return .ok
        case 429:      return .special(429)
        default:       return .serverError(status)
        }
    }

    // MARK: - Hedged-race leg rules

    /// A race leg whose response carries a 5xx is discarded (`return nil`)
    /// rather than accepted as the winner — a transient backend error on
    /// one leg shouldn't beat a slower-but-correct leg. 4xx is *not*
    /// discarded: it propagates so callers like `fetchAndSaveConfig`
    /// (404 → re-register) can react.
    static func legShouldBeDiscarded(status: Int) -> Bool {
        status >= 500
    }

    /// Whether `dataWithFallback` should mint and attach an `Idempotency-Key`.
    /// Only mutating methods that don't already carry one — GET/HEAD are
    /// safe to replay, and a caller-supplied key is respected.
    static func shouldAttachIdempotencyKey(method: String, existingKey: String?) -> Bool {
        guard existingKey == nil else { return false }
        let m = method.uppercased()
        return m != "GET" && m != "HEAD"
    }

    /// The direct-IP pool to race for the current region. RU mobile carriers
    /// block OVH Frankfurt (162.19.242.30) at the ASN level, so for RU users
    /// the DE legs are dropped — they'd only sit at their full timeout and
    /// delay the race. Everyone else races the full pool.
    static func raceIPs(allIPs: [String], isRURegion: Bool) -> [String] {
        guard isRURegion else { return allIPs }
        return allIPs.filter { $0 != "162.19.242.30" }
    }

    /// Hedged-dispatch stagger (Dean & Barroso, "The Tail at Scale").
    /// Leg `legIndex` waits `legIndex * 250ms` before doing real work, so a
    /// fast primary (legIndex 0) saves the rest from ever starting.
    static func staggerMilliseconds(legIndex: Int) -> Int {
        legIndex * 250
    }

    /// Start index for the HTTP:80 ladder — it continues the hedge ladder
    /// after the primary (index 0) and the `raceIPCount` direct legs.
    static func httpLegStartIndex(raceIPCount: Int) -> Int {
        1 + raceIPCount
    }

    /// The HTTP:80 fallback ladder only runs for unauthenticated requests —
    /// we never put a JWT in cleartext on the wire. Authenticated requests
    /// still get the primary + direct (HTTPS) legs.
    static func shouldRunHTTPFallback(isAuthenticated: Bool) -> Bool {
        !isAuthenticated
    }

    // MARK: - Config response sanity

    /// `fetchConfig` accepts a 200 body only if it's a real sing-box config.
    /// A backend error JSON disguised as `200 OK` (has `"error"`, lacks
    /// `"outbounds"`) is rejected. Returns true when the body should be
    /// treated as a server error rather than a valid config.
    static func configBodyIsDisguisedError(_ body: String) -> Bool {
        body.contains("\"error\"") && !body.contains("\"outbounds\"")
    }

    /// Build the request path (with query) used as the `:authority`/path on
    /// the direct-IP and HTTP:80 legs. Empty path normalises to "/".
    static func requestPath(path: String, query: String?) -> String {
        if let query, !query.isEmpty { return "\(path)?\(query)" }
        return path.isEmpty ? "/" : path
    }
}
