import SwiftUI

struct OnboardingView: View {
    @State private var page = 0
    @State private var isAppearing = false
    @State private var iconBounce = false
    @State private var dotPulse = false
    var onComplete: () -> Void

    private let pages: [(icon: String, title: String, subtitle: String, color: Color)] = [
        (
            "shield.checkered",
            "Безопасный интернет",
            "Защитите свои данные и\nполучите доступ ко всем сайтам",
            Color(red: 0.2, green: 0.84, blue: 0.42)
        ),
        (
            "bolt.fill",
            "Быстрые серверы",
            "Автовыбор лучшего сервера по пингу.\nНидерланды, Германия и другие",
            .cyan
        ),
        (
            "hand.tap.fill",
            "Одно нажатие",
            "Просто нажмите кнопку.\nВсё остальное сделаем мы",
            .orange
        )
    ]

    private var isLastPage: Bool { page == pages.count - 1 }

    var body: some View {
        ZStack {
            // Background — subtle dark gradient instead of plain black
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.07, blue: 0.10),
                    Color(red: 0.03, green: 0.03, blue: 0.05),
                    Color(red: 0.05, green: 0.06, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Page-colored ambient glow
            RadialGradient(
                colors: [pages[page].color.opacity(0.20), .clear],
                center: .init(x: 0.5, y: 0.35),
                startRadius: 20,
                endRadius: 400
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: page)

            VStack(spacing: 0) {
                // Swipeable content
                TabView(selection: $page) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        pageContent(index: index)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Custom page indicator
                customPageIndicator
                    .padding(.bottom, 30)

                // Navigation buttons
                bottomButtons
                    .padding(.horizontal, 40)
                    .padding(.bottom, 50)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.65).delay(0.2)) {
                isAppearing = true
            }
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true).delay(0.5)) {
                iconBounce = true
            }
        }
    }

    // MARK: - Page Content

    private func pageContent(index: Int) -> some View {
        let item = pages[index]

        return VStack(spacing: 28) {
            Spacer()

            // Animated icon
            ZStack {
                // Outer glow
                Circle()
                    .fill(item.color.opacity(0.12))
                    .frame(width: 200, height: 200)
                    .scaleEffect(iconBounce ? 1.05 : 0.95)

                // Middle ring
                Circle()
                    .fill(item.color.opacity(0.18))
                    .frame(width: 170, height: 170)

                // Inner background
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [item.color.opacity(0.35), item.color.opacity(0.15)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 80
                        )
                    )
                    .frame(width: 160, height: 160)

                // Icon
                Image(systemName: item.icon)
                    .font(.system(size: 68, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [item.color, item.color.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: item.color.opacity(0.3), radius: 8)
                    .symbolEffect(.pulse, options: .repeating.speed(0.5), isActive: page == index)
            }
            .scaleEffect(isAppearing ? 1.0 : 0.6)
            .opacity(isAppearing ? 1.0 : 0)

            // Text content
            VStack(spacing: 14) {
                Text(LocalizedStringKey(item.title))
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                Text(LocalizedStringKey(item.subtitle))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 20)
            }
            .opacity(isAppearing ? 1.0 : 0)
            .offset(y: isAppearing ? 0 : 20)

            Spacer()
            Spacer()
        }
    }

    // MARK: - Custom Page Indicator

    private var customPageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<pages.count, id: \.self) { index in
                Capsule()
                    .fill(index == page ? pages[page].color : Color(.systemGray4))
                    .frame(width: index == page ? 24 : 8, height: 8)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: page)
            }
        }
    }

    // MARK: - Bottom Buttons

    private var bottomButtons: some View {
        VStack(spacing: 12) {
            // Primary button — always in the same position
            Button {
                let impact = UIImpactFeedbackGenerator(style: isLastPage ? .medium : .light)
                impact.impactOccurred()
                if isLastPage {
                    onComplete()
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        page += 1
                    }
                }
            } label: {
                Text(isLastPage ? "Начать" : "Далее")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(
                        isLastPage
                        ? AnyShapeStyle(LinearGradient(
                            colors: [
                                Color(red: 0.2, green: 0.84, blue: 0.42),
                                Color(red: 0.15, green: 0.72, blue: 0.38)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        : AnyShapeStyle(Color(.systemGray2)),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .shadow(
                        color: isLastPage ? Color(red: 0.2, green: 0.84, blue: 0.42).opacity(0.35) : .clear,
                        radius: 12, y: 4
                    )
            }

            // Skip button — always present to maintain layout, invisible on last page
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    page = pages.count - 1
                }
            } label: {
                Text("Пропустить")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .opacity(isLastPage ? 0 : 1)
            .disabled(isLastPage)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: page)
    }
}
