import SwiftUI

/// First-launch screen: shows the two themes side-by-side as large preview
/// cards, user taps the one they like. Tap commits via `ThemeManager.select`,
/// which flips `hasSelected` and lets the app proceed to onboarding.
///
/// Also reachable from Settings → Оформление for later swaps.
struct ThemePickerView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    /// When `true`, the view is presented modally (from Settings) and should
    /// dismiss on selection. On first launch this is `false` — the parent
    /// switches on `themeManager.hasSelected` instead.
    let isModal: Bool

    init(isModal: Bool = false) {
        self.isModal = isModal
    }

    var body: some View {
        ZStack {
            // Neutral dark backdrop so neither theme dominates before choice
            Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer(minLength: 24)

                VStack(spacing: 10) {
                    Text(L10n.Theme.title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(L10n.Theme.subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        ForEach(Theme.all, id: \.id) { theme in
                            ThemeCard(
                                theme: theme,
                                isCurrent: themeManager.current.id == theme.id
                            )
                            .onTapGesture {
                                withAnimation(.spring(response: 0.35)) {
                                    themeManager.select(theme)
                                }
                                if isModal {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                        dismiss()
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }

                if isModal {
                    Button(L10n.Theme.done) { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.white.opacity(0.12), in: Capsule())
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }
            }
        }
    }
}

/// Large preview card showing the theme's background, accent, typography,
/// and a mock VPN connect button so the vibe is immediately legible.
private struct ThemeCard: View {
    let theme: Theme
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                theme.background

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(theme.displayName)
                            .font(theme.displayFont(size: 22, weight: .black))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        if isCurrent {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(theme.accent)
                        }
                    }

                    // Mock "Connect" card
                    HStack(spacing: 14) {
                        Circle()
                            .fill(theme.accent)
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: "power")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(theme.background)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connected")
                                .font(theme.font(size: 14, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                            Text("DE-1 · 24ms")
                                .font(theme.font(size: 12))
                                .foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cardCornerRadius)
                            .fill(theme.surface)
                    )

                    // Mock stat chips
                    HStack(spacing: 10) {
                        StatChip(value: "100", label: "ms", theme: theme)
                        StatChip(value: "85%", label: "up", theme: theme, filled: true)
                    }
                }
                .padding(20)
            }
            .frame(height: 260)

            HStack {
                Text(theme.tagline)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.black.opacity(0.35))
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(isCurrent ? theme.accent : Color.white.opacity(0.08), lineWidth: isCurrent ? 3 : 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
    }
}

private struct StatChip: View {
    let value: String
    let label: String
    let theme: Theme
    var filled: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Text(value)
                .font(theme.displayFont(size: 18, weight: .bold))
                .foregroundStyle(filled ? theme.background : theme.textPrimary)
            Text(label)
                .font(theme.font(size: 11))
                .foregroundStyle(filled ? theme.background.opacity(0.7) : theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(filled ? theme.accent : theme.surface)
        )
    }
}
