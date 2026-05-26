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
///   * H-002: sensitive=true MUST skip the direct-IP TLS legs too —
///     `DirectConnection` does not currently validate the server cert
///     chain, so a sensitive payload on a hijacked direct path could be
///     intercepted.
///   * RU-region quirk: for RU clients, the OVH Frankfurt IP
///     (`162.19.242.30`) is dropped from BOTH direct and HTTP:80 lists
///     because RU mobile carriers ASN-block it and the 6s timeout would
///     otherwise serialise the race.
@MainActor
final class APIClientSensitiveFlagTests: XCTestCase {

    private let allIPs = ["1.1.1.1", "162.19.242.30", "147.45.252.234"]

    // MARK: - H-001 / H-002 — sensitive wins over everything

    func testSensitiveUnauthenticatedRURegionStripsAllFallbacks() {
        let plan = APIClient.raceLegPlan(
            sensitive: true,
            isAuthenticated: false,
            region: "RU",
            availableIPs: allIPs
        )
        XCTAssertTrue(plan.primary, "primary HTTPS leg always fires")
        XCTAssertEqual(plan.directIPs, [], "H-002: no direct-IP legs for sensitive")
        XCTAssertEqual(plan.httpEightyIPs, [], "H-001: no HTTP:80 legs for sensitive")
    }

    func testSensitiveAuthenticatedStripsAllFallbacks() {
        let plan = APIClient.raceLegPlan(
            sensitive: true,
            isAuthenticated: true,
            region: "US",
            availableIPs: allIPs
        )
        // Even with a Bearer attached, sensitive=true is the dominant gate.
        XCTAssertEqual(plan.directIPs, [])
        XCTAssertEqual(plan.httpEightyIPs, [])
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
}
