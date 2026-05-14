import XCTest
@testable import MadFrogVPN

/// test-coverage (ios-api-client): pins the pure decision cores extracted
/// from `APIClient` — the HTTP-status classification every endpoint
/// branches on, plus the hedged-race planning rules (idempotency-key
/// decision, RU IP filtering, leg 5xx-reject, hedge stagger).
///
/// The live `URLSession` / `DirectConnection` dials stay on-device-verified;
/// what's tested here is the deterministic logic that decides what those
/// dials do and how their responses are interpreted.
final class APIResponseLogicTests: XCTestCase {

    // MARK: - classify (the shared 401 / 2xx / serverError table)

    func testClassify_200IsOk() {
        XCTAssertEqual(APIResponseLogic.classify(status: 200), .ok)
    }

    func testClassify_401IsUnauthorized() {
        XCTAssertEqual(APIResponseLogic.classify(status: 401), .unauthorized)
    }

    func testClassify_otherNon2xxIsServerError() {
        XCTAssertEqual(APIResponseLogic.classify(status: 500), .serverError(500))
        XCTAssertEqual(APIResponseLogic.classify(status: 404), .serverError(404))
        // 403 is NOT special-cased — only 401 maps to unauthorized.
        XCTAssertEqual(APIResponseLogic.classify(status: 403), .serverError(403))
    }

    func testClassify_widenedSuccessCodes() {
        // registerDevice accepts 200 AND 201.
        XCTAssertEqual(APIResponseLogic.classify(status: 201, successCodes: [200, 201]), .ok)
        // deleteAccount accepts 200 AND 204.
        XCTAssertEqual(APIResponseLogic.classify(status: 204, successCodes: [200, 204]), .ok)
        // a non-listed code still falls through.
        XCTAssertEqual(APIResponseLogic.classify(status: 202, successCodes: [200, 201]), .serverError(202))
    }

    func testClassify_401WinsEvenIfNotInSuccessCodes() {
        XCTAssertEqual(APIResponseLogic.classify(status: 401, successCodes: [200, 204]), .unauthorized)
    }

    // MARK: - classifyActivateCode

    func testClassifyActivateCode_table() {
        XCTAssertEqual(APIResponseLogic.classifyActivateCode(status: 200), .ok)
        XCTAssertEqual(APIResponseLogic.classifyActivateCode(status: 404), .special(404),
                       "404 → invalid code, surfaced as .special so the caller maps it to APIError.invalidCode")
        XCTAssertEqual(APIResponseLogic.classifyActivateCode(status: 500), .serverError(500))
        // 401 is not special-cased on the activate endpoint — falls to serverError.
        XCTAssertEqual(APIResponseLogic.classifyActivateCode(status: 401), .serverError(401))
    }

    // MARK: - classifyMagicLinkRequest

    func testClassifyMagicLinkRequest_table() {
        XCTAssertEqual(APIResponseLogic.classifyMagicLinkRequest(status: 200), .ok)
        XCTAssertEqual(APIResponseLogic.classifyMagicLinkRequest(status: 204), .ok,
                       "204 No Content is the documented success response")
        XCTAssertEqual(APIResponseLogic.classifyMagicLinkRequest(status: 429), .special(429),
                       "429 rate-limit is surfaced distinctly")
        XCTAssertEqual(APIResponseLogic.classifyMagicLinkRequest(status: 500), .serverError(500))
    }

    // MARK: - legShouldBeDiscarded (the 5xx-reject race rule)

    func testLegShouldBeDiscarded_only5xx() {
        XCTAssertTrue(APIResponseLogic.legShouldBeDiscarded(status: 500))
        XCTAssertTrue(APIResponseLogic.legShouldBeDiscarded(status: 502))
        XCTAssertTrue(APIResponseLogic.legShouldBeDiscarded(status: 599))
        // 4xx must NOT be discarded — it propagates so callers (404 →
        // re-register) can react.
        XCTAssertFalse(APIResponseLogic.legShouldBeDiscarded(status: 404))
        XCTAssertFalse(APIResponseLogic.legShouldBeDiscarded(status: 400))
        XCTAssertFalse(APIResponseLogic.legShouldBeDiscarded(status: 200))
        XCTAssertFalse(APIResponseLogic.legShouldBeDiscarded(status: 499))
    }

    // MARK: - shouldAttachIdempotencyKey

    func testShouldAttachIdempotencyKey_mutatingMethodsOnly() {
        XCTAssertTrue(APIResponseLogic.shouldAttachIdempotencyKey(method: "POST", existingKey: nil))
        XCTAssertTrue(APIResponseLogic.shouldAttachIdempotencyKey(method: "PATCH", existingKey: nil))
        XCTAssertTrue(APIResponseLogic.shouldAttachIdempotencyKey(method: "DELETE", existingKey: nil))
        // GET / HEAD are safe to replay — no key.
        XCTAssertFalse(APIResponseLogic.shouldAttachIdempotencyKey(method: "GET", existingKey: nil))
        XCTAssertFalse(APIResponseLogic.shouldAttachIdempotencyKey(method: "HEAD", existingKey: nil))
    }

    func testShouldAttachIdempotencyKey_respectsCallerSuppliedKey() {
        XCTAssertFalse(APIResponseLogic.shouldAttachIdempotencyKey(method: "POST", existingKey: "abc-123"),
                       "a caller-supplied Idempotency-Key must not be overwritten")
    }

    func testShouldAttachIdempotencyKey_methodCaseInsensitive() {
        XCTAssertFalse(APIResponseLogic.shouldAttachIdempotencyKey(method: "get", existingKey: nil))
        XCTAssertTrue(APIResponseLogic.shouldAttachIdempotencyKey(method: "post", existingKey: nil))
    }

    // MARK: - raceIPs (RU region filtering)

    func testRaceIPs_nonRURegionRacesFullPool() {
        let all = ["162.19.242.30", "147.45.252.234", "185.218.0.43"]
        XCTAssertEqual(APIResponseLogic.raceIPs(allIPs: all, isRURegion: false), all)
    }

    func testRaceIPs_RURegionDropsOVHFrankfurt() {
        // RU mobile carriers block 162.19.242.30 at the ASN level — racing
        // it only burns the full timeout.
        let all = ["162.19.242.30", "147.45.252.234", "185.218.0.43"]
        XCTAssertEqual(APIResponseLogic.raceIPs(allIPs: all, isRURegion: true),
                       ["147.45.252.234", "185.218.0.43"])
    }

    func testRaceIPs_RURegionWithoutOVHIsUnchanged() {
        let all = ["147.45.252.234", "185.218.0.43"]
        XCTAssertEqual(APIResponseLogic.raceIPs(allIPs: all, isRURegion: true), all)
    }

    // MARK: - hedge stagger / ladder indices

    func testStaggerMilliseconds_ladder() {
        // Primary (index 0) fires at T+0; each subsequent leg waits 250ms more.
        XCTAssertEqual(APIResponseLogic.staggerMilliseconds(legIndex: 0), 0)
        XCTAssertEqual(APIResponseLogic.staggerMilliseconds(legIndex: 1), 250)
        XCTAssertEqual(APIResponseLogic.staggerMilliseconds(legIndex: 4), 1000)
    }

    func testHttpLegStartIndex_continuesAfterPrimaryAndDirectLegs() {
        // primary = index 0, then `raceIPCount` direct legs (1...N),
        // then HTTP legs start at N+1.
        XCTAssertEqual(APIResponseLogic.httpLegStartIndex(raceIPCount: 3), 4)
        XCTAssertEqual(APIResponseLogic.httpLegStartIndex(raceIPCount: 0), 1)
    }

    func testShouldRunHTTPFallback_unauthenticatedOnly() {
        XCTAssertTrue(APIResponseLogic.shouldRunHTTPFallback(isAuthenticated: false))
        XCTAssertFalse(APIResponseLogic.shouldRunHTTPFallback(isAuthenticated: true),
                       "an authenticated request must never go cleartext over HTTP:80")
    }

    // MARK: - configBodyIsDisguisedError

    func testConfigBodyIsDisguisedError_detectsErrorJSON() {
        XCTAssertTrue(APIResponseLogic.configBodyIsDisguisedError("{\"error\":\"user not found\"}"),
                      "an error JSON with no outbounds disguised as 200 must be rejected")
    }

    func testConfigBodyIsDisguisedError_acceptsRealConfig() {
        // A real config has "outbounds" — even if it also contains the
        // substring "error" somewhere (e.g. a server tag), it's accepted.
        XCTAssertFalse(APIResponseLogic.configBodyIsDisguisedError("{\"outbounds\":[{\"tag\":\"de\"}]}"))
        XCTAssertFalse(APIResponseLogic.configBodyIsDisguisedError("{\"outbounds\":[],\"note\":\"error log\"}"))
    }

    func testConfigBodyIsDisguisedError_plainBodyIsNotAnError() {
        XCTAssertFalse(APIResponseLogic.configBodyIsDisguisedError("{}"))
    }

    // MARK: - requestPath

    func testRequestPath_appendsQuery() {
        XCTAssertEqual(APIResponseLogic.requestPath(path: "/api/v1/mobile/config", query: "username=bob&mode=smart"),
                       "/api/v1/mobile/config?username=bob&mode=smart")
    }

    func testRequestPath_noQuery() {
        XCTAssertEqual(APIResponseLogic.requestPath(path: "/api/mobile/auth/register", query: nil),
                       "/api/mobile/auth/register")
        XCTAssertEqual(APIResponseLogic.requestPath(path: "/api/mobile/auth/register", query: ""),
                       "/api/mobile/auth/register",
                       "an empty query string must not produce a trailing '?'")
    }

    func testRequestPath_emptyPathNormalisesToSlash() {
        XCTAssertEqual(APIResponseLogic.requestPath(path: "", query: nil), "/")
    }
}
