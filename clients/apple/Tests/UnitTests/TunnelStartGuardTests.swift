import XCTest
@testable import MadFrogVPN

/// CLIENT-EXT-RACE (P1) — guard for the startTunnel/stopTunnel zombie race:
/// ExtensionProvider.startTunnel dispatches sing-box bring-up onto an
/// untracked background queue and returns; stopTunnel runs synchronously
/// with no cancellation. A fast connect→disconnect could let the late start
/// completion publish a 'connected' signal (widget state, watchdogs,
/// completionHandler(nil)) after stop already reported 'disconnected'.
/// TunnelStartGuard is the pure generation/epoch counter that closes this —
/// these tests pin its semantics independent of the NEPacketTunnelProvider
/// host (which can't run in the unsigned-sim unit test target).
final class TunnelStartGuardTests: XCTestCase {

    func testFreshTokenIsCurrent() {
        let guardObj = TunnelStartGuard()
        let token = guardObj.beginGeneration()
        XCTAssertTrue(guardObj.isCurrent(token))
    }

    func testInvalidateStalesTheInFlightStart() {
        // Simulates: startTunnel captures its token, then stopTunnel fires
        // before the async start block finishes.
        let guardObj = TunnelStartGuard()
        let startToken = guardObj.beginGeneration()

        guardObj.invalidate() // stopTunnel

        XCTAssertFalse(guardObj.isCurrent(startToken),
                        "a start token must go stale once stopTunnel invalidates the guard")
    }

    func testInvalidateWithNoPriorStartIsHarmless() {
        // stopTunnel can fire with no startTunnel ever having run.
        let guardObj = TunnelStartGuard()
        guardObj.invalidate()
        // No token existed, nothing to assert beyond "doesn't crash" —
        // exercised for coverage of the no-op path.
    }

    func testNewStartAfterInvalidateBecomesCurrentAgain() {
        // A second connect attempt after a stop must be able to succeed
        // normally — the guard must not permanently wedge into "always
        // stale".
        let guardObj = TunnelStartGuard()
        let firstToken = guardObj.beginGeneration()
        guardObj.invalidate()

        let secondToken = guardObj.beginGeneration()

        XCTAssertFalse(guardObj.isCurrent(firstToken))
        XCTAssertTrue(guardObj.isCurrent(secondToken))
    }

    func testSecondStartWithoutStopStalesTheFirst() {
        // Two overlapping startTunnel calls (system quirk / retry): the
        // second start supersedes the first even without an explicit stop.
        let guardObj = TunnelStartGuard()
        let firstToken = guardObj.beginGeneration()
        let secondToken = guardObj.beginGeneration()

        XCTAssertFalse(guardObj.isCurrent(firstToken))
        XCTAssertTrue(guardObj.isCurrent(secondToken))
    }

    func testConcurrentBeginGenerationProducesUniqueMonotonicTokens() {
        // Guards against a naive non-atomic counter losing increments under
        // concurrent access (the whole point of using NSLock here).
        let guardObj = TunnelStartGuard()
        let iterations = 500
        var tokens = [Int](repeating: 0, count: iterations)
        let lock = NSLock()
        var nextIndex = 0

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            let token = guardObj.beginGeneration()
            lock.lock()
            tokens[nextIndex] = token
            nextIndex += 1
            lock.unlock()
        }

        let uniqueTokens = Set(tokens)
        XCTAssertEqual(uniqueTokens.count, iterations,
                        "every beginGeneration() call must yield a distinct token — a lost increment means two in-flight starts would share a generation")
    }
}
