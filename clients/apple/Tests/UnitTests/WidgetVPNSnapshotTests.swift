import XCTest
@testable import MadFrogVPN

/// launch-04: pins the widget snapshot's display logic — the part that
/// has branches worth a test. `read()` itself just touches the App Group
/// UserDefaults (covered on-device); the localised text + fallback are
/// pure and deterministic.
final class WidgetVPNSnapshotTests: XCTestCase {

    func testConnectedSnapshotReportsServerVerbatim() {
        let s = WidgetVPNSnapshot(connected: true, serverName: "🇩🇪 Германия")
        XCTAssertTrue(s.connected)
        XCTAssertEqual(s.serverDisplay, "🇩🇪 Германия",
                       "a stored server name must be shown verbatim, not replaced by the Auto fallback")
    }

    func testMissingServerNameFallsBackToAuto() {
        let none = WidgetVPNSnapshot(connected: true, serverName: nil)
        let empty = WidgetVPNSnapshot(connected: false, serverName: "")
        // Fallback is locale-dependent — assert it's one of the two known
        // values and never empty, rather than hard-coding the language.
        for s in [none, empty] {
            XCTAssertTrue(["Auto", "Авто"].contains(s.serverDisplay),
                          "fallback must be the Auto label, got \(s.serverDisplay)")
            XCTAssertFalse(s.serverDisplay.isEmpty)
        }
    }

    func testStatusTextDiffersByConnectedState() {
        let on = WidgetVPNSnapshot(connected: true, serverName: nil)
        let off = WidgetVPNSnapshot(connected: false, serverName: nil)
        XCTAssertNotEqual(on.statusText, off.statusText,
                          "connected and disconnected must read differently")
        XCTAssertFalse(on.statusText.isEmpty)
        XCTAssertFalse(off.statusText.isEmpty)
    }

    func testEquatable() {
        let a = WidgetVPNSnapshot(connected: true, serverName: "Auto")
        let b = WidgetVPNSnapshot(connected: true, serverName: "Auto")
        let c = WidgetVPNSnapshot(connected: false, serverName: "Auto")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testConnectedAtIsCarriedAndOptional() {
        // launch-04b: connectedAt backs the widget's live uptime timer.
        // It defaults to nil (back-compat with the 2-arg call sites) and
        // is carried verbatim when supplied.
        XCTAssertNil(WidgetVPNSnapshot(connected: false, serverName: nil).connectedAt)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let s = WidgetVPNSnapshot(connected: true, serverName: "Auto", connectedAt: t)
        XCTAssertEqual(s.connectedAt, t)
        // connectedAt participates in Equatable.
        XCTAssertNotEqual(s, WidgetVPNSnapshot(connected: true, serverName: "Auto"))
    }

    // MARK: - write() — the App-Group writer shared by ExtensionProvider
    // (source of truth) and ToggleVPNIntent (optimistic write).

    /// An isolated UserDefaults suite so the test never touches the real
    /// App Group. write() only ever mutates vpnConnectedAtKey.
    private func freshSuite() -> UserDefaults {
        let name = "test.widgetwrite.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removeObject(forKey: AppConstants.vpnConnectedAtKey)
        return d
    }

    func testWriteConnected_StampsAPositiveTimestamp() {
        let d = freshSuite()
        let before = Date().timeIntervalSince1970
        WidgetVPNSnapshot.write(connected: true, to: d)
        let ts = d.double(forKey: AppConstants.vpnConnectedAtKey)
        XCTAssertGreaterThanOrEqual(ts, before,
            "write(connected: true) must stamp a current unix timestamp")
    }

    func testWriteDisconnected_ClearsTheKey() {
        let d = freshSuite()
        WidgetVPNSnapshot.write(connected: true, to: d)
        XCTAssertGreaterThan(d.double(forKey: AppConstants.vpnConnectedAtKey), 0)
        WidgetVPNSnapshot.write(connected: false, to: d)
        XCTAssertEqual(d.double(forKey: AppConstants.vpnConnectedAtKey), 0,
            "write(connected: false) must remove the key — read() treats absent/0 as disconnected")
    }

    func testWriteToNilDefaultsIsNoOp() {
        // App Group unreachable — must not crash.
        WidgetVPNSnapshot.write(connected: true, to: nil)
        WidgetVPNSnapshot.write(connected: false, to: nil)
    }
}
