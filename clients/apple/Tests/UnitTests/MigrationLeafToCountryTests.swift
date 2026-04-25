import XCTest
@testable import MadFrogVPN

/// Tests for the build-32 leaf-to-country migration. Uses the pure-logic
/// overload `migrateLeafToCountry(currentTag:servers:isMigrated:markMigrated:)`
/// so we don't need a real ConfigStore or App Group UserDefaults.
@MainActor
final class MigrationLeafToCountryTests: XCTestCase {

    /// Synthetic server topology mirroring what `ConfigStore.parseServersFromConfig`
    /// produces post-2026-04-25: a Proxy selector with country urltests and
    /// each country listing the leaves reachable through it.
    private static func sampleServers() -> [ServerGroup] {
        let de = CountryGroup(
            id: "🇩🇪 Германия",
            tag: "🇩🇪 Германия",
            name: "Германия",
            flagEmoji: "🇩🇪",
            serverTags: ["de-direct-de", "de-h2-de", "de-tuic-de", "de-via-msk"],
            bestDelay: 50,
            section: .direct,
            subtitle: "4 сервера"
        )
        let nl = CountryGroup(
            id: "🇳🇱 Нидерланды",
            tag: "🇳🇱 Нидерланды",
            name: "Нидерланды",
            flagEmoji: "🇳🇱",
            serverTags: ["nl-direct-nl2", "nl-via-msk"],
            bestDelay: 60,
            section: .direct,
            subtitle: "2 сервера"
        )
        let proxy = ServerGroup(
            id: "Proxy", tag: "Proxy", type: "selector",
            selected: "Auto",
            items: [],
            selectable: true,
            hasAuto: true,
            countries: [de, nl]
        )
        return [proxy]
    }

    // MARK: - Stateful one-shot guard

    private final class GuardState {
        var done = false
    }

    private static func makeGuard(initiallyDone: Bool = false) -> (GuardState, () -> Bool, () -> Void) {
        let g = GuardState()
        g.done = initiallyDone
        return (g, { g.done }, { g.done = true })
    }

    // MARK: - Tests

    func testLeafIsRewrittenToCountry() {
        let (g, isDone, markDone) = Self.makeGuard()
        let result = AppState.migrateLeafToCountry(
            currentTag: "de-h2-de",
            servers: Self.sampleServers(),
            isMigrated: isDone,
            markMigrated: markDone
        )
        XCTAssertEqual(result, "🇩🇪 Германия")
        XCTAssertTrue(g.done, "guard should be set after a successful migration")
    }

    func testCountryUrltestIsUntouched() {
        let (g, isDone, markDone) = Self.makeGuard()
        let result = AppState.migrateLeafToCountry(
            currentTag: "🇩🇪 Германия",
            servers: Self.sampleServers(),
            isMigrated: isDone,
            markMigrated: markDone
        )
        XCTAssertNil(result)
        XCTAssertTrue(g.done, "guard should be set even when no rewrite needed")
    }

    func testNilTagIsNoop() {
        let (g, isDone, markDone) = Self.makeGuard()
        let result = AppState.migrateLeafToCountry(
            currentTag: nil,
            servers: Self.sampleServers(),
            isMigrated: isDone,
            markMigrated: markDone
        )
        XCTAssertNil(result)
        XCTAssertTrue(g.done)
    }

    func testAlreadyMigratedSkips() {
        let (_, isDone, markDone) = Self.makeGuard(initiallyDone: true)
        let result = AppState.migrateLeafToCountry(
            currentTag: "de-h2-de",
            servers: Self.sampleServers(),
            isMigrated: isDone,
            markMigrated: markDone
        )
        XCTAssertNil(result, "second-launch must not rewrite again")
    }

    func testIdempotent() {
        // First call rewrites. Second call (with the same guard state)
        // returns nil because isMigrated() now reports true.
        let (_, isDone, markDone) = Self.makeGuard()
        _ = AppState.migrateLeafToCountry(
            currentTag: "de-h2-de",
            servers: Self.sampleServers(),
            isMigrated: isDone,
            markMigrated: markDone
        )
        let second = AppState.migrateLeafToCountry(
            currentTag: "de-h2-de",
            servers: Self.sampleServers(),
            isMigrated: isDone,
            markMigrated: markDone
        )
        XCTAssertNil(second)
    }

    func testOrphanLeafReturnsNilButGuardIsStillMarked() {
        // Leaf tag references a country we don't know about — leave the
        // pin alone but still mark migration as done. Otherwise we'd loop
        // here forever on every launch.
        let (g, isDone, markDone) = Self.makeGuard()
        let result = AppState.migrateLeafToCountry(
            currentTag: "ru-spb-de",  // not present in sampleServers
            servers: Self.sampleServers(),
            isMigrated: isDone,
            markMigrated: markDone
        )
        XCTAssertNil(result)
        XCTAssertTrue(g.done)
    }

    func testDifferentCountryLeaf() {
        let (_, isDone, markDone) = Self.makeGuard()
        let result = AppState.migrateLeafToCountry(
            currentTag: "nl-via-msk",
            servers: Self.sampleServers(),
            isMigrated: isDone,
            markMigrated: markDone
        )
        XCTAssertEqual(result, "🇳🇱 Нидерланды")
    }
}
