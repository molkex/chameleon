import Foundation
import SwiftUI

/// Central wrapper over `Localizable.strings`. All user-visible strings in the
/// app go through `L10n` so we have one place to audit translations and make
/// sure every screen has both EN and RU variants.
///
/// Usage in SwiftUI: `Text(L10n.Home.statusProtected)` — returns
/// `LocalizedStringKey`, Text looks up the key in the active bundle.
/// For plain `String` contexts: `L10n.Home.statusProtected.string`.
enum L10n {
    enum Home {
        static let label               = LKey("home.status.label")

        static let statusProtected     = LKey("home.status.protected")
        static let statusExposed       = LKey("home.status.exposed")
        static let statusConnecting    = LKey("home.status.connecting")
        static let statusReconnecting  = LKey("home.status.reconnecting")
        static let statusDisconnecting = LKey("home.status.disconnecting")
        static let statusPermission    = LKey("home.status.permission_denied")

        static let subtitleConnected     = LKey("home.subtitle.connected")
        static let subtitleDisconnected  = LKey("home.subtitle.disconnected")
        static let subtitleConnecting    = LKey("home.subtitle.connecting")
        static let subtitleReconnecting  = LKey("home.subtitle.reconnecting")
        static let subtitleDisconnecting = LKey("home.subtitle.disconnecting")
        static let subtitlePermission    = LKey("home.subtitle.permission")

        static let ctaConnect       = LKey("home.cta.connect")
        static let ctaCancel        = LKey("home.cta.cancel")
        static let ctaDisconnect    = LKey("home.cta.disconnect")
        static let ctaPermission    = LKey("home.cta.permission")
        static let ctaReconnecting  = LKey("home.cta.reconnecting")
        static let ctaWaiting       = LKey("home.cta.waiting")

        static let ctaConnectNow    = LKey("home.cta.connect_now")
        static let ctaGrantAccess   = LKey("home.cta.grant_access")
        static let ctaDisconnectCaps = LKey("home.cta.disconnect_caps")
        static let ctaConnectingCaps = LKey("home.cta.connecting_caps")
        static let ctaReconnectingCaps = LKey("home.cta.reconnecting_caps")
        static let ctaStoppingCaps  = LKey("home.cta.stopping_caps")

        static let neonYouAre          = LKey("home.neon.you_are")
        static let neonProtected       = LKey("home.neon.protected")
        static let neonExposed         = LKey("home.neon.exposed")
        static let neonConnecting      = LKey("home.neon.connecting")
        static let neonReconnecting    = LKey("home.neon.reconnecting")
        static let neonStopping        = LKey("home.neon.stopping")
        static let neonPermission      = LKey("home.neon.permission")
        static let neonPermissionNeeded = LKey("home.neon.permission_needed")
        static let neonDots            = LKey("home.neon.dots")

        static let headerPro       = LKey("home.header.pro")
        static let headerFree      = LKey("home.header.free")
        static let headerProMember = LKey("home.header.pro_member")
        /// Header label shown when the user is on the 3-day backend free
        /// trial (subscriptionExpire != nil && !hasPaidEver). Must NOT
        /// claim "Pro/Premium" — Apple Review build 74 rejected the
        /// "Pro by default" UX. See incident
        /// 2026-05-15-app-review-iap-not-found.
        static let headerTrial     = LKey("home.header.trial")

        static let serverActive    = LKey("home.server.active")
        static let serverStandby   = LKey("home.server.standby")

        static let chipServer      = LKey("home.chip.server")
        static let chipSession     = LKey("home.chip.session")
        static let chipSessionIdle = LKey("home.chip.session_idle")

        static let autoName        = LKey("home.server.auto")
        static let autoLongName    = LKey("home.server.auto_long")

        // Subscription strip
        static let subGetPro        = LKey("home.subscription.get_pro")
        static let subProActive     = LKey("home.subscription.pro_active")
        static let subUnlock        = LKey("home.subscription.unlock")
        static let subExpired       = LKey("home.subscription.expired")
        static let subExpiredFull   = LKey("home.subscription.expired_full")
        static let subUnlockFull    = LKey("home.subscription.unlock_full")
        /// Trial-state version of `subProActive` — shown when the user is
        /// on the 3-day backend free trial. Must NOT use "Pro" wording.
        static let subTrialActive   = LKey("home.subscription.trial_active")

        static func subDaysLeft(_ days: Int) -> String {
            String(format: String(localized: "home.subscription.days_left"), days)
        }
        static func subProDays(_ days: Int) -> String {
            String(format: String(localized: "home.subscription.pro_days"), days)
        }
        /// Trial countdown — "Пробный период · N дн." / "Free trial · N days".
        /// Used by the home screen instead of `subProDays` while `isTrial`.
        static func subTrialDays(_ days: Int) -> String {
            String(format: String(localized: "home.subscription.trial_days"), days)
        }
    }

    enum Onboarding {
        static let title       = LKey("onboarding.title")
        static let subtitle    = LKey("onboarding.subtitle")
        static let featureTrial   = LKey("onboarding.feature.trial")
        static let featureNoLogs  = LKey("onboarding.feature.no_logs")
        static let featureServers = LKey("onboarding.feature.servers")
        static let signInFailed   = LKey("onboarding.signin_failed")
        static let signInFailedTitle = LKey("onboarding.signin_failed.title")
        static let anonFailed     = LKey("onboarding.anon_failed")
        static let continueWithoutAccount = LKey("onboarding.continue_no_account")
        static let signInWithApple    = LKey("onboarding.sign_in_with_apple")
        static let signInWithGoogle   = LKey("onboarding.sign_in_with_google")
        static let signInWithEmail    = LKey("onboarding.sign_in_with_email")
        static let orLabel            = LKey("onboarding.or")
        static let featureTrialShort  = LKey("onboarding.feature.trial_short")
        static let featureNoLogsShort = LKey("onboarding.feature.no_logs_short")
        static let featureFastShort   = LKey("onboarding.feature.fast_short")
        static let terms          = LKey("onboarding.terms")
    }

    enum Magic {
        static let title              = LKey("magic.title")
        static let subtitle           = LKey("magic.subtitle")
        static let emailPlaceholder   = LKey("magic.email.placeholder")
        static let send               = LKey("magic.send")
        static let checkEmailTitle    = LKey("magic.check_email.title")
        static let checkEmailBody     = LKey("magic.check_email.body")
        static let checkEmailClose    = LKey("magic.check_email.close")
    }

    enum Primer {
        static let title          = LKey("primer.title")
        static let subtitle       = LKey("primer.subtitle")
        static let step1          = LKey("primer.step1")
        static let step2          = LKey("primer.step2")
        static let step3          = LKey("primer.step3")
        static let continueButton = LKey("primer.continue")
        static let notNow         = LKey("primer.not_now")
    }

    enum MenuBar {
        static let connect        = LKey("menubar.connect")
        static let disconnect     = LKey("menubar.disconnect")
        static let openWindow     = LKey("menubar.open_window")
        static let quit           = LKey("menubar.quit")
        static let statusProtected = LKey("menubar.status.protected")
        static let statusConnecting = LKey("menubar.status.connecting")
        static let statusDisconnected = LKey("menubar.status.disconnected")
        static let autoFastest    = LKey("menubar.auto_fastest")
    }

    enum WebPaywall {
        static let title           = LKey("webpaywall.title")
        static let close           = LKey("webpaywall.close")
        static let headerTitle     = LKey("webpaywall.header.title")
        static let headerSubtitle  = LKey("webpaywall.header.subtitle")
        static let emailLabel      = LKey("webpaywall.email.label")
        static let emailHint       = LKey("webpaywall.email.hint")
        static let methodLabel     = LKey("webpaywall.method.label")
        static let methodSBP       = LKey("webpaywall.method.sbp")
        static let methodCard      = LKey("webpaywall.method.card")
        static let pay             = LKey("webpaywall.pay")
        static let checkStatus     = LKey("webpaywall.check_status")
        static let enterEmail      = LKey("webpaywall.enter_email")
        static let emailInvalid    = LKey("webpaywall.email.invalid")
        static let successTitle    = LKey("webpaywall.success.title")
        static let successBody     = LKey("webpaywall.success.body")
        static let successOk       = LKey("webpaywall.success.ok")
        static let legalText       = LKey("webpaywall.legal.text")
        static let legalTerms      = LKey("webpaywall.legal.terms")
        static let legalPrivacy    = LKey("webpaywall.legal.privacy")
        static let errorPlans      = LKey("webpaywall.error.plans")
        static let errorAuth       = LKey("webpaywall.error.auth")
        static let errorPending    = LKey("webpaywall.error.pending")
        static let errorSession    = LKey("webpaywall.error.session")
        static let errorPayment    = LKey("webpaywall.error.payment")

        static func planDaysOneDevice(_ days: Int) -> String {
            String(format: String(localized: "webpaywall.plan.days_one_device"), days)
        }
    }

    enum Paywall {
        static let title             = LKey("paywall.title")
        static let headerTitle       = LKey("paywall.header.title")
        static let headerSubtitle    = LKey("paywall.header.subtitle")
        static let noProductsTitle   = LKey("paywall.no_products.title")
        static let noProductsHint    = LKey("paywall.no_products.hint")
        static let retry             = LKey("paywall.retry")
        static let purchase          = LKey("paywall.purchase")
        static let restore           = LKey("paywall.restore")
        static let restoredAlert     = LKey("paywall.restored_alert")
        static let ok                = LKey("paywall.ok")
        static let close             = LKey("paywall.close")
        static let legal             = LKey("paywall.legal")
        static let terms             = LKey("paywall.terms")
        static let privacy           = LKey("paywall.privacy")
    }

    enum Theme {
        static let title       = LKey("theme.title")
        static let subtitle    = LKey("theme.subtitle")
        static let done        = LKey("theme.done")
        static let calmName    = LKey("theme.calm.name")
        static let calmTagline = LKey("theme.calm.tagline")
        static let neonName    = LKey("theme.neon.name")
        static let neonTagline = LKey("theme.neon.tagline")
    }

    enum Servers {
        static let title    = LKey("servers.title")
        static let done     = LKey("servers.done")
        static let autoBest = LKey("servers.auto_best")
        static let pingUnknown = LKey("servers.ping.unknown")
        static let refresh  = LKey("servers.refresh")
        static let sectionCountries = LKey("servers.section.countries")
        static let sectionDirect = LKey("servers.section.direct")
        static let sectionBypass = LKey("servers.section.bypass")
        static let sectionBypassHint = LKey("servers.section.bypass_hint")

        static func pingMs(_ ms: Int) -> String {
            String(format: String(localized: "servers.ping.ms"), ms)
        }
        static func serversIn(_ country: String) -> String {
            String(format: String(localized: "servers.servers_in"), country)
        }
        static func countryName(_ key: String) -> String {
            switch key {
            case "nl": return String(localized: "servers.country.nl")
            case "de": return String(localized: "servers.country.de")
            case "ru": return String(localized: "servers.country.ru")
            default:   return String(localized: "servers.country.other")
            }
        }
    }

    enum Settings {
        static let title           = LKey("settings.title")
        static let sectionAppearance = LKey("settings.section.appearance")
        static let sectionRouting    = LKey("settings.section.routing")
        static let sectionAccount    = LKey("settings.section.account")
        static let sectionAbout      = LKey("settings.section.about")
        static let sectionDiagnostics = LKey("settings.section.diagnostics")
        static let contactSupport    = LKey("settings.contact_support")
        static let theme           = LKey("settings.theme")
        static let routingMode     = LKey("settings.routing_mode")
        static let routingModeSmart        = LKey("settings.routing_mode.smart")
        static let routingModeSmartHint    = LKey("settings.routing_mode.smart.hint")
        static let routingModeRuDirect     = LKey("settings.routing_mode.ru_direct")
        static let routingModeRuDirectHint = LKey("settings.routing_mode.ru_direct.hint")
        static let routingModeFullVPN      = LKey("settings.routing_mode.full_vpn")
        static let routingModeFullVPNHint  = LKey("settings.routing_mode.full_vpn.hint")
        static let logout          = LKey("settings.logout")
        static let logoutTitle     = LKey("settings.logout_confirm.title")
        static let logoutBody      = LKey("settings.logout_confirm.body")
        static let logoutOk        = LKey("settings.logout_confirm.ok")
        static let deleteAccount   = LKey("settings.delete_account")
        static let deleteTitle     = LKey("settings.delete_confirm.title")
        static let deleteBody      = LKey("settings.delete_confirm.body")
        static let deleteOk        = LKey("settings.delete_confirm.ok")
        static let deleteCancel    = LKey("settings.delete_confirm.cancel")
        static let version         = LKey("settings.version")
        static let debugLogs       = LKey("settings.debug_logs")
        static let autoRecover     = LKey("settings.auto_recover")
        static let autoRecoverHint = LKey("settings.auto_recover.hint")
        static let autoConnect     = LKey("settings.auto_connect")
        static let autoConnectHint = LKey("settings.auto_connect.hint")
    }

    enum Recovery {
        static func switchedToAuto(_ country: String) -> String {
            String(format: String(localized: "recovery.switched_to_auto"), country)
        }
        static func switchedLeg(_ country: String) -> String {
            String(format: String(localized: "recovery.switched_leg"), country)
        }
        static func switchedFromTo(_ from: String, _ to: String) -> String {
            String(format: String(localized: "recovery.switched_from_to"), from, to)
        }
        static func switchedTo(_ to: String) -> String {
            String(format: String(localized: "recovery.switched_to"), to)
        }
        static var switchedToBypass: String { String(localized: "recovery.switched_to_bypass") }
        static var allDead: String { String(localized: "recovery.all_dead") }
    }

    enum Account {
        static let title                  = LKey("account.title")
        static let username               = LKey("account.username")
        static let subscription           = LKey("account.subscription")
        static let subscriptionFree       = LKey("account.subscription.free")

        static func subscriptionProUntil(_ date: String) -> String {
            String(format: String(localized: "account.subscription.pro_until"), date)
        }
        /// Trial-state version of `subscriptionProUntil` — "Пробный период
        /// до %@" / "Free trial until %@". App Review build 74 rejected
        /// "Pro" wording on the trial — see incident
        /// 2026-05-15-app-review-iap-not-found.
        static func subscriptionTrialUntil(_ date: String) -> String {
            String(format: String(localized: "account.subscription.trial_until"), date)
        }
    }

    enum Legal {
        static let termsTitle   = LKey("legal.terms.title")
        static let privacyTitle = LKey("legal.privacy.title")
        static let termsBody    = LKey("legal.terms.body")
        static let privacyBody  = LKey("legal.privacy.body")
    }

    enum Error {
        static let noConfig         = "error.no_config".localized
        static let serverRejected   = "error.server_rejected".localized
        static let timeout          = "error.timeout".localized
        static let permission       = "error.permission".localized
        static let generic          = "error.generic".localized
        static let configInvalid    = "error.config_invalid".localized
        static let configDisabled   = "error.config_disabled".localized
        static let connectionFailed = "error.connection_failed".localized
        static let configStale      = "error.config_stale".localized
        static let rwFailed         = "error.rw_failed".localized
        static let offline          = "error.offline".localized
        static let serverTimeout    = "error.server_timeout".localized
        static let allServersUnreachable = "error.all_servers_unreachable".localized
        static func selectedUnreachable(_ name: String) -> String {
            String(format: "error.selected_unreachable".localized, name)
        }
    }
}

/// Typealias for `LocalizedStringKey` — shortens call sites.
typealias LKey = LocalizedStringKey

extension String {
    /// Pulls the value from `Localizable.strings` for this key.
    /// Used outside of SwiftUI contexts where `LocalizedStringKey` isn't
    /// resolved automatically (e.g. `errorMessage`, alerts, formatters).
    var localized: String {
        String(localized: String.LocalizationValue(self))
    }
}
