import XCTest
@testable import HiveChat

/// End-to-end checks against a real Hive server.
///
/// Skipped unless `HIVE_WIDGET_KEY` is set, because they need a real widget
/// and CI has none:
///
/// ```sh
/// HIVE_WIDGET_KEY=wk_live_… swift test --filter LiveIntegrationTests
/// ```
///
/// `testSocketHandshake` connects as a visitor. That is not free of side
/// effects — the merchant's agents see a visitor appear in their presence
/// panel — but it creates no conversation and no ticket, because the server
/// only opens a session on the first message. Nothing here sends one.
final class LiveIntegrationTests: XCTestCase {

    private var widgetKey: String? { ProcessInfo.processInfo.environment["HIVE_WIDGET_KEY"] }

    private var host: URL {
        ProcessInfo.processInfo.environment["HIVE_HOST"].flatMap(URL.init(string:))
            ?? URL(string: "https://hivehd.app")!
    }

    func testWidgetSettingsLoad() async throws {
        guard let widgetKey else { throw XCTSkip("set HIVE_WIDGET_KEY to run") }
        let api = HiveAPIClient(host: host, widgetKey: widgetKey)
        let settings = try await api.widgetSettings()

        XCTAssertTrue(settings.isEnabled, "widget is disabled — pick an active key")
        XCTAssertFalse(settings.welcomeMessage.isEmpty)
        XCTAssertFalse(settings.brandColorHex.isEmpty)
        print("""
        ✓ \(settings.storeName)
          online: \(settings.isOnline)  bot: \(settings.botName)
          brand: \(settings.brandColorHex)  prechat: \(settings.isPrechatRequired)
          featured articles: \(settings.featuredArticles.count)
        """)
    }

    func testSocketHandshake() async throws {
        guard let widgetKey else { throw XCTSkip("set HIVE_WIDGET_KEY to run") }

        let chat = await HiveChat(configuration: .init(
            widgetKey: widgetKey,
            host: host,
            /* Ephemeral so a test run never adopts — or leaves behind — the
               conversation token of a real person on this machine. */
            tokenStore: .ephemeral(),
            isDebugLoggingEnabled: true
        ))

        await chat.connect()

        let connected = expectation(description: "socket connects and the server answers")
        let watcher = Task { @MainActor in
            for _ in 0..<100 {
                /* chat:restore is the definitive "handshake complete" signal:
                   the server always emits it, with a null session id when
                   there is nothing to resume. */
                if chat.connectionState == .connected {
                    connected.fulfill()
                    return
                }
                if case .failed(let reason) = chat.connectionState {
                    XCTFail("server refused the connection: \(reason)")
                    connected.fulfill()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTFail("never connected")
            connected.fulfill()
        }

        await fulfillment(of: [connected], timeout: 15)
        watcher.cancel()
        await chat.disconnect()
    }
}
