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
                TunnelFileLogger.log("PaywallRouter: storefront country=\(storefront.countryCode)", category: "ui")
            } else {
                TunnelFileLogger.log("PaywallRouter: Storefront.current returned nil", category: "ui")
            }
            // Debug override: check UserDefaults for "debug_paywall_force" = "web"|"storekit"
            resolved = true
        }
    }

    /// CIS storefronts → web paywall (FreeKassa / SBP). Everyone else →
    /// StoreKit. Covers RU + post-Soviet states where Russian cards and
    /// СБП work but Apple IAP is either missing or broken for local
    /// payment methods (Apple suspended transactions in RU, limited card
    /// support elsewhere). ISO 3166-1 alpha-3 and alpha-2 both supported.
    private static let cisThreeLetter: Set<String> = [
        "RUS", "KAZ", "BLR", "UZB", "UKR",
        "KGZ", "ARM", "AZE", "TJK", "MDA", "TKM",
    ]
    private static let cisTwoLetter: Set<String> = [
        "RU", "KZ", "BY", "UZ", "UA",
        "KG", "AM", "AZ", "TJ", "MD", "TM",
    ]

    /// Any CIS signal wins. Storefront is the authoritative source in the
    /// App Store build, but under TestFlight `Storefront.current` frequently
    /// returns the developer's account country (we saw "USA" on a KZ tester)
    /// which would strand real CIS users on a StoreKit screen they can't pay
    /// through. Accept either storefront OR Locale.region as "this is a CIS
    /// user" — false positives (e.g. Russian expat with a US card) are
    /// strictly better than false negatives.
    private var shouldUseWebPaywall: Bool {
        if let cc = storefrontCountry,
           Self.cisThreeLetter.contains(cc) || Self.cisTwoLetter.contains(cc) {
            return true
        }
        if let region = Locale.current.region?.identifier,
           Self.cisTwoLetter.contains(region) {
            return true
        }
        return false
    }
}
