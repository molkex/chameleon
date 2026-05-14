import XCTest
@testable import MadFrogVPN

/// test-coverage (ios-config-store): pins the UserDefaults-backed
/// preference accessors of `ConfigStore` — defaults, get/set round-trips,
/// and the first-run fallbacks that the auto-connect / auto-recover
/// features depend on.
///
/// Runs against an isolated `UserDefaults(suiteName:)` (injected via the
/// test-only `init(defaults:)` argument) so it never touches the real
/// App Group container. Keychain-backed properties (username / tokens)
/// are covered separately by KeychainHelperTests.
final class ConfigStoreTests: XCTestCase {

    /// A fresh, empty suite per test — no cross-test bleed.
    private func freshStore() -> (ConfigStore, UserDefaults) {
        let name = "test.configstore.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        // UserDefaults(suiteName:) can hand back a suite with stale keys if
        // the name ever collided — wipe the ones we touch.
        for k in ["vpnMode",
                  AppConstants.selectedServerTagKey,
                  AppConstants.autoRecoverEnabledKey,
                  AppConstants.autoConnectEnabledKey,
                  AppConstants.subscriptionExpireKey] {
            d.removeObject(forKey: k)
        }
        return (ConfigStore(defaults: d), d)
    }

    // MARK: - vpnMode

    func testVPNMode_defaultsToSmart() {
        let (store, _) = freshStore()
        XCTAssertEqual(store.vpnMode, "smart", "first-run vpnMode must default to smart")
    }

    func testVPNMode_roundTrips() {
        let (store, _) = freshStore()
        store.vpnMode = "global"
        XCTAssertEqual(store.vpnMode, "global")
        store.vpnMode = "smart"
        XCTAssertEqual(store.vpnMode, "smart")
    }

    // MARK: - selectedServerTag

    func testSelectedServerTag_defaultsToNil() {
        let (store, _) = freshStore()
        XCTAssertNil(store.selectedServerTag, "first-run selectedServerTag must be nil (= Auto)")
    }

    func testSelectedServerTag_roundTrips() {
        let (store, _) = freshStore()
        store.selectedServerTag = "de-h2-de"
        XCTAssertEqual(store.selectedServerTag, "de-h2-de")
    }

    func testSelectedServerTag_canBeClearedToNil() {
        let (store, _) = freshStore()
        store.selectedServerTag = "🇩🇪 Германия"
        XCTAssertNotNil(store.selectedServerTag)
        store.selectedServerTag = nil
        XCTAssertNil(store.selectedServerTag, "setting nil must clear the pin back to Auto")
    }

    // MARK: - autoRecoverEnabled (default ON)

    func testAutoRecoverEnabled_defaultsOn() {
        let (store, _) = freshStore()
        XCTAssertTrue(store.autoRecoverEnabled, "first-run autoRecover must default ON")
    }

    func testAutoRecoverEnabled_roundTripsBothWays() {
        let (store, _) = freshStore()
        store.autoRecoverEnabled = false
        XCTAssertFalse(store.autoRecoverEnabled, "an explicit false must persist, not snap back to the ON default")
        store.autoRecoverEnabled = true
        XCTAssertTrue(store.autoRecoverEnabled)
    }

    // MARK: - autoConnectEnabled (default OFF)

    func testAutoConnectEnabled_defaultsOff() {
        let (store, _) = freshStore()
        XCTAssertFalse(store.autoConnectEnabled,
                       "auto-connect is opt-in — defaulting it ON would re-enable a VPN the user turned off")
    }

    func testAutoConnectEnabled_roundTripsBothWays() {
        let (store, _) = freshStore()
        store.autoConnectEnabled = true
        XCTAssertTrue(store.autoConnectEnabled)
        store.autoConnectEnabled = false
        XCTAssertFalse(store.autoConnectEnabled)
    }

    // MARK: - subscriptionExpire

    func testSubscriptionExpire_defaultsToNil() {
        let (store, _) = freshStore()
        XCTAssertNil(store.subscriptionExpire)
    }

    func testSubscriptionExpire_roundTrips() {
        let (store, _) = freshStore()
        let d = Date(timeIntervalSince1970: 1_800_000_000)
        store.subscriptionExpire = d
        XCTAssertEqual(store.subscriptionExpire, d)
    }

    // MARK: - independence across stores sharing nothing

    func testTwoStoresOnSeparateSuitesDoNotShareState() {
        let (a, _) = freshStore()
        let (b, _) = freshStore()
        a.selectedServerTag = "de-h2-de"
        XCTAssertNil(b.selectedServerTag, "separate suites must be fully isolated")
    }

    // MARK: - nil-suite resilience (App Group misconfigured)

    func testNilSuite_readsReturnDefaults_writesNoOp() {
        // App Group entitlement missing → suite is nil. Reads must return
        // the documented defaults and writes must silently no-op (not crash).
        let store = ConfigStore(defaults: nil)
        XCTAssertEqual(store.vpnMode, "smart")
        XCTAssertNil(store.selectedServerTag)
        XCTAssertTrue(store.autoRecoverEnabled)
        XCTAssertFalse(store.autoConnectEnabled)
        // writes must not crash
        store.vpnMode = "global"
        store.selectedServerTag = "de-h2-de"
        store.autoConnectEnabled = true
        // and still read back as defaults since nothing was persisted
        XCTAssertEqual(store.vpnMode, "smart")
        XCTAssertNil(store.selectedServerTag)
    }
}
