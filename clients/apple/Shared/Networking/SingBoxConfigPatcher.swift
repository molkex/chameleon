import Foundation

/// Mutates a sing-box config JSON to bias an urltest group toward a
/// specific leg. Sing-box's URLTestGroup.Select returns the first matching
/// detour when no probe history exists yet — by reordering `outbounds`
/// to put the winner first, we control the leg used in the ~3-5 second
/// window between tunnel start and the first internal probe completing.
///
/// After internal probes complete, sing-box may re-elect to a leg with
/// lower HEAD-RTT; the TrafficHealthMonitor's first probe (run ~3s after
/// tunnel up) catches that mis-election if the new leg is broken in
/// practice.
enum SingBoxConfigPatcher {
    /// Reorders `outbounds` of the urltest/selector with the given tag so
    /// that `winnerLeg` is first. Returns the patched JSON, or the input
    /// unchanged if anything doesn't match (no group found, winner not
    /// in group, etc. — never throws to keep startup robust).
    static func biasGroup(_ groupTag: String, toFirst winnerLeg: String, inConfigJSON json: [String: Any]) -> [String: Any] {
        guard var outbounds = json["outbounds"] as? [[String: Any]] else { return json }
        var changed = false
        for i in 0..<outbounds.count {
            guard outbounds[i]["tag"] as? String == groupTag else { continue }
            guard var members = outbounds[i]["outbounds"] as? [String] else { continue }
            guard let idx = members.firstIndex(of: winnerLeg), idx != 0 else { continue }
            members.remove(at: idx)
            members.insert(winnerLeg, at: 0)
            outbounds[i]["outbounds"] = members
            changed = true
            break
        }
        if !changed { return json }
        var patched = json
        patched["outbounds"] = outbounds
        return patched
    }
}
