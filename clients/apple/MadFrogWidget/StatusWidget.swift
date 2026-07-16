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
        let now = Date()
        let snapshot = WidgetVPNSnapshot.read()
        let entry = StatusEntry(date: now, snapshot: snapshot)

        // WIDGET-CONNECTING-TIMELINE-FIX (2026-07-16): a single entry, always.
        // Previously this baked a SECOND entry hardcoded to `connected: false`
        // at the connecting flag's 30s expiry — a bake-time guess that stuck
        // unless a reloadAllTimelines() call happened to land first, which
        // iOS's own reload-budget throttling doesn't guarantee (see
        // WidgetVPNSnapshot.nextTimelineRefresh doc comment for the device-log
        // evidence). Now the policy date is the only thing scheduled ahead:
        // when it passes, WidgetKit calls getTimeline again and read() reports
        // whatever is ACTUALLY true by then — self-correcting, not guessing.
        // App-driven reloads (reloadAllTimelines on every status change)
        // remain the primary refresh path; this is the safety net.
        completion(Timeline(entries: [entry], policy: .after(snapshot.nextTimelineRefresh(now: now))))
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

    // Green when protected, amber while connecting, secondary/grey when
    // off — WIDGET-CONNECTING (2026-07-16) adds the middle state so a tap
    // gets an honest acknowledgement instead of dead air.
    private var tint: Color {
        if snapshot.connected { return .green }
        if snapshot.connecting { return .orange }
        return .secondary
    }
    private var shieldSymbol: String {
        if snapshot.connected { return "checkmark.shield.fill" }
        if snapshot.connecting { return "shield.lefthalf.filled" }
        return "shield.slash"
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
                    .foregroundStyle(snapshot.connected || snapshot.connecting ? Color.white : Color.secondary)
                    .frame(width: 54, height: 54)
                    .background(
                        snapshot.connected || snapshot.connecting ? AnyShapeStyle(tint)
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
