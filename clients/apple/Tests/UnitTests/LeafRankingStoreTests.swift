import XCTest
@testable import MadFrogVPN

@MainActor
final class LeafRankingStoreTests: XCTestCase {

    // MARK: - Helpers

    private func freshDefaults(label: String = #function) -> UserDefaults {
        let suite = "LeafRankingStoreTests-\(label)-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func makeStore(label: String = #function) -> (LeafRankingStore, UserDefaults) {
        let defaults = freshDefaults(label: label)
        let store = LeafRankingStore(defaults: defaults)
        return (store, defaults)
    }

    // MARK: - Basic load/save

    func testLoadOnEmptyStoreReturnsEmpty() {
        let (store, _) = makeStore()
        XCTAssertTrue(store.load().isEmpty)
    }

    func testRoundTrip() {
        let (store, _) = makeStore()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = LeafLatency(tag: "de-direct-de", latencyMs: 42, success: true, measuredAt: date)
        store.save([entry])
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].tag, "de-direct-de")
        XCTAssertEqual(loaded[0].latencyMs, 42)
        XCTAssertTrue(loaded[0].success)
        XCTAssertEqual(
            loaded[0].measuredAt.timeIntervalSince1970,
            date.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testRoundTripMultipleEntries() {
        let (store, _) = makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            LeafLatency(tag: "de-direct-de", latencyMs: 30, success: true, measuredAt: now),
            LeafLatency(tag: "nl-via-msk", latencyMs: 80, success: true, measuredAt: now),
            LeafLatency(tag: "de-via-msk", latencyMs: 0, success: false, measuredAt: now),
        ]
        store.save(entries)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(Set(loaded.map { $0.tag }), Set(entries.map { $0.tag }))
    }

    // MARK: - update() upsert semantics

    func testUpdateUpsertsSameTag() {
        let (store, _) = makeStore()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        store.update(tag: "de-direct-de", latencyMs: 50, success: true, at: t)
        store.update(tag: "de-direct-de", latencyMs: 25, success: true, at: t)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].latencyMs, 25, "second write should replace first")
    }

    func testUpdateDifferentTagAppends() {
        let (store, _) = makeStore()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        store.update(tag: "de-direct-de", latencyMs: 50, success: true, at: t)
        store.update(tag: "nl-direct-nl2", latencyMs: 30, success: true, at: t)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2)
    }

    func testUpdatePreservesOtherEntries() {
        let (store, _) = makeStore()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        store.update(tag: "de-direct-de", latencyMs: 50, success: true, at: t)
        store.update(tag: "nl-direct-nl2", latencyMs: 30, success: true, at: t)
        // Now overwrite only de-direct-de
        store.update(tag: "de-direct-de", latencyMs: 99, success: false, at: t)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2)
        let nl = loaded.first(where: { $0.tag == "nl-direct-nl2" })
        XCTAssertNotNil(nl)
        XCTAssertEqual(nl?.latencyMs, 30, "unrelated entry must not be touched")
    }

    // MARK: - clear()

    func testClearEmptiesStore() {
        let (store, _) = makeStore()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        store.update(tag: "de-direct-de", latencyMs: 50, success: true, at: t)
        store.clear()
        XCTAssertTrue(store.load().isEmpty)
    }

    // MARK: - Storage isolation

    func testTwoStoresWithDifferentKeysDontShareData() {
        let defaults = freshDefaults()
        let storeA = LeafRankingStore(defaults: defaults, storageKey: "key-a")
        let storeB = LeafRankingStore(defaults: defaults, storageKey: "key-b")
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        storeA.update(tag: "de-direct-de", latencyMs: 50, success: true, at: t)
        XCTAssertTrue(storeB.load().isEmpty, "storeB should not see storeA's data")
    }

    // MARK: - Date encoding precision

    func testDateEncodingRoundTrip() {
        let (store, _) = makeStore()
        // Use a date with sub-second component to test ISO-8601 precision.
        let precise = Date(timeIntervalSince1970: 1_700_000_000.999)
        store.update(tag: "de-direct-de", latencyMs: 10, success: true, at: precise)
        let loaded = store.load()
        XCTAssertEqual(
            loaded[0].measuredAt.timeIntervalSince1970,
            precise.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    // MARK: - Graceful garbage handling

    func testDecodingGarbageReturnsEmpty() {
        let defaults = freshDefaults()
        defaults.set("not json", forKey: LeafRankingStore.storageKey)
        let store = LeafRankingStore(defaults: defaults)
        XCTAssertTrue(store.load().isEmpty, "corrupted data must silently yield []")
    }
}
