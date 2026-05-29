import XCTest
import SwiftUI
import StoreKitTest
@testable import MadFrogVPN

/// Captures a StoreKit-paywall screenshot for the App Store subscription
/// review screenshot. The live StoreKit paywall is only shown to non-CIS
/// storefronts, so it can't be screenshotted from a RU device — we render
/// it with products supplied by an SKTestSession (Products.storekit), on a
/// LIVE window scene (a detached UIWindow renders blank).
@MainActor
final class PaywallSnapshotTests: XCTestCase {

    func testCapturePaywallScreenshot() async throws {
        let session = try SKTestSession(configurationFileNamed: "Products")
        session.disableDialogs = true
        session.resetToDefaultState()
        session.clearTransactions()

        let app = AppState()
        let theme = ThemeManager()
        await app.subscriptionManager.loadProducts()
        XCTAssertEqual(app.subscriptionManager.products.count, 4,
                       "expected 4 products, got \(app.subscriptionManager.products.map(\.id))")

        // Attach to the host app's live window scene so SwiftUI renders via
        // the real render server (a detached UIWindow renders blank).
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "no UIWindowScene available in the test host")
        let host = UIHostingController(
            rootView: PaywallView().environment(app).environment(theme))
        host.overrideUserInterfaceStyle = .dark
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        // Let SwiftUI commit + the (already-loaded) products lay out.
        try await Task.sleep(nanoseconds: 2_500_000_000)

        let bounds = window.bounds
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = window.screen.scale
        let image = UIGraphicsImageRenderer(bounds: bounds, format: fmt).image { _ in
            _ = window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        let png = try XCTUnwrap(image.pngData(), "PNG encoding failed")

        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "paywall-review"
        attachment.lifetime = .keepAlways
        add(attachment)

        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("paywall-review.png")
        try png.write(to: out)
        print("PAYWALL_SHOT_PATH=\(out.path) bytes=\(png.count) size=\(Int(bounds.width))x\(Int(bounds.height))@\(fmt.scale)")
    }
}
