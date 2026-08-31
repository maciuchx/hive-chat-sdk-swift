import Foundation

/// The merchant's widget settings, fetched from
/// `GET /livechat/widget-config/:widgetKey`.
///
/// The same document drives the web widget, so it carries a lot of
/// browser-specific styling (bubble offsets, launcher position, URL
/// visibility rules) that a native app has no use for. Only the fields that
/// mean something on a phone are surfaced here; the rest are ignored rather
/// than mapped into properties nobody can act on.
public struct WidgetSettings: Equatable, Sendable {
    /// False when the merchant has switched the widget off entirely. The
    /// SDK will refuse to connect and you should hide your chat entry point.
    public let isEnabled: Bool
    public let welcomeMessage: String
    /// Shown when the team is offline and the customer is asked to leave
    /// their email instead.
    public let offlineMessage: String
    public let placeholderText: String
    public let storeName: String
    /// Brand colour, as a hex string like `#6C3CE1`.
    public let brandColorHex: String
    /// Second stop of the brand gradient, when the merchant set one.
    public let gradientEndHex: String?
    public let agentName: String
    public let agentRole: String
    public let botName: String
    /// Emoji the merchant uses as their chat avatar.
    public let logoEmoji: String
    /// Whether at least one agent is online, in-hours and reachable right now.
    public let isOnline: Bool
    /// Whether the merchant asks for name and email before the chat starts.
    public let isPrechatRequired: Bool
    /// Whether a consent checkbox must be ticked, and its exact wording.
    public let isConsentRequired: Bool
    public let consentText: String?
    /// Articles the merchant featured, for a help view above the chat.
    public let featuredArticles: [KnowledgeBaseArticle]

    init?(json: [String: Any]) {
        /* A disabled widget answers with `{ widget_enabled: false }` and
           nothing else, so every other field has to be optional-with-default
           or this initialiser fails on the one response that most needs to
           be understood. */
        isEnabled = json["widget_enabled"] as? Bool ?? true
        welcomeMessage = json["welcome_message"] as? String ?? "Hi! How can we help?"
        offlineMessage = json["offline_message"] as? String ?? "Leave a message and we'll reply by email."
        placeholderText = json["placeholder_text"] as? String ?? "Type your message..."
        storeName = json["store_name"] as? String ?? ""
        brandColorHex = json["widget_color"] as? String ?? "#6C3CE1"
        gradientEndHex = json["gradient_end"] as? String
        agentName = json["agent_name"] as? String ?? "Support"
        agentRole = json["agent_role"] as? String ?? ""
        botName = json["bot_name"] as? String ?? "Assistant"
        logoEmoji = json["logo_emoji"] as? String ?? "💬"
        isOnline = json["is_online"] as? Bool ?? false
        isPrechatRequired = json["prechat_enabled"] as? Bool ?? false
        isConsentRequired = json["consent_required"] as? Bool ?? false
        consentText = json["consent_text"] as? String
        featuredArticles = (json["featured_kb"] as? [[String: Any]] ?? [])
            .compactMap(KnowledgeBaseArticle.init(json:))
    }
}

/// A help-centre article.
public struct KnowledgeBaseArticle: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let excerpt: String?
    public let slug: String?
    /// Rendered article body as HTML. Only populated by
    /// ``HiveChat/article(id:)`` — list and search endpoints return
    /// excerpts only.
    public let bodyHTML: String?

    init?(json: [String: Any]) {
        if let s = json["id"] as? String { id = s }
        else if let n = json["id"] as? Int { id = String(n) }
        else { return nil }
        title = json["title"] as? String ?? ""
        excerpt = json["excerpt"] as? String
        slug = json["slug"] as? String
        /* `html` is what GET /widget-article/:id calls it; the field is
           simply absent on list and search rows. */
        bodyHTML = json["html"] as? String
    }
}
