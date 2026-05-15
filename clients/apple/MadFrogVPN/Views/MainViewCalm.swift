import SwiftUI
import NetworkExtension

/// Calm — charcoal background with a big rounded lime-yellow hero card as
/// the central element. Soft hierarchy, plenty of whitespace, casual
/// greeting at the top. Reference: soil-monitor app screenshot.
///
/// Intentionally different composition from `MainViewNeon` — not a recolor.
struct MainViewCalm: View {
    let app: AppState
    @Binding var showServers: Bool
    @Binding var showSettings: Bool
    @Binding var showPaywall: Bool
    let cachedBuildInfoLine: String

    private let theme = Theme.calm
    private var connState: ConnectionState { VPNStateHelper.state(app) }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                headerRow
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                Spacer(minLength: 20)

                greetingBlock
                    .padding(.horizontal, 20)

                Spacer(minLength: 18)

                heroCard
                    .padding(.horizontal, 20)

                Spacer(minLength: 18)

                statChips
                    .padding(.horizontal, 20)

                Spacer()

                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

                if !cachedBuildInfoLine.isEmpty {
                    Text(cachedBuildInfoLine)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(theme.textSecondary.opacity(0.45))
                        .padding(.bottom, 6)
                }
            }
            .padding(.top, 48)
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(theme.surface)
                .frame(width: 42, height: 42)
                .overlay(
                    Text("🐸").font(.system(size: 22))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("MadFrog")
                    .font(theme.displayFont(size: 17, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                // Trial users see "Пробный период"; only paying users see
                // "Подписка Pro". App Review build 74 rejected the
                // "Pro by default" UX — see incident
                // 2026-05-15-app-review-iap-not-found.
                Text(
                    app.isTrial
                        ? L10n.Home.headerTrial
                        : (app.subscriptionExpire != nil ? L10n.Home.headerProMember : L10n.Home.headerFree)
                )
                    .font(theme.font(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(theme.surface, in: Circle())
            }
        }
    }

    // MARK: - Greeting

    private var greetingBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(statusHeadline)
                    .font(theme.displayFont(size: 28, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
            }
            Text(statusSubtitle)
                .font(theme.font(size: 14))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusHeadline: LocalizedStringKey {
        switch connState {
        case .connected:        return L10n.Home.statusProtected
        case .connecting:       return L10n.Home.statusConnecting
        case .reconnecting:     return L10n.Home.statusReconnecting
        case .disconnecting:    return L10n.Home.statusDisconnecting
        case .permissionDenied: return L10n.Home.statusPermission
        case .disconnected:     return L10n.Home.statusExposed
        }
    }

    private var statusSubtitle: LocalizedStringKey {
        switch connState {
        case .connecting:       return L10n.Home.subtitleConnecting
        case .reconnecting:     return L10n.Home.subtitleReconnecting
        case .disconnecting:    return L10n.Home.subtitleDisconnecting
        case .permissionDenied: return L10n.Home.subtitlePermission
        case .connected:        return L10n.Home.subtitleConnected
        case .disconnected:     return L10n.Home.subtitleDisconnected
        }
    }

    // MARK: - Hero card

    private var heroCard: some View {
        Button {
            TunnelFileLogger.log("TAP: connect button (state=\(connState), isLoading=\(app.isLoading))", category: "ui")
            Task { await app.requestToggle() }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(heroCardColor)

                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.Home.label)
                                .font(.system(size: 12, weight: .semibold))
                                .kerning(0.6)
                                .textCase(.uppercase)
                                .foregroundStyle(heroTextSecondary)
                            Text(heroValue)
                                .font(.system(size: 46, weight: .heavy, design: .rounded))
                                .foregroundStyle(heroTextPrimary)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: heroIcon)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(heroTextPrimary.opacity(0.8))
                    }

                    Spacer()

                    HStack {
                        Text(ctaText)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(heroTextPrimary)
                        Spacer()
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(connState.isProtected ? 1.0 : 0.85))
                                .frame(width: 72, height: 72)
                            if connState.isBusy {
                                ProgressView().tint(heroCardColor)
                            } else {
                                Image(systemName: powerIcon)
                                    .font(.system(size: 28, weight: .heavy))
                                    .foregroundStyle(connState.isProtected ? heroCardColor : .white)
                            }
                        }
                    }
                }
                .padding(26)
            }
            .frame(height: 280)
        }
        .buttonStyle(.plain)
        .disabled(connState == .disconnecting || connState == .permissionDenied)
    }

    private var heroCardColor: Color {
        switch connState {
        case .connected:
            return theme.accent                                     // lime — protected
        case .connecting, .reconnecting:
            return theme.accent.opacity(0.55)                       // muted lime — transient
        case .disconnecting:
            return Color(red: 0.18, green: 0.18, blue: 0.18)        // dim charcoal
        case .permissionDenied:
            return Color(red: 1.0, green: 0.42, blue: 0.42)         // red — action required
        case .disconnected:
            return theme.surfaceElevated                            // charcoal — exposed
        }
    }

    private var heroTextPrimary: Color {
        // Dark text on bright cards, white text on dark cards.
        switch connState {
        case .connected, .connecting, .reconnecting, .permissionDenied:
            return .black
        case .disconnecting, .disconnected:
            return .white
        }
    }

    private var heroTextSecondary: Color {
        heroTextPrimary.opacity(0.55)
    }

    private var heroValue: LocalizedStringKey {
        switch connState {
        case .connected:        return L10n.Home.statusProtected
        case .connecting:       return L10n.Home.statusConnecting
        case .reconnecting:     return L10n.Home.statusReconnecting
        case .disconnecting:    return L10n.Home.statusDisconnecting
        case .permissionDenied: return L10n.Home.statusPermission
        case .disconnected:     return L10n.Home.statusExposed
        }
    }

    private var heroIcon: String {
        switch connState {
        case .connected:        return "lock.shield.fill"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .disconnecting:    return "pause.circle"
        case .permissionDenied: return "exclamationmark.shield"
        case .disconnected:     return "lock.open"
        }
    }

    private var powerIcon: String {
        connState.isProtected ? "stop.fill" : "power"
    }

    private var ctaText: LocalizedStringKey {
        switch connState {
        case .connected:        return L10n.Home.ctaDisconnect
        case .connecting:       return L10n.Home.ctaCancel
        case .reconnecting:     return L10n.Home.ctaReconnecting
        case .disconnecting:    return L10n.Home.ctaWaiting
        case .permissionDenied: return L10n.Home.ctaPermission
        case .disconnected:     return L10n.Home.ctaConnect
        }
    }

    // MARK: - Stat chips

    private var statChips: some View {
        HStack(spacing: 12) {
            chip(
                title: L10n.Home.chipServer,
                value: VPNStateHelper.selectedServerName(app),
                icon: "globe"
            ) {
                showServers = true
            }

            // Session chip is wrapped in TimelineView so the running timer
            // re-renders every second — plain computed properties won't.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                chip(
                    title: L10n.Home.chipSession,
                    value: sessionValue,
                    icon: "clock"
                ) {}
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func chip(title: LocalizedStringKey, value: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 32, height: 32)
                    .background(theme.accent.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(theme.font(size: 11))
                        .foregroundStyle(theme.textSecondary)
                    Text(value)
                        .font(theme.font(size: 14, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.surface)
            )
        }
        .buttonStyle(.plain)
    }

    private var sessionValue: String {
        if VPNStateHelper.isConnected(app), let connectedAt = app.vpnConnectedAt {
            return CalmTimerFormatter.format(since: connectedAt)
        }
        return String(localized: "home.chip.session_idle")
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        // Trial uses an hourglass icon + amber accent so the bottom bar
        // doesn't read as "crown / Pro" while the user is still on the
        // backend trial. Paid users keep the crown. See incident
        // 2026-05-15-app-review-iap-not-found.
        let iconName: String
        let iconColor: Color
        if app.subscriptionExpire == nil {
            iconName = "sparkles"
            iconColor = theme.accent
        } else if app.isTrial {
            iconName = "hourglass"
            iconColor = theme.warning
        } else {
            iconName = "crown.fill"
            iconColor = theme.accent
        }
        return HStack(spacing: 10) {
            Button {
                showPaywall = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: iconName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(iconColor)
                    Text(subscriptionText)
                        .font(theme.font(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(theme.surface)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var subscriptionText: String {
        if let expire = app.subscriptionExpire {
            let days = Calendar.current.dateComponents([.day], from: .now, to: expire).day ?? 0
            if days < 0 { return String(localized: "home.subscription.expired_full") }
            // App Review build 74 (Guideline 2.1a) — must NOT call the
            // backend trial "Pro". Render trial wording while !hasPaidEver
            // && !isPremium. See incident 2026-05-15-app-review-iap-not-found.
            return app.isTrial ? L10n.Home.subTrialDays(days) : L10n.Home.subProDays(days)
        }
        return String(localized: "home.subscription.unlock_full")
    }
}

// Lightweight formatter so we don't spin TimerView here (hero uses label directly).
private enum CalmTimerFormatter {
    static func format(since: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(since))
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        let s = elapsed % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
