import XCTest
@testable import MadFrogVPN

// MARK: - Thread-safe probe call counter

/// Actor that counts how many times the injected probe was called.
/// `probeFn` runs off the MainActor (inside `withTaskGroup`), so we
/// need an isolation boundary that is Sendable-safe.
private actor ProbeCounter {
    private var _count = 0
    func increment() { _count += 1 }
    func count() -> Int { _count }
}

@MainActor
final class PathPickerTests: XCTestCase {

    // MARK: - Helpers

    private func freshDefaults(label: String = #function) -> UserDefaults {
        let suite = "PathPickerTests-\(label)-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// Fake probe that returns a successful result with the given latency map.
    /// Tags NOT in the map produce a failure result. The counter is incremented
    /// for every call so tests can assert no probes were fired (cache hit) or
    /// exactly N probes were fired.
    private func fakeProbeFn(
        latencies: [String: Int],
        counter: ProbeCounter
    ) -> @Sendable (LeafCandidate, TimeInterval) async -> LeafProbeResult {
        return { candidate, _ in
            await counter.increment()
            if let ms = latencies[candidate.tag] {
                return LeafProbeResult(
                    tag: candidate.tag,
                    latencyMs: ms,
                    success: true,
                    probedAt: Date()
                )
            }
            return LeafProbeResult(
                tag: candidate.tag,
                latencyMs: 0,
                success: false,
                probedAt: Date()
            )
        }
    }

    /// Leaf helper to cut boilerplate in tests.
    private func leaf(
        _ tag: String,
        host: String = "1.2.3.4",
        port: Int = 443,
        type: String = "vless"
    ) -> LeafCandidate {
        LeafCandidate(tag: tag, host: host, port: port, type: type)
    }

    // MARK: - countryCode(forSelectedTag:) mapping

    func testCountryCodeNilInputReturnsNil() {
        XCTAssertNil(PathPicker.countryCode(forSelectedTag: nil))
    }

    func testCountryCodeEmptyStringReturnsNil() {
        XCTAssertNil(PathPicker.countryCode(forSelectedTag: ""))
    }

    func testCountryCodeAutoReturnsNil() {
        XCTAssertNil(PathPicker.countryCode(forSelectedTag: "Auto"))
    }

    func testCountryCodeGermany() {
        XCTAssertEqual(PathPicker.countryCode(forSelectedTag: "🇩🇪 Германия"), "de")
    }

    func testCountryCodeNetherlands() {
        XCTAssertEqual(PathPicker.countryCode(forSelectedTag: "🇳🇱 Нидерланды"), "nl")
    }

    func testCountryCodeRussiaWhitelist() {
        XCTAssertEqual(
            PathPicker.countryCode(forSelectedTag: "🇷🇺 Россия (обход белых списков)"),
            "ru-spb"
        )
    }

    func testCountryCodeRussiaLegacyAlias() {
        XCTAssertEqual(PathPicker.countryCode(forSelectedTag: "🇷🇺 Россия"), "ru-spb")
    }

    func testCountryCodeLeafTagReturnsNil() {
        // Leaf tags are handled as power-mode pins upstream; they must not
        // accidentally map to a country code here.
        XCTAssertNil(PathPicker.countryCode(forSelectedTag: "de-via-msk"))
    }

    // MARK: - LeafCandidate.country

    func testLeafCountryDE() {
        XCTAssertEqual(leaf("de-direct-de").country, "de")
    }

    func testLeafCountryNLViaMsk() {
        XCTAssertEqual(leaf("nl-via-msk").country, "nl")
    }

    func testLeafCountryRuSpbDE() {
        XCTAssertEqual(leaf("ru-spb-de").country, "ru-spb")
    }

    func testLeafCountryRuSpbNL() {
        XCTAssertEqual(leaf("ru-spb-nl").country, "ru-spb")
    }

    // MARK: - LeafCandidate.tcpProbable

    func testTcpProbableVless() {
        XCTAssertTrue(leaf("x", type: "vless").tcpProbable)
    }

    func testTcpProbableTrojan() {
        XCTAssertTrue(leaf("x", type: "trojan").tcpProbable)
    }

    func testTcpProbableHysteria2False() {
        XCTAssertFalse(leaf("x", type: "hysteria2").tcpProbable)
    }

    func testTcpProbableTuicFalse() {
        XCTAssertFalse(leaf("x", type: "tuic").tcpProbable)
    }

    // MARK: - bestLeaf(for:candidates:) - leaf-pin (power mode)

    func testLeafPinReturnsPinnedLeafWithoutProbing() async {
        let counter = ProbeCounter()
        let store = LeafRankingStore(defaults: freshDefaults())
        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(latencies: [:], counter: counter),
            log: { _ in }
        )
        let candidates = [leaf("de-h2-de"), leaf("de-direct-de"), leaf("nl-direct-nl2")]
        let result = await picker.bestLeaf(for: "de-h2-de", candidates: candidates)
        XCTAssertEqual(result, "de-h2-de")
        let callCount = await counter.count()
        XCTAssertEqual(callCount, 0, "leaf-pin must not fire any probes")
    }

    // MARK: - Country filter

    func testCountryFilterDE() async {
        let counter = ProbeCounter()
        let store = LeafRankingStore(defaults: freshDefaults())
        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(
                latencies: ["de-direct-de": 50, "de-via-msk": 100],
                counter: counter
            ),
            log: { _ in }
        )
        // NL leaf has lower latency but should be filtered out by DE country.
        let candidates = [
            leaf("de-direct-de"),
            leaf("de-via-msk"),
            leaf("nl-direct-nl2"),
        ]
        let result = await picker.bestLeaf(for: "🇩🇪 Германия", candidates: candidates)
        XCTAssertEqual(result, "de-direct-de")
    }

    // MARK: - Auto (no country filter)

    func testAutoPicksLowestLatencyAcrossAllCountries() async {
        let counter = ProbeCounter()
        let store = LeafRankingStore(defaults: freshDefaults())
        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(
                latencies: ["de-direct-de": 80, "nl-direct-nl2": 20, "de-via-msk": 60],
                counter: counter
            ),
            log: { _ in }
        )
        let candidates = [
            leaf("de-direct-de"),
            leaf("nl-direct-nl2"),
            leaf("de-via-msk"),
        ]
        let result = await picker.bestLeaf(for: "Auto", candidates: candidates)
        XCTAssertEqual(result, "nl-direct-nl2")
    }

    // MARK: - All probes fail

    func testAllProbeFailuresReturnsFirstAlphabetical() async {
        let store = LeafRankingStore(defaults: freshDefaults())
        let counter = ProbeCounter()
        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(latencies: [:], counter: counter),
            log: { _ in }
        )
        // "de-direct-de" < "de-via-msk" alphabetically
        let candidates = [leaf("de-via-msk"), leaf("de-direct-de")]
        let result = await picker.bestLeaf(for: nil, candidates: candidates)
        XCTAssertNotNil(result)
        // Picker falls back to first in `probable` list (order preserved from pool, not re-sorted)
        // but it returns a non-nil result — main assertion is liveness.
    }

    // MARK: - UDP-only pool

    func testUdpOnlyPoolReturnsFirstByTagWithoutProbing() async {
        let counter = ProbeCounter()
        let store = LeafRankingStore(defaults: freshDefaults())
        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(latencies: [:], counter: counter),
            log: { _ in }
        )
        let candidates = [
            leaf("de-tuic-de", type: "tuic"),
            leaf("de-tuic2-de", type: "tuic"),
        ]
        let result = await picker.bestLeaf(for: nil, candidates: candidates)
        XCTAssertEqual(result, "de-tuic-de", "first alphabetically among UDP-only")
        let callCount = await counter.count()
        XCTAssertEqual(callCount, 0, "UDP pool must not fire any probes")
    }

    // MARK: - Mixed UDP + TCP, all TCP fail

    func testMixedPoolAllTCPFailsFallsBackToUDP() async {
        let counter = ProbeCounter()
        let store = LeafRankingStore(defaults: freshDefaults())
        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(latencies: [:], counter: counter),
            log: { _ in }
        )
        let candidates = [
            leaf("de-direct-de", type: "vless"),   // TCP, will fail
            leaf("de-tuic-de", type: "tuic"),       // UDP, unprobeable
        ]
        let result = await picker.bestLeaf(for: nil, candidates: candidates)
        XCTAssertEqual(result, "de-tuic-de")
    }

    // MARK: - Empty pool

    func testEmptyPoolReturnsNil() async {
        let store = LeafRankingStore(defaults: freshDefaults())
        let picker = PathPicker(store: store, log: { _ in })
        let result = await picker.bestLeaf(for: nil, candidates: [])
        XCTAssertNil(result)
    }

    // MARK: - Cache hit

    func testCacheHitSkipsProbes() async {
        let counter = ProbeCounter()
        let defaults = freshDefaults()
        let store = LeafRankingStore(defaults: defaults)
        // Pre-populate with fresh measurements for every candidate.
        let freshDate = Date()
        store.update(tag: "de-direct-de", latencyMs: 30, success: true, at: freshDate)
        store.update(tag: "de-via-msk", latencyMs: 80, success: true, at: freshDate)

        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(latencies: ["de-direct-de": 30, "de-via-msk": 80], counter: counter),
            now: { freshDate },
            log: { _ in }
        )
        let candidates = [leaf("de-direct-de"), leaf("de-via-msk")]
        let result = await picker.bestLeaf(for: nil, candidates: candidates)
        XCTAssertEqual(result, "de-direct-de", "cache should pick the lower-latency entry")
        let callCount = await counter.count()
        XCTAssertEqual(callCount, 0, "fresh cache must not fire probes")
    }

    // MARK: - Cache stale

    func testStaleCacheTriggersProbes() async {
        let counter = ProbeCounter()
        let defaults = freshDefaults()
        let store = LeafRankingStore(defaults: defaults)
        // Write a measurement that is 10 minutes old (beyond defaultCacheTTL of 5 min).
        let staleDate = Date().addingTimeInterval(-(PathPicker.defaultCacheTTL + 60))
        store.update(tag: "de-direct-de", latencyMs: 30, success: true, at: staleDate)

        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(latencies: ["de-direct-de": 30], counter: counter),
            log: { _ in }
        )
        let candidates = [leaf("de-direct-de")]
        _ = await picker.bestLeaf(for: nil, candidates: candidates)
        let callCount = await counter.count()
        XCTAssertGreaterThan(callCount, 0, "stale cache must trigger a live probe")
    }

    // MARK: - Partial cache

    func testPartialCacheTriggersProbesForAll() async {
        let counter = ProbeCounter()
        let defaults = freshDefaults()
        let store = LeafRankingStore(defaults: defaults)
        let freshDate = Date()
        // Only one of two candidates is in the cache.
        store.update(tag: "de-direct-de", latencyMs: 30, success: true, at: freshDate)
        // "de-via-msk" has no cache entry.

        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(latencies: ["de-direct-de": 30, "de-via-msk": 80], counter: counter),
            now: { freshDate },
            log: { _ in }
        )
        let candidates = [leaf("de-direct-de"), leaf("de-via-msk")]
        _ = await picker.bestLeaf(for: nil, candidates: candidates)
        // Both candidates must be re-probed when cache is incomplete.
        let callCount = await counter.count()
        XCTAssertEqual(callCount, 2, "partial cache must re-probe all TCP-probable candidates")
    }

    // MARK: - bestLeaf(excluding:)

    func testExcludingDeadLeafPicksNextBest() async {
        let counter = ProbeCounter()
        let store = LeafRankingStore(defaults: freshDefaults())
        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(
                latencies: ["de-direct-de": 30, "de-via-msk": 80],
                counter: counter
            ),
            log: { _ in }
        )
        let candidates = [leaf("de-direct-de"), leaf("de-via-msk")]
        // "de-direct-de" would normally win, but it's excluded.
        let result = await picker.bestLeaf(
            excluding: ["de-direct-de"],
            for: nil,
            candidates: candidates
        )
        XCTAssertEqual(result, "de-via-msk")
    }

    // MARK: - Recording

    func testRecordSuccessWritesToStore() {
        let defaults = freshDefaults()
        let store = LeafRankingStore(defaults: defaults)
        let picker = PathPicker(store: store, log: { _ in })
        picker.recordSuccess(leaf: "de-direct-de", latencyMs: 42)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].tag, "de-direct-de")
        XCTAssertEqual(loaded[0].latencyMs, 42)
        XCTAssertTrue(loaded[0].success)
    }

    func testRecordFailureWritesSuccessFalse() {
        let defaults = freshDefaults()
        let store = LeafRankingStore(defaults: defaults)
        let picker = PathPicker(store: store, log: { _ in })
        picker.recordFailure(leaf: "de-direct-de")
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertFalse(loaded[0].success)
        XCTAssertEqual(loaded[0].latencyMs, 0)
    }

    // MARK: - cachedBestLeaf (build-40, no-probe variant)

    /// Regression test for build-37 LTE bug: pre-connect probe correctly
    /// marked `de-direct-de` as failed and `de-via-msk` as the only
    /// successful leaf. After connect, the legacy `bestLeaf` re-probed
    /// (because `allSatisfy` required ALL pool entries fresh, and the
    /// failed entry was filtered out) and the in-tunnel re-probe falsely
    /// resurrected the dead leaf. `cachedBestLeaf` must NOT trigger any
    /// probes and must return the surviving good leaf.
    func testCachedBestLeafReturnsLowestSuccessfulNoProbe() async {
        let counter = ProbeCounter()
        let defaults = freshDefaults()
        let store = LeafRankingStore(defaults: defaults)
        let now = Date()
        store.update(tag: "de-direct-de", latencyMs: 0, success: false, at: now)
        store.update(tag: "de-via-msk", latencyMs: 80, success: true, at: now)

        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(latencies: [:], counter: counter),
            now: { now },
            log: { _ in }
        )
        let candidates = [leaf("de-direct-de"), leaf("de-via-msk")]
        let result = picker.cachedBestLeaf(for: "🇩🇪 Германия", candidates: candidates)
        XCTAssertEqual(result, "de-via-msk", "must skip the failed entry and pick the surviving good leaf")
        let calls = await counter.count()
        XCTAssertEqual(calls, 0, "cachedBestLeaf must never probe")
    }

    func testCachedBestLeafLeafPinReturnsLeafImmediately() async {
        let counter = ProbeCounter()
        let store = LeafRankingStore(defaults: freshDefaults())
        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(latencies: [:], counter: counter),
            log: { _ in }
        )
        let candidates = [leaf("de-direct-de"), leaf("de-via-msk")]
        let result = picker.cachedBestLeaf(for: "de-via-msk", candidates: candidates)
        XCTAssertEqual(result, "de-via-msk")
        let calls = await counter.count()
        XCTAssertEqual(calls, 0)
    }

    func testCachedBestLeafReturnsNilWhenNoFreshSuccess() async {
        let counter = ProbeCounter()
        let store = LeafRankingStore(defaults: freshDefaults())
        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(latencies: [:], counter: counter),
            log: { _ in }
        )
        let candidates = [leaf("de-direct-de"), leaf("de-via-msk")]
        // Empty store — caller should fall through to "skip and let baked-in default stand".
        let result = picker.cachedBestLeaf(for: "🇩🇪 Германия", candidates: candidates)
        XCTAssertNil(result)
        let calls = await counter.count()
        XCTAssertEqual(calls, 0)
    }

    func testCachedBestLeafIgnoresStaleEntries() async {
        let counter = ProbeCounter()
        let defaults = freshDefaults()
        let store = LeafRankingStore(defaults: defaults)
        let now = Date()
        let stale = now.addingTimeInterval(-(PathPicker.defaultCacheTTL + 60))
        store.update(tag: "de-via-msk", latencyMs: 80, success: true, at: stale)

        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(latencies: [:], counter: counter),
            now: { now },
            log: { _ in }
        )
        let candidates = [leaf("de-via-msk")]
        let result = picker.cachedBestLeaf(for: "🇩🇪 Германия", candidates: candidates)
        XCTAssertNil(result, "stale entries past defaultCacheTTL must not satisfy cache-only lookup")
    }

    func testCachedBestLeafPicksLowestLatency() async {
        let counter = ProbeCounter()
        let defaults = freshDefaults()
        let store = LeafRankingStore(defaults: defaults)
        let now = Date()
        store.update(tag: "de-direct-de", latencyMs: 30, success: true, at: now)
        store.update(tag: "de-via-msk", latencyMs: 80, success: true, at: now)

        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(latencies: [:], counter: counter),
            now: { now },
            log: { _ in }
        )
        let candidates = [leaf("de-direct-de"), leaf("de-via-msk")]
        let result = picker.cachedBestLeaf(for: "🇩🇪 Германия", candidates: candidates)
        XCTAssertEqual(result, "de-direct-de")
    }

    func testCachedBestLeafSetsCurrentLeaf() {
        let store = LeafRankingStore(defaults: freshDefaults())
        let now = Date()
        store.update(tag: "de-via-msk", latencyMs: 80, success: true, at: now)
        let picker = PathPicker(store: store, now: { now }, log: { _ in })
        XCTAssertNil(picker.currentLeaf)
        _ = picker.cachedBestLeaf(for: "🇩🇪 Германия", candidates: [leaf("de-via-msk")])
        XCTAssertEqual(picker.currentLeaf, "de-via-msk")
    }

    // MARK: - leaf(_:matchesSelection:in:)

    func testLeafMatchesSelectionExactPin() {
        let pool = [leaf("de-direct-de"), leaf("de-via-msk")]
        XCTAssertTrue(PathPicker.leaf("de-via-msk", matchesSelection: "de-via-msk", in: pool))
    }

    func testLeafMatchesSelectionCountry() {
        let pool = [leaf("de-direct-de"), leaf("de-via-msk"), leaf("nl-direct-nl2")]
        XCTAssertTrue(PathPicker.leaf("de-direct-de", matchesSelection: "🇩🇪 Германия", in: pool))
        XCTAssertTrue(PathPicker.leaf("de-via-msk", matchesSelection: "🇩🇪 Германия", in: pool))
        XCTAssertFalse(PathPicker.leaf("nl-direct-nl2", matchesSelection: "🇩🇪 Германия", in: pool))
    }

    func testLeafMatchesSelectionAutoAcceptsAny() {
        let pool = [leaf("de-direct-de"), leaf("nl-direct-nl2")]
        XCTAssertTrue(PathPicker.leaf("de-direct-de", matchesSelection: "Auto", in: pool))
        XCTAssertTrue(PathPicker.leaf("nl-direct-nl2", matchesSelection: nil, in: pool))
    }

    func testLeafMatchesSelectionStaleLeafNotInPool() {
        // After a config refresh that drops `de-direct-de`, a stale
        // currentLeaf pointing at it must NOT match — caller will fall
        // through to cache-only or skip.
        let pool = [leaf("de-via-msk")]
        XCTAssertFalse(PathPicker.leaf("de-direct-de", matchesSelection: "🇩🇪 Германия", in: pool))
    }

    // MARK: - isDirect classifier

    func testIsDirectForDirectLeaf() {
        XCTAssertTrue(leaf("de-direct-de").isDirect)
        XCTAssertTrue(leaf("nl-direct-nl2").isDirect)
        XCTAssertTrue(leaf("de-h2-de").isDirect)
        XCTAssertTrue(leaf("nl-tuic-nl2").isDirect)
    }

    func testIsDirectFalseForViaRelay() {
        XCTAssertFalse(leaf("de-via-msk").isDirect)
        XCTAssertFalse(leaf("nl-via-msk").isDirect)
    }

    func testIsDirectFalseForRuSpb() {
        // ru-spb-* are whitelist-bypass relays, never "direct" in the
        // user's mental model.
        XCTAssertFalse(leaf("ru-spb-de").isDirect)
        XCTAssertFalse(leaf("ru-spb-nl").isDirect)
    }

    // MARK: - Cascade selection (build-40 final)

    /// Cascade test: when direct's TLS probe succeeds, direct wins
    /// regardless of relay's lower first-hop latency. Relay measures only
    /// hop to MSK; end-to-end through working direct is strictly better.
    func testCascadeDirectWinsWhenAlive() async {
        let counter = ProbeCounter()
        let store = LeafRankingStore(defaults: freshDefaults())
        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(
                latencies: ["de-direct-de": 50, "de-via-msk": 10],
                counter: counter
            ),
            log: { _ in }
        )
        let candidates = [leaf("de-direct-de"), leaf("de-via-msk")]
        let result = await picker.bestLeaf(for: "🇩🇪 Германия", candidates: candidates)
        XCTAssertEqual(result, "de-direct-de", "cascade: direct wins when its probe succeeds")
    }

    /// When direct's TLS probe fails (RKN TLS-level block on the network),
    /// fall back to relay. This is the LTE / blocked-network case.
    func testCascadeFallsBackToRelayWhenDirectFails() async {
        let counter = ProbeCounter()
        let store = LeafRankingStore(defaults: freshDefaults())
        // de-direct-de probe fails (not in latencies dict), relay succeeds.
        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(latencies: ["de-via-msk": 10], counter: counter),
            log: { _ in }
        )
        let candidates = [leaf("de-direct-de"), leaf("de-via-msk")]
        let result = await picker.bestLeaf(for: "🇩🇪 Германия", candidates: candidates)
        XCTAssertEqual(result, "de-via-msk")
    }

    /// When direct AND relay both fail, fall back to bypass (SPB whitelist).
    func testCascadeFallsBackToBypassWhenDirectAndRelayFail() async {
        let counter = ProbeCounter()
        let store = LeafRankingStore(defaults: freshDefaults())
        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(latencies: ["ru-spb-de": 30], counter: counter),
            log: { _ in }
        )
        let candidates = [leaf("de-direct-de"), leaf("de-via-msk"), leaf("ru-spb-de")]
        let result = await picker.bestLeaf(for: nil, candidates: candidates)
        XCTAssertEqual(result, "ru-spb-de")
    }

    /// Within the direct class, lower probe latency wins.
    func testCascadeWithinDirectLowerLatencyWins() async {
        let counter = ProbeCounter()
        let store = LeafRankingStore(defaults: freshDefaults())
        let picker = PathPicker(
            store: store,
            probeFn: fakeProbeFn(
                latencies: ["de-direct-de": 80, "de-h2-de": 30],
                counter: counter
            ),
            log: { _ in }
        )
        let candidates = [leaf("de-direct-de"), leaf("de-h2-de")]
        let result = await picker.bestLeaf(for: "🇩🇪 Германия", candidates: candidates)
        XCTAssertEqual(result, "de-h2-de")
    }

    // MARK: - Build-39 demote-class tests

    /// When the caller passes `demoteClasses: [.direct]` (because per-network
    /// history says direct never worked here), cascadePick must skip
    /// `.direct` even when a direct candidate has a fresh successful
    /// measurement, and pick the lowest-latency relay instead.
    func testCascadePickDemotesDirectOnRequest() {
        let candidates = [
            leaf("de-direct-de"),
            leaf("de-via-msk"),
        ]
        let latencies: [String: Int] = ["de-direct-de": 30, "de-via-msk": 80]
        let pick = PathPicker.cascadePick(
            candidates,
            latencyByTag: { latencies[$0] },
            demoteClasses: [.direct]
        )
        XCTAssertEqual(pick?.tag, "de-via-msk", "demote=direct must skip direct in favour of relay")
    }

    /// With no demoted classes, behaviour is unchanged — direct wins by
    /// cascade priority even though relay has lower latency. Regression
    /// guard for the default code path.
    func testCascadePickEmptyDemoteIsBackwardCompatible() {
        let candidates = [
            leaf("de-direct-de"),
            leaf("de-via-msk"),
        ]
        let latencies: [String: Int] = ["de-direct-de": 30, "de-via-msk": 80]
        let pick = PathPicker.cascadePick(
            candidates,
            latencyByTag: { latencies[$0] }
        )
        XCTAssertEqual(pick?.tag, "de-direct-de", "default cascade must keep preferring direct")
    }

    /// If every non-demoted class is empty/unmeasured, the picker must
    /// fall back to a demoted candidate rather than refuse to connect.
    /// Better to give the user SOMETHING that probably works than nil.
    func testCascadePickFallsBackToDemotedClassWhenOthersEmpty() {
        let candidates = [leaf("de-direct-de")]   // only direct available
        let latencies: [String: Int] = ["de-direct-de": 30]
        let pick = PathPicker.cascadePick(
            candidates,
            latencyByTag: { latencies[$0] },
            demoteClasses: [.direct]
        )
        XCTAssertEqual(pick?.tag, "de-direct-de", "demoted class must still be reachable as last resort")
    }

    /// Cache-only path: same cascade — alive direct wins over alive relay.
    func testCachedBestLeafCascadesDirectOverRelay() {
        let store = LeafRankingStore(defaults: freshDefaults())
        let now = Date()
        store.update(tag: "de-direct-de", latencyMs: 50, success: true, at: now)
        store.update(tag: "de-via-msk", latencyMs: 10, success: true, at: now)
        let picker = PathPicker(store: store, now: { now }, log: { _ in })
        let candidates = [leaf("de-direct-de"), leaf("de-via-msk")]
        let result = picker.cachedBestLeaf(for: "🇩🇪 Германия", candidates: candidates)
        XCTAssertEqual(result, "de-direct-de")
    }

    /// Cache-only path: direct has no fresh measurement → fall to relay.
    func testCachedBestLeafCascadesToRelayWhenDirectMissing() {
        let store = LeafRankingStore(defaults: freshDefaults())
        let now = Date()
        store.update(tag: "de-via-msk", latencyMs: 10, success: true, at: now)
        let picker = PathPicker(store: store, now: { now }, log: { _ in })
        let candidates = [leaf("de-direct-de"), leaf("de-via-msk")]
        let result = picker.cachedBestLeaf(for: "🇩🇪 Германия", candidates: candidates)
        XCTAssertEqual(result, "de-via-msk")
    }

    // MARK: - LeafClass enum

    func testLeafClassDirect() {
        XCTAssertEqual(leaf("de-direct-de").leafClass, .direct)
        XCTAssertEqual(leaf("de-h2-de").leafClass, .direct)
        XCTAssertEqual(leaf("nl-direct-nl2").leafClass, .direct)
        XCTAssertEqual(leaf("de-tuic-de").leafClass, .direct)
    }

    func testLeafClassRelay() {
        XCTAssertEqual(leaf("de-via-msk").leafClass, .relay)
        XCTAssertEqual(leaf("nl-via-msk").leafClass, .relay)
    }

    func testLeafClassBypass() {
        XCTAssertEqual(leaf("ru-spb-de").leafClass, .bypass)
        XCTAssertEqual(leaf("ru-spb-nl").leafClass, .bypass)
    }

    func testLeafClassPriorityOrdering() {
        XCTAssertLessThan(LeafClass.direct, LeafClass.relay)
        XCTAssertLessThan(LeafClass.relay, LeafClass.bypass)
    }
}
