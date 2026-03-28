import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showLogout = false
    @State private var isUpdatingConfig = false
    @State private var configUpdateResult: ConfigUpdateResult? = nil
    @State private var showPaywall = false
    @State private var showCodeEntry = false
    @State private var subscriptionCode = ""
    @State private var isActivatingCode = false
    @State private var codeError: String? = nil
    @FocusState private var codeFocused: Bool
    @State private var isTestingMinimal = false
    @State private var minimalTestResult: ConfigUpdateResult? = nil
    @State private var isResettingVPN = false
    @State private var resetVPNResult: ConfigUpdateResult? = nil
    private enum ConfigUpdateResult: Equatable {
        case success
        case failure(String)
    }

    private var accentGreen: Color { Color(red: 0.2, green: 0.84, blue: 0.42) }

    var body: some View {
        List {
            Section {
            } header: {
                Text("Настройки")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .textCase(nil)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
            subscriptionSection
            accountSection
            diagnosticsSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environment(appState)
        }
        .sheet(isPresented: $showCodeEntry, onDismiss: {
            subscriptionCode = ""
            codeError = nil
            codeFocused = false
        }) {
            NavigationStack {
                VStack(spacing: 28) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(accentGreen)
                        .padding(.top, 36)

                    VStack(spacing: 8) {
                        Text("Код подписки")
                            .font(.title2.bold())
                        Text("Введите код для активации подписки")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)

                    VStack(spacing: 12) {
                        HStack(spacing: 0) {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.secondary).font(.subheadline).frame(width: 40)
                            TextField("Код доступа", text: $subscriptionCode)
                                .font(.body.monospaced())
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .keyboardType(.asciiCapable)
                                .focused($codeFocused)
                                .onSubmit { applySubscriptionCode() }
                                .onChange(of: subscriptionCode) { codeError = nil }
                        }
                        .padding(.vertical, 12).padding(.trailing, 12)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                codeError != nil ? Color.red.opacity(0.5) : (codeFocused ? accentGreen.opacity(0.4) : .clear),
                                lineWidth: 1.5
                            ))

                        if let error = codeError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.caption)
                                Text(error)
                                    .font(.caption)
                                    .multilineTextAlignment(.leading)
                            }
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                        }

                        Button {
                            applySubscriptionCode()
                        } label: {
                            Group {
                                if isActivatingCode {
                                    ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 50)
                                } else {
                                    Text("Активировать").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                                }
                            }
                            .foregroundStyle(.white)
                            .background(
                                subscriptionCode.isEmpty
                                    ? AnyShapeStyle(Color(.systemGray3))
                                    : AnyShapeStyle(LinearGradient(
                                        colors: [accentGreen, Color(red: 0.12, green: 0.70, blue: 0.36)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing)),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                        }
                        .disabled(subscriptionCode.isEmpty || isActivatingCode)
                    }
                    .padding(.horizontal, 32)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: codeError)

                    Spacer()
                }
                .navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Отмена") {
                            showCodeEntry = false
                        }
                        .foregroundStyle(.secondary)
                        .disabled(isActivatingCode)
                    }
                }
                .task {
                    try? await Task.sleep(for: .milliseconds(300))
                    codeFocused = true
                }
            }
        }
        .alert("Выйти из аккаунта?", isPresented: $showLogout) {
            Button("Отмена", role: .cancel) { }
            Button("Выйти", role: .destructive) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                    appState.logout()
                }
            }
        } message: {
            Text("VPN будет отключён, конфигурация удалена")
        }
        .alert(
            configUpdateResult == .success ? "Готово" : "Ошибка",
            isPresented: Binding(
                get: { configUpdateResult != nil },
                set: { if !$0 { configUpdateResult = nil } }
            )
        ) {
            Button("OK") { configUpdateResult = nil }
        } message: {
            switch configUpdateResult {
            case .success:
                Text("Конфигурация успешно обновлена")
            case .failure(let msg):
                Text(msg)
            case nil:
                EmptyView()
            }
        }
        .alert(
            minimalTestResult == .success ? "Готово" : "Ошибка",
            isPresented: Binding(
                get: { minimalTestResult != nil },
                set: { if !$0 { minimalTestResult = nil } }
            )
        ) {
            Button("OK") { minimalTestResult = nil }
        } message: {
            switch minimalTestResult {
            case .success:
                Text("Minimal конфиг загружен. Переподключи VPN для теста.")
            case .failure(let msg):
                Text(msg)
            case nil:
                EmptyView()
            }
        }
        .alert(
            resetVPNResult == .success ? "Готово" : "Ошибка",
            isPresented: Binding(
                get: { resetVPNResult != nil },
                set: { if !$0 { resetVPNResult = nil } }
            )
        ) {
            Button("OK") { resetVPNResult = nil }
        } message: {
            switch resetVPNResult {
            case .success:
                Text("VPN профиль удалён. Переподключись — создастся новый.")
            case .failure(let msg):
                Text(msg)
            case nil:
                EmptyView()
            }
        }
    }

    // MARK: - Subscription Section

    private var subscriptionSection: some View {
        Section {
            if let user = appState.configStore.username {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(accentGreen.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "person.fill")
                            .font(.body.weight(.medium))
                            .foregroundStyle(accentGreen)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Аккаунт")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(user)
                            .font(.subheadline.weight(.medium).monospaced())
                            .lineLimit(1)
                    }
                }
            }

            // StoreKit subscription badge (shown when active via App Store purchase)
            if appState.subscriptionManager.isPremium {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(accentGreen.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "checkmark.seal.fill")
                            .font(.body.weight(.medium))
                            .foregroundStyle(accentGreen)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Подписка")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Активна (App Store)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(accentGreen)
                    }
                }
            }

            // Telegram-bot-based subscription expiry
            if let expire = appState.configStore.subscriptionExpire {
                let isActive = expire > Date()
                let daysLeft = Calendar.current.dateComponents([.day], from: Date(), to: expire).day ?? 0
                let isExpiringSoon = isActive && daysLeft <= 3

                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(isActive ? (isExpiringSoon ? Color.orange.opacity(0.12) : accentGreen.opacity(0.12)) : Color.red.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: isActive ? (isExpiringSoon ? "calendar.badge.exclamationmark" : "calendar.badge.checkmark") : "calendar.badge.minus")
                            .font(.body.weight(.medium))
                            .foregroundStyle(isActive ? (isExpiringSoon ? Color.orange : accentGreen) : .red)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Подписка (бот)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isActive {
                            Text("до \(expire.formatted(.dateTime.day().month(.wide).year()))")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(isExpiringSoon ? Color.orange : Color.primary)
                            if isExpiringSoon {
                                Text(daysLeft == 0 ? "Истекает сегодня" : "Осталось \(daysLeft) \(StringUtils.dayNoun(daysLeft))")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            Text("Истекла \(expire.formatted(.dateTime.day().month(.wide).year()))")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.red)
                        }
                    }

                    Spacer()

                    if isActive && !isExpiringSoon {
                        Text("\(daysLeft) \(StringUtils.dayNoun(daysLeft))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accentGreen)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(accentGreen.opacity(0.1), in: Capsule())
                    }
                }
            }

            // Paywall CTA — shown when not premium via App Store
            if !appState.subscriptionManager.isPremium {
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(accentGreen.opacity(0.12))
                                .frame(width: 40, height: 40)
                            Image(systemName: "creditcard.fill")
                                .font(.body.weight(.medium))
                                .foregroundStyle(accentGreen)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Оформить подписку")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(accentGreen)
                            Text("Месяц или год — выбери свой план")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }

            // Update config button
            Button {
                guard !isUpdatingConfig else { return }
                isUpdatingConfig = true
                Task {
                    do {
                        try await appState.updateConfig()
                        configUpdateResult = .success
                    } catch {
                        configUpdateResult = .failure(error.localizedDescription)
                    }
                    isUpdatingConfig = false
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(accentGreen.opacity(0.12))
                            .frame(width: 40, height: 40)
                        if isUpdatingConfig {
                            ProgressView()
                                .tint(accentGreen)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.body.weight(.medium))
                                .foregroundStyle(accentGreen)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Обновить конфиг")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isUpdatingConfig ? .secondary : .primary)
                        if let lastUpdate = appState.configStore.lastUpdate {
                            Text("Обновлено \(lastUpdate.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .disabled(isUpdatingConfig)

            // Enter subscription code
            Button {
                showCodeEntry = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(accentGreen.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "key.fill")
                            .font(.body.weight(.medium))
                            .foregroundStyle(accentGreen)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ввести код подписки")
                            .font(.subheadline.weight(.medium))
                        Text("Активировать или сменить аккаунт")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        } header: {
            Label("Подписка", systemImage: "creditcard")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }

    private func applySubscriptionCode() {
        guard !subscriptionCode.isEmpty, !isActivatingCode else { return }
        isActivatingCode = true
        codeError = nil
        let code = subscriptionCode
        Task {
            do {
                try await appState.activate(code: code)
                isActivatingCode = false
                showCodeEntry = false
            } catch {
                isActivatingCode = false
                withAnimation {
                    codeError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Account Section

    private var accountSection: some View {
        Section {
            Button {
                showLogout = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.red)
                    }
                    Text("Выйти")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Diagnostics Section

    private var diagnosticsSection: some View {
        Section {
            Button {
                guard !isTestingMinimal else { return }
                isTestingMinimal = true
                Task {
                    do {
                        try await appState.updateConfig(mode: "minimal")
                        minimalTestResult = .success
                    } catch {
                        minimalTestResult = .failure(error.localizedDescription)
                    }
                    isTestingMinimal = false
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.12))
                            .frame(width: 40, height: 40)
                        if isTestingMinimal {
                            ProgressView()
                                .tint(.orange)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "wrench.and.screwdriver")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Minimal конфиг (тест)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isTestingMinimal ? .secondary : .primary)
                        Text("Простейший конфиг для диагностики")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(isTestingMinimal)

            // Reset VPN profile — fixes "connected but not routing" iOS bug
            Button {
                guard !isResettingVPN else { return }
                isResettingVPN = true
                Task {
                    do {
                        try await appState.resetVPNProfile()
                        resetVPNResult = .success
                    } catch {
                        resetVPNResult = .failure(error.localizedDescription)
                    }
                    isResettingVPN = false
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.1))
                            .frame(width: 40, height: 40)
                        if isResettingVPN {
                            ProgressView()
                                .tint(.red)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.counterclockwise.circle")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.red)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Сбросить VPN профиль")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isResettingVPN ? Color.secondary : Color.red)
                        Text("Если VPN подключён, но не работает")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(isResettingVPN)
        } header: {
            Label("Диагностика", systemImage: "stethoscope")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: 40, height: 40)
                    Image(systemName: "info.circle")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Версия")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
                    Text("\(version) (\(build))")
                        .font(.subheadline.weight(.medium))
                }
            }

            NavigationLink(destination: SupportChatView()) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(accentGreen.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "message.fill")
                            .font(.body.weight(.medium))
                            .foregroundStyle(accentGreen)
                    }
                    Text("Поддержка в Telegram")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                }
            }
        } header: {
            Label("О приложении", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }
}
