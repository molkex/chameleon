import XCTest
@testable import MadFrogVPN

/// ACCT-IDENTITY (2026-06-01) regression guards.
///
/// `shouldAnonReRegister` is the P0 invariant — the one decision that, when it
/// was implicitly "always true", silently demoted a paying Apple user to a
/// fresh anonymous trial. It's a pure static on `AppState` (the full object is
/// too heavyweight to build in a unit test, same as `AppStateFallbackTests`),
/// so we exercise it directly.
///
/// The ConfigStore identity round-trip touches the real Keychain, which is
/// sandboxed off in Simulator unit-test bundles (errSecMissingEntitlement) —
/// it `XCTSkip`s there and runs on a real device, mirroring `KeychainHelperTests`.
@MainActor
final class AcctIdentityTests: XCTestCase {

    // MARK: - P0 invariant: never anon-demote an identity user

    func testAnonUserMayReRegister() {
        XCTAssertTrue(AppState.shouldAnonReRegister(authProvider: nil),
                      "a user with no identity is the only case where anon re-register is valid")
    }

    func testAppleUserIsNeverAnonDemoted() {
        XCTAssertFalse(AppState.shouldAnonReRegister(authProvider: "apple"),
                       "THE BUG: an Apple identity must never fall back to anon register")
    }

    func testGoogleUserIsNeverAnonDemoted() {
        XCTAssertFalse(AppState.shouldAnonReRegister(authProvider: "google"))
    }

    func testEmailUserIsNeverAnonDemoted() {
        XCTAssertFalse(AppState.shouldAnonReRegister(authProvider: "email"))
    }

    // MARK: - P0 (recurred build 98): a bad cached config must NOT wipe identity

    /// `isUsableConfigPayload` is the second trip-wire. A real sing-box config
    /// has `outbounds`; an error/HTML/empty body does not. The recurrence:
    /// a degraded /config response (CF/relay error page on RU LTE) was cached,
    /// then `initialize()` clear()'d the whole identity on next launch — demoting
    /// a paying Apple user (sub→2026-06-15) to a fresh anon `device_0668c8cb`.
    func testUsableConfigAccepted() {
        XCTAssertTrue(AppState.isUsableConfigPayload(#"{"outbounds":[{"type":"vless","tag":"nl"}]}"#))
    }

    func testErrorBodyIsNotUsableConfig() {
        XCTAssertFalse(AppState.isUsableConfigPayload(#"{"error":"user not found"}"#),
                       "an error JSON body must never be treated as a config (would arm the identity-wipe)")
    }

    func testHtmlErrorPageIsNotUsableConfig() {
        XCTAssertFalse(AppState.isUsableConfigPayload("<html><body>503 Service Unavailable</body></html>"),
                       "a Cloudflare/relay error page is not a config")
    }

    func testEmptyOrGarbageIsNotUsableConfig() {
        XCTAssertFalse(AppState.isUsableConfigPayload(""))
        XCTAssertFalse(AppState.isUsableConfigPayload("null"))
    }

    // MARK: - ConfigStore identity persistence

    func testConfigStorePersistsAndClearsIdentity() throws {
        try Self.skipIfKeychainUnavailable()
        let store = ConfigStore()
        // Leave a clean slate regardless of prior runs.
        store.clear()

        store.authProvider = "apple"
        store.appleUserID = "001234.abcdef0123456789.5678"
        XCTAssertEqual(store.authProvider, "apple")
        XCTAssertEqual(store.appleUserID, "001234.abcdef0123456789.5678")

        // clear() is the explicit sign-out path — identity must go with it.
        store.clear()
        XCTAssertNil(store.authProvider, "clear() must wipe authProvider")
        XCTAssertNil(store.appleUserID, "clear() must wipe appleUserID")
    }

    // MARK: - Keychain availability probe (same as KeychainHelperTests)

    private static func skipIfKeychainUnavailable() throws {
        let probeKey = "test.acctidentity.probe"
        KeychainHelper.delete(key: probeKey)
        KeychainHelper.save(key: probeKey, value: "probe")
        let loaded = KeychainHelper.load(key: probeKey)
        KeychainHelper.delete(key: probeKey)
        if loaded != "probe" {
            throw XCTSkip("Keychain unavailable in this test environment (Simulator unit-test bundle without keychain-access-group entitlement). Run on a real device.")
        }
    }
}
