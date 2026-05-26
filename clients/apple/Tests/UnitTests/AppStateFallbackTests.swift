import XCTest
@testable import MadFrogVPN

/// Regression guard for the cascade-fallback decision logic in
/// `AppState.performFallbackForCurrentLeg`. `AppState` itself is too
/// heavyweight to construct in a unit test (1900+ LoC, several injected
/// stores plus a live `CommandClient`), so the two pure decisions that
/// drive the cascade have been extracted into static helpers
/// (`nextLeafForCountry`, `shouldEscalateBeyondCountry` — both build-85
/// testability extracts) and are exercised here directly.
///
/// NOTE: The build-85 P1-3 side-effect contract — that
/// `fallbackFromCountry` writes BOTH `commandClient.selectOutbound` AND
/// `configStore.selectedServerTag` so a cold restart honours the same
/// leaf — is validated by integration on the simulator, not in unit
/// isolation. What we CAN pin here is the leaf-pick that feeds those
/// writes (always the first not-dead leaf in declaration order).
@MainActor
final class AppStateFallbackTests: XCTestCase {

    // MARK: - Helpers to build minimal fixtures

    private func makeCountry(tag: String, leaves: [String]) -> CountryGroup {
        CountryGroup(
            id: tag,
            tag: tag,
            name: tag,
            flagEmoji: "",
            serverTags: leaves,
            bestDelay: 0,
            section: .direct,
            subtitle: ""
        )
    }

    private func makeGroup(countries: [CountryGroup]) -> ServerGroup {
        ServerGroup(
            id: "Proxy",
            tag: "Proxy",
            type: "selector",
            selected: "",
            items: [],
            selectable: true,
            hasAuto: false,
            countries: countries
        )
    }

    // MARK: - nextLeafForCountry (build-85 P1-3 extract)

    func testNextLeafReturnsFirstAliveLeaf() {
        let country = makeCountry(tag: "🇳🇱 Нидерланды",
                                  leaves: ["nl-direct-nl2", "nl-h2-nl", "nl-tuic-nl"])
        let next = AppState.nextLeafForCountry(country: country, deadLeaves: [])
        XCTAssertEqual(next, "nl-direct-nl2", "first leaf in declaration order")
    }

    func testNextLeafSkipsDeadLeavesAndPicksRemaining() {
        // The "single-NL with 2 of 3 leaves dead" scenario from the prompt.
        let country = makeCountry(tag: "🇳🇱 Нидерланды",
                                  leaves: ["nl-direct-nl2", "nl-h2-nl", "nl-tuic-nl"])
        let dead: Set<String> = ["nl-direct-nl2", "nl-h2-nl"]
        let next = AppState.nextLeafForCountry(country: country, deadLeaves: dead)
        XCTAssertEqual(next, "nl-tuic-nl",
                       "must pick the one remaining alive leaf, not declare exhausted")
    }

    func testNextLeafNilWhenAllLeavesDead() {
        let country = makeCountry(tag: "🇩🇪 Германия",
                                  leaves: ["de-h2-de", "de-direct-de"])
        let next = AppState.nextLeafForCountry(country: country,
                                               deadLeaves: ["de-h2-de", "de-direct-de"])
        XCTAssertNil(next, "exhausted country → nil so the caller can escalate")
    }

    func testNextLeafNilForCountryWithNoLeaves() {
        let country = makeCountry(tag: "🇫🇷 Франция", leaves: [])
        XCTAssertNil(AppState.nextLeafForCountry(country: country, deadLeaves: []))
    }

    // MARK: - shouldEscalateBeyondCountry (audit P0-B extract)

    func testSingleCountryTopologyDoesNotEscalate() {
        // Audit P0-B context: at single-NL topology (only one country with
        // any leaves) we must NOT auto-jump anywhere — there is nowhere
        // legitimate to go, and the prior version silently promoted to
        // SPB whitelist-bypass, which the user reported as
        // "переключилось куда-то, не знаю зачем".
        let nl = makeCountry(tag: "🇳🇱 Нидерланды",
                             leaves: ["nl-direct-nl2", "nl-h2-nl"])
        let group = makeGroup(countries: [nl])
        XCTAssertFalse(
            AppState.shouldEscalateBeyondCountry(
                group: group,
                currentCountry: "🇳🇱 Нидерланды",
                deadCountries: []
            ),
            "single-country topology must not escalate"
        )
    }

    func testMultiCountryWithLiveAlternativeDoesEscalate() {
        let nl = makeCountry(tag: "🇳🇱 Нидерланды", leaves: ["nl-direct-nl2"])
        let de = makeCountry(tag: "🇩🇪 Германия", leaves: ["de-h2-de"])
        let group = makeGroup(countries: [nl, de])
        XCTAssertTrue(
            AppState.shouldEscalateBeyondCountry(
                group: group,
                currentCountry: "🇳🇱 Нидерланды",
                deadCountries: []
            ),
            "two healthy countries → escalation IS valid"
        )
    }

    func testAllAlternativesDeadDoesNotEscalate() {
        let nl = makeCountry(tag: "🇳🇱 Нидерланды", leaves: ["nl-direct-nl2"])
        let de = makeCountry(tag: "🇩🇪 Германия", leaves: ["de-h2-de"])
        let group = makeGroup(countries: [nl, de])
        XCTAssertFalse(
            AppState.shouldEscalateBeyondCountry(
                group: group,
                currentCountry: "🇳🇱 Нидерланды",
                deadCountries: ["🇩🇪 Германия"]
            ),
            "every alternative dead → stop, don't oscillate"
        )
    }

    func testEmptyCountryIsNotAValidEscalationTarget() {
        // An alternative country with zero leaves can't actually be used.
        let nl = makeCountry(tag: "🇳🇱 Нидерланды", leaves: ["nl-direct-nl2"])
        let empty = makeCountry(tag: "🇫🇷 Франция", leaves: [])
        let group = makeGroup(countries: [nl, empty])
        XCTAssertFalse(
            AppState.shouldEscalateBeyondCountry(
                group: group,
                currentCountry: "🇳🇱 Нидерланды",
                deadCountries: []
            ),
            "an empty alternative country must not be treated as a live target"
        )
    }
}
