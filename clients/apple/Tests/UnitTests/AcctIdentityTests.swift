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

    func testAnonUserNeverOnboardedMayReRegister() {
        XCTAssertTrue(AppState.shouldAnonReRegister(authProvider: nil, onboardingCompleted: false),
                      "no identity + never onboarded (fresh install / true reinstall) is the only valid anon re-register")
    }

    func testOnboardedUserIsNeverAnonWiped() {
        // ACCT-IDENTITY-3: a returning user whose authProvider went transiently
        // nil (Apple sign-in not fully persisted during an RU network blackout)
        // must NOT be wiped to a fresh anon trial — their real account exists
        // server-side. This was the field bug (paid acct 12351 dropped to onboarding).
        XCTAssertFalse(AppState.shouldAnonReRegister(authProvider: nil, onboardingCompleted: true),
                       "an onboarded user must never be silently demoted to anon, even with nil authProvider")
    }

    func testAppleUserIsNeverAnonDemoted() {
        XCTAssertFalse(AppState.shouldAnonReRegister(authProvider: "apple", onboardingCompleted: false),
                       "THE BUG: an Apple identity must never fall back to anon register")
        XCTAssertFalse(AppState.shouldAnonReRegister(authProvider: "apple", onboardingCompleted: true))
    }

    func testGoogleUserIsNeverAnonDemoted() {
        XCTAssertFalse(AppState.shouldAnonReRegister(authProvider: "google", onboardingCompleted: false))
    }

    func testEmailUserIsNeverAnonDemoted() {
        XCTAssertFalse(AppState.shouldAnonReRegister(authProvider: "email", onboardingCompleted: false))
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

    /// 2026-07-11 field bug: a payload mangled somewhere on a device's network
    /// path (not by our backend — a direct fetch confirmed the server always
    /// returns clean JSON) can still happen to contain the literal substring
    /// `"outbounds"` without being valid JSON at all. The old substring-only
    /// check accepted this, permanently poisoning the on-disk config cache —
    /// every subsequent connect then failed inside the tunnel with sing-box's
    /// own `decode config` JSON errors, with no user-visible signal pointing
    /// at the real cause.
    func testMangledPayloadContainingOutboundsSubstringIsNotUsable() {
        XCTAssertFalse(AppState.isUsableConfigPayload(#"garbled "outbounds": [{"type":"vless"}] trailing junk"#))
    }

    func testEmptyOutboundsArrayIsNotUsable() {
        XCTAssertFalse(AppState.isUsableConfigPayload(#"{"outbounds":[]}"#))
    }

    func testOutboundsMissingTypeOrTagIsNotUsable() {
        XCTAssertFalse(AppState.isUsableConfigPayload(#"{"outbounds":[{"tag":"nl"}]}"#))
        XCTAssertFalse(AppState.isUsableConfigPayload(#"{"outbounds":[{"type":"vless"}]}"#))
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
