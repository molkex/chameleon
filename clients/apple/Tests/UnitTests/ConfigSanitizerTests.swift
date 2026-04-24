import XCTest
@testable import MadFrogVPN

final class ConfigSanitizerTests: XCTestCase {

    // MARK: - Edge cases

    func testEmptyStringDoesNotCrash() {
        // sanitizeForIOS guards against unparseable input by returning the
        // original string. Empty input is the simplest "unparseable" case.
        let result = ConfigSanitizer.sanitizeForIOS("")
        XCTAssertEqual(result, "")
    }

    func testInvalidJSONReturnsOriginal() {
        let garbage = "{not json"
        let result = ConfigSanitizer.sanitizeForIOS(garbage)
        XCTAssertEqual(result, garbage)
    }

    func testEmptyJSONObjectStaysEmpty() throws {
        let result = ConfigSanitizer.sanitizeForIOS("{}")
        let dict = try parseJSON(result)
        XCTAssertTrue(dict.isEmpty)
    }

    // MARK: - Stripping deprecated fields

    func testRemovesSniffFromInbounds() throws {
        let input = """
        {
          "inbounds": [
            {
              "type": "tun",
              "tag": "tun-in",
              "sniff": true,
              "sniff_override_destination": true,
              "domain_strategy": "ipv4_only"
            }
          ]
        }
        """
        let result = ConfigSanitizer.sanitizeForIOS(input)
        let dict = try parseJSON(result)

        guard let inbounds = dict["inbounds"] as? [[String: Any]] else {
            return XCTFail("inbounds missing or wrong type")
        }
        XCTAssertEqual(inbounds.count, 1)
        XCTAssertNil(inbounds[0]["sniff"])
        XCTAssertNil(inbounds[0]["sniff_override_destination"])
        XCTAssertNil(inbounds[0]["domain_strategy"])
        // Non-deprecated fields preserved.
        XCTAssertEqual(inbounds[0]["type"] as? String, "tun")
        XCTAssertEqual(inbounds[0]["tag"] as? String, "tun-in")
    }

    func testRemovesConfigVersionAndDNSStrategy() throws {
        let input = """
        {
          "config_version": 7,
          "dns": {
            "strategy": "ipv4_only",
            "servers": [{"tag": "dns-direct", "address": "1.1.1.1"}]
          }
        }
        """
        let result = ConfigSanitizer.sanitizeForIOS(input)
        let dict = try parseJSON(result)

        XCTAssertNil(dict["config_version"])
        let dns = dict["dns"] as? [String: Any]
        XCTAssertNil(dns?["strategy"])
        // Non-deprecated dns content preserved.
        XCTAssertNotNil(dns?["servers"])
    }

    func testRemovesClashAPIAndAutoDetectInterface() throws {
        let input = """
        {
          "experimental": {
            "clash_api": {"external_controller": "127.0.0.1:9090"}
          },
          "route": {
            "auto_detect_interface": true,
            "rules": [{"action": "sniff"}]
          }
        }
        """
        let result = ConfigSanitizer.sanitizeForIOS(input)
        let dict = try parseJSON(result)

        // experimental was only clash_api → should be dropped entirely.
        XCTAssertNil(dict["experimental"], "experimental should be dropped when only clash_api present")

        let route = dict["route"] as? [String: Any]
        XCTAssertNil(route?["auto_detect_interface"])
        XCTAssertNotNil(route?["rules"], "route.rules should remain")
    }

    func testValidConfigPassesThroughIntact() throws {
        // A minimal but realistic 1.13 config — none of the deprecated fields
        // are present, so the structural content must round-trip unchanged.
        let input = """
        {
          "log": {"level": "info"},
          "dns": {"servers": [{"tag": "dns-direct", "address": "1.1.1.1"}]},
          "inbounds": [{"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"]}],
          "outbounds": [{"type": "direct", "tag": "direct"}],
          "route": {"rules": [{"action": "sniff"}, {"protocol": "dns", "action": "hijack-dns"}]}
        }
        """
        let result = ConfigSanitizer.sanitizeForIOS(input)
        let actual = try parseJSON(result)
        let expected = try parseJSON(input)

        // Compare as serialized canonical strings (sorted keys) so dictionary
        // ordering doesn't trip the assertion.
        XCTAssertEqual(canonicalJSON(actual), canonicalJSON(expected))
    }

    // MARK: - Helpers

    private func parseJSON(_ s: String) throws -> [String: Any] {
        let data = s.data(using: .utf8) ?? Data()
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        return obj as? [String: Any] ?? [:]
    }

    private func canonicalJSON(_ dict: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.sortedKeys]
        )) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
