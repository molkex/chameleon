import SwiftUI

/// Account detail screen: shows the signed-in username, current subscription
/// state, and the App Store–required destructive actions (log out, delete
/// account). Delete runs through AppState.deleteAccount, which calls the
/// backend and then performs a local wipe.
struct AccountView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirm = false

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
                    Task {
                        await app.logout()
                        dismiss()
                    }
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
