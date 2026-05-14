import WidgetKit
import SwiftUI

/// launch-04: the WidgetKit extension entry point. One widget for now —
/// a read-only VPN status glance for the Home Screen and Lock Screen.
///
/// The interactive toggle (Home Screen AppIntent button + iOS-18
/// ControlWidget for Control Center) is launch-04b — deferred because
/// driving NEVPNManager from a widget-extension process needs on-device
/// verification, and a half-working toggle is worse than none.
@main
struct MadFrogWidgetBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
    }
}
