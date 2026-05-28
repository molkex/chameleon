import XCTest
import NetworkExtension
@testable import MadFrogVPN

/// LAUNCH-07 regression guards for `VPNManager.buildOnDemandRules`. The
/// real `applyAutoConnectRules` mutates `NETunnelProviderManager` which
/// can't be constructed in a unit-test environment — but the pure builder
/// is testable directly.
///
/// Invariants we pin:
///   * `enabled == false` → empty array (no rules attached to the profile).
///   * `enabled == true, trusted == [], cellular == false` → exactly one
///     `.wiFi` Connect rule.
///   * `enabled == true, trusted == [a,b], cellular == false` → 2 rules:
///     Ignore(.wiFi, ssidMatch=[a,b]) followed by Connect(.wiFi).
///   * `enabled == true, trusted == [], cellular == true` → 2 rules:
///     Connect(.wiFi) followed by Connect(.cellular).
///   * Whitespace + empty strings in the SSID list are trimmed defensively
///     even though ConfigStore.addTrustedSSID already does this on write.
final class VPNManagerOnDemandRulesTests: XCTestCase {

    func testDisabledReturnsEmptyArray() {
        let rules = VPNManager.buildOnDemandRules(
            enabled: false,
            trustedSSIDs: ["Home"],
            includeCellular: true
        )
        XCTAssertEqual(rules.count, 0,
                       "enabled=false MUST yield zero rules — we don't want a stale chain on the profile")
    }

    func testEnabledNoTrustedNoCellularHasJustOneWiFiConnect() {
        let rules = VPNManager.buildOnDemandRules(
            enabled: true,
            trustedSSIDs: [],
            includeCellular: false
        )
        XCTAssertEqual(rules.count, 1)
        guard let connect = rules.first as? NEOnDemandRuleConnect else {
            return XCTFail("expected NEOnDemandRuleConnect, got \(type(of: rules.first as Any))")
        }
        XCTAssertEqual(connect.interfaceTypeMatch, .wiFi)
    }

    func testEnabledWithTrustedSSIDsIgnoresThenConnects() {
        let rules = VPNManager.buildOnDemandRules(
            enabled: true,
            trustedSSIDs: ["HomeNet", "OfficeNet"],
            includeCellular: false
        )
        XCTAssertEqual(rules.count, 2, "trusted SSID list should add the Ignore rule in front of Connect")

        guard let ignore = rules[0] as? NEOnDemandRuleIgnore else {
            return XCTFail("rule[0] must be NEOnDemandRuleIgnore — got \(type(of: rules[0]))")
        }
        XCTAssertEqual(ignore.interfaceTypeMatch, .wiFi)
        XCTAssertEqual(ignore.ssidMatch, ["HomeNet", "OfficeNet"],
                       "trusted SSID list must be passed through verbatim and in order")

        guard let connect = rules[1] as? NEOnDemandRuleConnect else {
            return XCTFail("rule[1] must be NEOnDemandRuleConnect — got \(type(of: rules[1]))")
        }
        XCTAssertEqual(connect.interfaceTypeMatch, .wiFi)
        XCTAssertNil(connect.ssidMatch, "Connect must NOT carry an ssidMatch — that would invert the semantics")
    }

    func testEnabledIncludesCellularAppended() {
        let rules = VPNManager.buildOnDemandRules(
            enabled: true,
            trustedSSIDs: [],
            includeCellular: true
        )
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual((rules[0] as? NEOnDemandRuleConnect)?.interfaceTypeMatch, .wiFi)
        XCTAssertEqual((rules[1] as? NEOnDemandRuleConnect)?.interfaceTypeMatch, .cellular)
    }

    func testFullChain_TrustedPlusCellular() {
        let rules = VPNManager.buildOnDemandRules(
            enabled: true,
            trustedSSIDs: ["Home"],
            includeCellular: true
        )
        XCTAssertEqual(rules.count, 3)
        XCTAssertTrue(rules[0] is NEOnDemandRuleIgnore)
        XCTAssertEqual((rules[1] as? NEOnDemandRuleConnect)?.interfaceTypeMatch, .wiFi)
        XCTAssertEqual((rules[2] as? NEOnDemandRuleConnect)?.interfaceTypeMatch, .cellular)
    }

    func testWhitespaceAndEmptyTrustedSSIDsAreStripped() {
        let rules = VPNManager.buildOnDemandRules(
            enabled: true,
            trustedSSIDs: ["  Home  ", "", "  ", "Office"],
            includeCellular: false
        )
        XCTAssertEqual(rules.count, 2)
        let ignore = rules[0] as? NEOnDemandRuleIgnore
        XCTAssertEqual(ignore?.ssidMatch, ["Home", "Office"],
                       "blank entries dropped, surrounding whitespace trimmed")
    }
}
