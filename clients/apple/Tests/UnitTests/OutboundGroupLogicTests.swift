import XCTest
@testable import MadFrogVPN

/// test-coverage-hardening: pins `OutboundGroupSnapshot` — the pure
/// group-feed → snapshot transform + selected-outbound tracking
/// extracted from `PacketTunnel/OutboundGroupTracker.swift` (the
/// PacketTunnel extension target can't be linked from the test bundle).
///
/// What this guards:
///  - group-feed parsing: each raw libbox group → a snapshot entry,
///    member order preserved, last-wins on duplicate group tags.
///  - selected-outbound tracking: `selected(in:)` / `members(in:)`
///    return the live values, and nil / [] for unknown groups.
///
/// The tracker's LibboxCommandClient subscription + DispatchQueue stay
/// on-device-verified.
final class OutboundGroupLogicTests: XCTestCase {

    // MARK: - build — group-feed parsing

    func testBuild_parsesEachGroup() {
        let raw = [
            RawOutboundGroup(tag: "country-de", selected: "de-direct", members: ["de-direct", "de-via-msk"]),
            RawOutboundGroup(tag: "country-nl", selected: "nl-via-msk", members: ["nl-direct", "nl-via-msk"]),
        ]
        let snap = OutboundGroupSnapshot.build(from: raw)
        XCTAssertEqual(snap.groups.count, 2)
        XCTAssertEqual(snap.groups["country-de"], OutboundGroupSnapshot.Group(selected: "de-direct", members: ["de-direct", "de-via-msk"]))
        XCTAssertEqual(snap.groups["country-nl"]?.selected, "nl-via-msk")
    }

    func testBuild_preservesMemberOrder() {
        let raw = [RawOutboundGroup(tag: "g", selected: "c", members: ["c", "a", "b"])]
        let snap = OutboundGroupSnapshot.build(from: raw)
        XCTAssertEqual(snap.members(in: "g"), ["c", "a", "b"], "member order from the feed must be preserved")
    }

    func testBuild_duplicateGroupTagLastWins() {
        // Dictionary insertion semantics — a later group with the same
        // tag overwrites the earlier one.
        let raw = [
            RawOutboundGroup(tag: "g", selected: "old", members: ["old"]),
            RawOutboundGroup(tag: "g", selected: "new", members: ["new", "x"]),
        ]
        let snap = OutboundGroupSnapshot.build(from: raw)
        XCTAssertEqual(snap.groups.count, 1)
        XCTAssertEqual(snap.selected(in: "g"), "new")
        XCTAssertEqual(snap.members(in: "g"), ["new", "x"])
    }

    func testBuild_emptyFeedYieldsEmptySnapshot() {
        XCTAssertEqual(OutboundGroupSnapshot.build(from: []), .empty)
    }

    func testBuild_groupWithNoMembers() {
        let raw = [RawOutboundGroup(tag: "g", selected: "", members: [])]
        let snap = OutboundGroupSnapshot.build(from: raw)
        XCTAssertEqual(snap.selected(in: "g"), "")
        XCTAssertEqual(snap.members(in: "g"), [])
    }

    // MARK: - selected / members — tracking accessors

    func testSelected_tracksLiveSelection() {
        let snap = OutboundGroupSnapshot.build(from: [
            RawOutboundGroup(tag: "country-de", selected: "de-via-msk", members: ["de-direct", "de-via-msk"]),
        ])
        XCTAssertEqual(snap.selected(in: "country-de"), "de-via-msk")
    }

    func testSelected_nilForUnknownGroup() {
        XCTAssertNil(OutboundGroupSnapshot.empty.selected(in: "nope"))
    }

    func testMembers_emptyForUnknownGroup() {
        XCTAssertEqual(OutboundGroupSnapshot.empty.members(in: "nope"), [])
    }

    func testEmpty_hasNoGroups() {
        XCTAssertTrue(OutboundGroupSnapshot.empty.groups.isEmpty)
    }

    /// Simulates a re-publish of the feed: the snapshot is fully replaced
    /// (not merged) — a group dropped from the feed disappears.
    func testRebuild_replacesNotMerges() {
        let first = OutboundGroupSnapshot.build(from: [
            RawOutboundGroup(tag: "a", selected: "a1", members: ["a1"]),
            RawOutboundGroup(tag: "b", selected: "b1", members: ["b1"]),
        ])
        XCTAssertEqual(first.groups.count, 2)
        let second = OutboundGroupSnapshot.build(from: [
            RawOutboundGroup(tag: "a", selected: "a2", members: ["a2"]),
        ])
        XCTAssertEqual(second.groups.count, 1, "group 'b' was not in the new feed — it must be gone")
        XCTAssertNil(second.selected(in: "b"))
        XCTAssertEqual(second.selected(in: "a"), "a2")
    }
}
