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
