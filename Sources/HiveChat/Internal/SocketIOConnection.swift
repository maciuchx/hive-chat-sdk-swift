import Foundation

/// A minimal Socket.IO v4 / Engine.IO v4 client over `URLSessionWebSocketTask`.
///
/// Deliberately dependency-free. The alternative — pulling in
/// socket.io-client-swift — would put a large, sporadically-maintained
/// dependency in every host app for a protocol whose useful subset is one
/// file: OPEN → namespace CONNECT with auth → EVENT frames both ways, plus
/// ping/pong and reconnection.
///
/// Not implemented, because the Hive visitor namespace never uses them:
/// binary attachments (files go over HTTP), namespace multiplexing (one
/// namespace per connection), and compression.
final class SocketIOConnection: NSObject, @unchecked Sendable {
    typealias EventHandler = @Sendable (String, [Any]) -> Void
    typealias StateHandler = @Sendable (ConnectionState) -> Void

    private let endpoint: URL
    private let namespace: String
    private let queue = DispatchQueue(label: "app.hivehd.chat.socket")

    /// Rebuilt on every reconnect, so a token adopted mid-session (device
    /// handoff) or a name captured by a pre-chat form rides the next
    /// handshake without the caller having to reconnect by hand.
    private let authProvider: @Sendable () -> [String: Any]

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var isRunning = false
    private var reconnectAttempt = 0
    private var pendingReconnect: DispatchWorkItem?

    /* Socket.IO acks are a request/response pair keyed by an integer the
       client picks. `chat:handoff:create` is the only visitor event that
       uses one today, but a shipped SDK cannot add the plumbing later
       without a release, so it goes in now. */
    private var ackCounter = 0
    private var pendingAcks: [Int: @Sendable ([Any]) -> Void] = [:]

    var onEvent: EventHandler?
    var onStateChange: StateHandler?

    init(host: URL, namespace: String, authProvider: @escaping @Sendable () -> [String: Any]) {
        /* The server mounts Socket.IO under /api/socket.io/ (moved there so
           nginx's existing /api proxy carries the upgrade). EIO=4 and
           transport=websocket are pinned: we never negotiate long-polling,
           because a native client has no reason to fall back to it and the
           polling handshake would double the code in this file. */
        var components = URLComponents(url: host, resolvingAgainstBaseURL: false)
        components?.scheme = (host.scheme == "http") ? "ws" : "wss"
        components?.path = "/api/socket.io/"
        components?.queryItems = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "websocket"),
        ]
        self.endpoint = components?.url ?? host
        self.namespace = namespace
        self.authProvider = authProvider
        super.init()
    }

    // MARK: - Lifecycle

    func connect() {
        queue.async {
            guard !self.isRunning else { return }
            self.isRunning = true
            self.reconnectAttempt = 0
            self.open()
        }
    }

    func disconnect() {
        queue.async {
            self.isRunning = false
            self.pendingReconnect?.cancel()
            self.pendingReconnect = nil
            /* Send the Socket.IO DISCONNECT frame before tearing down the
               socket. Without it the server only learns we are gone when the
               transport times out, and the visitor's presence row sits
               "online" in the agent panel for a minute after the app quits. */
            self.write("41\(self.namespace)")
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.emitState(.disconnected)
        }
    }

    private func open() {
        emitState(reconnectAttempt == 0 ? .connecting : .reconnecting)
        let configuration = URLSessionConfiguration.default
        /* A chat socket that is idle for minutes is normal and must not be
           reaped; the server's own ping keeps it honest. */
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration)
        self.session = session
        let task = session.webSocketTask(with: endpoint)
        self.task = task
        task.resume()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .failure:
                    self.handleClose()
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleFrame(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.handleFrame(text) }
                    @unknown default:
                        break
                    }
                    self.receive()
                }
            }
        }
    }

    private func write(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    // MARK: - Framing

    private func handleFrame(_ text: String) {
        guard let type = text.first else { return }
        switch type {
        case "0":  // Engine.IO OPEN
            sendNamespaceConnect()
        case "2":  // Engine.IO PING
            write("3")
        case "4":  // Engine.IO MESSAGE — a Socket.IO packet
            handlePacket(String(text.dropFirst()))
        default:
            break
        }
    }

    private func sendNamespaceConnect() {
        let auth = authProvider()
        let json = (try? JSONSerialization.data(withJSONObject: auth))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        write("40\(namespace),\(json)")
    }

    private func handlePacket(_ packet: String) {
        guard let type = packet.first else { return }
        let rest = String(packet.dropFirst())

        switch type {
        case "0":  // CONNECT acknowledged
            reconnectAttempt = 0
            emitState(.connected)
        case "2":  // EVENT
            let (ackID, payload) = splitPacket(rest)
            dispatchEvent(payload, ackID: ackID)
        case "3":  // ACK — a reply to something we sent
            let (ackID, payload) = splitPacket(rest)
            guard let ackID, let handler = pendingAcks.removeValue(forKey: ackID) else { return }
            handler(decodeArray(payload) ?? [])
        case "4":  // CONNECT_ERROR — auth rejected, bad namespace
            let (_, payload) = splitPacket(rest)
            emitState(.failed(reason: connectErrorMessage(payload)))
            /* The server disconnects us after this. Retrying on a loop
               would hammer it with a handshake it has already refused —
               an invalid widget key does not become valid by asking again. */
            isRunning = false
        default:
            break
        }
    }

    /// Strips the optional `/namespace,` prefix and leading ack id from a
    /// packet body, returning the ack id (if any) and the JSON array.
    private func splitPacket(_ body: String) -> (ackID: Int?, payload: String) {
        var rest = body
        if rest.hasPrefix("/"), let comma = rest.firstIndex(of: ",") {
            rest = String(rest[rest.index(after: comma)...])
        }
        /* Whatever digits sit between the namespace and the opening bracket
           are the ack id. */
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty {
            return (Int(digits), String(rest.dropFirst(digits.count)))
        }
        return (nil, rest)
    }

    private func dispatchEvent(_ payload: String, ackID: Int?) {
        guard let array = decodeArray(payload), let name = array.first as? String else { return }
        let arguments = Array(array.dropFirst())
        onEvent?(name, arguments)
        /* The visitor namespace never asks US to ack anything today. If it
           starts to, an unanswered ack leaks a callback server-side, so
           answer emptily rather than silently ignoring it. */
        if let ackID { write("43\(namespace),\(ackID)[]") }
    }

    private func decodeArray(_ payload: String) -> [Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [Any]
    }

    private func connectErrorMessage(_ payload: String) -> String {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String
        else { return "The chat server refused the connection." }
        return message
    }

    // MARK: - Emit

    func emit(_ event: String, _ payload: [String: Any] = [:]) {
        queue.async {
            guard let json = self.encode([event, payload]) else { return }
            self.write("42\(self.namespace),\(json)")
        }
    }

    func emit(_ event: String, _ payload: [String: Any] = [:], ack: @escaping @Sendable ([Any]) -> Void) {
        queue.async {
            self.ackCounter += 1
            let id = self.ackCounter
            self.pendingAcks[id] = ack
            guard let json = self.encode([event, payload]) else {
                self.pendingAcks.removeValue(forKey: id)
                return
            }
            self.write("42\(self.namespace),\(id)\(json)")

            /* An ack the server never sends would pin the callback (and
               whatever it captures) forever. Five seconds is generous for a
               round trip that only mints a code. */
            self.queue.asyncAfter(deadline: .now() + 5) {
                guard let handler = self.pendingAcks.removeValue(forKey: id) else { return }
                handler([])
            }
        }
    }

    private func encode(_ value: [Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Reconnection

    private func handleClose() {
        task = nil
        for (_, handler) in pendingAcks { handler([]) }
        pendingAcks.removeAll()

        guard isRunning else {
            emitState(.disconnected)
            return
        }

        /* Exponential backoff with jitter, capped at 30s. The jitter is not
           decoration: a Cloudflare edge drop or a server restart knocks every
           connected client offline at the same instant, and a fixed delay
           marches them all back in lockstep. */
        reconnectAttempt += 1
        let base = min(pow(2.0, Double(reconnectAttempt - 1)), 30)
        let delay = min(base + Double.random(in: 0...1), 30)
        emitState(.reconnecting)

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.open()
        }
        pendingReconnect = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Drops the current socket and reconnects immediately, skipping backoff.
    /// Called when the app returns to the foreground: iOS suspends the
    /// WebSocket on background and the client often does not learn it is dead
    /// until it tries to write, which would leave the customer looking at a
    /// thread that silently receives nothing.
    func reconnectNow() {
        queue.async {
            guard self.isRunning else { return }
            self.pendingReconnect?.cancel()
            self.reconnectAttempt = 0
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.open()
        }
    }

    private func emitState(_ state: ConnectionState) {
        onStateChange?(state)
    }
}

/// Where the SDK's connection to Hive currently stands.
public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    /// The server refused us and retrying will not help — a bad or disabled
    /// widget key, most likely. Carries a message safe to log, not to show.
    case failed(reason: String)
}
