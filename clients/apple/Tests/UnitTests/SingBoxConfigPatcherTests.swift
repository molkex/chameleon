import XCTest
@testable import MadFrogVPN

final class SingBoxConfigPatcherTests: XCTestCase {

    private func sampleConfig() -> [String: Any] {
        [
            "outbounds": [
                [
                    "type": "selector",
                    "tag": "Proxy",
                    "outbounds": ["Auto", "🇩🇪 Германия", "🇳🇱 Нидерланды"]
                ],
                [
                    "type": "urltest",
                    "tag": "🇩🇪 Германия",
                    "outbounds": ["de-direct-de", "de-via-msk", "de-h2-de", "de-tuic-de"]
                ],
                [
                    "type": "vless",
                    "tag": "de-direct-de",
                    "server": "162.19.242.30",
                    "server_port": 2096
                ],
                [
                    "type": "vless",
                    "tag": "de-via-msk",
                    "server": "217.198.5.52",
                    "server_port": 443
                ]
            ]
        ]
    }

    // MARK: - SingBoxConfigPatcher

    func testBiasGroupReordersOutboundsToWinnerFirst() {
        let cfg = sampleConfig()
        let patched = SingBoxConfigPatcher.biasGroup("🇩🇪 Германия", toFirst: "de-via-msk", inConfigJSON: cfg)
        let outbounds = patched["outbounds"] as? [[String: Any]] ?? []
        let germany = outbounds.first(where: { ($0["tag"] as? String) == "🇩🇪 Германия" })
        let members = germany?["outbounds"] as? [String]
        XCTAssertEqual(members?.first, "de-via-msk")
        XCTAssertEqual(members?.count, 4, "no leaves dropped during reorder")
        XCTAssertEqual(Set(members ?? []), Set(["de-direct-de", "de-via-msk", "de-h2-de", "de-tuic-de"]))
    }

    func testBiasGroupNoOpWhenWinnerAlreadyFirst() {
        let cfg = sampleConfig()
        let patched = SingBoxConfigPatcher.biasGroup("🇩🇪 Германия", toFirst: "de-direct-de", inConfigJSON: cfg)
        let outbounds = patched["outbounds"] as? [[String: Any]] ?? []
        let germany = outbounds.first(where: { ($0["tag"] as? String) == "🇩🇪 Германия" })
        let members = germany?["outbounds"] as? [String]
        XCTAssertEqual(members?.first, "de-direct-de")
    }

    func testBiasGroupReturnsInputWhenGroupMissing() {
        let cfg = sampleConfig()
        let patched = SingBoxConfigPatcher.biasGroup("🇫🇷 Франция", toFirst: "fr-direct-fr", inConfigJSON: cfg)
        // Should be byte-equivalent to the original.
        let originalSerialized = try! JSONSerialization.data(withJSONObject: cfg, options: .sortedKeys)
        let patchedSerialized = try! JSONSerialization.data(withJSONObject: patched, options: .sortedKeys)
        XCTAssertEqual(originalSerialized, patchedSerialized)
    }

    func testBiasGroupReturnsInputWhenWinnerNotInGroup() {
        let cfg = sampleConfig()
        let patched = SingBoxConfigPatcher.biasGroup("🇩🇪 Германия", toFirst: "fr-direct-fr", inConfigJSON: cfg)
        let outbounds = patched["outbounds"] as? [[String: Any]] ?? []
        let germany = outbounds.first(where: { ($0["tag"] as? String) == "🇩🇪 Германия" })
        let members = germany?["outbounds"] as? [String]
        XCTAssertEqual(members?.first, "de-direct-de", "unknown winner is silently ignored, order preserved")
    }
}
