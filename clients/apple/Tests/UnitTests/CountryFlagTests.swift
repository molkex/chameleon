import XCTest
@testable import MadFrogVPN

/// Guards the flag→country-code mapping that drives the vector `CountryFlag`
/// view on the home card and in the server list (build 96-97 — replaced emoji
/// flags). If the mapping drifts, a country renders the wrong flag or a globe.
final class CountryFlagTests: XCTestCase {

    private func group(flag: String) -> CountryGroup {
        CountryGroup(
            id: "g", tag: "g", name: "n", flagEmoji: flag,
            serverTags: [], bestDelay: 0, section: .direct, subtitle: ""
        )
    }

    func testKnownFlagsMapToCodes() {
        XCTAssertEqual(group(flag: "🇳🇱").countryCode, "nl")
        XCTAssertEqual(group(flag: "🇩🇪").countryCode, "de")
        XCTAssertEqual(group(flag: "🇫🇷").countryCode, "fr")
        XCTAssertEqual(group(flag: "🇺🇸").countryCode, "us")
        XCTAssertEqual(group(flag: "🇷🇺").countryCode, "ru")
    }

    func testUnknownOrEmptyFlagIsNil() {
        // nil → CountryFlag renders the globe (Auto / non-country group).
        XCTAssertNil(group(flag: "").countryCode)
        XCTAssertNil(group(flag: "🌍").countryCode)
        XCTAssertNil(group(flag: "🇯🇵").countryCode) // a country we don't serve
    }

    /// The whitelist-bypass group ("🇷🇺 Россия (обход…)") must still resolve to
    /// ru so its row shows the Russian flag, not a globe.
    func testWhitelistBypassRussiaResolvesToRu() {
        let g = CountryGroup.from(urltestTag: "🇷🇺 Россия (обход белых списков)", items: [])
        XCTAssertEqual(g.countryCode, "ru")
    }
}
