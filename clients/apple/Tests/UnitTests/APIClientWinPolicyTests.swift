import XCTest
@testable import MadFrogVPN

/// AUTH-DIRECT-IP-INTERACTIVE (2026-06-17). Pins the fallback-leg winner rule
/// that lets interactive sign-in (Apple/Google/magic-verify) race the
/// cert-validated direct-IP legs WITHOUT reintroducing the build-53 regression:
/// a transport-mangled 4xx from a fallback leg (raw-IP nginx 400, torn-TLS) must
/// not win over primary's correct 200 and make a valid login look "invalid".
final class APIClientWinPolicyTests: XCTestCase {

    // MARK: - .anyBelow500 (default — unchanged behaviour for existing callers)

    func testAnyBelow500_winsOnEverythingUnder500() {
        for s in [200, 204, 301, 400, 401, 403, 404, 429, 499] {
            XCTAssertTrue(APIClient.fallbackLegWins(status: s, policy: .anyBelow500),
                          "status \(s) should win under .anyBelow500")
        }
    }

    func testAnyBelow500_rejects5xx() {
        for s in [500, 502, 503] {
            XCTAssertFalse(APIClient.fallbackLegWins(status: s, policy: .anyBelow500),
                           "status \(s) must not win (server failing)")
        }
    }

    // MARK: - .definitiveAuthOnly (auth sign-in)

    func testDefinitiveAuthOnly_winsOn2xxAnd401() {
        for s in [200, 201, 204, 299, 401] {
            XCTAssertTrue(APIClient.fallbackLegWins(status: s, policy: .definitiveAuthOnly),
                          "status \(s) is a definitive auth outcome and should win")
        }
    }

    func testDefinitiveAuthOnly_rejectsAmbiguous4xx() {
        // THE build-53 guard: a fallback leg's mangled 4xx must NOT shadow
        // primary's 200. These must all be non-winning under auth policy.
        for s in [400, 403, 404, 405, 409, 429] {
            XCTAssertFalse(APIClient.fallbackLegWins(status: s, policy: .definitiveAuthOnly),
                           "status \(s) from a fallback leg must not win auth (could be transport noise)")
        }
    }

    func testDefinitiveAuthOnly_rejects5xx() {
        for s in [500, 503] {
            XCTAssertFalse(APIClient.fallbackLegWins(status: s, policy: .definitiveAuthOnly))
        }
    }

    /// raceLegPlan(sensitive:true) already exposes the cert-validated direct-IP
    /// legs that the auth flow now races (the other half of this fix).
    func testSensitivePlanExposesDirectIPLegsForAuth() {
        let plan = APIClient.raceLegPlan(sensitive: true,
                                         isAuthenticated: false,
                                         region: "RU",
                                         availableIPs: ["147.45.252.234", "185.218.0.43"])
        XCTAssertTrue(plan.primary)
        XCTAssertEqual(plan.directIPs, ["147.45.252.234", "185.218.0.43"])
        XCTAssertTrue(plan.httpEightyIPs.isEmpty, "auth must never use cleartext HTTP:80 legs (H-001)")
    }
}
