import Foundation

/// STALL-ON-NETSWITCH-LEAN-FIX (2026-07-16): extracts the tags of every
/// `type: "urltest"` outbound from a sing-box client config JSON string.
///
/// `TunnelStallProbe` used to hardcode `["Auto"]` and assume that group
/// always exists. It doesn't: the backend's OOM-emergency lean config
/// (`clientconfig.go` leanMode) omits ALL urltest groups, and a device log
/// from 2026-07-16 showed every stall-recovery nudge failing all day with
/// "outbound group not found: Auto" as a result — the nudge was a silent
/// no-op. Deriving the tag list from the config that's actually running
/// fixes that, and also fixes a second latent bug: hardcoding "Auto" only
/// nudges the cross-country fallback group, not a per-country group
/// (e.g. "🇳🇱 Нидерланды") the user may have deliberately pinned.
///
/// Lives in `Shared/` (not `PacketTunnel/`) so `MadFrogVPNTests` — which
/// only links the `MadFrogVPN` target, not `PacketTunnel` — can cover it.
func urltestGroupTags(fromConfigJSON json: String) -> [String] {
    guard let data = json.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let outbounds = root["outbounds"] as? [[String: Any]] else {
        return []
    }
    return outbounds.compactMap { outbound in
        guard outbound["type"] as? String == "urltest",
              let tag = outbound["tag"] as? String, !tag.isEmpty else {
            return nil
        }
        return tag
    }
}
