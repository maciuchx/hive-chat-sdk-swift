import Foundation

/// The handful of REST calls the chat needs alongside the socket.
///
/// Everything here is unauthenticated by design — the widget key is public
/// (it ships in every storefront's HTML) and these endpoints are the same
/// ones the web widget calls. Nothing tenant-private is reachable with it.
struct HiveAPIClient: Sendable {
    let host: URL
    let widgetKey: String
    let session: URLSession

    init(host: URL, widgetKey: String, session: URLSession = .shared) {
        self.host = host
        self.widgetKey = widgetKey
        self.session = session
    }

    /* The visitor endpoints live at the bare /livechat prefix, which is what
       the web widget calls and what the server leaves open to a widget key.

       This used to be /api/livechat on the assumption that both were mounted
       and that the /api one was the safer bet behind nginx. It is mounted, but
       it sits behind the dashboard's auth: every call from a widget key came
       back 401, so configuration, KB search, transcript and upload all failed
       silently while the socket carried on working. Socket.IO is the genuine
       exception and stays under /api — see SocketIOConnection. */
    private var base: URL { host.appendingPathComponent("livechat") }

    // MARK: - Configuration

    func widgetSettings() async throws -> WidgetSettings {
        let url = base.appendingPathComponent("widget-config").appendingPathComponent(widgetKey)
        let json = try await getJSON(url)
        guard let configuration = WidgetSettings(json: json) else {
            throw HiveChatError.invalidResponse
        }
        return configuration
    }

    // MARK: - Knowledge base

    func searchArticles(query: String) async throws -> [KnowledgeBaseArticle] {
        var components = URLComponents(
            url: base.appendingPathComponent("widget-kb-search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "widget_key", value: widgetKey),
            URLQueryItem(name: "q", value: query),
        ]
        guard let url = components?.url else { throw HiveChatError.invalidResponse }
        let json = try await getJSON(url)
        let rows = json["results"] as? [[String: Any]] ?? []
        return rows.compactMap(KnowledgeBaseArticle.init(json:))
    }

    func article(id: String) async throws -> KnowledgeBaseArticle {
        let url = base.appendingPathComponent("widget-article").appendingPathComponent(id)
        let json = try await getJSON(url)
        guard let article = KnowledgeBaseArticle(json: json) else {
            throw HiveChatError.invalidResponse
        }
        return article
    }

    // MARK: - Transcript

    func emailTranscript(sessionID: String, visitorToken: String, to email: String) async throws {
        let url = base
            .appendingPathComponent("widget-transcript")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("email")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "visitor_token": visitorToken,
            "email": email,
        ])
        _ = try await perform(request)
    }

    // MARK: - Uploads

    /// Uploads a file and returns the payload the caller should then send as
    /// a `__VISITOR_FILE__` message body.
    func upload(data: Data, filename: String, contentType: String) async throws -> UploadedFile {
        /* The server caps uploads at 5MB and answers 413 above it, but a
           phone photo is routinely 8-12MB, so checking here turns a wasted
           upload of several megabytes over cellular into an instant error. */
        guard data.count <= Self.maximumUploadBytes else {
            throw HiveChatError.fileTooLarge(limitBytes: Self.maximumUploadBytes)
        }

        let boundary = "hive-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"widgetKey\"\r\n\r\n")
        append("\(widgetKey)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: base.appendingPathComponent("widget-upload"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        /* An upload over a bad cellular link deserves longer than the
           default read timeout of a JSON GET. */
        request.timeoutInterval = 120

        let json = try await perform(request)
        guard let path = json["url"] as? String else { throw HiveChatError.invalidResponse }
        return UploadedFile(
            url: URL(string: path, relativeTo: host)?.absoluteURL,
            name: json["name"] as? String ?? filename,
            contentType: json["contentType"] as? String ?? contentType
        )
    }

    static let maximumUploadBytes = 5 * 1024 * 1024

    struct UploadedFile: Sendable {
        let url: URL?
        let name: String
        let contentType: String
    }

    // MARK: - Plumbing

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        try await perform(URLRequest(url: url))
    }

    private func perform(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HiveChatError.network(underlying: error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard (200..<300).contains(status) else {
            if status == 413 { throw HiveChatError.fileTooLarge(limitBytes: Self.maximumUploadBytes) }
            throw HiveChatError.server(status: status, message: json?["error"] as? String)
        }
        guard let json else { throw HiveChatError.invalidResponse }
        return json
    }
}

/// Everything the SDK can fail with.
public enum HiveChatError: Error, Equatable, Sendable {
    /// The transport failed — no connectivity, TLS, DNS.
    case network(underlying: Error)
    /// The server answered, unhappily.
    case server(status: Int, message: String?)
    /// The server answered with something we could not read.
    case invalidResponse
    /// The file exceeds the merchant's upload limit.
    case fileTooLarge(limitBytes: Int)
    /// The action needs a live conversation and there isn't one yet — the
    /// customer has to send a message first.
    case noActiveSession

    public static func == (lhs: HiveChatError, rhs: HiveChatError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidResponse, .invalidResponse), (.noActiveSession, .noActiveSession):
            return true
        case let (.server(l, lm), .server(r, rm)):
            return l == r && lm == rm
        case let (.fileTooLarge(l), .fileTooLarge(r)):
            return l == r
        case let (.network(l), .network(r)):
            return (l as NSError) == (r as NSError)
        default:
            return false
        }
    }
}

extension HiveChatError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .network:
            return "We couldn't reach the chat service. Check your connection and try again."
        case .server(_, let message):
            return message ?? "Something went wrong at our end. Please try again."
        case .invalidResponse:
            return "Something went wrong at our end. Please try again."
        case .fileTooLarge(let limit):
            return "That file is too large — the limit is \(limit / 1024 / 1024)MB."
        case .noActiveSession:
            return "Send a message first to start the conversation."
        }
    }
}
