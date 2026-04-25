import XCTest
@testable import MadFrogVPN

/// Tests for `ServerTagShape` — the classifier that distinguishes Auto / a
/// country urltest pin / a leaf pin / unknown legacy tags. The build-32
/// migration and the TrafficHealthMonitor fallback chain both branch on
/// this, so every shape variant has to be unambiguous.
@MainActor
final class ServerTagShapeTests: XCTestCase {
    func testNilIsAuto() {
        XCTAssertEqual(ServerTagShape(nil), .auto)
    }

    func testEmptyIsAuto() {
        XCTAssertEqual(ServerTagShape(""), .auto)
    }

    func testFlagPrefixIsCountryUrltest() {
        XCTAssertEqual(ServerTagShape("🇩🇪 Германия"), .countryUrltest)
        XCTAssertEqual(ServerTagShape("🇳🇱 Нидерланды"), .countryUrltest)
        XCTAssertEqual(ServerTagShape("🇷🇺 Россия (обход белых списков)"), .countryUrltest)
    }

    func testKnownLeafIsLeaf() {
        guard case .leaf(let cc) = ServerTagShape("de-h2-de") else {
            XCTFail("expected .leaf, got \(ServerTagShape("de-h2-de"))")
            return
        }
        XCTAssertEqual(cc, "de")

        guard case .leaf(let cc2) = ServerTagShape("nl-direct-nl2") else {
            XCTFail("expected .leaf"); return
        }
        XCTAssertEqual(cc2, "nl")

        guard case .leaf(let cc3) = ServerTagShape("ru-spb-de") else {
            XCTFail("expected .leaf"); return
        }
        XCTAssertEqual(cc3, "ru")
    }

    func testViaIsLeaf() {
        guard case .leaf(let cc) = ServerTagShape("de-via-msk") else {
            XCTFail("expected .leaf"); return
        }
        XCTAssertEqual(cc, "de")
    }

    func testUnknownIsUnknown() {
        // Legacy tags from old backend topologies. Migration leaves them
        // alone — we can't safely guess the country.
        guard case .unknown(let raw) = ServerTagShape("VLESS") else {
            XCTFail("expected .unknown, got \(ServerTagShape("VLESS"))")
            return
        }
        XCTAssertEqual(raw, "VLESS")

        // Unknown country code.
        guard case .unknown = ServerTagShape("xx-direct-xx") else {
            XCTFail("expected .unknown for xx-")
            return
        }

        // Unknown kind.
        guard case .unknown = ServerTagShape("de-foobar-de") else {
            XCTFail("expected .unknown for de-foobar-de")
            return
        }
    }

    func testIsLeafFlag() {
        XCTAssertTrue(ServerTagShape("de-h2-de").isLeaf)
        XCTAssertFalse(ServerTagShape("🇩🇪 Германия").isLeaf)
        XCTAssertFalse(ServerTagShape(nil).isLeaf)
        XCTAssertFalse(ServerTagShape("VLESS").isLeaf)
    }
}

extension ServerTagShape: Equatable {
    public static func == (lhs: ServerTagShape, rhs: ServerTagShape) -> Bool {
        switch (lhs, rhs) {
        case (.auto, .auto): return true
        case (.countryUrltest, .countryUrltest): return true
        case (.leaf(let a), .leaf(let b)): return a == b
        case (.unknown(let a), .unknown(let b)): return a == b
        default: return false
        }
    }
}
