import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A live conversation between the person using your app and the merchant's
/// support team.
///
/// ```swift
/// let chat = HiveChat(configuration: .init(widgetKey: "hv_a1b2c3d4e5f6a1b2c3d4e5f6"))
/// chat.identify(name: customer.name, email: customer.email)
/// await chat.start()
/// chat.send("Where is my order?")
/// ```
///
/// Observe ``messages``, ``connectionState`` and the rest from SwiftUI, or
/// drop in `HiveChatView` from the `HiveChatUI` product.
///
/// Everything is main-actor isolated: state that a view binds to has no
/// business changing on a background queue, and the socket callbacks hop
/// here themselves.
@MainActor
public final class HiveChat: ObservableObject {

    // MARK: - Observable state

    /// The conversation, oldest first. Includes optimistic local echoes of
    /// messages that have not reached the server yet — check
    /// ``ChatMessage/delivery``.
    @Published public private(set) var messages: [ChatMessage] = []

    /// Where the socket stands. Show a banner on ``ConnectionState/reconnecting``
    /// if you like; the SDK recovers on its own.
    @Published public private(set) var connectionState: ConnectionState = .disconnected

    /// The merchant's settings — branding, welcome text, whether the team is
    /// online. Nil until ``start()`` (or ``loadConfiguration()``) completes.
    @Published public private(set) var widgetSettings: WidgetSettings?

    /// Whether someone on the other end is typing right now.
    @Published public private(set) var isAgentTyping = false

    /// Who is typing, when the server tells us.
    @Published public private(set) var typingAgentName: String?

    /// Whether the merchant has anyone available. The bot answers regardless.
    @Published public private(set) var isTeamOnline = false

    /// Position in the queue while waiting for a human, 1-based. Nil when not
    /// queued.
    @Published public private(set) var queuePosition: Int?

    /// Messages that have arrived but not been marked read. Drive your badge
    /// off this.
    @Published public private(set) var unreadCount = 0

    /// Set when the team is offline and the customer should be asked for an
    /// email address instead. Carries the merchant's wording.
    @Published public private(set) var offlinePrompt: String?

    /// Set when the server asks the customer to rate the conversation.
    /// Answer with ``submitCSAT(rating:comment:)``, then clear it.
    @Published public private(set) var satisfactionRequest: SatisfactionRequest?

    /// True once the conversation has been closed by either side. The
    /// customer's next message reopens it.
    @Published public private(set) var hasEnded = false

    /// Link previews the server generated, keyed by message id.
    @Published public private(set) var linkPreviews: [String: [LinkPreview]] = [:]

    /// The current conversation's id, once one exists. Nil until the customer
    /// sends their first message — the server creates sessions lazily so that
    /// merely opening the chat does not spawn an empty ticket.
    @Published public private(set) var sessionID: String?

    // MARK: - Internals

    private let configuration: HiveChatConfiguration
    private let api: HiveAPIClient
    private var connection: SocketIOConnection?

    private var visitorToken: String
    private var visitorName: String?
    private var visitorEmail: String?
    private var consentText: String?
    private var handoffCode: String?

    /// Messages the customer sent while the socket was down. Flushed in order
    /// on reconnect — a chat that silently eats what you typed on a train is
    /// worse than one that admits it is offline.
    private var outbox: [(localID: String, body: String)] = []

    private var typingResetTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// Creates a chat client.
    ///
    /// Deliberately `nonisolated`: the rest of the type is main-actor bound
    /// because a view binds to its state, but *construction* touches nothing
    /// shared, and requiring the main actor here made the natural places to
    /// build one — a `ViewModel.init`, an `App` struct's property
    /// initialiser, an `AppDelegate` — fail to compile under Swift 6.
    public nonisolated init(configuration: HiveChatConfiguration) {
        self.configuration = configuration
        self.api = HiveAPIClient(host: configuration.host, widgetKey: configuration.widgetKey)

        if let existing = configuration.tokenStore.load() {
            self.visitorToken = existing
        } else {
            /* Same shape the web widget mints, so a customer who used the
               website and then the app is not obviously two different people
               in the agent's visitor list. */
            let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
            let stamp = String(Int(Date().timeIntervalSince1970), radix: 36)
            self.visitorToken = "v_\(random)\(stamp)"
            configuration.tokenStore.save(self.visitorToken)
        }

    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Identity

    /// Tells Hive who the customer is, so the agent sees a name rather than
    /// "Visitor" and the conversation is threaded onto their customer record.
    ///
    /// Call before ``start()`` when you already know — a signed-in app should.
    /// Calling later is fine too; it updates the live conversation.
    ///
    /// - Important: Hive does not currently verify this. Anything your app
    ///   sends is taken at face value, so treat it as a display convenience,
    ///   not as authentication of who the customer is.
    public func identify(name: String? = nil, email: String? = nil) {
        if let name, !name.isEmpty { visitorName = name }
        if let email, !email.isEmpty { visitorEmail = email }

        guard connectionState == .connected else { return }
        connection?.emit("visitor:info", [
            "name": visitorName ?? "",
            "email": visitorEmail ?? "",
        ])
    }

    /// Records that the customer accepted the merchant's data-consent wording.
    /// Pass the exact text they were shown — it is stored alongside the
    /// conversation as the audit trail. Must be set before ``connect()``.
    public func recordConsent(text: String) {
        consentText = text
    }

    /// Adopts a conversation started on another device, from a Hive
    /// "continue this chat here" link (`?hive_chat=CODE`). Set before
    /// connecting; the code is single-use and expires.
    public func redeemHandoffCode(_ code: String) {
        handoffCode = code.uppercased()
    }

    // MARK: - Lifecycle

    /// Loads the merchant's configuration and opens the socket.
    public func start() async {
        await loadConfiguration()
        connect()
    }

    /// Fetches the widget configuration without connecting — useful to decide
    /// whether to show a chat entry point at all.
    @discardableResult
    public func loadConfiguration() async -> WidgetSettings? {
        do {
            let configuration = try await api.widgetSettings()
            widgetSettings = configuration
            isTeamOnline = configuration.isOnline
            return configuration
        } catch {
            log("configuration load failed: \(error)")
            return nil
        }
    }

    /// Opens the socket. Safe to call repeatedly.
    public func connect() {
        observeAppLifecycle()
        guard connection == nil else {
            connection?.reconnectNow()
            return
        }
        /* The merchant switched the widget off. Connecting would be refused
           anyway; failing here says why. */
        if let configuration = widgetSettings, !configuration.isEnabled {
            connectionState = .failed(reason: "This chat widget is disabled.")
            return
        }

        let connection = SocketIOConnection(
            host: configuration.host,
            namespace: "/livechat/visitor",
            authProvider: { [weak self] in
                /* Read on the socket's queue, written on the main actor.
                   Hopping to grab a snapshot would deadlock the handshake,
                   so the values are copied into a Sendable box each time
                   they change instead. */
                self?.authSnapshot.value ?? [:]
            }
        )
        refreshAuthSnapshot()

        connection.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handleStateChange(state) }
        }
        connection.onEvent = { [weak self] event, arguments in
            Task { @MainActor in self?.handle(event: event, arguments: arguments) }
        }

        self.connection = connection
        connection.connect()
    }

    /// Closes the socket. The conversation itself stays open — this is not
    /// "end chat", it is "stop listening".
    public func disconnect() {
        connection?.disconnect()
        connection = nil
        connectionState = .disconnected
    }

    private let authSnapshot = AuthSnapshot()

    private func refreshAuthSnapshot() {
        var auth: [String: Any] = [
            "widgetKey": configuration.widgetKey,
            "visitorToken": visitorToken,
            "name": visitorName ?? "",
            "email": visitorEmail ?? "",
        ]
        if let handoffCode { auth["handoffCode"] = handoffCode }
        if let consentText { auth["consentText"] = consentText }
        /* pageUrl/pageTitle/referrer are web concepts the agent panel shows
           as "what they were looking at". Sending the bundle id is the honest
           native equivalent — it tells the agent which app this is without
           pretending to be a URL they can open. */
        auth["pageUrl"] = Bundle.main.bundleIdentifier.map { "app://\($0)" } ?? "app://ios"
        auth["pageTitle"] = Self.appDisplayName
        authSnapshot.value = auth
    }

    private static var appDisplayName: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? "iOS app"
    }

    // MARK: - Sending

    /// Sends a message. Appears in ``messages`` immediately as
    /// ``ChatMessage/DeliveryState/sending`` and is queued if the socket is
    /// down.
    public func send(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        enqueue(body: body, echo: .text(body))
    }

    /// Uploads a file and sends it as a message.
    ///
    /// The customer sees it in the thread straight away; if the upload fails
    /// the echo is marked ``ChatMessage/DeliveryState/failed`` and the error
    /// is thrown.
    public func send(
        fileData: Data,
        filename: String,
        contentType: String
    ) async throws {
        let localID = "local_\(UUID().uuidString)"
        let pending = Attachment(
            kind: Attachment.kind(forContentType: contentType),
            url: nil,
            name: filename,
            contentType: contentType,
            isUploading: true
        )
        appendLocalEcho(id: localID, content: .attachment(pending))

        do {
            let uploaded = try await api.upload(data: fileData, filename: filename, contentType: contentType)
            let payload: [String: Any] = [
                "url": uploaded.url?.absoluteString ?? "",
                "contentType": uploaded.contentType,
                "name": uploaded.name,
            ]
            guard let json = try? JSONSerialization.data(withJSONObject: payload),
                  let string = String(data: json, encoding: .utf8)
            else { throw HiveChatError.invalidResponse }

            /* Replace the optimistic echo rather than adding a second row:
               the server's own copy will arrive with a real id and we drop
               ours when it does. */
            removeLocalEcho(id: localID)
            enqueue(
                body: "\(MessageContent.Sentinel.visitorFile)\(string)",
                echo: .attachment(Attachment(
                    kind: uploaded.url.map { _ in Attachment.kind(forContentType: uploaded.contentType) } ?? .file,
                    url: uploaded.url,
                    name: uploaded.name,
                    contentType: uploaded.contentType
                ))
            )
        } catch {
            markLocalEcho(id: localID, as: .failed)
            throw error
        }
    }

    /// Submits a form an agent pushed into the chat.
    public func submit(form: ChatForm, values: [String: String]) {
        let entries = form.fields.map { field in
            FormResponse.Entry(key: field.key, label: field.label, value: values[field.key] ?? "")
        }
        let response = FormResponse(formID: form.formID, formName: form.name, entries: entries)
        guard let data = try? JSONEncoder().encode(response),
              let json = String(data: data, encoding: .utf8)
        else { return }

        enqueue(
            body: "\(MessageContent.Sentinel.formResponse)\(json)\(MessageContent.Sentinel.terminator)",
            echo: .formResponse(response)
        )
    }

    /// Tells the agent the customer is typing. Call on every keystroke; the
    /// SDK throttles and clears the indicator for you.
    public func setTyping(_ isTyping: Bool, previewText: String? = nil) {
        connection?.emit("chat:typing", [
            "typing": isTyping,
            /* The agent dashboard shows the customer's half-typed text live.
               It is a real feature (agents start looking things up early) but
               it is also surprising, so the SDK only sends it when the caller
               explicitly opts in by passing it. */
            "text": previewText ?? "",
        ])

        typingResetTask?.cancel()
        guard isTyping else { return }
        typingResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.connection?.emit("chat:typing", ["typing": false, "text": ""])
        }
    }

    /// Marks everything the team has sent as read, and clears ``unreadCount``.
    /// Call when the conversation is actually visible.
    public func markRead() {
        unreadCount = 0
        for index in messages.indices where messages[index].sender != .visitor {
            messages[index].isRead = true
        }
        connection?.emit("chat:read")
    }

    /// Asks to be put through to a human. The bot hands over and the
    /// conversation joins the queue.
    public func requestHuman() {
        connection?.emit("chat:request-human")
    }

    /// Ends the conversation. The customer's next message reopens it.
    public func endChat() {
        connection?.emit("chat:end")
    }

    /// Adds or removes an emoji reaction on a message.
    public func toggleReaction(_ emoji: String, on messageID: String) {
        connection?.emit("chat:reaction:toggle", ["messageId": messageID, "emoji": emoji])
    }

    /// Answers a ``satisfactionRequest``.
    public func submitCSAT(rating: Int, comment: String? = nil) {
        connection?.emit("csat:submit", [
            "rating": max(1, min(5, rating)),
            "comment": comment ?? "",
        ])
        satisfactionRequest = nil
    }

    /// Tells the team which screen the customer is on.
    ///
    /// On the web an agent sees the page someone is browsing, which is half of
    /// how they answer "where's my order?" before it is asked. An app has no
    /// URL, so pass something that reads well in the agent panel — a screen
    /// name, and ideally the thing being looked at.
    ///
    /// ```swift
    /// chat.trackScreen("Product", title: "Slim Fit Suit", reference: "slim-fit-suit")
    /// ```
    ///
    /// Safe to call before a conversation exists: it is recorded against the
    /// visitor either way, so an agent picking the chat up can see what they
    /// were looking at beforehand.
    public func trackScreen(_ screen: String, title: String? = nil, reference: String? = nil) {
        let name = screen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        /* Shaped as a URL because that is the column it lands in and what the
           agent panel renders. `app://` says plainly this was not a web page,
           rather than dressing it up as one an agent might try to open. */
        var path = name.lowercased().replacingOccurrences(of: " ", with: "-")
        if let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty {
            path += "/" + reference
        }
        connection?.emit("page:update", [
            "url": "app://ios/" + path,
            "title": title ?? name,
        ])
    }

    /// Mirrors the customer's basket to the team.
    ///
    /// An agent seeing what is in the basket can answer "will this arrive
    /// before Friday?" without asking the customer to read their order back.
    /// Call it when the basket changes; only the latest state is kept.
    ///
    /// - Parameters:
    ///   - total: formatted as you would show it, e.g. `"129.99"`
    ///   - currency: ISO code, e.g. `"GBP"`
    public func updateCart(items: [CartItem], total: String, currency: String) {
        connection?.emit("cart:update", [
            "items": items.map { item -> [String: Any] in
                var payload: [String: Any] = [
                    "title": item.title,
                    "quantity": item.quantity,
                    "price": item.price,
                ]
                if let variant = item.variant { payload["variant"] = variant }
                if let imageURL = item.imageURL { payload["image"] = imageURL.absoluteString }
                return payload
            },
            "total": total,
            "currency": currency,
            "count": items.reduce(0) { $0 + $1.quantity },
        ])
    }

    /// Registers this device's APNs token so Hive can notify the customer when
    /// a reply arrives and the app is closed.
    ///
    /// Call it from `didRegisterForRemoteNotificationsWithDeviceToken` — the
    /// `Data` Apple hands you goes straight in, no hex conversion needed.
    /// Registration is tied to this device's visitor token, so it works for a
    /// customer who has never signed in, and it needs nothing of your backend:
    /// Hive sends the notification itself using the credentials your team
    /// pasted into Settings → Live Chat → Mobile Push.
    ///
    /// Safe to call before a conversation exists.
    public func registerDeviceToken(_ deviceToken: Data) {
        registerDeviceToken(deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    /// Registers an already hex-encoded APNs token.
    public func registerDeviceToken(_ hexToken: String) {
        guard !hexToken.isEmpty else { return }
        let token = visitorToken
        Task { @MainActor [weak self] in
            do {
                try await self?.api.registerPushDevice(visitorToken: token, deviceToken: hexToken)
            } catch {
                self?.log("device registration failed: \(error)")
            }
        }
    }

    /// Stops pushes to this device. Call on sign-out, so the next person using
    /// the phone is not notified about a conversation that was never theirs.
    public func unregisterDeviceToken(_ hexToken: String) {
        guard !hexToken.isEmpty else { return }
        Task { [weak self] in
            try? await self?.api.unregisterPushDevice(deviceToken: hexToken)
        }
    }

    /// Gives the customer's email to the team mid-conversation — what the
    /// offline form collects.
    public func provideEmail(_ email: String) {
        visitorEmail = email
        refreshAuthSnapshot()
        connection?.emit("visitor:email", ["email": email])
        offlinePrompt = nil
    }

    /// Mints a one-time link that moves this conversation to another device.
    public func createDeviceHandoff() async throws -> DeviceHandoff {
        guard let connection, sessionID != nil else { throw HiveChatError.noActiveSession }
        return try await withCheckedThrowingContinuation { continuation in
            connection.emit("chat:handoff:create", [:]) { response in
                guard let payload = response.first as? [String: Any],
                      payload["ok"] as? Bool == true,
                      let urlString = payload["url"] as? String,
                      let url = URL(string: urlString)
                else {
                    let message = (response.first as? [String: Any])?["error"] as? String
                    continuation.resume(throwing: HiveChatError.server(status: 0, message: message))
                    return
                }
                continuation.resume(returning: DeviceHandoff(
                    url: url,
                    code: payload["code"] as? String ?? "",
                    qrCodeSVG: payload["qrSvg"] as? String,
                    expiresInMinutes: payload["expiresInMinutes"] as? Int ?? 5
                ))
            }
        }
    }

    // MARK: - Help centre

    /// Searches the merchant's help articles.
    public func searchArticles(query: String) async throws -> [KnowledgeBaseArticle] {
        try await api.searchArticles(query: query)
    }

    /// Fetches one article, with its rendered HTML body.
    public func article(id: String) async throws -> KnowledgeBaseArticle {
        try await api.article(id: id)
    }

    /// Emails the customer a copy of the conversation.
    public func emailTranscript(to email: String) async throws {
        guard let sessionID else { throw HiveChatError.noActiveSession }
        try await api.emailTranscript(sessionID: sessionID, visitorToken: visitorToken, to: email)
    }

    // MARK: - Outbound plumbing

    private func enqueue(body: String, echo: MessageContent) {
        let localID = "local_\(UUID().uuidString)"
        appendLocalEcho(id: localID, content: echo)

        guard connectionState == .connected, let connection else {
            outbox.append((localID, body))
            return
        }
        connection.emit("chat:message", ["body": body])
        markLocalEcho(id: localID, as: .sent)
    }

    private func flushOutbox() {
        guard let connection, !outbox.isEmpty else { return }
        let queued = outbox
        outbox.removeAll()
        for item in queued {
            connection.emit("chat:message", ["body": item.body])
            markLocalEcho(id: item.localID, as: .sent)
        }
    }

    private func appendLocalEcho(id: String, content: MessageContent) {
        messages.append(ChatMessage(
            id: id,
            sender: .visitor,
            senderName: visitorName,
            content: content,
            createdAt: Date(),
            delivery: .sending
        ))
    }

    private func markLocalEcho(id: String, as state: ChatMessage.DeliveryState) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].delivery = state
    }

    private func removeLocalEcho(id: String) {
        messages.removeAll { $0.id == id }
    }

    // MARK: - Inbound events

    private func handleStateChange(_ state: ConnectionState) {
        connectionState = state
        guard state == .connected else {
            if state == .disconnected || state == .reconnecting { isAgentTyping = false }
            return
        }
        /* Re-assert identity on every connect. The handshake carries it too,
           but a name captured by a pre-chat form after the socket opened
           would otherwise not reach the agent panel until the next reconnect. */
        if visitorName != nil || visitorEmail != nil { identify() }
        flushOutbox()
    }

    private func handle(event: String, arguments: [Any]) {
        let payload = arguments.first as? [String: Any] ?? [:]
        log("← \(event)")

        switch event {
        case "chat:session":
            sessionID = payload["sessionId"] as? String

        case "chat:restore":
            handleRestore(payload)

        case "chat:message":
            handleIncomingMessage(payload)

        case "chat:typing":
            isAgentTyping = payload["typing"] as? Bool ?? false
            typingAgentName = payload["name"] as? String

        case "chat:read":
            /* The agent read the customer's messages. The server sends the
               ids it marked; anything the customer sent is now read. */
            for index in messages.indices where messages[index].sender == .visitor {
                messages[index].isRead = true
            }

        case "chat:transfer":
            if let message = payload["message"] as? String {
                appendSystemMessage(message)
            }

        case "chat:offline":
            offlinePrompt = payload["message"] as? String

        case "chat:queue-position":
            queuePosition = payload["position"] as? Int

        case "chat:ended":
            hasEnded = true
            queuePosition = nil

        case "agents:status":
            isTeamOnline = payload["online"] as? Bool ?? false

        case "visitor:name":
            visitorName = payload["name"] as? String ?? visitorName

        case "visitor:invite":
            /* An agent reached out first. The invitation text arrives as a
               normal chat:message straight after, so there is nothing to
               append here — but the host app may want to open the chat. */
            onProactiveInvitation?(payload["message"] as? String ?? "")

        case "csat:request":
            satisfactionRequest = SatisfactionRequest(
                prompt: payload["prompt"] as? String ?? "How would you rate this conversation?"
            )

        case "csat:received":
            satisfactionRequest = nil

        case "chat:reactions":
            handleReactions(payload)

        case "chat:message:enriched":
            handleEnrichment(payload)

        case "chat:handoff:adopted":
            if let token = payload["visitorToken"] as? String {
                visitorToken = token
                configuration.tokenStore.save(token)
                refreshAuthSnapshot()
            }
            sessionID = payload["sessionId"] as? String ?? sessionID
            handoffCode = nil

        case "chat:handoff:invalid":
            handoffCode = nil
            onHandoffFailed?()

        default:
            log("unhandled event \(event)")
        }
    }

    private func handleRestore(_ payload: [String: Any]) {
        sessionID = payload["sessionId"] as? String
        hasEnded = (payload["status"] as? String) == "ended"

        let restored = (payload["messages"] as? [[String: Any]] ?? [])
            .compactMap { ChatMessage.from(wire: $0, host: configuration.host) }

        /* Rebuild rather than merge. The server's copy is authoritative and
           this event fires on every reconnect, so appending would duplicate
           the whole thread each time the socket blinked. Anything still in
           the outbox is re-appended: it is not on the server yet, and
           dropping it would make the customer's own words vanish. */
        let unsent = messages.filter { $0.delivery != .sent && $0.sender == .visitor }
        messages = restored + unsent.filter { unsentMessage in
            !restored.contains { $0.content == unsentMessage.content }
        }

        if configuration.marksMessagesReadAutomatically {
            markRead()
        } else {
            unreadCount = restored.filter { $0.sender != .visitor && !$0.isRead }.count
        }
    }

    private func handleIncomingMessage(_ payload: [String: Any]) {
        guard let message = ChatMessage.from(wire: payload, host: configuration.host) else { return }

        /* The server echoes the customer's own messages back. Drop the
           optimistic copy in favour of the server's, matching on content
           because the ids differ by construction. */
        if message.sender == .visitor,
           let index = messages.lastIndex(where: { $0.sender == .visitor && $0.content == message.content && $0.id.hasPrefix("local_") }) {
            messages[index] = message
            return
        }
        guard !messages.contains(where: { $0.id == message.id }) else { return }

        messages.append(message)
        isAgentTyping = false
        queuePosition = nil

        if message.sender != .visitor {
            if configuration.marksMessagesReadAutomatically {
                markRead()
            } else {
                unreadCount += 1
            }
            onMessageReceived?(message)
        }
    }

    private func handleReactions(_ payload: [String: Any]) {
        guard let messageID = payload["message_id"] as? String,
              let index = messages.firstIndex(where: { $0.id == messageID })
        else { return }
        messages[index].reactions = Reaction.list(from: payload["reactions"])
    }

    private func handleEnrichment(_ payload: [String: Any]) {
        guard let messageID = payload["messageId"] as? String,
              let metadata = payload["metadata"] as? [String: Any],
              let previews = metadata["url_previews"] as? [[String: Any]]
        else { return }
        linkPreviews[messageID] = previews.compactMap(LinkPreview.init(json:))
    }

    private func appendSystemMessage(_ text: String) {
        messages.append(ChatMessage(
            id: "system_\(UUID().uuidString)",
            sender: .system,
            senderName: nil,
            content: .text(text),
            createdAt: Date()
        ))
    }

    // MARK: - Callbacks

    /// Called when a message arrives from the team while the app is running.
    ///
    /// This is the half of notifications that needs no server: the app is
    /// awake, the socket is connected, and you already have the message — so
    /// raise an in-app banner, or post a `UNNotificationRequest` if the chat
    /// screen is not the one on top.
    ///
    /// Only fires for live arrivals from the team, never for the customer's
    /// own messages and never for the thread replayed on reconnect — someone
    /// returning to the app should not be notified about messages they have
    /// already read.
    ///
    /// It cannot help while the app is closed. A suspended app runs no code,
    /// so nothing local can notice a message or raise anything; only a push
    /// sent by a server can wake it. That is what the push webhook is for.
    public var onMessageReceived: ((ChatMessage) -> Void)?

    /// Called when an agent proactively invites the customer into a chat.
    /// Open your chat screen from here.
    public var onProactiveInvitation: ((String) -> Void)?

    /// Called when a device-handoff code turned out to be spent or expired.
    public var onHandoffFailed: (() -> Void)?

    // MARK: - App lifecycle

    private func observeAppLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        #if canImport(UIKit) && !os(watchOS)
        /* iOS suspends WebSockets when the app backgrounds, and the client
           usually does not find out until a write fails — which, for a screen
           that is only ever reading, is never. So force a fresh socket on
           foreground rather than trusting the old one. */
        let foreground = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.connection?.reconnectNow() }
        }
        lifecycleObservers.append(foreground)
        #endif
    }

    private func log(_ message: @autoclosure () -> String) {
        guard configuration.isDebugLoggingEnabled else { return }
        print("[HiveChat] \(message())")
    }
}

// MARK: - Supporting types

/// A prompt to rate the conversation.
public struct SatisfactionRequest: Equatable, Sendable {
    public let prompt: String
}

/// A one-time link that moves the conversation to another device.
public struct DeviceHandoff: Equatable, Sendable {
    public let url: URL
    public let code: String
    /// A ready-made QR of ``url``, as SVG markup.
    public let qrCodeSVG: String?
    public let expiresInMinutes: Int
}

/// A preview of a link someone posted in the chat.
public struct LinkPreview: Equatable, Sendable, Identifiable {
    public var id: String { url }
    public let url: String
    public let title: String?
    public let description: String?
    public let imageURL: String?
    public let siteName: String?

    init?(json: [String: Any]) {
        guard let url = json["url"] as? String else { return nil }
        self.url = url
        title = json["title"] as? String
        description = json["description"] as? String
        imageURL = json["image_url"] as? String
        siteName = json["site_name"] as? String
    }
}

/// A thread-safe box for the handshake payload, read from the socket queue.
final class AuthSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Any] = [:]
    var value: [String: Any] {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
