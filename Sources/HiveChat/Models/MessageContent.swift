import Foundation

/// The rich content a chat message can carry.
///
/// Hive transports rich content as a *sentinel-prefixed* message body — the
/// body is a plain string that begins with a marker such as
/// `__PRODUCT_CARD__` followed by JSON, rather than a structured field. That
/// choice predates this SDK and is load-bearing across the web widget, the
/// agent dashboard, email rendering and the WhatsApp/Meta bridges, so the SDK
/// parses the format rather than asking the server to change it.
///
/// Anything unrecognised lands in ``unsupported(raw:)`` with the body intact.
/// That case exists so an SDK built today survives a sentinel invented
/// tomorrow: a shipped app can render the raw text (or hide it) instead of
/// crashing or dropping the message on the floor.
public enum MessageContent: Equatable, Sendable {
    /// A plain text message. The common case.
    case text(String)
    /// A product the bot or agent linked — image, title, price, buy URL.
    case productCard(ProductCard)
    /// A help-centre article card that opens the in-app article reader.
    case articleCard(ArticleCard)
    /// A form an agent pushed into the chat for the customer to fill in.
    case form(ChatForm)
    /// A form the customer already submitted, echoed back into the thread.
    case formResponse(FormResponse)
    /// An image, video, audio clip or document — sent either way.
    case attachment(Attachment)
    /// A sentinel this SDK version does not know about, body preserved.
    case unsupported(raw: String)

    /// A human-readable one-liner suitable for a notification or a thread
    /// preview, in the caller's language-neutral form.
    public var previewText: String {
        switch self {
        case .text(let body): return body
        case .productCard(let card): return card.title
        case .articleCard(let card): return card.title
        case .form(let form): return form.name
        case .formResponse(let response): return response.formName
        case .attachment(let attachment): return attachment.previewText
        case .unsupported(let raw): return raw
        }
    }
}

// MARK: - Wire format

extension MessageContent {
    /* The markers, verbatim from the server. `__END__` is a terminator that
       SOME producers append and others do not — chat forms and agent
       attachments carry it, product and article cards do not — so every
       parse strips a trailing one rather than requiring it. */
    enum Sentinel {
        static let productCard = "__PRODUCT_CARD__"
        static let articleCard = "__ARTICLE_CARD__"
        static let chatForm = "__CHAT_FORM__"
        static let formResponse = "__FORM_RESPONSE__"
        static let visitorFile = "__VISITOR_FILE__"
        static let metaAttachment = "__META_ATTACHMENT__"
        static let terminator = "__END__"
    }

    /* Server-side bookkeeping that rides the same field as real content.
       `OFFLINE_EMAIL_SENT::` is written when the offline form mails a
       transcript and the visitor must never see it; `OFFLINE_HANDOFF::` and
       `BOT_FALLBACK::` prefix a message the visitor SHOULD see, so they are
       stripped rather than suppressed. Mirrors widget.js. */
    static let suppressedPrefixes = ["OFFLINE_EMAIL_SENT::"]
    static let strippedPrefixes = ["OFFLINE_HANDOFF::", "BOT_FALLBACK::"]

    /// Parses a raw message body into structured content.
    ///
    /// Returns `nil` for bodies the customer is never meant to see, so the
    /// caller can drop the message entirely rather than render a blank row.
    public static func parse(body: String) -> MessageContent? {
        for prefix in suppressedPrefixes where body.hasPrefix(prefix) { return nil }

        var raw = body
        for prefix in strippedPrefixes where raw.hasPrefix(prefix) {
            raw = String(raw.dropFirst(prefix.count))
        }

        /* Order matters only in that every branch is a prefix test against a
           distinct marker; a body can carry at most one. A malformed JSON
           payload falls through to plain text on purpose — a customer seeing
           a slightly odd message beats a customer seeing nothing, which is
           what a thrown error would produce here. */
        if let json = payload(of: raw, after: Sentinel.productCard) {
            if let card = decode(ProductCard.self, from: json) { return .productCard(card) }
        } else if let json = payload(of: raw, after: Sentinel.articleCard) {
            if let card = decode(ArticleCard.self, from: json) { return .articleCard(card) }
        } else if let json = payload(of: raw, after: Sentinel.chatForm) {
            if let form = decode(ChatForm.self, from: json) { return .form(form) }
        } else if let json = payload(of: raw, after: Sentinel.formResponse) {
            if let response = decode(FormResponse.self, from: json) { return .formResponse(response) }
        } else if let json = payload(of: raw, after: Sentinel.visitorFile) {
            if let file = decode(VisitorFilePayload.self, from: json) { return .attachment(file.attachment) }
        } else if let json = payload(of: raw, after: Sentinel.metaAttachment) {
            if let media = decode(MetaAttachmentPayload.self, from: json) { return .attachment(media.attachment) }
        } else if raw.hasPrefix("__"), raw.contains("__") {
            /* Looks like a sentinel we have never heard of. Surfacing it as
               `unsupported` rather than `text` lets a host app hide it, which
               is the right default for a marker whose whole point is that it
               is not meant to be read as prose. */
            if let marker = unknownSentinel(in: raw) { return .unsupported(raw: marker) }
        }

        return .text(raw)
    }

    /// Strips `sentinel` and any trailing `__END__`, returning the JSON body.
    private static func payload(of raw: String, after sentinel: String) -> String? {
        guard raw.hasPrefix(sentinel) else { return nil }
        var json = String(raw.dropFirst(sentinel.count))
        if json.hasSuffix(Sentinel.terminator) {
            json = String(json.dropLast(Sentinel.terminator.count))
        }
        return json.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func unknownSentinel(in raw: String) -> String? {
        let known = [
            Sentinel.productCard, Sentinel.articleCard, Sentinel.chatForm,
            Sentinel.formResponse, Sentinel.visitorFile, Sentinel.metaAttachment,
        ]
        guard known.allSatisfy({ !raw.hasPrefix($0) }) else { return nil }
        /* `__WHATEVER__…` — a double-underscore token at the very start is
           the shape every Hive sentinel takes. Anything else beginning with
           two underscores is far more likely to be a customer typing them. */
        let body = raw.dropFirst(2)
        guard let end = body.range(of: "__"), !body[body.startIndex..<end.lowerBound].isEmpty,
              body[body.startIndex..<end.lowerBound].allSatisfy({ $0.isUppercase || $0 == "_" })
        else { return nil }
        return raw
    }
}
