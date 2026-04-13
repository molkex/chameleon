import SwiftUI

/// Top-level settings entry point reached from the main screen gear icon.
/// Intentionally lean: Appearance, Account, Legal, Diagnostics, About.
/// Debug logs live under Diagnostics so the prod header stays clean.
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    @State private var showThemePicker = false
    @State private var showDebugLogs = false
    @State private var preloadedTunnelLines: [String] = []
    @State private var preloadedStderrLines: [String] = []

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.Settings.sectionAppearance) {
                    Button {
                        showThemePicker = true
                    } label: {
                        HStack {
                            Label {
                                Text(L10n.Settings.theme)
                            } icon: {
                                Image(systemName: "paintpalette.fill")
                            }
                            Spacer()
                            Text(themeManager.current.displayName)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                }

                Section(L10n.Settings.sectionAccount) {
                    NavigationLink {
                        AccountView()
                    } label: {
                        Label {
                            Text(L10n.Account.title)
                        } icon: {
                            Image(systemName: "person.crop.circle")
                        }
                    }
                }

                Section(L10n.Settings.sectionAbout) {
                    NavigationLink {
                        LegalView(title: L10n.Legal.termsTitle, body: L10n.Legal.termsBody)
                    } label: {
                        Label {
                            Text(L10n.Paywall.terms)
                        } icon: {
                            Image(systemName: "doc.text")
                        }
                    }
                    NavigationLink {
                        LegalView(title: L10n.Legal.privacyTitle, body: L10n.Legal.privacyBody)
                    } label: {
                        Label {
                            Text(L10n.Paywall.privacy)
                        } icon: {
                            Image(systemName: "hand.raised")
                        }
                    }
                    HStack {
                        Label {
                            Text(L10n.Settings.version)
                        } icon: {
                            Image(systemName: "info.circle")
                        }
                        Spacer()
                        Text(versionString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Section(L10n.Settings.sectionDiagnostics) {
                    Button {
                        TunnelFileLogger.log("TAP: debug logs (from settings)", category: "ui")
                        preloadedTunnelLines = TunnelFileLogger.readLog().components(separatedBy: "\n")
                        preloadedStderrLines = TunnelFileLogger.readStderrLog().components(separatedBy: "\n")
                        showDebugLogs = true
                    } label: {
                        Label {
                            Text(L10n.Settings.debugLogs)
                        } icon: {
                            Image(systemName: "ladybug")
                        }
                    }
                    .tint(.primary)
                }
            }
            .navigationTitle(Text(L10n.Settings.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Servers.done) { dismiss() }
                }
            }
            .sheet(isPresented: $showThemePicker) {
                ThemePickerView(isModal: true).environment(themeManager)
            }
            .sheet(isPresented: $showDebugLogs) {
                DebugLogsView(
                    preloadedTunnelLines: preloadedTunnelLines,
                    preloadedStderrLines: preloadedStderrLines
                )
                .environment(app)
            }
        }
    }

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
