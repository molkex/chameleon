import SwiftUI

/// Top-level settings. Themed to match the app look (not system Form). Each
/// logical section is a single rounded card on the theme.background with
/// divider lines inside — reads as "one thing" visually, avoids the iOS
/// grouped-list fight with dark themes.
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    @State private var showThemePicker = false
    @State private var showDebugLogs = false
    @State private var preloadedTunnelLines: [String] = []
    @State private var preloadedStderrLines: [String] = []
    @State private var showAccount = false
    @State private var showTerms = false
    @State private var showPrivacy = false

    private var theme: Theme { themeManager.current }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        sectionHeader(L10n.Settings.sectionAppearance)
                        card {
                            row(icon: "paintpalette.fill", title: L10n.Settings.theme,
                                trailing: Text(themeManager.current.displayName)
                                    .font(theme.font(size: 15))
                                    .foregroundStyle(theme.textSecondary),
                                showChevron: true
                            ) { showThemePicker = true }
                        }

                        sectionHeader(L10n.Settings.sectionRouting)
                        card {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(spacing: 14) {
                                    iconCircle("arrow.triangle.branch")
                                    Text(L10n.Settings.routingMode)
                                        .font(theme.font(size: 16, weight: .medium))
                                        .foregroundStyle(theme.textPrimary)
                                    Spacer()
                                }

                                // Segmented pill — 3 options in one row. Custom
                                // rendering so it adopts the theme accent and
                                // matches the rest of Settings.
                                HStack(spacing: 0) {
                                    routingSegment(.smart,    label: L10n.Settings.routingModeSmart)
                                    routingSegment(.ruDirect, label: L10n.Settings.routingModeRuDirect)
                                    routingSegment(.fullVPN,  label: L10n.Settings.routingModeFullVPN)
                                }
                                .padding(3)
                                .background(theme.background.opacity(0.6),
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                                Text(routingModeHint)
                                    .font(theme.font(size: 13))
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(16)
                        }

                        sectionHeader(L10n.Settings.sectionAccount)
                        card {
                            row(icon: "person.crop.circle", title: L10n.Account.title,
                                showChevron: true) { showAccount = true }
                        }

                        sectionHeader(L10n.Settings.sectionAbout)
                        card {
                            VStack(spacing: 0) {
                                row(icon: "doc.text", title: L10n.Paywall.terms,
                                    showChevron: true) { showTerms = true }
                                divider
                                row(icon: "hand.raised", title: L10n.Paywall.privacy,
                                    showChevron: true) { showPrivacy = true }
                                divider
                                HStack(spacing: 14) {
                                    iconCircle("info.circle")
                                    Text(L10n.Settings.version)
                                        .font(theme.font(size: 16, weight: .medium))
                                        .foregroundStyle(theme.textPrimary)
                                    Spacer()
                                    Text(versionString)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(theme.textSecondary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                            }
                        }

                        sectionHeader(L10n.Settings.sectionDiagnostics)
                        card {
                            row(icon: "ladybug", title: L10n.Settings.debugLogs,
                                showChevron: true) {
                                TunnelFileLogger.log("TAP: debug logs (from settings)", category: "ui")
                                preloadedTunnelLines = TunnelFileLogger.readLog().components(separatedBy: "\n")
                                preloadedStderrLines = TunnelFileLogger.readStderrLog().components(separatedBy: "\n")
                                showDebugLogs = true
                            }
                        }

                        Spacer().frame(height: 24)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .navigationTitle(Text(L10n.Settings.title))
            .iosInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: PlatformToolbarPlacement.trailing.resolved) {
                    Button(L10n.Servers.done) { dismiss() }
                        .tint(theme.accent)
                }
            }
            .sheet(isPresented: $showThemePicker) {
                ThemePickerView(isModal: true).environment(themeManager).macSheetSize()
            }
            .sheet(isPresented: $showDebugLogs) {
                DebugLogsView(
                    preloadedTunnelLines: preloadedTunnelLines,
                    preloadedStderrLines: preloadedStderrLines
                )
                .environment(app)
                .macSheetSize(width: 640, height: 760)
            }
            .sheet(isPresented: $showAccount) {
                NavigationStack { AccountView() }
                    .environment(app)
                    .macSheetSize()
            }
            .sheet(isPresented: $showTerms) {
                NavigationStack {
                    LegalView(title: L10n.Legal.termsTitle, body: L10n.Legal.termsBody)
                }
                .macSheetSize()
            }
            .sheet(isPresented: $showPrivacy) {
                NavigationStack {
                    LegalView(title: L10n.Legal.privacyTitle, body: L10n.Legal.privacyBody)
                }
                .macSheetSize()
            }
        }
    }

    // MARK: - Theming helpers

    @ViewBuilder
    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(theme.font(size: 12, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
            .textCase(.uppercase)
            .tracking(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 8)
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func row<Trailing: View>(
        icon: String,
        title: LocalizedStringKey,
        trailing: Trailing = EmptyView(),
        showChevron: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                iconCircle(icon)
                Text(title)
                    .font(theme.font(size: 16, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                trailing
                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.textSecondary.opacity(0.6))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func routingSegment(_ mode: RoutingMode, label: LocalizedStringKey) -> some View {
        let isSelected = app.routingMode == mode
        Button {
            if !isSelected { app.setRoutingMode(mode) }
        } label: {
            Text(label)
                .font(theme.font(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? theme.background : theme.textPrimary.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(
                    Group {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(theme.accent)
                        }
                    }
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func iconCircle(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(theme.accent)
            .frame(width: 32, height: 32)
            .background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var divider: some View {
        Divider()
            .background(theme.textSecondary.opacity(0.15))
            .padding(.leading, 62)
    }

    private var routingModeHint: LocalizedStringKey {
        switch app.routingMode {
        case .smart:    return L10n.Settings.routingModeSmartHint
        case .ruDirect: return L10n.Settings.routingModeRuDirectHint
        case .fullVPN:  return L10n.Settings.routingModeFullVPNHint
        }
    }

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
