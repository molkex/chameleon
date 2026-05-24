import Foundation
import NetworkExtension
import WidgetKit

/// Push VPN status + selected server label into the shared App Group
/// UserDefaults so the Home Screen widget (`MadFrogWidget` target) can
/// render up-to-date state, and kick a `WidgetCenter` reload so iOS
/// re-runs the widget's TimelineProvider on the next vsync.
///
/// Keys MUST match `SharedKey` in MadFrogWidget.swift — change here and
/// there together.
enum WidgetStatusBridge {
    private static let suite = AppConstants.appGroupID
    private static let kStatus = "widget.vpn.status"
    private static let kServer = "widget.vpn.serverName"
    private static let kUpdatedAt = "widget.vpn.updatedAt"

    static func publish(status: NEVPNStatus, serverName: String?) {
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defaults.set(stringValue(for: status), forKey: kStatus)
        defaults.set(serverName, forKey: kServer)
        defaults.set(ISO8601DateFormatter().string(from: Date()), forKey: kUpdatedAt)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func stringValue(for status: NEVPNStatus) -> String {
        switch status {
        case .connected:                   return "connected"
        case .connecting, .reasserting:    return "connecting"
        case .disconnecting:               return "connecting"
        case .disconnected, .invalid:      return "disconnected"
        @unknown default:                  return "disconnected"
        }
    }
}
