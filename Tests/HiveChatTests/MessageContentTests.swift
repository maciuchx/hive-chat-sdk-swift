import XCTest
@testable import HiveChat

/// The sentinel format is a contract with a server this SDK cannot change and
/// a shipped app cannot re-release quickly, so every shape below is copied
/// from what the live server actually emits rather than from what would be
/// convenient to parse.
final class MessageContentTests: XCTestCase {

    func testPlainText() {
        XCTAssertEqual(MessageContent.parse(body: "Where is my order?"), .text("Where is my order?"))
    }

    func testProductCard() throws {
        let body = #"""
        __PRODUCT_CARD__{"title":"Slim Fit Suit","image_url":"https://cdn.example/suit.jpg","buy_url":"https://shop.example/suit","price":129.99,"agent_name":"Buzz"}
        """#
        guard case .productCard(let card)? = MessageContent.parse(body: body) else {
            return XCTFail("expected a product card")
        }
        XCTAssertEqual(card.title, "Slim Fit Suit")
        XCTAssertEqual(card.price, Decimal(129.99))
        XCTAssertEqual(card.buyURL?.absoluteString, "https://shop.example/suit")
        XCTAssertEqual(card.agentName, "Buzz")
    }

    /// The agent product picker sends prices as strings; the bot sends
    /// numbers. Both have to land in the same field.
    func testProductCardAcceptsStringPrices() throws {
        let body = #"__PRODUCT_CARD__{"title":"Tie","variants":[{"title":"Navy","price":"19.50"}]}"#
        guard case .productCard(let card)? = MessageContent.parse(body: body) else {
            return XCTFail("expected a product card")
        }
        XCTAssertEqual(card.variants.first?.price, Decimal(string: "19.50"))
        /* No top-level price, so it must fall back to the cheapest variant —
           the same rule widget.js applies. */
        XCTAssertEqual(card.price, Decimal(string: "19.50"))
    }

    func testArticleCard() throws {
        let body = #"__ARTICLE_CARD__{"id":"kb_123","title":"Returns policy","excerpt":"You have 30 days."}"#
        guard case .articleCard(let card)? = MessageContent.parse(body: body) else {
            return XCTFail("expected an article card")
        }
        XCTAssertEqual(card.id, "kb_123")
        XCTAssertEqual(card.title, "Returns policy")
    }

    /// Forms carry the `__END__` terminator; cards do not. Both must parse.
    func testChatFormWithTerminator() throws {
        let body = #"""
        __CHAT_FORM__{"form_id":"f_1","name":"Return request","fields":[{"key":"order","label":"Order number","type":"text","required":true},{"key":"reason","label":"Why?","type":"textarea"}]}__END__
        """#
        guard case .form(let form)? = MessageContent.parse(body: body) else {
            return XCTFail("expected a form")
        }
        XCTAssertEqual(form.name, "Return request")
        XCTAssertEqual(form.fields.count, 2)
        XCTAssertEqual(form.fields[0].type, .text)
        XCTAssertTrue(form.fields[0].required)
        XCTAssertEqual(form.fields[1].type, .textarea)
    }

    /// A field type invented after this SDK shipped must degrade to a text
    /// input, not break the whole card.
    func testUnknownFormFieldTypeFallsBackToText() throws {
        let body = #"__CHAT_FORM__{"name":"F","fields":[{"key":"k","label":"L","type":"colour-picker"}]}__END__"#
        guard case .form(let form)? = MessageContent.parse(body: body) else {
            return XCTFail("expected a form")
        }
        XCTAssertEqual(form.fields.first?.type, .text)
    }

    func testVisitorFileAttachment() throws {
        let body = #"__VISITOR_FILE__{"url":"https://hivehd.app/uploads/visitor/a.jpg","contentType":"image/jpeg","name":"a.jpg"}"#
        guard case .attachment(let attachment)? = MessageContent.parse(body: body) else {
            return XCTFail("expected an attachment")
        }
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.name, "a.jpg")
    }

    /// Agent-sent files arrive as `__META_ATTACHMENT__` with a host-relative
    /// URL — the one shape the web widget does NOT render today.
    func testAgentAttachmentResolvesRelativeURL() throws {
        let body = #"__META_ATTACHMENT__{"type":"image","url":"/uploads/livechat/x.png","name":"x.png"}__END__"#
        guard case .attachment(let attachment)? = MessageContent.parse(body: body) else {
            return XCTFail("expected an attachment")
        }
        XCTAssertEqual(attachment.kind, .image)

        let host = URL(string: "https://hivehd.app")!
        guard case .attachment(let resolved) = MessageContent.attachment(attachment).resolvingRelativeURLs(against: host) else {
            return XCTFail("expected an attachment")
        }
        XCTAssertEqual(resolved.url?.absoluteString, "https://hivehd.app/uploads/livechat/x.png")
    }

    /// Bookkeeping the customer must never see.
    func testSuppressedPrefixReturnsNil() {
        XCTAssertNil(MessageContent.parse(body: "OFFLINE_EMAIL_SENT::sent to a@b.com"))
    }

    /// Bookkeeping the customer SHOULD see, minus the marker.
    func testStrippedPrefixKeepsBody() {
        XCTAssertEqual(
            MessageContent.parse(body: "OFFLINE_HANDOFF::We'll email you back."),
            .text("We'll email you back.")
        )
    }

    /// A sentinel from a newer server must not be rendered as prose.
    func testUnknownSentinelIsNotShownAsText() {
        guard case .unsupported? = MessageContent.parse(body: #"__ORDER_TIMELINE__{"id":1}"#) else {
            return XCTFail("expected unsupported")
        }
    }

    /// …but a customer who types underscores is writing text, not a sentinel.
    func testUnderscoresInProseStayText() {
        XCTAssertEqual(MessageContent.parse(body: "__hello__ there"), .text("__hello__ there"))
    }

    /// Malformed JSON must degrade to text rather than losing the message.
    func testMalformedSentinelJSONFallsBackToText() {
        let body = "__PRODUCT_CARD__{not json"
        guard case .text? = MessageContent.parse(body: body) else {
            return XCTFail("expected text fallback")
        }
    }
}
