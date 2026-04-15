import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Thin wrapper around UIKit haptic generators so call sites stay one-liners
/// and the code compiles on macOS (where UIKit is unavailable) without #if.
@MainActor
enum Haptics {
    static func impact(_ style: ImpactStyle) {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: style.uiKit).impactOccurred()
        #endif
    }

    static func selection() {
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    static func notify(_ type: NotifyType) {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(type.uiKit)
        #endif
    }

    enum ImpactStyle {
        case light, medium, heavy, soft, rigid
        #if canImport(UIKit)
        var uiKit: UIImpactFeedbackGenerator.FeedbackStyle {
            switch self {
            case .light: return .light
            case .medium: return .medium
            case .heavy: return .heavy
            case .soft: return .soft
            case .rigid: return .rigid
            }
        }
        #endif
    }

    enum NotifyType {
        case success, warning, error
        #if canImport(UIKit)
        var uiKit: UINotificationFeedbackGenerator.FeedbackType {
            switch self {
            case .success: return .success
            case .warning: return .warning
            case .error: return .error
            }
        }
        #endif
    }
}
