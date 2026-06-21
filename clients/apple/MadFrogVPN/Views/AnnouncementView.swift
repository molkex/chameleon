import SwiftUI

/// INAPP-ANNOUNCEMENTS — the centered card shown over the home when there's an
/// active, not-yet-dismissed announcement. Theme-aware (neon/calm). Dismiss via
/// the ✕, the primary button, or a tap on the dimmed backdrop; dismissal is
/// remembered so it never reappears.
struct AnnouncementView: View {
    @Environment(AppState.self) private var app
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.openURL) private var openURL

    let announcement: Announcement

    private var theme: Theme { themeManager.current }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { app.dismissActiveAnnouncement() }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    badge
                    Spacer(minLength: 8)
                    Button { app.dismissActiveAnnouncement() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(theme.surfaceElevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                Text(announcement.title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(announcement.body)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                primaryButton
                    .padding(.top, 4)
            }
            .padding(20)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(theme.accent.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    @ViewBuilder
    private var primaryButton: some View {
        if let url = announcement.ctaURL {
            // ctaLabel is admin-authored (dynamic) → keep verbatim; the fallback is localized.
            actionButton(announcement.ctaLabel ?? String(localized: "announcement.cta.default")) {
                openURL(url)
                app.dismissActiveAnnouncement()
            }
        } else {
            actionButton(String(localized: "announcement.dismiss")) { app.dismissActiveAnnouncement() }
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(theme.background)
        }
        .buttonStyle(.plain)
    }

    private var badge: some View {
        let style = badgeStyle
        return Text(style.0)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(style.1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(style.1.opacity(0.16), in: Capsule())
    }

    private var badgeStyle: (String, Color) {
        switch announcement.kind {
        case "promo": return (String(localized: "announcement.badge.promo"), theme.accentSecondary)
        case "update": return (String(localized: "announcement.badge.update"), theme.accent)
        default: return (String(localized: "announcement.badge.important"), theme.accent)
        }
    }
}
