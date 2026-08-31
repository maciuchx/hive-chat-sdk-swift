import XCTest
@testable import HiveChat

/// `HiveChat` is main-actor bound because views bind to its state, but it must
/// be *constructible* from anywhere: a `ViewModel.init`, an `App` struct's
/// property initialiser and an `AppDelegate` are all nonisolated, and those
/// are the three most natural places to build one.
///
/// This whole file is deliberately nonisolated. If the initialiser ever
/// regains main-actor isolation, these stop compiling — which is the point.
/// A runtime assertion could not catch it; only the compiler can.
final class ConstructionTests: XCTestCase {

    func testConstructibleFromNonisolatedContext() {
        let chat = HiveChat(configuration: .init(
            widgetKey: "hv_a1b2c3d4e5f6a1b2c3d4e5f6",
            tokenStore: .ephemeral()
        ))
        XCTAssertNotNil(chat)
    }

    /// The shape a host app's view model actually takes.
    func testConstructibleInsideANonisolatedType() {
        final class SupportViewModel {
            let chat: HiveChat
            init() {
                chat = HiveChat(configuration: .init(
                    widgetKey: "hv_a1b2c3d4e5f6a1b2c3d4e5f6",
                    tokenStore: .ephemeral()
                ))
            }
        }
        XCTAssertNotNil(SupportViewModel().chat)
    }

    /// A visitor token is minted on first run and reused thereafter — losing it
    /// silently starts the customer a new conversation while the agent is still
    /// looking at the old one.
    func testVisitorTokenIsMintedOnceAndReused() {
        var stored: String?
        let store = VisitorTokenStore(
            load: { stored },
            save: { stored = $0 }
        )

        _ = HiveChat(configuration: .init(widgetKey: "hv_test", tokenStore: store))
        let first = stored
        XCTAssertNotNil(first)
        XCTAssertTrue(first?.hasPrefix("v_") == true, "token should match the web widget's shape")

        _ = HiveChat(configuration: .init(widgetKey: "hv_test", tokenStore: store))
        XCTAssertEqual(stored, first, "a second client must adopt the stored token, not mint a new one")
    }
}
