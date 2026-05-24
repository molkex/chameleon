import WidgetKit
import SwiftUI

/// The WidgetKit extension entry point.
///
/// - launch-04  — `StatusWidget`: read-only VPN status glance for the
///   Home Screen and Lock Screen.
/// - launch-04b — `MadFrogControlWidget`: an iOS-18 Control Center
///   toggle that connects/disconnects in place. `StatusWidget`'s
///   systemSmall tile also gained an interactive toggle button.
///   Both drive `ToggleVPNIntent`, which runs in this extension's
///   process (hence the packet-tunnel-provider entitlement on the
///   widget target) and starts the tunnel with the App-Group-persisted
///   config — no app launch, no backend round-trip on the warm path.
@main
struct MadFrogWidgetBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        if #available(iOS 18.0, *) {
            MadFrogControlWidget()
        }
    }
}
