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

    // MARK: - OOM-PRESSURE-RESET (2026-07-14)

    /// libbox appends a DEFAULT oom-killer service on iOS when the config declares
    /// none, and that default runs in "pressure monitor" mode: it calls
    /// router.ResetNetwork() on every DEVICE-WIDE critical memory-pressure signal,
    /// never checking our own usage. That produced 62,756 network resets (~one per
    /// 20 ms) in an exported device log. An explicit memory_limit selects timer
    /// mode instead. The sanitizer injects it so even a stale cached config is safe.
    func testInjectsOOMKillerServiceWithMemoryLimit() throws {
        let input = #"{"log":{},"outbounds":[]}"#
        let dict = try parseJSON(ConfigSanitizer.sanitizeForIOS(input))

        let services = dict["services"] as? [[String: Any]]
        XCTAssertNotNil(services, "services block must exist, else libbox adds a pressure-mode oom-killer")

        let oom = services?.first { $0["type"] as? String == "oom-killer" }
        XCTAssertNotNil(oom, "oom-killer service must be injected")
        // 512MB (not 45/48): the service exists only to select timer mode and
        // disable libbox's pressure-monitor auto-reset; the limit sits ABOVE the
        // ~50 MiB jetsam ceiling so the timer never self-trips (45/48 sat at/below
        // the operating footprint and caused reset loops / connect-time trips).
        // sing-box maps "mb"→MiByte; "512MiB" would be rejected. See ConfigSanitizer.
        XCTAssertEqual(oom?["memory_limit"] as? String, "512MB")
    }

    /// Never clobber an oom-killer the backend already configured.
    func testKeepsExistingOOMKillerService() throws {
        let input = #"{"log":{},"outbounds":[],"services":[{"type":"oom-killer","memory_limit":"40MB"}]}"#
        let dict = try parseJSON(ConfigSanitizer.sanitizeForIOS(input))

        let services = dict["services"] as? [[String: Any]] ?? []
        XCTAssertEqual(services.count, 1, "must not append a duplicate oom-killer")
        XCTAssertEqual(services.first?["memory_limit"] as? String, "40MB")
    }

    // MARK: - Routing mode baked in before start (2026-07-14)

    /// The extension used to start in whatever mode the backend baked in; only the
    /// host app applied the real mode afterwards, on a retry that gives up after 5s.
    /// Any start without a live foreground app ran the wrong mode. The sanitizer now
    /// rewrites the selector defaults up front, so there is no window to lose.
    func testBakesPersistedRoutingModeIntoSelectorDefaults() throws {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupID)
        let previous = defaults?.string(forKey: AppConstants.routingModeKey)
        defer {
            if let previous { defaults?.set(previous, forKey: AppConstants.routingModeKey) }
            else { defaults?.removeObject(forKey: AppConstants.routingModeKey) }
        }
        defaults?.set(RoutingMode.fullVPN.rawValue, forKey: AppConstants.routingModeKey)

        let input = """
        {"log":{},"outbounds":[
          {"type":"selector","tag":"RU Traffic","outbounds":["direct","Proxy"],"default":"direct"},
          {"type":"selector","tag":"Default Route","outbounds":["Proxy"],"default":"Proxy"}
        ]}
        """
        let dict = try parseJSON(ConfigSanitizer.sanitizeForIOS(input))
        let outbounds = dict["outbounds"] as? [[String: Any]] ?? []

        let ru = outbounds.first { $0["tag"] as? String == "RU Traffic" }
        XCTAssertEqual(ru?["default"] as? String, "Proxy", "full-vpn must send RU traffic through the tunnel too")
    }

    /// A selector must never be pointed at an outbound it does not contain — that
    /// would be a config sing-box refuses, or worse, a silent mis-route.
    func testNeverSelectsANonMemberOutbound() throws {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupID)
        let previous = defaults?.string(forKey: AppConstants.routingModeKey)
        defer {
            if let previous { defaults?.set(previous, forKey: AppConstants.routingModeKey) }
            else { defaults?.removeObject(forKey: AppConstants.routingModeKey) }
        }
        defaults?.set(RoutingMode.ruDirect.rawValue, forKey: AppConstants.routingModeKey)

        // "RU Traffic" here lists only Proxy — ru-direct wants "direct", which is absent.
        let input = """
        {"log":{},"outbounds":[
          {"type":"selector","tag":"RU Traffic","outbounds":["Proxy"],"default":"Proxy"}
        ]}
        """
        let dict = try parseJSON(ConfigSanitizer.sanitizeForIOS(input))
        let outbounds = dict["outbounds"] as? [[String: Any]] ?? []
        let ru = outbounds.first { $0["tag"] as? String == "RU Traffic" }

        XCTAssertEqual(ru?["default"] as? String, "Proxy", "must leave the default alone when the target is not a member")
    }

    // MARK: - Bundled geoip-ru rule_set (MEM-01, 2026-07-15)

    /// The backend still emits geoip-ru as a `remote` rule_set (fetched +
    /// parsed into RAM on every tunnel start, and RKN-blocked in Russia on
    /// top of that). The sanitizer rewrites it to `local`, pointing at the
    /// .srs bundled into the extension, so this must hold for every config
    /// that reaches the extension — fresh from the backend or cached on
    /// disk from a previous fetch.
    func testRewritesRemoteGeoipRuRuleSetToLocal() throws {
        let input = """
        {
          "route": {
            "rule_set": [
              {
                "tag": "geoip-ru",
                "type": "remote",
                "format": "binary",
                "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs",
                "download_detour": "direct",
                "update_interval": "168h"
              }
            ]
          }
        }
        """
        let dict = try parseJSON(ConfigSanitizer.sanitizeForIOS(input))
        let ruleSets = (dict["route"] as? [String: Any])?["rule_set"] as? [[String: Any]] ?? []
        let geoipRu = ruleSets.first { $0["tag"] as? String == "geoip-ru" }

        XCTAssertEqual(geoipRu?["type"] as? String, "local")
        XCTAssertNil(geoipRu?["url"])
        XCTAssertNil(geoipRu?["download_detour"])
        XCTAssertNil(geoipRu?["update_interval"])
        let path = geoipRu?["path"] as? String
        XCTAssertNotNil(path, "local rule_set must carry a path")
        XCTAssertTrue(path?.hasSuffix("geoip-ru.srs") ?? false)
        // Non-matching rule_set fields (format) untouched.
        XCTAssertEqual(geoipRu?["format"] as? String, "binary")
    }

    /// Idempotent: re-running against an already-local entry (a cached config
    /// this same rewrite already touched) must not reintroduce url/etc, and
    /// must still carry a path.
    func testGeoipRuRewriteIsIdempotentOnAlreadyLocalEntry() throws {
        let input = """
        {
          "route": {
            "rule_set": [
              {"tag": "geoip-ru", "type": "local", "format": "binary", "path": "/old/stale/path.srs"}
            ]
          }
        }
        """
        let dict = try parseJSON(ConfigSanitizer.sanitizeForIOS(input))
        let ruleSets = (dict["route"] as? [String: Any])?["rule_set"] as? [[String: Any]] ?? []
        let geoipRu = ruleSets.first { $0["tag"] as? String == "geoip-ru" }

        XCTAssertEqual(geoipRu?["type"] as? String, "local")
        XCTAssertNil(geoipRu?["url"])
        XCTAssertNotNil(geoipRu?["path"] as? String)
    }

    /// Other rule_set entries (any future non-geoip-ru tag) must pass through
    /// untouched — this rewrite only targets the specific geoip-ru tag.
    func testNonGeoipRuRuleSetsUntouched() throws {
        let input = """
        {
          "route": {
            "rule_set": [
              {"tag": "other-set", "type": "remote", "url": "https://example.com/other.srs"}
            ]
          }
        }
        """
        let dict = try parseJSON(ConfigSanitizer.sanitizeForIOS(input))
        let ruleSets = (dict["route"] as? [String: Any])?["rule_set"] as? [[String: Any]] ?? []
        let other = ruleSets.first { $0["tag"] as? String == "other-set" }

        XCTAssertEqual(other?["type"] as? String, "remote")
        XCTAssertEqual(other?["url"] as? String, "https://example.com/other.srs")
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
