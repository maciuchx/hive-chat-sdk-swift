import XCTest
@testable import HiveChat

final class ChatMessageTests: XCTestCase {
    private let host = URL(string: "https://hivehd.app")!

    /// The bot is stored as its own sender type but delivered to customers as
    /// an agent. A thread that distinguished them would leak which replies
    /// were automated, so both must map to `.agent`.
    func testBotIsPresentedAsAgent() {
        let message = ChatMessage.from(
            wire: ["id": "m1", "sender_type": "bot", "body": "Hi", "created_at": "2026-08-31T10:00:00.000Z"],
            host: host
        )
        XCTAssertEqual(message?.sender, .agent)
    }

    /// The socket path sends fractional seconds; the restore path (straight
    /// from MySQL) does not. One formatter cannot read both, and getting it
    /// wrong stamps every restored message 1970 and sorts the thread inside
    /// out.
    func testParsesBothTimestampShapes() {
        let withFraction = ChatMessage.date(from: "2026-08-31T10:00:00.123Z")
        let withoutFraction = ChatMessage.date(from: "2026-08-31T10:00:00Z")
        XCTAssertEqual(withFraction.timeIntervalSince1970, 1788170400.123, accuracy: 0.01)
        XCTAssertEqual(withoutFraction.timeIntervalSince1970, 1788170400, accuracy: 0.01)
    }

    func testReactionsDecodeWithMineFlag() {
        let message = ChatMessage.from(
            wire: [
                "id": "m1", "sender_type": "agent", "body": "Hi",
                "reactions": [["emoji": "👍", "count": 2, "mine": true]],
            ],
            host: host
        )
        XCTAssertEqual(message?.reactions.first?.emoji, "👍")
        XCTAssertEqual(message?.reactions.first?.count, 2)
        XCTAssertEqual(message?.reactions.first?.isMine, true)
    }

    func testSuppressedBodyProducesNoMessage() {
        let message = ChatMessage.from(
            wire: ["id": "m1", "sender_type": "system", "body": "OFFLINE_EMAIL_SENT::x"],
            host: host
        )
        XCTAssertNil(message)
    }
}
