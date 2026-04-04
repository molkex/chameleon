import SwiftUI
import PhotosUI

struct SupportChatView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [SupportMessage] = []
    @State private var isLoading = true
    @State private var isSending = false
    @State private var inputText = ""
    @State private var selectedPhotosItems: [PhotosPickerItem] = []
    @State private var pendingImages: [UIImage] = []
    @State private var fullscreenImage: URL? = nil
    @State private var pollingTask: Task<Void, Never>? = nil
    @State private var errorMessage: String? = nil
    @State private var keyboardHeight: CGFloat = 0

    private var accentGreen: Color { Color(red: 0.2, green: 0.84, blue: 0.42) }

    private var canSend: Bool {
        !isSending && (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if isLoading {
                        loadingView
                            .frame(maxWidth: .infinity, minHeight: 500)
                    } else if messages.isEmpty && !isSending {
                        emptyView
                            .frame(maxWidth: .infinity, minHeight: 500)
                    } else {
                        LazyVStack(spacing: 4) {
                            ForEach(messages) { message in
                                MessageBubble(
                                    message: message,
                                    onImageTap: { url in fullscreenImage = url }
                                )
                                .id(message.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            // Input bar sits below ScrollView — keyboard pushes entire VStack up
            VStack(spacing: 0) {
                if !messages.isEmpty || isSending {
                    Divider()
                }
                inputBar
                    .padding(.bottom, 8)
            }
            .background(Color(.systemBackground))
        }
        .padding(.bottom, keyboardHeight)
        .animation(.easeOut(duration: 0.25), value: keyboardHeight)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            guard let frame = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let duration = n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else { return }
            // Subtract bottom safe area + TabView's .padding(.bottom, 70) from TabRootView
            // so input bar sits flush against the keyboard with no gap
            let safeBottom = UIApplication.shared.windows.first?.safeAreaInsets.bottom ?? 0
            let overlap = max(0, UIScreen.main.bounds.height - safeBottom - 70 - frame.minY)
            withAnimation(.easeOut(duration: duration)) {
                keyboardHeight = overlap
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { n in
            let duration = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            withAnimation(.easeOut(duration: duration)) {
                keyboardHeight = 0
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle("Поддержка")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadMessages()
            startPolling()
        }
        .onDisappear {
            pollingTask?.cancel()
            pollingTask = nil
        }
        .sheet(item: $fullscreenImage) { url in
            FullscreenImageView(url: url)
        }
        .alert("Ошибка", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(accentGreen)
                .scaleEffect(1.4)
            Text("Загрузка...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(accentGreen.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "message.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(accentGreen)
            }
            VStack(spacing: 8) {
                Text("Нет сообщений")
                    .font(.title3.weight(.semibold))
                Text("Напишите нам — ответим\nв течение нескольких часов")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 8) {
            // Pending image previews
            if !pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(pendingImages.enumerated()), id: \.offset) { index, img in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                Button {
                                    pendingImages.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundStyle(.white)
                                        .background(Circle().fill(Color.black.opacity(0.5)).padding(2))
                                }
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: 80)
            }

            HStack(alignment: .bottom, spacing: 8) {
                // Photo picker button
                PhotosPicker(
                    selection: $selectedPhotosItems,
                    maxSelectionCount: 5,
                    matching: .images
                ) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                }
                .onChange(of: selectedPhotosItems) { _, newItems in
                    Task { await loadSelectedImages(from: newItems) }
                }

                // Text field
                TextField("Сообщение...", text: $inputText, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                    .onChange(of: inputText) { _, new in
                        if new.last == "\n" {
                            inputText = String(new.dropLast())
                            if canSend { Task { await sendMessage() } }
                        }
                    }

                // Send button
                Button {
                    Task { await sendMessage() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(canSend ? accentGreen : Color(.systemGray4))
                            .frame(width: 36, height: 36)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .disabled(!canSend)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: canSend)

                // Hide keyboard button — visible only when keyboard is open
                if keyboardHeight > 0 {
                    Button {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Token Helpers

    /// Retry wrapper: if the call throws .unauthorized, refresh the access token and retry once.
    private func withTokenRefresh<T>(_ call: @escaping (String) async throws -> T) async throws -> T {
        guard let token = appState.configStore.accessToken else {
            throw APIError.unauthorized
        }
        do {
            return try await call(token)
        } catch APIError.unauthorized {
            // Token expired — try to refresh
            guard let refreshToken = appState.configStore.refreshToken else {
                throw APIError.unauthorized
            }
            let newToken = try await appState.apiClient.refreshAccessToken(refreshToken)
            appState.configStore.accessToken = newToken
            return try await call(newToken)
        }
    }

    // MARK: - Actions

    private func loadMessages() async {
        do {
            let response = try await withTokenRefresh { token in
                try await appState.apiClient.fetchSupportMessages(accessToken: token)
            }
            withAnimation {
                messages = response.messages.sorted { $0.createdAt < $1.createdAt }
                isLoading = false
            }
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await refreshMessages()
            }
        }
    }

    private func refreshMessages() async {
        guard appState.configStore.accessToken != nil else { return }
        do {
            let response = try await withTokenRefresh { token in
                try await appState.apiClient.fetchSupportMessages(accessToken: token)
            }
            let sorted = response.messages.sorted { $0.createdAt < $1.createdAt }
            if sorted.map(\.id) != messages.map(\.id) {
                withAnimation {
                    messages = sorted
                }
            }
        } catch {
            // Silent — don't disturb user during polling
        }
    }

    private func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty else { return }
        guard appState.configStore.accessToken != nil else { return }

        // Optimistic: add placeholder message
        let optimisticID = -(messages.map(\.id).min() ?? 0) - 1
        let optimistic = SupportMessage(
            id: optimisticID,
            direction: "user",
            content: text.isEmpty ? nil : text,
            attachments: [],
            isRead: false,
            createdAt: Date()
        )
        withAnimation {
            messages.append(optimistic)
        }

        let imagesToSend = pendingImages
        let textToSend = text.isEmpty ? nil : text
        inputText = ""
        pendingImages = []
        selectedPhotosItems = []
        isSending = true

        do {
            let sent = try await withTokenRefresh { token in
                try await appState.apiClient.sendSupportMessage(
                    accessToken: token,
                    content: textToSend,
                    images: imagesToSend
                )
            }
            // Replace optimistic with real message
            withAnimation {
                if let idx = messages.firstIndex(where: { $0.id == optimisticID }) {
                    messages[idx] = sent
                }
            }
            // Sync full list after short delay
            try? await Task.sleep(for: .milliseconds(500))
            await refreshMessages()
        } catch {
            // Remove optimistic on failure and restore input
            withAnimation {
                messages.removeAll { $0.id == optimisticID }
            }
            inputText = textToSend ?? ""
            pendingImages = imagesToSend
            errorMessage = error.localizedDescription
        }
        isSending = false
    }

    private func loadSelectedImages(from items: [PhotosPickerItem]) async {
        var loaded: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                loaded.append(img)
            }
        }
        pendingImages = loaded
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: SupportMessage
    let onImageTap: (URL) -> Void

    private var accentGreen: Color { Color(red: 0.2, green: 0.84, blue: 0.42) }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: message.createdAt)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.isFromUser { Spacer(minLength: 60) }

            VStack(alignment: message.isFromUser ? .trailing : .leading, spacing: 4) {
                // Attachment images
                if !message.attachments.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(message.attachments, id: \.self) { urlString in
                            if let url = URL(string: attachmentURL(urlString)) {
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .scaledToFill()
                                            .frame(maxWidth: 220, maxHeight: 220)
                                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    case .failure:
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(Color(.systemGray5))
                                            .frame(width: 180, height: 120)
                                            .overlay(
                                                Image(systemName: "photo")
                                                    .foregroundStyle(.secondary)
                                            )
                                    default:
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(Color(.systemGray5))
                                            .frame(width: 180, height: 120)
                                            .overlay(ProgressView())
                                    }
                                }
                                .onTapGesture { onImageTap(url) }
                            }
                        }
                    }
                }

                // Text bubble
                if let content = message.content, !content.isEmpty {
                    VStack(alignment: message.isFromUser ? .trailing : .leading, spacing: 2) {
                        Text(content)
                            .font(.body)
                            .foregroundStyle(message.isFromUser ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(
                                message.isFromUser
                                    ? AnyShapeStyle(accentGreen)
                                    : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                            )

                        Text(timeText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                } else if message.attachments.isEmpty {
                    // Placeholder for optimistic message with no content
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text(timeText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                } else {
                    // Attachments-only — show timestamp below
                    Text(timeText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }

            if !message.isFromUser { Spacer(minLength: 60) }
        }
        .padding(.vertical, 2)
    }

    private func attachmentURL(_ path: String) -> String {
        if path.hasPrefix("http") { return path }
        return "\(AppConstants.baseURL)\(path)"
    }
}

// MARK: - Fullscreen Image

private struct FullscreenImageView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .ignoresSafeArea()
                case .failure:
                    VStack(spacing: 12) {
                        Image(systemName: "photo.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Не удалось загрузить фото")
                            .foregroundStyle(.secondary)
                    }
                default:
                    ProgressView()
                }
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }
}

// MARK: - URL Identifiable conformance

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
