import XCTest
@testable import MadFrogVPN

/// Regression guard for the refresh-token ROTATION bug (Pain #2).
///
/// The backend rotates the refresh token on every `/api/mobile/auth/refresh`
/// call: each token is single-use and blacklisted (SHA-256) in Redis for 30
/// days. The iOS client used to parse only `access_token` from the response
/// and drop the rotated `refresh_token`, leaving the OLD (now-consumed) token
/// in the keychain. The NEXT refresh then resent a blacklisted token →
/// backend 401 "refresh token already used" → a forced visible re-login every
/// ~24h.
///
/// The fix surfaces the rotated token via `APIClient.parseRefreshResponse`
/// (pure static helper, mirrors the `raceLegPlan` testability extract). These
/// tests pin the invariant: the response's NEW refresh_token MUST win.
final class RefreshTokenRotationTests: XCTestCase {

    private func body(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: - Load-bearing invariant: the rotated token wins

    func testRotatedRefreshTokenIsSurfacedNotDropped() {
        let data = body([
            "access_token": "NEW_ACCESS",
            "refresh_token": "ROTATED_REFRESH",
            "expires_at": 1_900_000_000,
        ])
        let result = APIClient.parseRefreshResponse(data, sentRefreshToken: "OLD_CONSUMED_REFRESH")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.accessToken, "NEW_ACCESS")
        XCTAssertEqual(result?.refreshToken, "ROTATED_REFRESH",
                       "the response's rotated refresh_token MUST win over the consumed one we sent")
        XCTAssertNotEqual(result?.refreshToken, "OLD_CONSUMED_REFRESH",
                          "persisting the old token reproduces Pain #2 (next refresh 401s)")
    }

    func testExpiresAtParsedAsDate() {
        let data = body([
            "access_token": "A",
            "refresh_token": "R",
            "expires_at": 1_900_000_000,
        ])
        let result = APIClient.parseRefreshResponse(data, sentRefreshToken: "OLD")
        XCTAssertEqual(result?.expiresAt, Date(timeIntervalSince1970: 1_900_000_000))
    }

    // MARK: - Backwards-compat: older backend may omit fields

    func testMissingRefreshTokenFallsBackToSentToken() {
        // An older backend (or a partial response) without `refresh_token`:
        // fall back to the token we sent so we never persist an empty string.
        let data = body(["access_token": "A"])
        let result = APIClient.parseRefreshResponse(data, sentRefreshToken: "STILL_VALID")
        XCTAssertEqual(result?.refreshToken, "STILL_VALID")
        XCTAssertNil(result?.expiresAt, "absent expires_at → nil, not 1970")
    }

    // MARK: - Missing access_token → nil (caller treats as 401)

    func testMissingAccessTokenYieldsNil() {
        let data = body(["refresh_token": "R"])
        XCTAssertNil(APIClient.parseRefreshResponse(data, sentRefreshToken: "OLD"),
                     "no access_token → nil → refreshAccessToken throws .unauthorized")
    }

    func testGarbageBodyYieldsNil() {
        XCTAssertNil(APIClient.parseRefreshResponse(Data("not json".utf8), sentRefreshToken: "OLD"))
    }
}
