#if os(macOS)
import SwiftUI
import AppKit

/// Menu bar popover content. Shown when user clicks the tray icon.
/// Exposes the most important VPN actions without opening the main window:
/// connection status, Connect/Disconnect, current server, and Show Window.
struct MenuBarContent: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()

            VStack(spacing: 6) {
                connectButton
                if let server = selectedServerName {
                    Label(server, systemImage: "globe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)

            Divider()

            footer
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .frame(width: 260)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(statusTint)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("MadFrog")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var connectButton: some View {
        Button {
            Task { @MainActor in await app.toggleVPN() }
        } label: {
            HStack {
                Image(systemName: VPNStateHelper.isConnected(app) ? "power.circle.fill" : "power.circle")
                Text(VPNStateHelper.isConnected(app) ? "Отключить" : "Подключить")
                    .fontWeight(.medium)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.12))
        )
        .disabled(app.isLoading)
    }

    private var footer: some View {
        VStack(spacing: 2) {
            Button {
                openMainWindow()
            } label: {
                Label("Открыть окно", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("Выход", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Derived state

    private var statusIcon: String {
        if VPNStateHelper.isConnected(app) { return "checkmark.shield.fill" }
        if app.isLoading { return "hourglass" }
        return "shield.slash"
    }

    private var statusTint: Color {
        if VPNStateHelper.isConnected(app) { return .green }
        if app.isLoading { return .orange }
        return .secondary
    }

    private var statusText: String {
        if VPNStateHelper.isConnected(app) { return "Защищено" }
        if app.isLoading { return "Подключение…" }
        return "Не подключено"
    }

    private var selectedServerName: String? {
        guard let tag = app.configStore.selectedServerTag, !tag.isEmpty, tag != "auto" else {
            return "Авто (быстрейший)"
        }
        for group in app.servers {
            if let item = group.items.first(where: { $0.tag == tag }) {
                return "\(item.flagEmoji) \(item.tag)"
            }
        }
        return tag
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // No window exists — tell SwiftUI to reopen the WindowGroup.
        if let url = URL(string: "madfrog://main") {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
