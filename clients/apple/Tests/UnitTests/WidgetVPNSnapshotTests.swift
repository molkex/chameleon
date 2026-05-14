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
}
