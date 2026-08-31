import Foundation

// MARK: - Product card

/// A product the bot or an agent dropped into the conversation.
public struct ProductCard: Codable, Equatable, Sendable {
    public let title: String
    public let description: String?
    public let imageURL: URL?
    public let buyURL: URL?
    /// Lowest in-stock variant price, decided server-side.
    public let price: Decimal?
    public let variants: [Variant]
    /// Optional line the agent typed alongside the card.
    public let message: String?
    /// Who the card should appear to come from.
    public let agentName: String?

    public struct Variant: Codable, Equatable, Sendable {
        public let title: String
        public let price: Decimal?
        public let sku: String?
        public let available: Bool?
        public let inventoryQuantity: Int?

        enum CodingKeys: String, CodingKey {
            case title, price, sku, available
            case inventoryQuantity = "inventory_quantity"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = (try? c.decode(String.self, forKey: .title)) ?? ""
            price = Self.decodePrice(from: c, key: .price)
            sku = try? c.decode(String.self, forKey: .sku)
            available = try? c.decode(Bool.self, forKey: .available)
            inventoryQuantity = try? c.decode(Int.self, forKey: .inventoryQuantity)
        }

        /* Prices arrive as a JSON number from the bot and as a string from
           the agent product picker ("29.99"). Decoding one shape only meant
           whichever half you did not test dropped the price silently. */
        static func decodePrice(from c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Decimal? {
            if let number = try? c.decode(Double.self, forKey: key) { return Decimal(number) }
            if let string = try? c.decode(String.self, forKey: key) {
                return Decimal(string: string.filter { $0.isNumber || $0 == "." || $0 == "-" })
            }
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case title, description, price, variants, message
        case imageURL = "image_url"
        case buyURL = "buy_url"
        case agentName = "agent_name"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        description = try? c.decode(String.self, forKey: .description)
        imageURL = (try? c.decode(String.self, forKey: .imageURL)).flatMap(URL.init(string:))
        buyURL = (try? c.decode(String.self, forKey: .buyURL)).flatMap(URL.init(string:))
        variants = (try? c.decode([Variant].self, forKey: .variants)) ?? []
        message = try? c.decode(String.self, forKey: .message)
        agentName = try? c.decode(String.self, forKey: .agentName)

        if let direct = Self.decodeTopLevelPrice(from: c) {
            price = direct
        } else {
            /* Older cards carry no top-level price and expect the client to
               take the cheapest variant — the same fallback widget.js does. */
            let candidates = variants.compactMap(\.price).filter { $0 > 0 }
            price = candidates.min()
        }
    }

    private static func decodeTopLevelPrice(from c: KeyedDecodingContainer<CodingKeys>) -> Decimal? {
        if let number = try? c.decode(Double.self, forKey: .price) { return Decimal(number) }
        if let string = try? c.decode(String.self, forKey: .price) {
            return Decimal(string: string.filter { $0.isNumber || $0 == "." || $0 == "-" })
        }
        return nil
    }
}

// MARK: - Article card

/// A knowledge-base article surfaced in the thread.
public struct ArticleCard: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let excerpt: String?
    public let slug: String?
    public let agentName: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, excerpt, slug
        case agentName = "agent_name"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        /* Article ids are strings server-side but a hand-written card can
           carry a number; accepting both saves a support ticket later. */
        if let s = try? c.decode(String.self, forKey: .id) { id = s }
        else if let n = try? c.decode(Int.self, forKey: .id) { id = String(n) }
        else { id = "" }
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        excerpt = try? c.decode(String.self, forKey: .excerpt)
        slug = try? c.decode(String.self, forKey: .slug)
        agentName = try? c.decode(String.self, forKey: .agentName)
    }
}

// MARK: - Forms

/// A form an agent pushed into the chat.
public struct ChatForm: Codable, Equatable, Sendable {
    public let formID: String?
    public let name: String
    public let description: String?
    public let fields: [Field]

    public struct Field: Codable, Equatable, Sendable, Identifiable {
        public var id: String { key }
        public let key: String
        public let label: String
        public let type: FieldType
        public let placeholder: String?
        public let required: Bool
        public let options: [String]

        private enum CodingKeys: String, CodingKey {
            case key, label, type, placeholder, required, options
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = (try? c.decode(String.self, forKey: .key)) ?? ""
            label = (try? c.decode(String.self, forKey: .label)) ?? ""
            type = (try? c.decode(FieldType.self, forKey: .type)) ?? .text
            placeholder = try? c.decode(String.self, forKey: .placeholder)
            required = (try? c.decode(Bool.self, forKey: .required)) ?? false
            options = (try? c.decode([String].self, forKey: .options)) ?? []
        }
    }

    /// The field kinds the dashboard's form builder can produce. Unknown
    /// kinds decode to ``text`` so a new one renders as a plain input rather
    /// than breaking the whole card on an app you cannot update today.
    public enum FieldType: String, Codable, Equatable, Sendable {
        case text, email, number, textarea, select, checkbox

        public init(from decoder: Decoder) throws {
            let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "text"
            self = FieldType(rawValue: raw) ?? .text
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, fields
        case formID = "form_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formID = try? c.decode(String.self, forKey: .formID)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Quick form"
        description = try? c.decode(String.self, forKey: .description)
        fields = (try? c.decode([Field].self, forKey: .fields)) ?? []
    }
}

/// A submitted form, as it appears in the thread afterwards.
public struct FormResponse: Codable, Equatable, Sendable {
    public let formID: String?
    public let formName: String
    public let entries: [Entry]

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: String { key }
        public let key: String
        public let label: String
        public let value: String
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case formID = "form_id"
        case formName = "form_name"
    }

    public init(formID: String?, formName: String, entries: [Entry]) {
        self.formID = formID
        self.formName = formName
        self.entries = entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formID = try? c.decode(String.self, forKey: .formID)
        formName = (try? c.decode(String.self, forKey: .formName)) ?? "Form"
        entries = (try? c.decode([Entry].self, forKey: .entries)) ?? []
    }
}

// MARK: - Attachments

/// A file in the conversation, sent by either side.
public struct Attachment: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case image, video, audio, file
    }

    public let kind: Kind
    /// Absolute URL. Server payloads are host-relative (`/uploads/livechat/…`)
    /// and are resolved against the configured host before you see them.
    public let url: URL?
    public let name: String
    public let contentType: String?
    /// True while a local file is still uploading — set by the SDK on the
    /// optimistic echo, never present on a server message.
    public let isUploading: Bool

    public init(kind: Kind, url: URL?, name: String, contentType: String?, isUploading: Bool = false) {
        self.kind = kind
        self.url = url
        self.name = name
        self.contentType = contentType
        self.isUploading = isUploading
    }

    var previewText: String {
        switch kind {
        case .image: return "📷 Photo"
        case .video: return "🎥 Video"
        case .audio: return "🎤 Audio"
        case .file: return "📄 \(name)"
        }
    }

    static func kind(forContentType type: String?) -> Kind {
        guard let type = type?.lowercased() else { return .file }
        if type.hasPrefix("image/") { return .image }
        if type.hasPrefix("video/") { return .video }
        if type.hasPrefix("audio/") { return .audio }
        return .file
    }
}

/// `__VISITOR_FILE__{"url":…,"contentType":…,"name":…}` — what the customer sent.
struct VisitorFilePayload: Codable {
    let url: String?
    let contentType: String?
    let name: String?
    let uploading: Bool?

    var attachment: Attachment {
        Attachment(
            kind: Attachment.kind(forContentType: contentType),
            url: url.flatMap(URL.init(string:)),
            name: name ?? "file",
            contentType: contentType,
            isUploading: uploading ?? false
        )
    }
}

/// `__META_ATTACHMENT__{"type":"image","url":…,"name":…}__END__` — what an
/// agent sent, and what inbound WhatsApp/Instagram media is normalised to.
struct MetaAttachmentPayload: Codable {
    let type: String?
    let url: String?
    let name: String?

    var attachment: Attachment {
        Attachment(
            kind: Attachment.Kind(rawValue: type ?? "file") ?? .file,
            url: url.flatMap(URL.init(string:)),
            name: name ?? "file",
            contentType: nil
        )
    }
}
