import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import HiveChat

/// A complete chat screen, ready to push or present.
///
/// ```swift
/// NavigationLink("Chat with us") {
///     HiveChatView(chat: chat)
/// }
/// ```
///
/// It reads the merchant's branding from the widget configuration, so it
/// matches their storefront out of the box. Override with
/// ``SwiftUI/View/hiveChatTheme(_:)``.
public struct HiveChatView: View {
    @ObservedObject private var chat: HiveChat
    @State private var draft = ""
    @State private var explicitTheme: HiveChatTheme?
    @State private var article: KnowledgeBaseArticle?
    @State private var offlineEmail = ""
    @State private var errorMessage: String?
    @FocusState private var isComposerFocused: Bool

    private let voiceMessagesEnabled: Bool
    private let onProductTap: ((ProductCard) -> Void)?
    private let onOpenURL: ((URL) -> Bool)?
    @StateObject private var recorder = VoiceRecorder()
    @State private var photoItem: PhotosPickerItem?
    @State private var isShowingFileImporter = false

    /// - Parameters:
    ///   - chat: The conversation to show. Owned by you, so it survives the
    ///     view being dismissed and rebuilt — messages that arrive while the
    ///     screen is closed still land in the thread.
    ///   - theme: Overrides the merchant's branding entirely.
    ///   - onProductTap: Called when the customer taps a product the bot or an
    ///     agent sent. Without it the card opens its `buyURL` in a browser,
    ///     which walks the customer out of your app mid-conversation. Handle it
    ///     to push your own product screen instead — the card carries the
    ///     title, image, price and URL, and a product id or handle can be
    ///     recovered from ``ProductCard/buyURL``.
    ///   - onOpenURL: Called before any link is opened externally. Return
    ///     `true` if you handled it; `false` to let the SDK open a browser.
    ///   - voiceMessagesEnabled: Whether the customer can send a voice note.
    ///     Off by default, and deliberately: recording needs a microphone
    ///     prompt and an `NSMicrophoneUsageDescription` in your Info.plist, and
    ///     an SDK should not impose either. The prompt appears when the
    ///     customer taps the mic, not at launch.
    public init(
        chat: HiveChat,
        theme: HiveChatTheme? = nil,
        voiceMessagesEnabled: Bool = false,
        onProductTap: ((ProductCard) -> Void)? = nil,
        onOpenURL: ((URL) -> Bool)? = nil
    ) {
        self.chat = chat
        self.voiceMessagesEnabled = voiceMessagesEnabled
        self.onProductTap = onProductTap
        self.onOpenURL = onOpenURL
        _explicitTheme = State(initialValue: theme)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            thread
            composerArea
        }
        .background(theme.background.ignoresSafeArea())
        .hiveChatTheme(theme)
        .task {
            if chat.widgetSettings == nil { await chat.start() } else { chat.connect() }
        }
        .onAppear { chat.markRead() }
        .sheet(item: $article) { article in
            ArticleReaderView(article: article)
                .hiveChatTheme(theme)
        }
        .onChange(of: photoItem) {
            guard let photoItem else { return }
            Task {
                defer { self.photoItem = nil }
                do {
                    guard let data = try await photoItem.loadTransferable(type: Data.self) else { return }
                    /* PhotosPicker hands back the asset's data without naming
                       it; the extension only has to be honest enough for the
                       server to pick a Content-Type. */
                    try await chat.send(fileData: data, filename: "photo.jpg", contentType: "image/jpeg")
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .fileImporter(isPresented: $isShowingFileImporter, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            Task {
                /* A file outside the app's container needs the security scope
                   opened before it can be read, and closed after — skipping
                   this reads zero bytes from anything in Files. */
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    try await chat.send(
                        fileData: data,
                        filename: url.lastPathComponent,
                        contentType: url.mimeType
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .alert("Couldn't send", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var theme: HiveChatTheme {
        if let explicitTheme { return explicitTheme }
        if let configuration = chat.widgetSettings { return HiveChatTheme(configuration: configuration) }
        return HiveChatTheme()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(chat.widgetSettings?.logoEmoji ?? "💬")
                .font(.title3)
                .frame(width: 38, height: 38)
                .background(theme.brandColor.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 1) {
                Text(chat.widgetSettings?.storeName ?? "Support")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(chat.isTeamOnline ? Color.green : Color.gray)
                        .frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.caption2)
                        .foregroundColor(theme.secondaryText)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.background)
    }

    private var statusText: String {
        switch chat.connectionState {
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .failed: return "Unavailable"
        case .disconnected, .connected:
            if let position = chat.queuePosition {
                return position == 1 ? "You're next in line" : "You're #\(position) in the queue"
            }
            return chat.isTeamOnline ? "Online now" : "We'll reply by email"
        }
    }

    // MARK: Thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if let welcome = chat.widgetSettings?.welcomeMessage, chat.messages.isEmpty {
                        MessageRow(
                            message: ChatMessage(
                                id: "welcome",
                                sender: .agent,
                                senderName: chat.widgetSettings?.botName,
                                content: .text(welcome),
                                createdAt: Date()
                            ),
                            previews: [],
                            onReact: { _ in },
                            onOpenArticle: { _ in },
                            onSubmitForm: { _, _ in },
                            onProductTap: onProductTap,
                            onOpenURL: onOpenURL
                        )
                    }

                    ForEach(chat.messages) { message in
                        MessageRow(
                            message: message,
                            previews: chat.linkPreviews[message.id] ?? [],
                            onReact: { chat.toggleReaction($0, on: message.id) },
                            onOpenArticle: openArticle,
                            onSubmitForm: { form, values in chat.submit(form: form, values: values) },
                            onProductTap: onProductTap,
                            onOpenURL: onOpenURL
                        )
                        .id(message.id)
                    }

                    if chat.isAgentTyping {
                        TypingIndicator(name: chat.typingAgentName)
                            .id(Self.typingAnchor)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: chat.messages.count) { scrollToBottom(proxy) }
            .onChange(of: chat.isAgentTyping) { scrollToBottom(proxy) }
        }
    }

    private static let typingAnchor = "hive.typing"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        let target = chat.isAgentTyping ? Self.typingAnchor : chat.messages.last?.id
        guard let target else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .bottom) }
    }

    // MARK: Composer

    @ViewBuilder
    private var composerArea: some View {
        VStack(spacing: 0) {
            if let request = chat.satisfactionRequest {
                SatisfactionPrompt(prompt: request.prompt) { rating in
                    chat.submitCSAT(rating: rating)
                }
                Divider()
            }

            if let prompt = chat.offlinePrompt {
                OfflineEmailPrompt(message: prompt, email: $offlineEmail) {
                    chat.provideEmail(offlineEmail)
                    offlineEmail = ""
                }
                Divider()
            }

            Composer(
                draft: $draft,
                placeholder: chat.widgetSettings?.placeholderText ?? "Type your message…",
                isFocused: _isComposerFocused,
                voiceMessagesEnabled: voiceMessagesEnabled,
                recorder: recorder,
                photoItem: $photoItem,
                onPickFile: { isShowingFileImporter = true },
                onSendRecording: sendRecording,
                onSend: send,
                onTypingChanged: { chat.setTyping($0) }
            )
        }
    }

    private func sendRecording() {
        guard let recording = recorder.stopAndTake() else {
            errorMessage = "That recording was too short."
            return
        }
        Task {
            do {
                try await chat.send(
                    fileData: recording.data,
                    filename: recording.filename,
                    contentType: "audio/mp4"
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func send() {
        let text = draft
        draft = ""
        chat.send(text)
    }

    private func openArticle(_ card: ArticleCard) {
        Task {
            /* Cards carry a title and excerpt but not the body, so fetch the
               full article before presenting the reader — showing a sheet
               that then fills in would flash empty. */
            if let full = try? await chat.article(id: card.id) {
                article = full
            }
        }
    }
}

// MARK: - Composer

struct Composer: View {
    @Binding var draft: String
    let placeholder: String
    @FocusState var isFocused: Bool
    let voiceMessagesEnabled: Bool
    @ObservedObject var recorder: VoiceRecorder
    @Binding var photoItem: PhotosPickerItem?
    let onPickFile: () -> Void
    let onSendRecording: () -> Void
    let onSend: () -> Void
    let onTypingChanged: (Bool) -> Void

    @Environment(\.hiveChatTheme) private var theme

    var body: some View {
        if recorder.isRecording {
            recordingBar
        } else {
            composingBar
        }
    }

    /* While recording, the row becomes the recording — a text field nobody can
       type into and a send button that would send an empty message are just
       clutter at that moment. */
    private var recordingBar: some View {
        HStack(spacing: 8) {
            Button { recorder.cancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.red)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel recording")

            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 9, height: 9)
                Text(String(format: "Recording  %d:%02d", recorder.elapsedSeconds / 60, recorder.elapsedSeconds % 60))
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(HivePalette.secondaryBackground)
            .clipShape(Capsule())

            Button(action: onSendRecording) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.onBrandColor)
                    .frame(width: 34, height: 34)
                    .background(theme.brandFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send voice message")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.background)
    }

    private var composingBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                /* Two entries, because they are not the same experience: the
                   photo picker shows the camera roll without a permission
                   prompt, while a PDF receipt or returns label lives in Files. */
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Photo", systemImage: "photo")
                }
                Button { onPickFile() } label: {
                    Label("File", systemImage: "doc")
                }
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 17))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("Attach a photo or file")

            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($isFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(HivePalette.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .onChange(of: draft) {
                    onTypingChanged(!draft.isEmpty)
                }
                .onSubmit(send)

            /* The mic gives way the moment someone is clearly composing text —
               either they have typed something, or the field is focused and
               the keyboard is up, which is intent enough. It comes back when
               they dismiss the keyboard without having typed. */
            if voiceMessagesEnabled && trimmed.isEmpty && !isFocused {
                Button {
                    Task { try? await recorder.start() }
                } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 17))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record a voice message")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.onBrandColor)
                        .frame(width: 34, height: 34)
                        .background(theme.brandFill)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty)
                .opacity(trimmed.isEmpty ? 0.4 : 1)
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.background)
    }

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        guard !trimmed.isEmpty else { return }
        onSend()
        onTypingChanged(false)
    }
}

// MARK: - Small pieces

struct TypingIndicator: View {
    let name: String?
    @State private var phase = 0.0
    @Environment(\.hiveChatTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(theme.secondaryText.opacity(0.6))
                    .frame(width: 6, height: 6)
                    .scaleEffect(scale(for: index))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(theme.incomingBubble)
        .clipShape(Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { phase = 1 }
        }
        .accessibilityLabel(name.map { "\($0) is typing" } ?? "Typing")
    }

    private func scale(for index: Int) -> CGFloat {
        /* Stagger the three dots off one animated value rather than three
           timers — cheaper, and they stay in step through view updates. */
        let offset = Double(index) * 0.25
        return 0.7 + 0.3 * abs(sin((phase + offset) * .pi))
    }
}

struct SatisfactionPrompt: View {
    let prompt: String
    let onRate: (Int) -> Void
    @Environment(\.hiveChatTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Text(prompt).font(.footnote.weight(.medium))
            HStack(spacing: 10) {
                ForEach(1...5, id: \.self) { rating in
                    Button { onRate(rating) } label: {
                        Image(systemName: "star")
                            .font(.title3)
                            .foregroundColor(theme.brandColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(rating) out of 5")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(theme.brandColor.opacity(0.06))
    }
}

struct OfflineEmailPrompt: View {
    let message: String
    @Binding var email: String
    let onSubmit: () -> Void
    @Environment(\.hiveChatTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.footnote).foregroundColor(theme.secondaryText)
            HStack(spacing: 8) {
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    #if canImport(UIKit)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                Button("Send", action: onSubmit)
                    .font(.footnote.weight(.semibold))
                    .disabled(!email.contains("@"))
            }
        }
        .padding(14)
        .background(HivePalette.secondaryBackground)
    }
}

struct ArticleReaderView: View {
    let article: KnowledgeBaseArticle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(article.title).font(.title2.weight(.bold))
                    /* The body is server-rendered HTML. AttributedString's
                       HTML importer is the only first-party way to show it
                       without a WebView, and it is strict — anything it
                       refuses falls back to the excerpt rather than a blank
                       sheet. */
                    if let attributed = article.attributedBody {
                        Text(attributed)
                    } else if let excerpt = article.excerpt {
                        Text(excerpt)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("Help")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension KnowledgeBaseArticle {
    var attributedBody: AttributedString? {
        guard let html = bodyHTML, let data = html.data(using: .utf8) else { return nil }
        guard let ns = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return nil }
        return try? AttributedString(ns, including: \.foundation)
    }
}
