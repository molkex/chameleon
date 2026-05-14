import XCTest
@testable import MadFrogVPN

/// test-coverage (ios-server-group): pins the pure grouping / sorting /
/// labelling logic in `ServerGroup.swift` — `ServerItem` tag-derived
/// display fields, `CountryGroup.from` construction + section
/// classification, and `ServerGroup`'s country ordering + selection
/// lookup. `ServerTagShape` is covered separately by ServerTagShapeTests.
final class ServerGroupTests: XCTestCase {

    private func item(_ tag: String, type: String = "vless", delay: Int32 = 0) -> ServerItem {
        ServerItem(id: tag, tag: tag, type: type, delay: delay, delayTime: 0)
    }

    // MARK: - ServerItem.countryKey

    func testCountryKey_newLeafTagPrefix() {
        XCTAssertEqual(item("nl-direct-nl2").countryKey, "nl")
        XCTAssertEqual(item("de-via-msk").countryKey, "de")
        XCTAssertEqual(item("ru-spb-de").countryKey, "ru")
    }

    func testCountryKey_legacyFlagAndWordFormats() {
        XCTAssertEqual(item("🇳🇱 Нидерланды").countryKey, "nl")
        XCTAssertEqual(item("🇩🇪 Германия").countryKey, "de")
        XCTAssertEqual(item("VLESS Россия").countryKey, "ru")
        XCTAssertEqual(item("Germany VLESS").countryKey, "de")
    }

    func testCountryKey_cdnAndUnknown() {
        XCTAssertEqual(item("cdn-cloudflare").countryKey, "cdn")
        XCTAssertEqual(item("xx-direct-xx").countryKey, "other")
    }

    // MARK: - ServerItem display fields keyed off countryKey

    func testCountryCodeAndFlagTrackCountryKey() {
        XCTAssertEqual(item("nl-direct-nl2").countryCode, "NL")
        XCTAssertEqual(item("de-h2-de").countryCode, "DE")
        XCTAssertEqual(item("ru-spb-de").countryCode, "RU")
        XCTAssertEqual(item("xx-direct-xx").countryCode, "—")

        XCTAssertEqual(item("nl-direct-nl2").flagEmoji, "🇳🇱")
        XCTAssertEqual(item("de-h2-de").flagEmoji, "🇩🇪")
        XCTAssertEqual(item("xx-direct-xx").flagEmoji, "🌍")
    }

    // MARK: - ServerItem.isHysteria

    func testIsHysteria_recognisedAcrossTagAndType() {
        XCTAssertTrue(item("de-h2-de").isHysteria)
        XCTAssertTrue(item("server-hysteria2").isHysteria)
        XCTAssertTrue(item("anything", type: "hysteria2").isHysteria)
        XCTAssertFalse(item("de-direct-de").isHysteria)
        XCTAssertFalse(item("nl-tuic-nl2").isHysteria)
    }

    // MARK: - ServerItem.protocolLabel

    func testProtocolLabel() {
        XCTAssertEqual(item("x", type: "vless").protocolLabel, "VLESS")
        XCTAssertEqual(item("x", type: "hysteria2").protocolLabel, "HY2")
        XCTAssertEqual(item("x", type: "wireguard").protocolLabel, "WG")
        XCTAssertEqual(item("x", type: "tuic").protocolLabel, "TUIC")
    }

    // MARK: - ServerItem.shortLabel

    func testShortLabel_bracketExtraction() {
        XCTAssertEqual(item("🇳🇱 Нидерланды [ads]").shortLabel, "ads")
        XCTAssertEqual(item("server [gRPC]").shortLabel, "gRPC")
    }

    func testShortLabel_fallbacks() {
        XCTAssertEqual(item("de-h2-de").shortLabel, "HY2", "a hysteria leaf with no brackets → HY2")
        XCTAssertEqual(item("node gRPC").shortLabel, "gRPC")
    }

    // MARK: - ServerItem.delayText

    func testDelayText() {
        XCTAssertEqual(item("x", delay: 0).delayText, "—")
        XCTAssertEqual(item("x", delay: -1).delayText, "—")
        XCTAssertEqual(item("x", delay: 42).delayText, "42 ms")
    }

    // MARK: - ServerItem.displayLabel — structural (locale-independent parts)

    func testDisplayLabel_knownLeafKindsAreNonEmptyAndStable() {
        // server.leaf.direct is localized — assert non-empty rather than text.
        XCTAssertFalse(item("de-direct-de").displayLabel.isEmpty)
        XCTAssertEqual(item("de-h2-de").displayLabel, "Hysteria2")
        XCTAssertEqual(item("nl-tuic-nl2").displayLabel, "TUIC")
        XCTAssertEqual(item("ru-spb-de").displayLabel, "SPB → DE")
    }

    func testDisplayLabel_legacyTagStripsNoiseTokens() {
        // "🇩🇪 Германия VLESS" → flags + "VLESS" stripped, trimmed.
        XCTAssertEqual(item("🇩🇪 Германия VLESS").displayLabel, "Германия")
    }

    func testHomePillLabel_cdnIsSpecialCased() {
        XCTAssertEqual(item("cdn-node").homePillLabel, "CDN Cloudflare")
        // non-CDN falls through to displayLabel
        XCTAssertEqual(item("de-h2-de").homePillLabel, item("de-h2-de").displayLabel)
    }

    // MARK: - CountryGroup.from

    func testCountryGroupFrom_splitsFlagAndName() {
        let g = CountryGroup.from(urltestTag: "🇩🇪 Германия", items: [item("de-h2-de")])
        XCTAssertEqual(g.flagEmoji, "🇩🇪")
        XCTAssertEqual(g.name, "Германия")
        XCTAssertEqual(g.section, .direct)
        XCTAssertEqual(g.serverTags, ["de-h2-de"])
        XCTAssertEqual(g.serverCount, 1)
    }

    func testCountryGroupFrom_noFlagPrefixKeepsWholeTagAsName() {
        let g = CountryGroup.from(urltestTag: "Auto", items: [])
        XCTAssertEqual(g.flagEmoji, "")
        XCTAssertEqual(g.name, "Auto")
    }

    func testCountryGroupFrom_whitelistBypassSectionFromKeyword() {
        let g = CountryGroup.from(urltestTag: "🇷🇺 Россия (обход белых списков)",
                                  items: [item("ru-spb-de"), item("ru-spb-nl")])
        XCTAssertEqual(g.section, .whitelistBypass)
        XCTAssertEqual(g.sortOrder, 100, "whitelist-bypass always sorts last")
        XCTAssertFalse(g.subtitle.isEmpty)
    }

    func testCountryGroupFrom_directSectionSortsFirst() {
        let g = CountryGroup.from(urltestTag: "🇳🇱 Нидерланды", items: [item("nl-direct-nl2")])
        XCTAssertEqual(g.section, .direct)
        XCTAssertEqual(g.sortOrder, 0)
    }

    func testCountryGroupFrom_bestDelayIgnoresZeroAndUnknown() {
        // 0 / negative delays are "unknown" and must not win min().
        let items = [item("de-h2-de", delay: 0), item("de-direct-de", delay: 120), item("de-tuic-de", delay: 45)]
        let g = CountryGroup.from(urltestTag: "🇩🇪 Германия", items: items)
        XCTAssertEqual(g.bestDelay, 45)
        XCTAssertEqual(g.bestDelayText, "45 ms")
    }

    func testCountryGroupFrom_bestDelayZeroWhenAllUnknown() {
        let g = CountryGroup.from(urltestTag: "🇩🇪 Германия", items: [item("de-h2-de", delay: 0)])
        XCTAssertEqual(g.bestDelay, 0)
        XCTAssertEqual(g.bestDelayText, "", "an unknown best delay renders as empty, not '0 ms'")
    }

    // MARK: - ServerGroup.countryGroups ordering

    func testServerGroupCountryGroups_pushesWhitelistBypassLast() {
        let de = CountryGroup.from(urltestTag: "🇩🇪 Германия", items: [item("de-h2-de")])
        let bypass = CountryGroup.from(urltestTag: "🇷🇺 Россия (обход белых списков)", items: [item("ru-spb-de")])
        let nl = CountryGroup.from(urltestTag: "🇳🇱 Нидерланды", items: [item("nl-direct-nl2")])
        // Deliberately put bypass in the middle of the input order.
        let group = ServerGroup(id: "Proxy", tag: "Proxy", type: "selector",
                                selected: "Auto", items: [], selectable: true,
                                hasAuto: true, countries: [de, bypass, nl])
        let ordered = group.countryGroups
        XCTAssertEqual(ordered.last?.section, .whitelistBypass,
                       "whitelist-bypass must always render last regardless of input order")
        XCTAssertEqual(ordered.prefix(2).map(\.section), [.direct, .direct])
    }

    // MARK: - ServerGroup.selectedCountryKey

    func testSelectedCountryKey_matchesByLeafMembership() {
        let de = CountryGroup.from(urltestTag: "🇩🇪 Германия", items: [item("de-h2-de"), item("de-direct-de")])
        let nl = CountryGroup.from(urltestTag: "🇳🇱 Нидерланды", items: [item("nl-direct-nl2")])
        let group = ServerGroup(id: "Proxy", tag: "Proxy", type: "selector",
                                selected: "de-h2-de", items: [], selectable: true,
                                hasAuto: true, countries: [de, nl])
        XCTAssertEqual(group.selectedCountryKey, de.id,
                       "a selected leaf tag resolves to the country group that contains it")
    }

    func testSelectedCountryKey_matchesWholeCountryPin() {
        let de = CountryGroup.from(urltestTag: "🇩🇪 Германия", items: [item("de-h2-de")])
        let group = ServerGroup(id: "Proxy", tag: "Proxy", type: "selector",
                                selected: "🇩🇪 Германия", items: [], selectable: true,
                                hasAuto: true, countries: [de])
        XCTAssertEqual(group.selectedCountryKey, de.id,
                       "selecting a whole country urltest resolves to that country directly")
    }

    func testSelectedCountryKey_nilWhenNoMatch() {
        let de = CountryGroup.from(urltestTag: "🇩🇪 Германия", items: [item("de-h2-de")])
        let group = ServerGroup(id: "Proxy", tag: "Proxy", type: "selector",
                                selected: "Auto", items: [], selectable: true,
                                hasAuto: true, countries: [de])
        XCTAssertNil(group.selectedCountryKey, "‘Auto’ belongs to no country group")
    }
}
