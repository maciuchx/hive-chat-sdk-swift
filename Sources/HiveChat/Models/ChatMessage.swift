import Foundation

/// One message in a conversation.
public struct ChatMessage: Identifiable, Equatable, Sendable {
    /// Server id, or a locally-minted id while the message is in flight.
    public let id: String
    public let sender: Sender
    /// Display name of the sender — an agent's name, the bot's name, or nil.
    public let senderName: String?
    public let content: MessageContent
    public let createdAt: Date
    /// Whether the other side has read this message. Only meaningful on
    /// messages the customer sent.
    public var isRead: Bool
    public var reactions: [Reaction]
    public var delivery: DeliveryState

    public enum Sender: String, Equatable, Sendable {
        /// The person using your app.
        case visitor
        /// A human agent, or the bot — the server deliberately presents the
        /// bot to customers as an agent, and this SDK does not second-guess
        /// that. A thread that distinguished them would leak which replies
        /// were automated.
        case agent
        /// Server narration: "Chat ended", "Connecting you with the team".
        case system

        init(wire: String?) {
            switch wire {
            case "visitor": self = .visitor
            case "agent", "bot": self = .agent
            default: self = .system
            }
        }
    }

    /// Local delivery state for messages this device sent. Server messages
    /// are always ``sent``.
    public enum DeliveryState: Equatable, Sendable {
        /// Written to the thread optimistically, not yet acknowledged.
        case sending
        /// The server has it.
        case sent
        /// The socket was down and the send could not be queued.
        case failed
    }

    public init(
        id: String,
        sender: Sender,
        senderName: String?,
        content: MessageContent,
        createdAt: Date,
        isRead: Bool = false,
        reactions: [Reaction] = [],
        delivery: DeliveryState = .sent
    ) {
        self.id = id
        self.sender = sender
        self.senderName = senderName
        self.content = content
        self.createdAt = createdAt
        self.isRead = isRead
        self.reactions = reactions
        self.delivery = delivery
    }

    /// Builds a message from a `chat:message` or `chat:restore` payload.
    /// Returns nil for bodies the customer must not see.
    static func from(wire: [String: Any], host: URL) -> ChatMessage? {
        let body = wire["body"] as? String ?? ""
        guard let content = MessageContent.parse(body: body) else { return nil }

        return ChatMessage(
            id: wire["id"] as? String ?? UUID().uuidString,
            sender: Sender(wire: wire["sender_type"] as? String),
            senderName: wire["sender_name"] as? String,
            content: content.resolvingRelativeURLs(against: host),
            createdAt: Self.date(from: wire["created_at"]),
            isRead: wire["read"] as? Bool ?? false,
            reactions: Reaction.list(from: wire["reactions"])
        )
    }

    /* Dates cross the wire as ISO-8601 with fractional seconds from the
       socket path (`new Date().toISOString()`) and WITHOUT them from MySQL
       on the restore path. One formatter cannot read both, and the failure
       is silent — every restored message stamped 1970 and the thread sorts
       inside out — so try both and fall back to now. */
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(from value: Any?) -> Date {
        guard let string = value as? String else { return Date() }
        if let d = isoFractional.date(from: string) { return d }
        if let d = isoPlain.date(from: string) { return d }
        return Date()
    }
}

/// An emoji reaction on a message.
public struct Reaction: Equatable, Sendable, Identifiable {
    public var id: String { emoji }
    public let emoji: String
    public let count: Int
    /// Whether this device's customer is one of the reactors.
    public let isMine: Bool

    public init(emoji: String, count: Int, isMine: Bool) {
        self.emoji = emoji
        self.count = count
        self.isMine = isMine
    }

    static func list(from value: Any?) -> [Reaction] {
        guard let raw = value as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let emoji = entry["emoji"] as? String else { return nil }
            return Reaction(
                emoji: emoji,
                count: entry["count"] as? Int ?? 1,
                isMine: entry["mine"] as? Bool ?? false
            )
        }
    }
}

extension MessageContent {
    /// Rewrites host-relative attachment URLs (`/uploads/livechat/…`) into
    /// absolute ones. The server emits them relative because the web widget
    /// is same-origin; a native app has no origin to be relative to.
    func resolvingRelativeURLs(against host: URL) -> MessageContent {
        guard case .attachment(let attachment) = self else { return self }
        guard let url = attachment.url, url.host == nil else { return self }
        let resolved = URL(string: url.absoluteString, relativeTo: host)?.absoluteURL
        return .attachment(Attachment(
            kind: attachment.kind,
            url: resolved,
            name: attachment.name,
            contentType: attachment.contentType,
            isUploading: attachment.isUploading
        ))
    }
}
