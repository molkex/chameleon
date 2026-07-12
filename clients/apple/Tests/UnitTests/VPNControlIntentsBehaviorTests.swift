import NetworkExtension
import XCTest
@testable import MadFrogVPN

/// Regression guard for the AppIntents control surface in
/// `Shared/VPNControlIntents.swift`. Four things are pinned:
///
///   1. The `vpnControlPlan` decision matrix — the pure entry-point that
///      decides `.start` / `.stop` / `.needsApp` from the inputs.
///   2. The localised dialog produced by `vpnStatusDialog(for:)`.
///   3. **Build-84 invariant** — `.start` MUST NOT optimistically write
///      `connected=true` into the App Group, because the widget process
///      can never observe whether the tunnel actually came up and a
///      false `.connected` write would never get reverted. `.stop` IS
///      optimistic (kernel teardown is essentially immediate). Both are
///      asserted here so a future refactor that flips the policy fails
///      the suite loudly.
///   4. **CLIENT-VPN-PROFILE-SELECT** — `selectOurManager` must pick the
///      manager whose `providerBundleIdentifier` matches ours, not just
///      the first entry in `loadAllFromPreferences()`'s result.
@MainActor
final class VPNControlIntentsBehaviorTests: XCTestCase {

    // MARK: - vpnControlPlan matrix

    func testNoManagerAlwaysNeedsApp() {
        XCTAssertEqual(vpnControlPlan(desiredOn: true, hasManager: false), .needsApp)
        XCTAssertEqual(vpnControlPlan(desiredOn: false, hasManager: false), .needsApp,
                       "even a 'turn off' tap with no profile needs the app — there's nothing to stop")
    }

    func testManagerPresentDesiredOnYieldsStart() {
        XCTAssertEqual(vpnControlPlan(desiredOn: true, hasManager: true), .start)
    }

    func testManagerPresentDesiredOffYieldsStop() {
        XCTAssertEqual(vpnControlPlan(desiredOn: false, hasManager: true), .stop)
    }

    // MARK: - vpnStatusDialog (English path — locale isn't easily overridable
    // in a unit test; the RU path is exercised on-device).

    func testStatusDialogConnectedMentionsServer() {
        // The localised string is built off `Locale.current`. On CI/local
        // simulators that runs in en-US, so we assert the English path; if
        // the simulator is RU-locale the assertion is best-effort skipped
        // rather than flaky.
        let snapshot = WidgetVPNSnapshot(
            connected: true,
            serverName: "🇩🇪 Германия",
            connectedAt: Date()
        )
        let dialog = String(localized: vpnStatusDialog(for: snapshot))
        if Locale.current.language.languageCode?.identifier == "ru" {
            XCTAssertTrue(dialog.contains("подключён"), "RU connected dialog: got \(dialog)")
        } else {
            XCTAssertTrue(dialog.contains("connected"),
                          "EN connected dialog should say 'connected': got \(dialog)")
        }
        XCTAssertTrue(dialog.contains("🇩🇪 Германия"),
                      "dialog must include serverDisplay: got \(dialog)")
    }

    func testStatusDialogDisconnectedNoServerName() {
        let snapshot = WidgetVPNSnapshot(
            connected: false,
            serverName: nil,
            connectedAt: nil
        )
        let dialog = String(localized: vpnStatusDialog(for: snapshot))
        if Locale.current.language.languageCode?.identifier == "ru" {
            XCTAssertTrue(dialog.contains("отключён"), "RU disconnected dialog: got \(dialog)")
        } else {
            XCTAssertTrue(dialog.contains("disconnected"),
                          "EN disconnected dialog should say 'disconnected': got \(dialog)")
        }
    }

    // MARK: - Build-84 invariant: .start does NOT publish optimistic .connected

    func testStartDoesNotPublishOptimisticConnected() {
        // The `publishesOptimisticOnStart` constant is the explicit seam
        // documenting the build-84 decision. Flipping it without updating
        // this test (and the body of `VPNControl.perform(.start, …)`) is
        // the change we want to catch.
        XCTAssertFalse(VPNControl.publishesOptimisticOnStart,
                       "build-84: .start MUST NOT optimistically write connected=true")
    }

    // MARK: - .stop optimistic-write semantics

    func testStopOptimisticWriteFlipsSnapshotToDisconnected() throws {
        // Use a private UserDefaults suite as a stand-in for the App Group
        // (`WidgetVPNSnapshot.write` accepts the suite explicitly). We
        // can't easily *read* from the suite via the public
        // `WidgetVPNSnapshot.read()` API (it hard-codes the App-Group ID),
        // so we drive `write` directly and inspect the keys.
        let suiteName = "vpn-control-intents-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create scratch UserDefaults suite"); return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        // Seed an "already connected" snapshot — like a stale prior session.
        WidgetVPNSnapshot.write(connected: true, to: defaults)
        XCTAssertGreaterThan(defaults.double(forKey: AppConstants.vpnConnectedAtKey), 0,
                             "precondition: suite holds a 'connected' timestamp")

        // The .stop branch in VPNControl.perform calls
        // publishOptimisticState(connected: false), which goes through
        // WidgetVPNSnapshot.write — exercise the same call here.
        WidgetVPNSnapshot.write(connected: false, to: defaults)

        XCTAssertNil(defaults.object(forKey: AppConstants.vpnConnectedAtKey),
                     ".stop must clear the connected timestamp")
    }

    func testWriteNilDefaultsIsSafeNoOp() {
        // Defensive: AppGroup unreachable in a test environment is a
        // realistic edge — write must not crash.
        WidgetVPNSnapshot.write(connected: true, to: nil)
        WidgetVPNSnapshot.write(connected: false, to: nil)
    }

    // MARK: - connect timestamp is idempotent across transparent restarts

    func testWriteConnectedPreservesSessionStartAcrossRestarts() throws {
        // Reproduces the user-reported 2026-06-03 split (app 19:27:21 vs widget
        // 0:12): publishWidgetState(connected:true) re-fires on every startTunnel
        // (On-Demand reconnect / extension relaunch). write(true) must PRESERVE
        // the existing session-start timestamp, not reset it to now.
        let suiteName = "widget-snapshot-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create scratch UserDefaults suite"); return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Simulate a long-running session: stamped ~19h ago.
        let longAgo = Date().timeIntervalSince1970 - 70_000
        defaults.set(longAgo, forKey: AppConstants.vpnConnectedAtKey)

        // A transparent restart re-publishes .connected.
        WidgetVPNSnapshot.write(connected: true, to: defaults)
        XCTAssertEqual(defaults.double(forKey: AppConstants.vpnConnectedAtKey), longAgo, accuracy: 0.5,
                       "transparent restart must NOT reset the session-start timestamp")

        // A real disconnect clears it; the next genuine connect stamps fresh.
        WidgetVPNSnapshot.write(connected: false, to: defaults)
        XCTAssertNil(defaults.object(forKey: AppConstants.vpnConnectedAtKey))
        WidgetVPNSnapshot.write(connected: true, to: defaults)
        XCTAssertGreaterThan(defaults.double(forKey: AppConstants.vpnConnectedAtKey), longAgo + 1,
                             "after a real disconnect, the next connect stamps a fresh timestamp")
    }

    // MARK: - CLIENT-VPN-PROFILE-SELECT: selectOurManager

    private func makeManager(providerBundleID: String?) -> NETunnelProviderManager {
        let manager = NETunnelProviderManager()
        if let providerBundleID {
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = providerBundleID
            proto.serverAddress = "test"
            manager.protocolConfiguration = proto
        }
        return manager
    }

    func testSelectOurManagerPicksMatchingBundleID() {
        let ours = makeManager(providerBundleID: "com.madfrog.vpn.tunnel")
        let legacy = makeManager(providerBundleID: "com.example.legacy.tunnel")
        let selected = selectOurManager(from: [legacy, ours], bundleID: "com.madfrog.vpn.tunnel")
        XCTAssertTrue(selected === ours,
                      "must pick the manager matching our tunnel's bundle id, not index 0")
    }

    func testSelectOurManagerReturnsNilWhenNoneMatch() {
        let legacy1 = makeManager(providerBundleID: "com.example.legacy.tunnel")
        let legacy2 = makeManager(providerBundleID: nil)
        let selected = selectOurManager(from: [legacy1, legacy2], bundleID: "com.madfrog.vpn.tunnel")
        XCTAssertNil(selected, "no legacy/foreign profile must ever be silently adopted as ours")
    }

    func testSelectOurManagerOnEmptyListReturnsNil() {
        XCTAssertNil(selectOurManager(from: [], bundleID: "com.madfrog.vpn.tunnel"))
    }

    // MARK: - CLIENT-INTENT-GATE-BYPASS: VPNIntentSubscriptionGate.mayConnect

    // Mirrors AppStateConnectGateTests — this is a deliberate duplicate of
    // AppState.mayConnect (see VPNControlIntents.swift's header comment on
    // why the widget target can't import AppState), so the same matrix is
    // pinned here to catch the two definitions drifting apart.
    private let gateNow = Date(timeIntervalSince1970: 1_700_000_000)
    private var gateFuture: Date { gateNow.addingTimeInterval(86_400) }
    private var gatePast: Date { gateNow.addingTimeInterval(-86_400) }

    func testGateFutureExpiryMayConnect() {
        XCTAssertTrue(VPNIntentSubscriptionGate.mayConnect(subscriptionExpire: gateFuture, isPremium: false, now: gateNow))
    }

    func testGatePastExpiryBlocked() {
        XCTAssertFalse(VPNIntentSubscriptionGate.mayConnect(subscriptionExpire: gatePast, isPremium: false, now: gateNow))
    }

    func testGateNilExpiryNoPremiumBlocked() {
        XCTAssertFalse(VPNIntentSubscriptionGate.mayConnect(subscriptionExpire: nil, isPremium: false, now: gateNow))
    }

    func testGatePastExpiryBlocksEvenWithPremiumFlag() {
        // Same NonRenewingSubscription caveat as AppState.mayConnect: a
        // stale/permanent isPremium flag must never override a past backend
        // expiry.
        XCTAssertFalse(VPNIntentSubscriptionGate.mayConnect(subscriptionExpire: gatePast, isPremium: true, now: gateNow))
    }

    func testGateNilExpiryWithPremiumIsFreshPurchaseFallback() {
        XCTAssertTrue(VPNIntentSubscriptionGate.mayConnect(subscriptionExpire: nil, isPremium: true, now: gateNow))
    }
}
