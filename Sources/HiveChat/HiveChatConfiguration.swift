import Foundation

/// How the SDK should talk to Hive.
public struct HiveChatConfiguration: Sendable {
    /// The merchant's public widget key, from Settings → Live Chat in the
    /// Hive dashboard. Safe to ship in your app: it is already public in
    /// every storefront's HTML, and grants nothing beyond starting a chat.
    public let widgetKey: String

    /// Where Hive lives. Only change this if you are on a dedicated host.
    public let host: URL

    /// Where the visitor token — the id that ties this device to its
    /// conversation history — is kept between launches.
    public let tokenStore: VisitorTokenStore

    /// Whether to mark incoming messages read automatically as they arrive.
    /// Leave this off (the default) and call ``HiveChat/markRead()`` when the
    /// chat is genuinely on screen; otherwise the customer's read receipts
    /// tell the agent they have seen messages that arrived while the app was
    /// in their pocket.
    public let marksMessagesReadAutomatically: Bool

    /// Emits protocol traffic to the console. Never enable in a release
    /// build: message bodies are customer data.
    public let isDebugLoggingEnabled: Bool

    public init(
        widgetKey: String,
        host: URL = URL(string: "https://hivehd.app")!,
        tokenStore: VisitorTokenStore = .userDefaults(),
        marksMessagesReadAutomatically: Bool = false,
        isDebugLoggingEnabled: Bool = false
    ) {
        self.widgetKey = widgetKey
        self.host = host
        self.tokenStore = tokenStore
        self.marksMessagesReadAutomatically = marksMessagesReadAutomatically
        self.isDebugLoggingEnabled = isDebugLoggingEnabled
    }
}

/// Persistence for the visitor token.
///
/// The token is what lets a customer close the app, come back tomorrow and
/// find the conversation still there — the server keys chat history off it.
/// Lose it and the customer silently starts a fresh thread while the agent
/// still sees the old one.
///
/// The default keeps it in `UserDefaults`, which means it dies with the app
/// on uninstall. That is the honest default: Keychain entries survive
/// reinstall, which would hand a conversation to whoever installs the app
/// next on a shared device. Supply ``custom(load:save:)`` if you would rather
/// put it in the Keychain, or tie it to your own signed-in user record.
public struct VisitorTokenStore: Sendable {
    let load: @Sendable () -> String?
    let save: @Sendable (String) -> Void

    public init(load: @escaping @Sendable () -> String?, save: @escaping @Sendable (String) -> Void) {
        self.load = load
        self.save = save
    }

    public static func custom(
        load: @escaping @Sendable () -> String?,
        save: @escaping @Sendable (String) -> Void
    ) -> VisitorTokenStore {
        VisitorTokenStore(load: load, save: save)
    }

    public static func userDefaults(
        key: String = "app.hivehd.chat.visitorToken",
        suiteName: String? = nil
    ) -> VisitorTokenStore {
        /* Held by name rather than by instance: UserDefaults is not Sendable,
           and resolving it inside the closure keeps the store usable from the
           socket queue without smuggling a non-Sendable capture across it. */
        VisitorTokenStore(
            load: { Self.defaults(suiteName).string(forKey: key) },
            save: { Self.defaults(suiteName).set($0, forKey: key) }
        )
    }

    private static func defaults(_ suiteName: String?) -> UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// Keeps the token only for the lifetime of the process. Every launch
    /// starts a brand-new conversation — useful in tests and for kiosk-style
    /// apps where one device is used by many people.
    public static func ephemeral() -> VisitorTokenStore {
        let storage = EphemeralStorage()
        return VisitorTokenStore(load: { storage.value }, save: { storage.value = $0 })
    }

    private final class EphemeralStorage: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}
