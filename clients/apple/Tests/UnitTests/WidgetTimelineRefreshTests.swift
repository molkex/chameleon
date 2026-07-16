import XCTest
@testable import MadFrogVPN

/// WIDGET-CONNECTING-TIMELINE-FIX (2026-07-16): pins `WidgetVPNSnapshot.nextTimelineRefresh`,
/// the seam that replaced `StatusProvider.getTimeline`'s old hardcoded
/// `connected: false` fallback entry. A device log the same day showed a
/// real connect succeed in ~1s while the widget still rendered "Не
/// защищено" for ~28s, because the old code baked a guess at render time
/// instead of scheduling a re-read.
final class WidgetTimelineRefreshTests: XCTestCase {

    func testConnectingRefreshesAtFlagExpiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let connectingAt = now.addingTimeInterval(-5) // stamped 5s ago
        let snapshot = WidgetVPNSnapshot(connected: false, serverName: "Auto",
                                          connecting: true, connectingAt: connectingAt)
        XCTAssertEqual(snapshot.nextTimelineRefresh(now: now), connectingAt.addingTimeInterval(30))
    }

    func testNotConnectingRefreshesIn30Minutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = WidgetVPNSnapshot(connected: false, serverName: nil)
        XCTAssertEqual(snapshot.nextTimelineRefresh(now: now), now.addingTimeInterval(30 * 60))
    }

    func testConnectedIgnoresConnectingFlag() {
        // `connected` always wins in WidgetVPNSnapshot.read(), so a real
        // instance can never have both true — but nextTimelineRefresh must
        // not accidentally key off a stale connectingAt if constructed
        // directly with connected=true.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = WidgetVPNSnapshot(connected: true, serverName: "Auto",
                                          connectedAt: now, connecting: false, connectingAt: nil)
        XCTAssertEqual(snapshot.nextTimelineRefresh(now: now), now.addingTimeInterval(30 * 60))
    }

    func testConnectingWithoutTimestampFallsBackTo30Minutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = WidgetVPNSnapshot(connected: false, serverName: nil,
                                          connecting: true, connectingAt: nil)
        XCTAssertEqual(snapshot.nextTimelineRefresh(now: now), now.addingTimeInterval(30 * 60))
    }
}
