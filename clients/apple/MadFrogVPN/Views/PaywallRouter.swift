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

    /// Route by **App Store storefront only** — NOT by device Locale.
    ///
    /// History: build 74 was rejected (Guideline 2.1(a)+(b), round 4 / submission
    /// 0280c9a8) — App Review on iPhone 17 Pro Max could not find the StoreKit
    /// IAPs in the binary because the device's Locale.region tripped the CIS
    /// check and routed the reviewer to the web paywall (FreeKassa). Apple's
    /// reviewer is identified by their `Storefront`, not their device locale,
    /// so storefront alone is the right signal for that decision. The earlier
    /// "TestFlight returns dev country" worry is moot for App Store builds —
    /// in the App Store build `Storefront.current` reliably reflects the user's
    /// purchasing region.
    ///
    /// Real CIS users still get the web paywall (their storefront is RU/KZ/etc.).
    /// A Russian expat on a US storefront sees StoreKit — that is fine; they
    /// can pay with an international card via Apple IAP.
    ///
    /// See incident 2026-05-15-app-review-iap-not-found.
    private var shouldUseWebPaywall: Bool {
        guard let cc = storefrontCountry else { return false }
        return Self.cisThreeLetter.contains(cc) || Self.cisTwoLetter.contains(cc)
    }
}
