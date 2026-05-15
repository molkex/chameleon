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
    }

    private var subscriptionLabel: String {
        guard let expire = app.subscriptionExpire else {
            return String(localized: "account.subscription.free")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let dateString = formatter.string(from: expire)
        // App Review build 74 rejected "Pro" wording on the backend trial
        // — see incident 2026-05-15-app-review-iap-not-found.
        return app.isTrial
            ? L10n.Account.subscriptionTrialUntil(dateString)
            : L10n.Account.subscriptionProUntil(dateString)
    }
}
