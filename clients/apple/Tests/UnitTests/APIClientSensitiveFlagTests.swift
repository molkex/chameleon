import XCTest
@testable import MadFrogVPN

/// Regression guard for the hedged-race leg-selection invariants in
/// `APIClient.dataWithFallback`. The decision lives in the pure helper
/// `APIClient.raceLegPlan(sensitive:isAuthenticated:region:availableIPs:)`
/// (build-88 testability extract); this file pins down the three
/// audit-derived invariants:
///
///   * H-001: sensitive=true MUST skip the HTTP:80 fallback legs — refresh
///     tokens, magic tokens and signed JWS bodies must never traverse
///     cleartext.
///   * H-002 (CLOSED by H-002b, build 89): sensitive=true MAY now use the
///     direct-IP TLS legs. `DirectConnection` validates the server cert chain
///     against the SNI (SecPolicyCreateSSL + SecTrustEvaluateWithError), and
///     NL:443 / SPB:443 present a valid Let's Encrypt cert for
///     api.madfrog.online, so the direct-IP path is MITM-safe. Auth racing
///     these IPs is the documented "never trust a single path" resilience
///     (AUTH-RKN-DIRECT-IP, 2026-06-09) — it fixes "не получилось войти" when
///     the primary host stalls (the Cloudflare-SNI-filter class).
///   * RU-region quirk: for RU clients, the OVH Frankfurt IP
///     (`162.19.242.30`) is dropped from BOTH direct and HTTP:80 lists
///     because RU mobile carriers ASN-block it and the 6s timeout would
///     otherwise serialise the race.
@MainActor
final class APIClientSensitiveFlagTests: XCTestCase {

    private let allIPs = ["1.1.1.1", "162.19.242.30", "147.45.252.234"]

    // MARK: - H-001 (cleartext) holds; H-002 closed by H-002b (cert-validated direct-IP)

    func testSensitiveUnauthenticatedRURegionKeepsDirectButNoHTTP80() {
        let plan = APIClient.raceLegPlan(
            sensitive: true,
            isAuthenticated: false,
            region: "RU",
            availableIPs: allIPs
        )
        XCTAssertTrue(plan.primary, "primary HTTPS leg always fires")
        XCTAssertEqual(plan.directIPs, ["1.1.1.1", "147.45.252.234"],
                       "H-002b: cert-validated direct-IP TLS legs ARE used for sensitive (RU drops OVH)")
        XCTAssertEqual(plan.httpEightyIPs, [], "H-001: never HTTP:80 cleartext for sensitive")
    }

    func testSensitiveAuthenticatedKeepsDirectButNoHTTP80() {
        let plan = APIClient.raceLegPlan(
            sensitive: true,
            isAuthenticated: true,
            region: "US",
            availableIPs: allIPs
        )
        // sensitive uses the cert-validated direct-IP legs (H-002b) but the
        // HTTP:80 cleartext legs stay off (H-001) regardless of the Bearer.
        XCTAssertEqual(plan.directIPs, allIPs, "non-RU sensitive keeps all direct-IP TLS legs")
        XCTAssertEqual(plan.httpEightyIPs, [], "H-001: still no HTTP:80 for sensitive")
    }

    // MARK: - Authenticated callers skip HTTP:80 (no Bearer in cleartext)

    func testAuthenticatedNonRUKeepsDirectButSkipsHTTPEighty() {
        let plan = APIClient.raceLegPlan(
            sensitive: false,
            isAuthenticated: true,
            region: "US",
            availableIPs: allIPs
        )
        XCTAssertEqual(plan.directIPs, allIPs, "non-RU keeps all direct legs")
        XCTAssertEqual(plan.httpEightyIPs, [],
                       "authenticated callers never see HTTP:80 (Bearer would be cleartext)")
    }

    // MARK: - Unauthenticated / non-sensitive — full ladder

    func testUnauthenticatedNonRUFullLadder() {
        let plan = APIClient.raceLegPlan(
            sensitive: false,
            isAuthenticated: false,
            region: "US",
            availableIPs: allIPs
        )
        XCTAssertEqual(plan.directIPs, allIPs)
        XCTAssertEqual(plan.httpEightyIPs, allIPs,
                       "unauthenticated GET allows the full HTTP:80 hedge")
    }

    // MARK: - RU region filters out OVH Frankfurt from both lists

    func testRURegionDropsOVHFrankfurtFromBothLists() {
        let plan = APIClient.raceLegPlan(
            sensitive: false,
            isAuthenticated: false,
            region: "RU",
            availableIPs: allIPs
        )
        XCTAssertEqual(plan.directIPs, ["1.1.1.1", "147.45.252.234"],
                       "RU drops OVH Frankfurt 162.19.242.30 from direct")
        XCTAssertEqual(plan.httpEightyIPs, ["1.1.1.1", "147.45.252.234"],
                       "RU filter applies to HTTP:80 too (httpEighty derives from directIPs)")
    }

    // MARK: - Empty available list — no fabricated legs

    func testEmptyAvailableIPsYieldsEmptyLists() {
        for sens in [true, false] {
            for auth in [true, false] {
                for region in ["RU", "US", nil] as [String?] {
                    let plan = APIClient.raceLegPlan(
                        sensitive: sens,
                        isAuthenticated: auth,
                        region: region,
                        availableIPs: []
                    )
                    XCTAssertEqual(plan.directIPs, [],
                                   "empty input → empty direct (sens=\(sens) auth=\(auth) region=\(region ?? "nil"))")
                    XCTAssertEqual(plan.httpEightyIPs, [],
                                   "empty input → empty HTTP:80 (sens=\(sens) auth=\(auth) region=\(region ?? "nil"))")
                    XCTAssertTrue(plan.primary, "primary always fires")
                }
            }
        }
    }

    // MARK: - Nil region treated as non-RU

    func testNilRegionTreatedAsNonRU() {
        let plan = APIClient.raceLegPlan(
            sensitive: false,
            isAuthenticated: false,
            region: nil,
            availableIPs: allIPs
        )
        XCTAssertEqual(plan.directIPs, allIPs, "nil region keeps OVH Frankfurt")
    }

    // MARK: - Per-endpoint regression guard
    //
    // Security-review 2026-05-27 followup: the helper above is well-tested,
    // but a future developer could still forget `sensitive: true` at a new
    // call site. This is documentation-as-test — it pins down which
    // endpoint URLs MUST be called sensitive end-to-end. When a new
    // sensitive endpoint is added, append its path here and grep for the
    // path in `APIClient.swift` to confirm the `sensitive: true` parameter
    // is present on the `dataWithFallback` call.

    /// Endpoints that handle credentials (refresh tokens, magic-link tokens,
    /// signed JWS receipts, Apple/Google identity tokens, registration
    /// secrets) and therefore MUST use `sensitive: true`. Every entry here
    /// represents a real call site verified against `APIClient.swift` as of
    /// build 89. If a path is added/renamed, update this list.
    static let sensitiveEndpointPaths: [String] = [
        "/api/mobile/auth/register",
        "/api/mobile/auth/apple",
        "/api/mobile/auth/google",
        "/api/mobile/auth/magic/request",
        "/api/mobile/auth/magic/verify",
        "/api/mobile/auth/refresh",
        "/api/mobile/subscription/verify",
    ]

    func testSensitiveEndpointPathsKeepDirectTLSButNeverHTTP80() {
        // Every sensitive endpoint feeds the same `raceLegPlan` with
        // `sensitive: true`. The combinations below cover the matrix of
        // (RU vs non-RU, authenticated vs not). Post-H-002b the invariant is:
        // direct-IP TLS legs ARE raced (cert-validated, MITM-safe), but the
        // HTTP:80 cleartext legs are NEVER used for a credential payload.
        for path in Self.sensitiveEndpointPaths {
            for region in ["RU", "US"] as [String?] {
                for auth in [true, false] {
                    let plan = APIClient.raceLegPlan(
                        sensitive: true,
                        isAuthenticated: auth,
                        region: region,
                        availableIPs: allIPs
                    )
                    XCTAssertFalse(plan.directIPs.isEmpty,
                        "sensitive endpoint \(path) SHOULD race cert-validated direct-IP (auth=\(auth) region=\(region ?? "nil"))")
                    XCTAssertEqual(plan.httpEightyIPs, [],
                        "H-001: sensitive endpoint \(path) must NEVER race HTTP:80 (auth=\(auth) region=\(region ?? "nil"))")
                    XCTAssertTrue(plan.primary,
                        "sensitive endpoint \(path) still uses the primary HTTPS leg")
                }
            }
        }
    }
}
