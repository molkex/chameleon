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
    // LAUNCH-07 — Auto-connect on untrusted Wi-Fi state.
    // Local mirrors of the persisted prefs so the toggles feel snappy; AppState
    // writes through to ConfigStore + NETunnelProviderManager on change.
    @State private var autoConnectOn: Bool = false
    @State private var autoConnectCellular: Bool = false
    @State private var trustedSSIDs: [String] = []
    @State private var showAddSSIDAlert = false
    @State private var pendingSSIDInput: String = ""
    /// Hidden Diagnostics unlock — 5 taps on the version row reveals
    /// DebugLogs in Release builds (it is always visible in DEBUG).
    /// Production testers can dump logs without us shipping the section
    /// to every end user.
    @State private var versionTapCount = 0
    @State private var diagnosticsUnlocked = false

    private var theme: Theme { themeManager.current }

    private var diagnosticsVisible: Bool {
        #if DEBUG
        return true
        #else
        return diagnosticsUnlocked
        #endif
    }

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

                                // Auto-recover toggle. Default ON — TrafficHealthMonitor
                                // probes the tunnel and switches the user off a dead
                                // leg when the chosen server stops responding. User can
                                // disable for fully manual control. Storage lives in the
                                // App Group UserDefaults so the picker hint and the
                                // monitor read the same source of truth.
                                Divider()
                                    .background(theme.textSecondary.opacity(0.15))
                                HStack(spacing: 14) {
                                    iconCircle("arrow.triangle.2.circlepath")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(L10n.Settings.autoRecover)
                                            .font(theme.font(size: 16, weight: .medium))
                                            .foregroundStyle(theme.textPrimary)
                                        Text(L10n.Settings.autoRecoverHint)
                                            .font(theme.font(size: 12))
                                            .foregroundStyle(theme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    Toggle("", isOn: Binding(
                                        get: { app.configStore.autoRecoverEnabled },
                                        set: { newValue in
                                            app.configStore.autoRecoverEnabled = newValue
                                            TunnelFileLogger.log("auto-recover toggled: \(newValue)", category: "ui")
                                        }
                                    ))
                                    .labelsHidden()
                                    .tint(theme.accent)
                                }
                            }
                            .padding(16)
                        }

                        // LAUNCH-07 — Auto-connect on untrusted Wi-Fi via
                        // NEOnDemandRule. Strings are intentionally plain
                        // English for the first ship; localization arrives in
                        // a follow-up pass.
                        sectionHeader("Auto-connect")
                        card {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(spacing: 14) {
                                    iconCircle("wifi.exclamationmark")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Connect on untrusted Wi-Fi")
                                            .font(theme.font(size: 16, weight: .medium))
                                            .foregroundStyle(theme.textPrimary)
                                        Text("VPN turns on automatically whenever you join a Wi-Fi network that isn't in your Trusted list below.")
                                            .font(theme.font(size: 12))
                                            .foregroundStyle(theme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    Toggle("", isOn: Binding(
                                        get: { autoConnectOn },
                                        set: { newValue in
                                            autoConnectOn = newValue
                                            Task { await app.setAutoConnectOnUntrustedWiFi(newValue) }
                                        }
                                    ))
                                    .labelsHidden()
                                    .tint(theme.accent)
                                }

                                Divider().background(theme.textSecondary.opacity(0.15))

                                HStack(spacing: 14) {
                                    iconCircle("antenna.radiowaves.left.and.right")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Also connect on cellular")
                                            .font(theme.font(size: 16, weight: .medium))
                                            .foregroundStyle(theme.textPrimary)
                                        Text("Off by default. Turn on if you're in a censored region and want the VPN up on LTE/5G too.")
                                            .font(theme.font(size: 12))
                                            .foregroundStyle(theme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    Toggle("", isOn: Binding(
                                        get: { autoConnectCellular },
                                        set: { newValue in
                                            autoConnectCellular = newValue
                                            Task { await app.setAutoConnectOnCellular(newValue) }
                                        }
                                    ))
                                    .labelsHidden()
                                    .tint(theme.accent)
                                    .disabled(!autoConnectOn)
                                    .opacity(autoConnectOn ? 1 : 0.5)
                                }

                                Divider().background(theme.textSecondary.opacity(0.15))

                                HStack(spacing: 14) {
                                    iconCircle("checkmark.shield")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Trusted networks")
                                            .font(theme.font(size: 16, weight: .medium))
                                            .foregroundStyle(theme.textPrimary)
                                        Text("Add the names of Wi-Fi networks you trust (home, office). The VPN won't auto-connect on these.")
                                            .font(theme.font(size: 12))
                                            .foregroundStyle(theme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    Button {
                                        pendingSSIDInput = ""
                                        showAddSSIDAlert = true
                                    } label: {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 24))
                                            .foregroundStyle(theme.accent)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!autoConnectOn)
                                    .opacity(autoConnectOn ? 1 : 0.5)
                                }

                                if trustedSSIDs.isEmpty {
                                    Text("No trusted networks yet.")
                                        .font(theme.font(size: 13))
                                        .foregroundStyle(theme.textSecondary)
                                        .padding(.leading, 46)
                                } else {
                                    VStack(spacing: 6) {
                                        ForEach(trustedSSIDs, id: \.self) { ssid in
                                            trustedSSIDRow(ssid)
                                        }
                                    }
                                    .padding(.leading, 46)
                                }

                                // Comment for code readers (NOT shown to users):
                                // Apple has restricted live SSID introspection
                                // since iOS 13 — requires CoreLocation auth +
                                // active location use, and returns
                                // _undefined on the simulator. We deliberately
                                // do NOT request CoreLocation; the user enters
                                // network names manually. The On-Demand
                                // engine inside NetworkExtension still gets
                                // to compare the live SSID against the list
                                // we install on the profile.
                                if app.autoConnectErrorMessage != nil {
                                    Text(app.autoConnectErrorMessage ?? "")
                                        .font(theme.font(size: 12))
                                        .foregroundStyle(.red)
                                        .padding(.leading, 46)
                                }
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
                                Link(destination: URL(string: "mailto:support@madfrog.online")!) {
                                    HStack(spacing: 14) {
                                        iconCircle("envelope")
                                        Text(L10n.Settings.contactSupport)
                                            .font(theme.font(size: 16, weight: .medium))
                                            .foregroundStyle(theme.textPrimary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(theme.textSecondary.opacity(0.5))
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
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
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    // Hidden Diagnostics unlock — 5 taps on version
                                    // reveals DebugLogs section in Release builds.
                                    versionTapCount += 1
                                    if versionTapCount >= 5 {
                                        diagnosticsUnlocked = true
                                        Haptics.notify(.success)
                                    }
                                }
                            }
                        }

                        // Diagnostics — always visible in DEBUG, hidden behind
                        // 5-tap unlock in Release. Even when shown, the view
                        // contains server IPs + the user's UUID — fine for
                        // testers, not for the general App Store audience.
                        if diagnosticsVisible {
                        sectionHeader(L10n.Settings.sectionDiagnostics)
                        card {
                            row(icon: "ladybug", title: L10n.Settings.debugLogs,
                                showChevron: true) {
                                TunnelFileLogger.log("TAP: debug logs (from settings)", category: "ui")
                                // File I/O off the main thread; ROADMAP iOS-15.
                                Task {
                                    let tunnel = await Task.detached { TunnelFileLogger.readLog().components(separatedBy: "\n") }.value
                                    let stderr = await Task.detached { TunnelFileLogger.readStderrLog().components(separatedBy: "\n") }.value
                                    await MainActor.run {
                                        preloadedTunnelLines = tunnel
                                        preloadedStderrLines = stderr
                                        showDebugLogs = true
                                    }
                                }
                            }
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
            .alert("Add trusted network", isPresented: $showAddSSIDAlert) {
                TextField("Wi-Fi name (SSID)", text: $pendingSSIDInput)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)   // iOS-only modifier
                    #endif
                    .autocorrectionDisabled(true)
                Button("Cancel", role: .cancel) {
                    pendingSSIDInput = ""
                }
                Button("Add") {
                    let ssid = pendingSSIDInput
                    pendingSSIDInput = ""
                    Task {
                        trustedSSIDs = await app.addTrustedSSID(ssid)
                    }
                }
            } message: {
                Text("Type the network name exactly as it appears in iOS Settings → Wi-Fi.")
            }
            .task {
                // Hydrate local state from the persisted prefs whenever the
                // sheet appears. Keeps the toggles correct after the user
                // opens Settings a second time within the same app session.
                autoConnectOn = app.configStore.autoConnectOnUntrustedWiFi
                autoConnectCellular = app.configStore.autoConnectOnCellular
                trustedSSIDs = app.configStore.trustedWiFiSSIDs
            }
        }
    }

    // MARK: - Theming helpers

    // Extracted from the trusted-SSID ForEach: the inline row tipped the Swift
    // type-checker over its budget on macOS ("unable to type-check in
    // reasonable time"). Behaviour-identical on both platforms.
    @ViewBuilder
    private func trustedSSIDRow(_ ssid: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
            Text(ssid)
                .font(theme.font(size: 15))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer()
            Button {
                Task {
                    trustedSSIDs = await app.removeTrustedSSID(ssid)
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(theme.textSecondary.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.background.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

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
