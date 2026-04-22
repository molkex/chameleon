import SwiftUI
import StoreKit

/// Chooses between the StoreKit-backed paywall and the web paywall (FreeKassa/СБП)
/// based on the user's App Store storefront.
///
/// App Store rule (Guideline 3.1.1): digital goods sold to users outside
/// regions where alternative processors are permitted must go through
/// StoreKit. We route RU storefront users to the web paywall (СБП/cards
/// via FreeKassa) because Apple's in-app payments don't support Russian
/// cards well, and everyone else to StoreKit.
///
/// Storefront (not Locale) is the right signal — it reflects which App Store
/// the user purchases from, which determines what IAP are even available.
/// A user with RU interface in Georgia on a US App Store account should
/// see the StoreKit flow.
struct PaywallRouter: View {
    @State private var storefrontCountry: String?
    @State private var resolved = false

    var body: some View {
        Group {
            if !resolved {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shouldUseWebPaywall {
                WebPaywallView()
            } else {
                PaywallView()
            }
        }
        .task {
            if let storefront = await Storefront.current {
                storefrontCountry = storefront.countryCode
            }
            resolved = true
        }
    }

    /// RU storefront → web paywall. Everyone else → StoreKit.
    /// If we fail to resolve (edge case, e.g. user signed out of App Store),
    /// default to StoreKit to stay Guideline 3.1.1 compliant.
    private var shouldUseWebPaywall: Bool {
        storefrontCountry == "RUS"
    }
}
