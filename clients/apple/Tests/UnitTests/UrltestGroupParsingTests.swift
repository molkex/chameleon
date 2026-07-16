import XCTest
@testable import MadFrogVPN

/// STALL-ON-NETSWITCH-LEAN-FIX (2026-07-16): pins `urltestGroupTags(fromConfigJSON:)`
/// against both real config shapes `backend/internal/vpn/clientconfig.go` can
/// emit. A device log the same day showed the OLD hardcoded `["Auto"]`
/// default failing on every single stall-recovery nudge, all day, with
/// "outbound group not found: Auto" — because the backend's OOM-emergency
/// lean mode omits every urltest group. This function is what replaced that
/// hardcoded assumption: derive the tag list from whatever config sing-box
/// was actually handed.
final class UrltestGroupParsingTests: XCTestCase {

    /// Trimmed but structurally real shape of the full (non-lean) config —
    /// a "Proxy" selector plus "Auto" and one country urltest group, mirroring
    /// what generateClientConfig emits when clientBuild >= firstUrltestSafeBuild.
    private let fullModeConfig = """
    {
      "outbounds": [
        {"type": "selector", "tag": "Proxy", "outbounds": ["Auto", "🇳🇱 Нидерланды"], "default": "Auto"},
        {"type": "urltest", "tag": "Auto", "outbounds": ["nl-direct-nl2", "de-direct-de"]},
        {"type": "urltest", "tag": "🇳🇱 Нидерланды", "outbounds": ["nl-direct-nl2"]},
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"}
      ]
    }
    """

    /// Trimmed but structurally real shape of the OOM-emergency lean config —
    /// "Proxy" is a plain selector over raw leaves, no urltest outbound at all.
    private let leanModeConfig = """
    {
      "outbounds": [
        {"type": "selector", "tag": "Proxy", "outbounds": ["nl-direct-nl2", "de-direct-de"], "default": "nl-direct-nl2"},
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"}
      ]
    }
    """

    func testExtractsAllUrltestTagsInFullMode() {
        let tags = urltestGroupTags(fromConfigJSON: fullModeConfig)
        XCTAssertEqual(Set(tags), Set(["Auto", "🇳🇱 Нидерланды"]))
    }

    func testReturnsEmptyInLeanMode() {
        XCTAssertEqual(urltestGroupTags(fromConfigJSON: leanModeConfig), [])
    }

    func testIgnoresSelectorAndSystemOutbounds() {
        // "Proxy" (selector), "direct", "block" must never be mistaken for
        // urltest groups regardless of mode.
        let tags = urltestGroupTags(fromConfigJSON: fullModeConfig)
        XCTAssertFalse(tags.contains("Proxy"))
        XCTAssertFalse(tags.contains("direct"))
        XCTAssertFalse(tags.contains("block"))
    }

    func testMalformedOrEmptyJSONReturnsEmpty() {
        XCTAssertEqual(urltestGroupTags(fromConfigJSON: ""), [])
        XCTAssertEqual(urltestGroupTags(fromConfigJSON: "not json"), [])
        XCTAssertEqual(urltestGroupTags(fromConfigJSON: "{}"), [])
        XCTAssertEqual(urltestGroupTags(fromConfigJSON: "{\"outbounds\": \"not-an-array\"}"), [])
    }

    func testSkipsUrltestOutboundWithMissingOrEmptyTag() {
        let malformed = """
        {"outbounds": [{"type": "urltest"}, {"type": "urltest", "tag": ""}, {"type": "urltest", "tag": "Auto"}]}
        """
        XCTAssertEqual(urltestGroupTags(fromConfigJSON: malformed), ["Auto"])
    }
}
