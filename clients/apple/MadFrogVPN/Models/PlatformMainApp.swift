import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Cross-platform helpers that use APIs unavailable to app extensions
/// (UIApplication.shared / NSWorkspace.shared). Main app target only.

enum PlatformPasteboard {
    static func setString(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #else
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        #endif
    }
}

/// Opens a URL in the platform default browser. Apple treats both
/// `UIApplication.shared.open` and `NSWorkspace.shared.open` as user-initiated
/// navigation to an external website — the distinction that keeps external
/// payment flows (SBP/card) compliant with App Store Guideline 3.1.3.
@MainActor
enum PlatformURLOpener {
    static func open(_ url: URL) async {
        #if os(iOS)
        await UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }
}
