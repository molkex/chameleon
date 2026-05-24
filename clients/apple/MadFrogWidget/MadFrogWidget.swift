import SwiftUI
import WidgetKit

@main
struct MadFrogWidgetBundle: WidgetBundle {
    var body: some Widget {
        MadFrogStatusWidget()
    }
}

// MARK: - Shared state

/// Mirror of the values we read from the App Group UserDefaults. Keys MUST
/// stay in sync with `WidgetStatusBridge` in the main app.
private enum SharedKey {
    static let suite = "group.com.madfrog.vpn"
    static let status = "widget.vpn.status"            // "connected" | "connecting" | "disconnected"
    static let serverName = "widget.vpn.serverName"    // user-facing label, optional
    static let updatedAt = "widget.vpn.updatedAt"      // ISO8601 string, optional
}

private enum VPNDisplayStatus: String {
    case connected, connecting, disconnected

    var emoji: String {
        switch self {
        case .connected:   return "🟢"
        case .connecting:  return "🟡"
        case .disconnected: return "⚪️"
        }
    }

    var label: String {
        switch self {
        case .connected:   return "Подключено"
        case .connecting:  return "Подключение…"
        case .disconnected: return "Отключено"
        }
    }
}

private struct VPNSnapshot {
    let status: VPNDisplayStatus
    let serverName: String?

    static let placeholder = VPNSnapshot(status: .disconnected, serverName: nil)

    static func read() -> VPNSnapshot {
        guard let defaults = UserDefaults(suiteName: SharedKey.suite) else {
            return .placeholder
        }
        let raw = defaults.string(forKey: SharedKey.status) ?? "disconnected"
        let status = VPNDisplayStatus(rawValue: raw) ?? .disconnected
        let server = defaults.string(forKey: SharedKey.serverName)
        return VPNSnapshot(status: status, serverName: server)
    }
}

// MARK: - Timeline

private struct VPNEntry: TimelineEntry {
    let date: Date
    let snapshot: VPNSnapshot
}

private struct VPNStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> VPNEntry {
        VPNEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (VPNEntry) -> Void) {
        completion(VPNEntry(date: Date(), snapshot: VPNSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VPNEntry>) -> Void) {
        // Widget refresh strategy: main app calls WidgetCenter.reloadAllTimelines()
        // on every VPN status change, so the live data is always fresh-ish. We
        // also schedule a passive refresh every 15 minutes as a safety net in
        // case the main app is suspended and never gets to push.
        let now = Date()
        let entry = VPNEntry(date: now, snapshot: VPNSnapshot.read())
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - View

private struct MadFrogWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VPNEntry

    var body: some View {
        switch family {
        case .systemSmall:           SmallView(entry: entry)
        case .systemMedium:          MediumView(entry: entry)
        case .accessoryRectangular:  AccessoryRectangularView(entry: entry)
        case .accessoryCircular:     AccessoryCircularView(entry: entry)
        case .accessoryInline:       AccessoryInlineView(entry: entry)
        default:                     SmallView(entry: entry)
        }
    }
}

private struct SmallView: View {
    let entry: VPNEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MADFROG")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(entry.snapshot.status.emoji)
                    .font(.system(size: 18))
                Text(entry.snapshot.status.label)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if let server = entry.snapshot.serverName, !server.isEmpty {
                Text(server)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) {
            Color(red: 0.05, green: 0.07, blue: 0.06)
        }
    }
}

private struct MediumView: View {
    let entry: VPNEntry
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Left: brand + status dot
            VStack(alignment: .leading, spacing: 8) {
                Text("MADFROG")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(entry.snapshot.status.emoji)
                        .font(.system(size: 22))
                    Text(entry.snapshot.status.label)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            Spacer(minLength: 8)
            // Right: server label, if any
            if let server = entry.snapshot.serverName, !server.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Сервер")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(server)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) {
            Color(red: 0.05, green: 0.07, blue: 0.06)
        }
    }
}

private struct AccessoryRectangularView: View {
    let entry: VPNEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(entry.snapshot.status.emoji)
                Text("MadFrog")
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(entry.snapshot.status.label)
                .font(.system(size: 12, weight: .medium))
            if let server = entry.snapshot.serverName, !server.isEmpty {
                Text(server)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color.clear }
    }
}

private struct AccessoryCircularView: View {
    let entry: VPNEntry
    var body: some View {
        ZStack {
            Circle().stroke(lineWidth: 2).opacity(0.4)
            VStack(spacing: 0) {
                Text("🐸").font(.system(size: 18))
                Text(entry.snapshot.status == .connected ? "ON" : "OFF")
                    .font(.system(size: 9, weight: .heavy))
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

private struct AccessoryInlineView: View {
    let entry: VPNEntry
    var body: some View {
        let head = "MadFrog \(entry.snapshot.status.emoji) \(entry.snapshot.status.label)"
        let server = entry.snapshot.serverName?.isEmpty == false ? " · \(entry.snapshot.serverName!)" : ""
        return Text(head + server)
    }
}

// MARK: - Widget

struct MadFrogStatusWidget: Widget {
    let kind: String = "MadFrogStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VPNStatusProvider()) { entry in
            MadFrogWidgetView(entry: entry)
        }
        .configurationDisplayName("MadFrog VPN")
        .description("Статус VPN-подключения. Тапни — откроется приложение.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline,
        ])
    }
}
