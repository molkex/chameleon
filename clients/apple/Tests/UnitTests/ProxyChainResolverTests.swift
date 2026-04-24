import XCTest
@testable import MadFrogVPN

/// Tests for `AppState.resolveChain(target:outbounds:)` — the pure graph-walk
/// function that decides which `selectOutbound` Clash-API calls to fire when
/// the user picks something in the server picker.
///
/// The function is agnostic to Clash API, network, or VPN state; it only
/// knows the outbound graph. We feed it hand-crafted sing-box outbound
/// arrays covering the cases the backend actually emits: a Proxy selector
/// containing country urltests + Auto + (post-2026-04-25) direct leaves.
final class ProxyChainResolverTests: XCTestCase {

    typealias Step = AppState.SelectionStep

    // MARK: - Helpers

    /// Build a synthetic outbounds array matching the post-2026-04-25
    /// backend topology: Proxy selector has Auto, country urltests, and
    /// individual leaves as direct children. Country groups are urltests.
    private static func backendTopology() -> [[String: Any]] {
        return [
            [
                "tag": "Proxy",
                "type": "selector",
                "outbounds": [
                    "Auto",
                    "🇳🇱 Нидерланды",
                    "🇩🇪 Германия",
                    "🇷🇺 Россия (обход белых списков)",
                    "de-direct-de",
                    "de-h2-de",
                    "de-tuic-de",
                    "nl-direct-nl2",
                    "de-via-msk",
                    "nl-via-msk",
                    "ru-spb-de",
                    "ru-spb-nl",
                ],
                "default": "Auto",
            ],
            [
                "tag": "Auto",
                "type": "urltest",
                "outbounds": [
                    "de-direct-de", "de-h2-de", "de-tuic-de",
                    "nl-direct-nl2", "de-via-msk", "nl-via-msk",
                ],
            ],
            [
                "tag": "🇳🇱 Нидерланды",
                "type": "urltest",
                "outbounds": ["nl-direct-nl2", "nl-via-msk"],
            ],
            [
                "tag": "🇩🇪 Германия",
                "type": "urltest",
                "outbounds": ["de-direct-de", "de-h2-de", "de-tuic-de", "de-via-msk"],
            ],
            [
                "tag": "🇷🇺 Россия (обход белых списков)",
                "type": "selector",
                "outbounds": ["ru-spb-de", "ru-spb-nl"],
                "default": "ru-spb-de",
            ],
            // Leaf outbounds (only type matters for classifier; host/port omitted).
            ["tag": "de-direct-de", "type": "vless"],
            ["tag": "de-h2-de", "type": "hysteria2"],
            ["tag": "de-tuic-de", "type": "tuic"],
            ["tag": "de-via-msk", "type": "vless"],
            ["tag": "nl-direct-nl2", "type": "vless"],
            ["tag": "nl-via-msk", "type": "vless"],
            ["tag": "ru-spb-de", "type": "vless"],
            ["tag": "ru-spb-nl", "type": "vless"],
            ["tag": "direct", "type": "direct"],
            ["tag": "block", "type": "block"],
        ]
    }

    /// Legacy topology (pre-2026-04-25): Proxy selector contains ONLY country
    /// urltests + Auto — no direct leaves. Exercises Case 2 (leaf-in-country)
    /// and confirms we still return a valid 2-step chain for clients whose
    /// cached config predates the architectural fix.
    private static func legacyTopology() -> [[String: Any]] {
        return [
            [
                "tag": "Proxy",
                "type": "selector",
                "outbounds": ["Auto", "🇳🇱 Нидерланды", "🇩🇪 Германия"],
                "default": "Auto",
            ],
            [
                "tag": "Auto",
                "type": "urltest",
                "outbounds": ["de-direct-de", "nl-direct-nl2"],
            ],
            [
                "tag": "🇩🇪 Германия",
                "type": "urltest",
                "outbounds": ["de-direct-de", "de-via-msk"],
            ],
            [
                "tag": "🇳🇱 Нидерланды",
                "type": "urltest",
                "outbounds": ["nl-direct-nl2"],
            ],
            ["tag": "de-direct-de", "type": "vless"],
            ["tag": "de-via-msk", "type": "vless"],
            ["tag": "nl-direct-nl2", "type": "vless"],
        ]
    }

    // MARK: - Case 1 — direct Proxy members (new topology)

    func testCountryUrltestIsDirectProxyMember_OneStep() {
        // User taps the country pill itself (🇩🇪 Германия).
        // Chain = one step: Proxy → country urltest.
        // Country urltest then auto-picks its best leaf by RTT.
        let chain = AppState.resolveChain(
            target: "🇩🇪 Германия",
            outbounds: Self.backendTopology()
        )
        XCTAssertEqual(chain, [Step(group: "Proxy", target: "🇩🇪 Германия")])
    }

    func testAutoIsDirectProxyMember_OneStep() {
        // Picking "Auto" from the picker is equivalent to no-pin — the
        // backend's Proxy.default = Auto on a fresh config. Returning a
        // one-step chain ensures cold-start still pins deterministically.
        let chain = AppState.resolveChain(
            target: "Auto",
            outbounds: Self.backendTopology()
        )
        XCTAssertEqual(chain, [Step(group: "Proxy", target: "Auto")])
    }

    func testLeafIsDirectProxyMember_OneStepAfter2026_04_25() {
        // This is the fix: a leaf like de-tuic-de is now a direct Proxy
        // child, so `selectOutbound("Proxy", "de-tuic-de")` succeeds
        // without the prior "outbound is not a selector" failure on the
        // country urltest step.
        let chain = AppState.resolveChain(
            target: "de-tuic-de",
            outbounds: Self.backendTopology()
        )
        XCTAssertEqual(chain, [Step(group: "Proxy", target: "de-tuic-de")])
    }

    func testWhitelistBypassLeafIsDirectProxyMember_OneStep() {
        // ru-spb-* leaves also appended as direct Proxy children.
        let chain = AppState.resolveChain(
            target: "ru-spb-nl",
            outbounds: Self.backendTopology()
        )
        XCTAssertEqual(chain, [Step(group: "Proxy", target: "ru-spb-nl")])
    }

    // MARK: - Case 2 — nested leaf, country-over-Auto preference

    func testLegacyTopology_LeafViaCountry_TwoStepChain() {
        // Pre-fix: leaf is NOT a direct Proxy child. Chain walks
        // country urltest first, then Proxy → country. Order matters.
        let chain = AppState.resolveChain(
            target: "de-direct-de",
            outbounds: Self.legacyTopology()
        )
        XCTAssertEqual(chain, [
            Step(group: "🇩🇪 Германия", target: "de-direct-de"),
            Step(group: "Proxy", target: "🇩🇪 Германия"),
        ])
    }

    func testLegacyTopology_PrefersCountryOverAuto() {
        // de-direct-de is in BOTH Auto urltest AND 🇩🇪 Германия urltest.
        // The resolver must pick the country group, never Auto, so the
        // user's deliberate DE pick doesn't get redirected through Auto
        // (which could RTT-select a non-DE leaf in other topologies).
        let chain = AppState.resolveChain(
            target: "de-direct-de",
            outbounds: Self.legacyTopology()
        )
        XCTAssertEqual(chain.last?.target, "🇩🇪 Германия",
                       "last step must route Proxy → DE country, not → Auto")
    }

    func testLegacyTopology_WhitelistBypassSelectorIsAccepted() {
        // Whitelist-bypass is a selector (not urltest). Resolver must
        // accept selector parents, not only urltest, for Case 2.
        let outbounds: [[String: Any]] = [
            [
                "tag": "Proxy", "type": "selector",
                "outbounds": ["Auto", "🇷🇺 Россия (обход белых списков)"],
            ],
            [
                "tag": "🇷🇺 Россия (обход белых списков)",
                "type": "selector",
                "outbounds": ["ru-spb-de", "ru-spb-nl"],
            ],
            ["tag": "ru-spb-de", "type": "vless"],
            ["tag": "ru-spb-nl", "type": "vless"],
            ["tag": "Auto", "type": "urltest", "outbounds": []],
        ]
        let chain = AppState.resolveChain(target: "ru-spb-de", outbounds: outbounds)
        XCTAssertEqual(chain, [
            Step(group: "🇷🇺 Россия (обход белых списков)", target: "ru-spb-de"),
            Step(group: "Proxy", target: "🇷🇺 Россия (обход белых списков)"),
        ])
    }

    // MARK: - Degenerate / error cases

    func testUnknownTargetReturnsEmptyChain() {
        // Caller passed a tag not present anywhere — never pin, never
        // return a partial chain that might break the user's existing
        // selection.
        let chain = AppState.resolveChain(
            target: "does-not-exist-anywhere",
            outbounds: Self.backendTopology()
        )
        XCTAssertTrue(chain.isEmpty)
    }

    func testEmptyOutboundsReturnsEmptyChain() {
        let chain = AppState.resolveChain(target: "any", outbounds: [])
        XCTAssertTrue(chain.isEmpty)
    }

    func testOutboundsWithoutProxySelectorReturnsEmptyChain() {
        // Garbage config — no Proxy selector — should gracefully return
        // empty, not crash. AppState caller falls back to the current
        // pin in this case.
        let outbounds: [[String: Any]] = [
            ["tag": "direct", "type": "direct"],
            ["tag": "some-leaf", "type": "vless"],
        ]
        let chain = AppState.resolveChain(target: "some-leaf", outbounds: outbounds)
        XCTAssertTrue(chain.isEmpty)
    }

    // MARK: - Case 3 — last-resort Auto fallback

    func testLeafOnlyInAuto_FallsBackToAutoTwoStep() {
        // If a leaf somehow appears in Auto but not in any country group
        // (shouldn't happen with normal backend emission, but could arise
        // mid-migration), resolver falls back to a two-step via Auto.
        let outbounds: [[String: Any]] = [
            [
                "tag": "Proxy", "type": "selector",
                "outbounds": ["Auto"],
            ],
            [
                "tag": "Auto", "type": "urltest",
                "outbounds": ["orphan-leaf"],
            ],
            ["tag": "orphan-leaf", "type": "vless"],
        ]
        let chain = AppState.resolveChain(target: "orphan-leaf", outbounds: outbounds)
        XCTAssertEqual(chain, [
            Step(group: "Auto", target: "orphan-leaf"),
            Step(group: "Proxy", target: "Auto"),
        ])
    }
}
