import XCTest
@testable import MadFrogVPN

/// SubscriptionManager.loadWithRetry (2026-06-05) — the auto-retry behind
/// product loading. StoreKit's Product.products(for:) can return an EMPTY array
/// WITHOUT throwing (transient, esp. right after launch), which left an empty
/// paywall (observed in prod: paywall.view products:0, zero Apple-IAP convs).
/// These pin the retry semantics with an injected fetch (no StoreKit) and a
/// no-op sleep (no real waiting).
@MainActor
final class SubscriptionLoadRetryTests: XCTestCase {

    func testRetriesUntilNonEmpty() async {
        var calls = 0
        let result = await SubscriptionManager.loadWithRetry(maxAttempts: 3, sleep: { _ in }) {
            () -> [Int] in
            calls += 1
            return calls < 3 ? [] : [1, 2, 3, 4]   // empty twice, then loads
        }
        XCTAssertEqual(result.items, [1, 2, 3, 4])
        XCTAssertEqual(result.attempts, 3, "should have taken 3 attempts")
        XCTAssertEqual(calls, 3)
        XCTAssertNil(result.lastError)
    }

    func testNoRetryWhenFirstSucceeds() async {
        var calls = 0
        let result = await SubscriptionManager.loadWithRetry(maxAttempts: 3, sleep: { _ in }) {
            () -> [Int] in
            calls += 1
            return [42]
        }
        XCTAssertEqual(result.items, [42])
        XCTAssertEqual(calls, 1, "a successful first call must not retry")
        XCTAssertEqual(result.attempts, 1)
    }

    func testGivesUpEmptyAfterMaxAttempts() async {
        var calls = 0
        let result = await SubscriptionManager.loadWithRetry(maxAttempts: 3, sleep: { _ in }) {
            () -> [Int] in
            calls += 1
            return []   // always empty
        }
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(calls, 3, "must exhaust all attempts")
        XCTAssertEqual(result.attempts, 3)
        XCTAssertNil(result.lastError, "empty-without-error is not an error")
    }

    func testRetriesPastAThrow() async {
        struct StoreError: Error {}
        var calls = 0
        let result = await SubscriptionManager.loadWithRetry(maxAttempts: 3, sleep: { _ in }) {
            () async throws -> [Int] in
            calls += 1
            if calls == 1 { throw StoreError() }   // first throws, then loads
            return [7]
        }
        XCTAssertEqual(result.items, [7])
        XCTAssertEqual(calls, 2)
        XCTAssertNil(result.lastError, "a recovered throw clears the error")
    }

    func testCapturesLastErrorWhenAlwaysThrows() async {
        struct StoreError: Error {}
        var calls = 0
        let result = await SubscriptionManager.loadWithRetry(maxAttempts: 2, sleep: { _ in }) {
            () async throws -> [Int] in
            calls += 1
            throw StoreError()
        }
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertNotNil(result.lastError, "all-throw must surface the error for the paywall")
        XCTAssertEqual(calls, 2)
    }

    func testMaxAttemptsClampedToAtLeastOne() async {
        var calls = 0
        let result = await SubscriptionManager.loadWithRetry(maxAttempts: 0, sleep: { _ in }) {
            () -> [Int] in
            calls += 1
            return [1]
        }
        XCTAssertEqual(calls, 1, "maxAttempts < 1 must still run once")
        XCTAssertEqual(result.items, [1])
    }
}
