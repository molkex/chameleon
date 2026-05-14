import Foundation

/// Pure snapshot model + group-feed parsing extracted from
/// `PacketTunnel/OutboundGroupTracker.swift` so the group-feed → snapshot
/// transform and selected-outbound tracking are unit-testable without
/// the PacketTunnel target (which the test target can't link) or a live
/// `LibboxCommandClient`.
///
/// `OutboundGroupTracker` keeps the `LibboxCommandClient`, the
/// `DispatchQueue` and the `LibboxOutboundGroupIteratorProtocol` bridge;
/// it converts each Libbox group into a plain `RawGroup` and routes
/// through `OutboundGroupSnapshot.build` — exactly the loop that used to
/// be inlined in `ingest(_:)`.

/// One group as read off the libbox feed, stripped to primitives.
struct RawOutboundGroup: Equatable {
    let tag: String
    let selected: String
    let members: [String]
}

/// Immutable per-feed snapshot: every group's currently-selected
/// outbound + its ordered member list. Built from the raw libbox feed,
/// queried synchronously by the penalty-aware fallback.
struct OutboundGroupSnapshot: Equatable {
    /// groupTag → (selected, members).
    struct Group: Equatable {
        let selected: String     // active outbound tag in the group
        let members: [String]    // ordered member tags
    }

    let groups: [String: Group]

    static let empty = OutboundGroupSnapshot(groups: [:])

    /// Build a snapshot from the raw libbox group feed. Mirrors the
    /// `while message.hasNext()` loop in `OutboundGroupTracker.ingest`:
    /// each group becomes a `Group`; later groups with a duplicate tag
    /// overwrite earlier ones (last-wins), matching dictionary insertion.
    static func build(from rawGroups: [RawOutboundGroup]) -> OutboundGroupSnapshot {
        var groups: [String: Group] = [:]
        for raw in rawGroups {
            groups[raw.tag] = Group(selected: raw.selected, members: raw.members)
        }
        return OutboundGroupSnapshot(groups: groups)
    }

    /// The currently-selected outbound tag for `groupTag`, or nil if the
    /// group isn't in this snapshot.
    func selected(in groupTag: String) -> String? {
        groups[groupTag]?.selected
    }

    /// The ordered member tags for `groupTag`, or `[]` if absent.
    func members(in groupTag: String) -> [String] {
        groups[groupTag]?.members ?? []
    }
}
