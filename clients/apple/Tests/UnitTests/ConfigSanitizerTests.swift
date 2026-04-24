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

    func testEmptyJSONObjectGetsLogSectionAdded() throws {
        // Even an empty config now acquires a `log` section because we force
        // the level to keep libbox's internal log buffering bounded.
        let result = ConfigSanitizer.sanitizeForIOS("{}")
        let dict = try parseJSON(result)
        XCTAssertNotNil(dict["log"], "log section should be populated")
        let log = dict["log"] as? [String: Any]
        XCTAssertNotNil(log?["level"])
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

    // MARK: - Memory hardening (iOS 50MB jetsam cap)

    func testDNSCacheIsCapped() throws {
        // Backend could ship unbounded cache_capacity. We force 512.
        let input = """
        {
          "dns": {
            "cache_capacity": 99999,
            "independent_cache": true,
            "servers": [{"tag": "dns-direct", "address": "1.1.1.1"}]
          }
        }
        """
        let result = ConfigSanitizer.sanitizeForIOS(input)
        let dict = try parseJSON(result)
        let dns = dict["dns"] as? [String: Any]
        XCTAssertEqual(dns?["cache_capacity"] as? Int, 512)
        XCTAssertEqual(dns?["independent_cache"] as? Bool, false)
    }

    func testDNSHardeningAppliedEvenWhenDNSSectionMissing() throws {
        // If backend forgot to ship a `dns` section, we leave it missing —
        // no point in fabricating one; sing-box will use its own default.
        let input = #"{"outbounds": [{"type":"direct","tag":"direct"}]}"#
        let result = ConfigSanitizer.sanitizeForIOS(input)
        let dict = try parseJSON(result)
        XCTAssertNil(dict["dns"])
    }

    func testCacheFileStrippedFromExperimental() throws {
        // cache_file geolocates every outbound and keeps per-node state on disk.
        // Neither needed nor cheap inside the 50 MB extension.
        let input = """
        {
          "experimental": {
            "cache_file": {"enabled": true, "path": "cache.db"}
          }
        }
        """
        let result = ConfigSanitizer.sanitizeForIOS(input)
        let dict = try parseJSON(result)
        XCTAssertNil(dict["experimental"],
                     "experimental should be dropped when only cache_file present")
    }

    func testLogOutputRemoved() throws {
        // Backend may set log.output to a path. Inside the NE sandbox, that
        // path usually isn't writable. Drop it so libbox falls back to stderr
        // which we redirect to the App Group container ourselves.
        let input = """
        {
          "log": {
            "level": "trace",
            "output": "/var/log/singbox.log",
            "timestamp": true
          }
        }
        """
        let result = ConfigSanitizer.sanitizeForIOS(input)
        let dict = try parseJSON(result)
        let log = dict["log"] as? [String: Any]
        XCTAssertNil(log?["output"])
        XCTAssertNil(log?["timestamp"])
        // In Release builds, level is forced to "error"; in DEBUG the backend's
        // value is preserved. We can only assert it exists.
        XCTAssertNotNil(log?["level"])
    }

    #if !DEBUG
    func testLogLevelForcedToErrorInRelease() throws {
        let input = #"{"log": {"level": "trace"}}"#
        let result = ConfigSanitizer.sanitizeForIOS(input)
        let dict = try parseJSON(result)
        let log = dict["log"] as? [String: Any]
        XCTAssertEqual(log?["level"] as? String, "error")
    }
    #endif

    func testExperimentalPreservedWhenNonStrippedFieldsPresent() throws {
        let input = """
        {
          "experimental": {
            "clash_api": {"external_controller": "127.0.0.1:9090"},
            "v2ray_api": {"listen": "127.0.0.1:8080"}
          }
        }
        """
        let result = ConfigSanitizer.sanitizeForIOS(input)
        let dict = try parseJSON(result)
        let experimental = dict["experimental"] as? [String: Any]
        XCTAssertNotNil(experimental, "v2ray_api should keep experimental alive")
        XCTAssertNil(experimental?["clash_api"])
        XCTAssertNotNil(experimental?["v2ray_api"])
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
