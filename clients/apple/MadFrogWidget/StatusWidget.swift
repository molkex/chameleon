import AppIntents
import WidgetKit
import SwiftUI

/// launch-04: VPN status widget.
///
/// Supported families:
///   - systemSmall      — Home Screen tile: shield + status + server.
///     launch-04b: the shield is an interactive `Button(intent:)` —
///     tapping it toggles the VPN in place; tapping elsewhere on the
///     tile still opens the app (the default widget tap).
///   - accessoryCircular — Lock Screen: filled/outline shield
///   - accessoryRectangular — Lock Screen: shield + status + server
///   - accessoryInline  — Lock Screen inline: "MadFrog: Protected"
///
/// The timeline carries a single entry — the snapshot is a point-in-time
/// read of the App Group. The app calls WidgetCenter.reloadAllTimelines()
/// on every VPN status change so the widget refreshes promptly; the
/// 30-minute refresh policy below is just a self-healing safety net in
/// case a reload is ever missed.

// MARK: - Timeline

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetVPNSnapshot
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), snapshot: WidgetVPNSnapshot(connected: false, serverName: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: Date(), snapshot: WidgetVPNSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let entry = StatusEntry(date: Date(), snapshot: WidgetVPNSnapshot.read())
        // App-driven reloads are the primary refresh path; this is the
        // safety net if one is ever missed.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Widget

struct StatusWidget: Widget {
    let kind = "MadFrogStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StatusProvider()) { entry in
            StatusWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("MadFrog VPN")
        .description(
            Locale.current.language.languageCode?.identifier == "ru"
                ? "Статус подключения VPN"
                : "VPN connection status"
        )
        .supportedFamilies([
            .systemSmall,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

// MARK: - Views

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetVPNSnapshot

    var body: some View {
        switch family {
        case .systemSmall:        smallView
        case .accessoryCircular:  circularView
        case .accessoryRectangular: rectangularView
        case .accessoryInline:    inlineView
        default:                  smallView
        }
    }

    // Green when protected, secondary/grey when not — the one glanceable bit.
    private var tint: Color { snapshot.connected ? .green : .secondary }
    private var shieldSymbol: String {
        snapshot.connected ? "checkmark.shield.fill" : "shield.slash"
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 4) {
            // launch-04b: the shield is an interactive toggle. The
            // intent runs in the widget extension and drives the VPN
            // directly — no app launch. value: !connected = "flip it".
            // The filled circular background is the tap affordance —
            // a bare SF Symbol doesn't read as a button (build-70
            // field feedback).
            Button(intent: ToggleVPNIntent(value: !snapshot.connected)) {
                Image(systemName: shieldSymbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(snapshot.connected ? Color.white : Color.secondary)
                    .frame(width: 54, height: 54)
                    .background(
                        snapshot.connected ? AnyShapeStyle(tint)
                                           : AnyShapeStyle(.fill.secondary),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Text(snapshot.statusText)
                .font(.headline)
                .foregroundStyle(.primary)
            // launch-04b: live uptime — ticks on its own, no timeline
            // reload needed (build-70 field feedback: "время нет").
            if let connectedAt = snapshot.connectedAt {
                Text(connectedAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tint)
            }
            Text(snapshot.serverDisplay)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: shieldSymbol)
                .font(.system(size: 22, weight: .semibold))
        }
    }

    private var rectangularView: some View {
        HStack(spacing: 8) {
            Image(systemName: shieldSymbol)
                .font(.system(size: 20, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.statusText)
                    .font(.headline)
                if let connectedAt = snapshot.connectedAt {
                    Text(connectedAt, style: .timer)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(snapshot.serverDisplay)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var inlineView: some View {
        // accessoryInline is one line, system-tinted — keep it terse.
        Label("MadFrog: \(snapshot.statusText)", systemImage: shieldSymbol)
    }
}
