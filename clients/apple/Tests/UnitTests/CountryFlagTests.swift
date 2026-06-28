import XCTest
@testable import MadFrogVPN

/// Guards the flag→country-code mapping that drives the `CountryFlag` view on the
/// home card and in the server list. As of 2026-06-28 (audit H-06) this is
/// DATA-DRIVEN: the cc is decoded straight from the backend group tag's flag
/// emoji, so a NEW exit country (e.g. 🇵🇱) gets a code with ZERO app changes.
/// CountryFlag renders a hand-drawn vector for the subset that has one and falls
/// back to the emoji for the rest — never a blank globe for a real country.
final class CountryFlagTests: XCTestCase {

    private func group(flag: String) -> CountryGroup {
        CountryGroup(
            id: "g", tag: "g", name: "n", flagEmoji: flag,
            serverTags: [], bestDelay: 0, section: .direct, subtitle: ""
        )
    }

    func testKnownVectorFlagsMapToCodes() {
        XCTAssertEqual(group(flag: "🇳🇱").countryCode, "nl")
        XCTAssertEqual(group(flag: "🇩🇪").countryCode, "de")
        XCTAssertEqual(group(flag: "🇫🇷").countryCode, "fr")
        XCTAssertEqual(group(flag: "🇺🇸").countryCode, "us")
        XCTAssertEqual(group(flag: "🇷🇺").countryCode, "ru")
        XCTAssertEqual(group(flag: "🇵🇱").countryCode, "pl") // Poland, added 2026-06-28
    }

    /// The whole point of the data-driven change: ANY flag emoji decodes to its
    /// ISO cc, even a country with no hand-drawn vector yet. CountryFlag then
    /// renders that emoji instead of a globe — so new exits "just work".
    func testAnyFlagEmojiDecodesDataDriven() {
        XCTAssertEqual(group(flag: "🇵🇱").countryCode, "pl")
        XCTAssertEqual(group(flag: "🇯🇵").countryCode, "jp") // no vector → CountryFlag shows the emoji
        XCTAssertEqual(group(flag: "🇬🇧").countryCode, "gb")
    }

    func testNonFlagInputIsNil() {
        // nil → CountryFlag renders the globe (Auto / non-country group only).
        XCTAssertNil(group(flag: "").countryCode)
        XCTAssertNil(group(flag: "🌍").countryCode)        // globe emoji, not a regional-indicator flag
        XCTAssertNil(group(flag: "x").countryCode)
    }

    /// The whitelist-bypass group ("🇷🇺 Россия (обход…)") must still resolve to
    /// ru so its row shows the Russian flag, not a globe.
    func testWhitelistBypassRussiaResolvesToRu() {
        let g = CountryGroup.from(urltestTag: "🇷🇺 Россия (обход белых списков)", items: [])
        XCTAssertEqual(g.countryCode, "ru")
    }

    /// End-to-end: the backend Poland group tag parses to the right name + cc.
    func testPolandGroupParsesNameAndCode() {
        let g = CountryGroup.from(urltestTag: "🇵🇱 Польша", items: [])
        XCTAssertEqual(g.name, "Польша")
        XCTAssertEqual(g.flagEmoji, "🇵🇱")
        XCTAssertEqual(g.countryCode, "pl")
    }
}
