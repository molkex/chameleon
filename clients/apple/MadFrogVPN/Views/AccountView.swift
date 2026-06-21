import SwiftUI

/// Account detail screen: shows the signed-in username, current subscription
/// state, and the App Store–required destructive actions (log out, delete
/// account). Delete runs through AppState.deleteAccount, which calls the
/// backend and then performs a local wipe.
struct AccountView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirm = false
    @State private var showLogoutConfirm = false
    @State private var restoring = false
    @State private var showRestoreResult = false
    @State private var restoredActive = false

    var body: some View {
        List {
            Section {
                HStack {
                    Text(L10n.Account.username)
                    Spacer()
                    Text(app.configStore.username ?? "—")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Text(L10n.Account.subscription)
                    Spacer()
                    Text(subscriptionLabel)
                        .foregroundStyle(.secondary)
                }
            }

            // B8: restore must be reachable outside the paywall — a reinstalled
            // payer who never opens the paywall otherwise can't recover access.
            Section {
                Button {
                    guard !restoring else { return }
                    restoreSubscription()
                } label: {
                    Label {
                        Text(L10n.Account.restore)
                    } icon: {
                        if restoring {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                .tint(.primary)
                .disabled(restoring)
            }

            Section {
                Button(role: .none) {
                    showLogoutConfirm = true
                } label: {
                    Label {
                        Text(L10n.Settings.logout)
                    } icon: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                }
                .tint(.primary)
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label {
                        Text(L10n.Settings.deleteAccount)
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
            } footer: {
                Text(L10n.Settings.deleteBody)
            }
        }
        .navigationTitle(Text(L10n.Account.title))
        .iosInlineNavTitle()
        .alert(Text(L10n.Settings.deleteTitle), isPresented: $showDeleteConfirm) {
            Button(L10n.Settings.deleteCancel, role: .cancel) {}
            Button(L10n.Settings.deleteOk, role: .destructive) {
                Task {
                    await app.deleteAccount()
                    dismiss()
                }
            }
        } message: {
            Text(L10n.Settings.deleteBody)
        }
        .alert(Text(L10n.Settings.logoutTitle), isPresented: $showLogoutConfirm) {
            Button(L10n.Settings.deleteCancel, role: .cancel) {}
            Button(L10n.Settings.logoutOk, role: .destructive) {
                Task {
                    await app.logout()
                    dismiss()
                }
            }
        } message: {
            Text(L10n.Settings.logoutBody)
        }
        .alert(Text(restoredActive ? L10n.Account.restoreActive : L10n.Account.restoreNone),
               isPresented: $showRestoreResult) {
            Button(L10n.Paywall.ok, role: .cancel) {}
        }
    }

    private func restoreSubscription() {
        restoring = true
        Task {
            // StoreKit restore (Apple) + a config refresh (reclaims a cross-device
            // FreeKassa payment too). Mirrors the paywall restore + connect-gate reclaim.
            await app.subscriptionManager.restorePurchases()
            await app.refreshConfig()
            restoring = false
            restoredActive = app.subscriptionExpire.map { $0 > Date() } ?? false
            showRestoreResult = true
        }
    }

    private var subscriptionLabel: String {
        guard let expire = app.subscriptionExpire else {
            return String(localized: "account.subscription.free")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return L10n.Account.subscriptionProUntil(formatter.string(from: expire))
    }
}
