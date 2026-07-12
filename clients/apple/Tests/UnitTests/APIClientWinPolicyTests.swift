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

    // MARK: - .definitiveConfigOnly (config fetch, 2026-07-11)

    /// 2026-07-11 field bug: live-verified a stale/dead direct-IP leg (NL —
    /// backend stopped by the WAW failover; SPB — confirmed application-dead)
    /// answering `/api/v1/mobile/config` with a fast, empty-body HTTP 400.
    /// Under `.anyBelow500` that 400 could win the race over a slower-but-
    /// correct primary/decoy leg, so every config fetch on that device failed
    /// with "no config" even though a working leg existed. 400 must NEVER win.
    func testDefinitiveConfigOnly_rejectsTheDeadLegBug() {
        XCTAssertFalse(APIClient.fallbackLegWins(status: 400, policy: .definitiveConfigOnly),
                       "a raw 400 (the dead-leg signature) must never shadow a working config leg")
    }

    /// Every status GetConfig's own handler can actually emit must win: 2xx
    /// success, 401 (bad/expired JWT), 403 (deactivated / sub expired), 404
    /// (user row missing — drives ACCT-IDENTITY re-register), 409 (VPN creds
    /// not provisioned yet).
    func testDefinitiveConfigOnly_winsOnRealHandlerOutcomes() {
        for s in [200, 204, 299, 401, 403, 404, 409] {
            XCTAssertTrue(APIClient.fallbackLegWins(status: s, policy: .definitiveConfigOnly),
                          "status \(s) is a real GetConfig outcome and should win")
        }
    }

    /// Anything else (400, 405, 429, ...) can only be transport/routing noise
    /// from something that isn't our app answering — must not win.
    func testDefinitiveConfigOnly_rejectsEverythingElse() {
        for s in [400, 405, 429] {
            XCTAssertFalse(APIClient.fallbackLegWins(status: s, policy: .definitiveConfigOnly),
                           "status \(s) is not a real GetConfig outcome and must not win")
        }
    }

    func testDefinitiveConfigOnly_rejects5xx() {
        for s in [500, 503] {
            XCTAssertFalse(APIClient.fallbackLegWins(status: s, policy: .definitiveConfigOnly))
        }
    }

    /// Regression guard for the 2026-07-11 incident itself: NL (backend
    /// stopped by the WAW failover) and SPB (confirmed application-dead) must
    /// stay OUT of the direct-IP hedge pool until independently re-verified —
    /// don't let a future merge/rollback silently restore them from an old
    /// branch or a stale memory of "NL is the production backend".
    func testDirectBackendIPs_excludesKnownDeadLegs() {
        XCTAssertFalse(AppConfig.directBackendIPs.contains("147.45.252.234"),
                       "NL — backend stopped by the 2026-06-29 WAW failover, don't re-add without re-verifying it serves /api/v1/mobile/config")
        XCTAssertFalse(AppConfig.directBackendIPs.contains("185.218.0.43"),
                       "SPB — confirmed application-dead (roadmap SPB-RECOVER, P0), don't re-add without re-verifying")
    }

    /// CLIENT-FALLBACK-STALE-NL (2026-07-12): the hedged race must not waste a
    /// budget slot on guaranteed-fail legs. NL (backend stopped 2026-06-29 WAW
    /// failover) and DE (retired 2026-05-25) must never reappear in any API
    /// backend fallback/direct-IP list, and the confirmed-live MSK relay must
    /// stay present.
    func testAPIBackendLists_excludeDeadNLAndDELegs() {
        XCTAssertFalse(AppConfig.fallbackBaseURL.contains("147.45.252.234"),
                       "NL — backend stopped by the 2026-06-29 WAW failover, don't repoint fallbackBaseURL at it without re-verifying")
        XCTAssertFalse(AppConfig.fallbackBaseURL.contains("162.19.242.30"),
                       "DE — retired 2026-05-25, fully decommissioned, must never reappear")
        XCTAssertFalse(AppConfig.directBackendIPs.contains("162.19.242.30"),
                       "DE — retired 2026-05-25, fully decommissioned, must never reappear")
        XCTAssertTrue(AppConfig.directBackendIPs.contains("217.198.5.52"),
                      "MSK relay — confirmed live 2026-07-11 stability audit, must stay in the direct-IP pool")
    }

    // MARK: - RU-DECOY-SNI gate (clean-SNI MSK leg)

    /// Sign-in / refresh (sensitive) must ALWAYS get the decoy leg — it's the
    /// only path that survives RKN's api.madfrog.online SNI filter without a VPN.
    func testDecoyLeg_alwaysOnForSensitive() {
        for region in ["RU", "US", "DE", nil] {
            XCTAssertTrue(APIClient.shouldUseDecoyLeg(sensitive: true, region: region),
                          "sensitive auth must use the decoy leg regardless of region (\(region ?? "nil"))")
        }
    }

    /// Non-sensitive requests use the decoy leg only where the filtered SNI
    /// bites: RU or an unknown region. A confirmed non-RU region skips it.
    func testDecoyLeg_regionGatedForNonSensitive() {
        XCTAssertTrue(APIClient.shouldUseDecoyLeg(sensitive: false, region: "RU"))
        XCTAssertTrue(APIClient.shouldUseDecoyLeg(sensitive: false, region: nil))
        XCTAssertFalse(APIClient.shouldUseDecoyLeg(sensitive: false, region: "US"))
        XCTAssertFalse(APIClient.shouldUseDecoyLeg(sensitive: false, region: "DE"))
    }

    // MARK: - RU-DECOY-FIRST timing (hold the poisoning SNI behind the decoy)

    /// Sensitive auth must HOLD the filtered-SNI legs (primary + direct-IP) so a
    /// fast decoy win cancels them before any api.madfrog.online ClientHello
    /// leaves the device — otherwise the leaked SNI trips the TSPU and the next
    /// sign-in hangs. Non-sensitive traffic keeps the primary at T+0.
    func testPoisonHold_onlyForSensitive() {
        XCTAssertEqual(APIClient.poisonHoldMs(sensitive: true), 2000)
        XCTAssertEqual(APIClient.poisonHoldMs(sensitive: false), 0)
    }

    /// The decoy leads at T+0 for sensitive auth (must beat the held legs) and
    /// only lightly staggers otherwise.
    func testDecoyLead_zeroForSensitive() {
        XCTAssertEqual(APIClient.decoyLeadMs(sensitive: true), 0)
        XCTAssertEqual(APIClient.decoyLeadMs(sensitive: false), 150)
    }

    /// Invariant that makes the fix work: on sensitive auth the decoy fires
    /// strictly before the poisoning legs, so a sub-second win cancels them
    /// while still asleep — zero filtered-SNI ClientHellos escape.
    func testDecoyLeadsPoisonLegsForSensitive() {
        XCTAssertLessThan(APIClient.decoyLeadMs(sensitive: true),
                          APIClient.poisonHoldMs(sensitive: true),
                          "decoy must dial before the held api.madfrog.online legs")
    }
}
