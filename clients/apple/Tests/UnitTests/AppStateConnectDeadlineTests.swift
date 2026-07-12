import XCTest
@testable import MadFrogVPN

/// CLIENT-CONNECT-DEADLINE (2026-07-12). Project rule (CLAUDE.md): a VPN
/// connect must fail within 30s wall-clock if it never reaches `.connected`.
/// `awaitConnectionWithSilentRetry` itself needs a live `VPNManager`/NE
/// round-trip to exercise end-to-end, so it isn't unit-testable directly —
/// but the three `Duration`s that drive its worst-case budget
/// (`connectAttemptTimeout`, `disconnectWaitTimeout`, `retrySleep`) were
/// extracted as named, internal statics specifically so the arithmetic can
/// be pinned here instead of only living in a comment.
final class AppStateConnectDeadlineTests: XCTestCase {

    func testWorstCaseBudgetIsWithin30Seconds() {
        // Worst case: first attempt times out, we tear down, wait for
        // disconnect, sleep, then the second attempt also times out.
        // first attempt + disconnect-wait + retry-sleep + second attempt
        let total = AppState.connectAttemptTimeout
            + AppState.disconnectWaitTimeout
            + AppState.retrySleep
            + AppState.connectAttemptTimeout

        XCTAssertLessThanOrEqual(total, .seconds(30))
        XCTAssertEqual(total, .seconds(29))
    }
}
