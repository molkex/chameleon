import SwiftUI
import NetworkExtension

/// Neon Swamp — dark blue background, radial neon glows, 68pt uppercase
/// status type, huge 🐸 watermark, chunky CTA button with glow.
///
/// Layout is intentionally different from `MainViewCalm` — this is not a
/// recolor. Bold street-art energy, Mullvad × Cash App × Arc Search vibe.
struct MainViewNeon: View {
    let app: AppState
    @Binding var showServers: Bool
    @Binding var showSettings: Bool
    @Binding var showPaywall: Bool
    let cachedBuildInfoLine: String

    private let theme = Theme.neon

    var body: some View {
        ZStack {
            // Multi-layer radial glow background
            backgroundLayer

            // Huge frog watermark (decorative)
            Text("🐸")
                .font(.system(size: 260))
                .opacity(0.10)
                .rotationEffect(.degrees(-12))
                .offset(x: 80, y: 140)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                // Top bar: logo + PRO pill + icons
                headerRow
                    .padding(.top, 8)

                Spacer(minLength: 40)

                // BIG uppercase status
                bigStatus

                // Timer with glowing dot
                if VPNStateHelper.isConnected(app), let connectedAt = app.vpnConnectedAt {
                    timerRow(since: connectedAt)
                        .padding(.top, 18)
                }

                Spacer()

                // Server card with flag + IP badge
                serverCard
                    .padding(.bottom, 14)

                // Big CTA button
                ctaButton

                // Subscription strip
                subscriptionStrip
                    .padding(.top, 14)

                if !cachedBuildInfoLine.isEmpty {
                    Text(cachedBuildInfoLine)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(theme.textSecondary.opacity(0.45))
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 48)
            .padding(.bottom, 24)
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.039, green: 0.055, blue: 0.102),
                    Color(red: 0.027, green: 0.039, blue: 0.078),
                ],
                startPoint: .top, endPoint: .bottom
            )

            // Top neon glow
            RadialGradient(
                colors: [theme.accent.opacity(0.22), .clear],
                center: .init(x: 0.5, y: -0.1),
                startRadius: 20, endRadius: 500
            )

            // Bottom-right magenta glow
            RadialGradient(
                colors: [theme.accentSecondary.opacity(0.18), .clear],
                center: .init(x: 0.95, y: 1.05),
                startRadius: 20, endRadius: 420
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 10) {
            Text("🐸")
                .font(.system(size: 26))
                .shadow(color: theme.accent.opacity(0.8), radius: 10)
            Text("MADFROG")
                .font(.system(size: 22, weight: .black, design: .default))
                .kerning(-0.4)
                .foregroundStyle(.white)

            Spacer()

            if app.subscriptionExpire != nil {
                Text("PRO")
                    .font(.system(size: 11, weight: .black))
                    .kerning(1.2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(theme.background)
            }

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.accent.opacity(0.25), lineWidth: 1))
            }
        }
    }

    // MARK: - Big status

    private var connState: ConnectionState { VPNStateHelper.state(app) }

    private var bigStatus: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(statusTopLine)
                .font(.system(size: 60, weight: .black, design: .default))
                .kerning(-2.0)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(statusBottomLine)
                .font(.system(size: 60, weight: .black, design: .default))
                .kerning(-2.0)
                .foregroundStyle(statusBottomColor)
                .shadow(color: statusBottomColor.opacity(0.4), radius: 20)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
    }

    private var statusTopLine: LocalizedStringKey {
        switch connState {
        case .connecting:       return L10n.Home.neonConnecting
        case .reconnecting:     return L10n.Home.neonReconnecting
        case .disconnecting:    return L10n.Home.neonStopping
        case .permissionDenied: return L10n.Home.neonPermission
        case .connected:        return L10n.Home.neonYouAre
        case .disconnected:     return L10n.Home.neonYouAre
        }
    }

    private var statusBottomLine: LocalizedStringKey {
        switch connState {
        case .connecting:       return L10n.Home.neonDots
        case .reconnecting:     return L10n.Home.neonDots
        case .disconnecting:    return L10n.Home.neonDots
        case .permissionDenied: return L10n.Home.neonPermissionNeeded
        case .connected:        return L10n.Home.neonProtected
        case .disconnected:     return L10n.Home.neonExposed
        }
    }

    private var statusBottomColor: Color {
        switch connState {
        case .connected:                return theme.accent
        case .connecting, .reconnecting: return theme.accent.opacity(0.7)
        case .disconnecting:            return theme.textSecondary
        case .permissionDenied, .disconnected: return theme.accentSecondary
        }
    }

    private func timerRow(since: Date) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(theme.accent)
                .frame(width: 10, height: 10)
                .shadow(color: theme.accent, radius: 8)
            TimerView(since: since, theme: theme)
                .font(.system(.body, design: .monospaced).weight(.bold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Server card

    private var selectedServer: ServerItem? {
        guard let tag = app.selectedServerTag else { return nil }
        for group in app.servers {
            if let item = group.items.first(where: { $0.tag == tag }) { return item }
        }
        return nil
    }

    private var serverCard: some View {
        Button {
            showServers = true
        } label: {
            HStack(spacing: 14) {
                // Real country flag (or globe for Auto/unknown)
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.06))
                        .frame(width: 44, height: 44)
                    Text(selectedServer?.flagEmoji ?? "🌍")
                        .font(.system(size: 26))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(serverDisplayName)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(VPNStateHelper.isConnected(app) ? L10n.Home.serverActive : L10n.Home.serverStandby)
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(0.8)
                        .foregroundStyle(theme.textSecondary)
                }

                Spacer()

                Text(protocolBadgeText)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accent.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.accent.opacity(0.3), lineWidth: 1)
                    )
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(theme.accent.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var serverDisplayName: String {
        if app.selectedServerTag == nil {
            return String(localized: "home.server.auto_long")
        }
        // If the selected tag is itself a country urltest (user picked the
        // whole country, not a specific leaf), show the country label as-is.
        if let tag = app.selectedServerTag,
           let group = app.servers.first(where: { $0.type == "selector" && $0.selectable }),
           let country = group.countries.first(where: { $0.tag == tag }) {
            return "\(country.flagEmoji) \(country.name)".trimmingCharacters(in: .whitespaces)
        }
        if let server = selectedServer {
            return "\(L10n.Servers.countryName(server.countryKey)) · \(server.displayLabel)"
        }
        return VPNStateHelper.selectedServerName(app)
    }

    private var protocolBadgeText: String {
        if let server = selectedServer {
            return "⬢ \(server.protocolLabel)"
        }
        return "⬢ AUTO"
    }

    // MARK: - CTA

    private var ctaButton: some View {
        // TimelineView drives a subtle breathing glow while connected
        // (and a faster pulse while busy). When idle the shadow stays flat.
        TimelineView(.animation) { timeline in
            let phase = glowPhase(at: timeline.date)
            Button {
                TunnelFileLogger.log("TAP: connect button (state=\(connState), isLoading=\(app.isLoading))", category: "ui")
                Task { await app.requestToggle() }
            } label: {
                HStack {
                    if connState.isBusy {
                        ProgressView().tint(theme.background)
                        Spacer()
                        Text(ctaBusyText)
                            .font(.system(size: 18, weight: .black))
                            .kerning(0.5)
                    } else {
                        Text(ctaIdleText)
                            .font(.system(size: 18, weight: .black))
                            .kerning(0.5)
                        Spacer()
                        Image(systemName: connState == .connected ? "stop.fill" : "arrow.right")
                            .font(.system(size: 20, weight: .black))
                    }
                }
                .foregroundStyle(theme.background)
                .padding(.vertical, 22)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(ctaButtonColor)
                )
                .shadow(
                    color: ctaButtonColor.opacity(0.35 + 0.35 * phase),
                    radius: 24 + 14 * phase,
                    y: 0
                )
            }
            .buttonStyle(NeonPressStyle())
        }
        // Only block the button for states the user can't do anything about.
        // .connecting stays tappable so they can cancel a slow connect.
        .disabled(connState == .disconnecting || connState == .permissionDenied)
    }

    /// Returns a 0…1 oscillation for the CTA shadow. Connected → slow breath
    /// (~2.4s period). Busy → faster pulse (~0.9s). Idle → 0 (flat shadow).
    private func glowPhase(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        switch connState {
        case .connected:
            return 0.5 * (1 + sin(t * 2 * .pi / 2.4))
        case .connecting, .reconnecting:
            return 0.5 * (1 + sin(t * 2 * .pi / 0.9))
        default:
            return 0
        }
    }

    private var ctaIdleText: LocalizedStringKey {
        switch connState {
        case .connected:        return L10n.Home.ctaDisconnectCaps
        case .permissionDenied: return L10n.Home.ctaGrantAccess
        default:                return L10n.Home.ctaConnectNow
        }
    }

    private var ctaBusyText: LocalizedStringKey {
        switch connState {
        case .connecting:     return L10n.Home.ctaConnectingCaps
        case .reconnecting:   return L10n.Home.ctaReconnectingCaps
        case .disconnecting:  return L10n.Home.ctaStoppingCaps
        default:              return L10n.Home.neonDots
        }
    }

    private var ctaButtonColor: Color {
        switch connState {
        case .disconnecting: return theme.textSecondary
        default:             return theme.accent
        }
    }

    // MARK: - Subscription strip

    @ViewBuilder
    private var subscriptionStrip: some View {
        Button {
            showPaywall = true
        } label: {
            HStack {
                Text(subscriptionStripLeftText)
                    .font(.system(size: 11, weight: .black))
                    .kerning(1.2)
                    .foregroundStyle(theme.accentSecondary)
                Spacer()
                Text(subscriptionStripRightText)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(theme.accentSecondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(theme.accentSecondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var subscriptionStripLeftText: LocalizedStringKey {
        app.subscriptionExpire != nil ? L10n.Home.subProActive : L10n.Home.subGetPro
    }

    private var subscriptionStripRightText: String {
        if let expire = app.subscriptionExpire {
            let days = Calendar.current.dateComponents([.day], from: .now, to: expire).day ?? 0
            if days < 0 { return String(localized: "home.subscription.expired") }
            return L10n.Home.subDaysLeft(days)
        }
        return String(localized: "home.subscription.unlock")
    }
}

/// Tactile press feedback for the big Neon CTA — scales down + dims on tap.
private struct NeonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
