import XCTest
@testable import MadFrogVPN

// OutboundPenaltyStore lives in PacketTunnel/ but is pure Swift with no
// Libbox dependency — we re-export the source by including it in the
// test target via project.yml. If the unit-test target can't see it, the
// import is symbolic only; build will fail loudly.

final class OutboundPenaltyStoreTests: XCTestCase {

    func testPenaliseMarksOutboundAndIsPenalisedReturnsTrueWithinWindow() {
        let store = OutboundPenaltyStore()
        XCTAssertFalse(store.isPenalised("nl-via-msk"), "Fresh store must not flag any outbound penalised")

        store.penalise("nl-via-msk", window: 60)
        XCTAssertTrue(store.isPenalised("nl-via-msk"), "Just-penalised outbound must read as penalised")
    }

    func testIsPenalisedReturnsFalseAfterWindowExpires() {
        let store = OutboundPenaltyStore()
        store.penalise("nl-via-msk", window: 0.01)         // 10 ms window
        Thread.sleep(forTimeInterval: 0.05)                 // 50 ms wait > window
        XCTAssertFalse(store.isPenalised("nl-via-msk"), "Expired penalty must auto-clear on read")
    }

    func testFirstNonPenalisedSkipsPenalisedAndReturnsFirstClean() {
        let store = OutboundPenaltyStore()
        store.penalise("nl-via-msk", window: 60)
        store.penalise("de-via-msk", window: 60)

        let candidates = ["nl-via-msk", "de-via-msk", "nl-direct-nl2", "ru-spb-de"]
        XCTAssertEqual(store.firstNonPenalised(among: candidates), "nl-direct-nl2",
                       "Should skip both penalised and return first clean member in input order")
    }

    func testFirstNonPenalisedReturnsNilWhenEveryCandidateIsPenalised() {
        let store = OutboundPenaltyStore()
        store.penalise("a", window: 60)
        store.penalise("b", window: 60)

        XCTAssertNil(store.firstNonPenalised(among: ["a", "b"]),
                     "All-penalised input must return nil so caller can fall back to legacy nudge")
    }

    func testFirstNonPenalisedReturnsFirstWhenStoreEmpty() {
        let store = OutboundPenaltyStore()
        XCTAssertEqual(store.firstNonPenalised(among: ["a", "b", "c"]), "a",
                       "Empty store must return first candidate verbatim — no opinion expressed")
    }

    func testPenaliseDoesNotShortenAnExistingLongerPenalty() {
        let store = OutboundPenaltyStore()
        store.penalise("nl-via-msk", window: 60)
        let firstSnapshot = store.snapshot()["nl-via-msk"]!

        store.penalise("nl-via-msk", window: 1)            // shorter
        let secondSnapshot = store.snapshot()["nl-via-msk"]!

        XCTAssertEqual(firstSnapshot, secondSnapshot,
                       "Re-penalising with a shorter window must NOT shorten the existing entry")
    }

    func testPenaliseExtendsAShorterPenalty() {
        let store = OutboundPenaltyStore()
        store.penalise("nl-via-msk", window: 1)
        let firstSnapshot = store.snapshot()["nl-via-msk"]!

        store.penalise("nl-via-msk", window: 60)           // longer
        let secondSnapshot = store.snapshot()["nl-via-msk"]!

        XCTAssertGreaterThan(secondSnapshot, firstSnapshot,
                             "Re-penalising with a longer window must extend the expiry")
    }

    func testResetClearsAllPenalties() {
        let store = OutboundPenaltyStore()
        store.penalise("a", window: 60)
        store.penalise("b", window: 60)
        store.reset()
        XCTAssertFalse(store.isPenalised("a"))
        XCTAssertFalse(store.isPenalised("b"))
        XCTAssertTrue(store.snapshot().isEmpty)
    }

    func testFirstNonPenalisedSweepsExpiredEntriesOnRead() {
        let store = OutboundPenaltyStore()
        store.penalise("expired-leaf", window: 0.01)
        store.penalise("fresh-leaf", window: 60)
        Thread.sleep(forTimeInterval: 0.05)

        // Side-effect under test: snapshot returns a freshly-filtered map.
        let snap = store.snapshot()
        XCTAssertNil(snap["expired-leaf"], "snapshot() must drop expired entries")
        XCTAssertNotNil(snap["fresh-leaf"], "Live entries survive the sweep")

        // And firstNonPenalised should treat the expired one as available
        // when it appears in candidates.
        XCTAssertEqual(store.firstNonPenalised(among: ["expired-leaf", "fresh-leaf"]),
                       "expired-leaf",
                       "Expired entry must be eligible again")
    }
}
