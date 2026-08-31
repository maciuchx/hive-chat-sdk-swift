# HiveChat for Swift

Native live chat for iOS apps, powered by [Hive](https://hivehd.app). Connects
your customers to the same inbox, bot and agents as the web chat widget on
your storefront — no WebView.

```swift
let chat = HiveChat(configuration: .init(widgetKey: "hv_a1b2c3d4e5f6a1b2c3d4e5f6"))
chat.identify(name: "Alex Doe", email: "alex@example.com")

NavigationLink("Chat with us") {
    HiveChatView(chat: chat)
}
```

- **Native, not a WebView.** SwiftUI throughout — real scroll physics, real
  keyboard handling, your fonts and colours.
- **Bring your own UI, or don't.** `HiveChatView` drops straight in; or take
  the `HiveChat` target alone and bind your own views to its published state.
- **No dependencies.** Socket.IO, multipart uploads and the message format are
  all implemented in the package. Nothing to audit but this.
- **Rich content included.** Product cards, help articles, agent-pushed forms,
  photos, reactions, read receipts, typing indicators, CSAT.

## Requirements

| | |
|---|---|
| iOS | 16.0+ |
| macOS | 14.0+ |
| visionOS | 1.0+ |
| Swift | 5.9+ |
| Xcode | 15+ |

The `HiveChat` core target has no SwiftUI dependency. `HiveChatUI` is where
the views live, and it is a separate product you can leave out.

## Installation

### Swift Package Manager (Xcode)

**File → Add Package Dependencies…** and paste:

```
https://github.com/maciuchx/hive-chat-sdk-swift
```

### Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/maciuchx/hive-chat-sdk-swift", from: "0.1.0")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "HiveChat", package: "hive-chat-sdk-swift"),
        .product(name: "HiveChatUI", package: "hive-chat-sdk-swift"), // optional
    ])
]
```

## Getting your widget key

Hive dashboard → **Settings → Live Chat → your widget**, or the **Mobile app →
Native SDK** panel on that widget, which shows the key next to ready-made
snippets. Keys are `hv_` followed by 24 hex characters, e.g.
`hv_a1b2c3d4e5f6a1b2c3d4e5f6`.

It is safe to ship in your app binary. The same key is already public in the
HTML of every storefront running the web widget, and it grants exactly one
capability: starting a conversation. It cannot read other conversations, and
it carries no tenant data.

## Usage

### Create the chat once, keep it alive

```swift
@main
struct MyApp: App {
    /* Own the HiveChat instance above your view hierarchy. A chat recreated
       every time the screen appears drops the socket, loses the unread count
       and starts a new thread each time. */
    @StateObject private var chat = HiveChat(configuration: .init(
        widgetKey: "hv_a1b2c3d4e5f6a1b2c3d4e5f6"
    ))

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(chat)
        }
    }
}
```

### Identify the customer

Call before `start()` when you already know who they are — a signed-in app
should. The agent then sees a name instead of "Visitor", and the conversation
threads onto that customer's record and order history.

```swift
chat.identify(name: customer.name, email: customer.email)
```

> **Identity is not verified.** Hive currently takes whatever your app sends at
> face value. Treat it as a display convenience, not proof of who the customer
> is, and do not put anything in it you would not show a stranger. Signed
> identity is on the roadmap — see [PROTOCOL.md](PROTOCOL.md#identity).

### Show the chat

```swift
struct SupportScreen: View {
    @EnvironmentObject var chat: HiveChat

    var body: some View {
        HiveChatView(chat: chat)
    }
}
```

`HiveChatView` loads the merchant's settings on first appearance, connects,
and matches their brand colour automatically.

### Badge the entry point

```swift
Button("Support") { showChat = true }
    .badge(chat.unreadCount)
    .task { await chat.start() }   // connect at launch so messages arrive
```

`unreadCount` clears when you call `chat.markRead()` — `HiveChatView` does
that when it appears. Leave `marksMessagesReadAutomatically` off (the default)
unless you want read receipts sent for messages that arrived while the app was
in someone's pocket.

### Headless

Everything `HiveChatView` uses is public and observable:

```swift
@ObservedObject var chat: HiveChat

chat.messages            // [ChatMessage], oldest first, incl. unsent echoes
chat.connectionState     // .connecting / .connected / .reconnecting / .failed
chat.widgetSettings      // branding, welcome text, whether the team is online
chat.isAgentTyping       // + typingAgentName
chat.isTeamOnline
chat.queuePosition       // 1-based while waiting for a human
chat.unreadCount
chat.offlinePrompt       // set when the team is away — ask for an email
chat.satisfactionRequest // set when the server asks for a rating
chat.hasEnded
chat.linkPreviews        // [messageID: [LinkPreview]]
chat.sessionID
```

```swift
chat.send("Where is my order?")
try await chat.send(fileData: jpeg, filename: "photo.jpg", contentType: "image/jpeg")
chat.setTyping(true)
chat.markRead()
chat.requestHuman()
chat.toggleReaction("👍", on: message.id)
chat.submit(form: form, values: ["order": "TC-10432"])
chat.submitCSAT(rating: 5, comment: "Fast!")
chat.provideEmail("alex@example.com")
chat.endChat()

let articles = try await chat.searchArticles(query: "returns")
let article  = try await chat.article(id: articles[0].id)
try await chat.emailTranscript(to: "alex@example.com")
let handoff  = try await chat.createDeviceHandoff()  // QR to continue elsewhere
```

### Message content

`ChatMessage.content` is an enum, so rich content is a `switch`, not string
parsing:

```swift
switch message.content {
case .text(let body):            Text(body)
case .productCard(let card):     ProductRow(card)
case .articleCard(let card):     ArticleRow(card)
case .form(let form):            FormCard(form)
case .formResponse(let response): SubmittedForm(response)
case .attachment(let file):      Attachment(file)
case .unsupported:               EmptyView()   // sentinel from a newer server
}
```

Always handle `.unsupported` by rendering nothing rather than crashing or
showing raw text. It exists so an app shipped today survives a content type
Hive adds tomorrow — your users may be several releases behind.

### Theming

Colours come from the merchant's widget settings by default. Override:

```swift
HiveChatView(chat: chat, theme: HiveChatTheme(
    brandColor: .accentColor,
    cornerRadius: 12,
    font: .custom("Inter", size: 15)
))
```

### Proactive invitations

An agent can reach out first. Open your chat screen when they do:

```swift
chat.onProactiveInvitation = { message in
    showChat = true
}
```

### Continuing a chat from another device

Hive can mint a one-time link (`?hive_chat=CODE`) that moves a live
conversation between devices. If your app handles universal links, pass the
code through before connecting:

```swift
chat.redeemHandoffCode(code)
await chat.start()
```

## What this SDK does not do yet

Stated plainly, because finding out later is worse:

- **No push notifications.** Hive has no APNs infrastructure today, so when
  your app is backgrounded the socket closes and the customer learns about a
  reply only when they next open the app. Until that lands, the practical
  workaround is a Hive webhook into your own backend, which already has push
  credentials for your app.
- **Identity is unverified** — see above.
- **No voice or video.** The dashboard has video rooms; the SDK does not.
- **No message editing or deletion.** Neither has a visitor-side protocol.

## Verifying against a real server

```sh
HIVE_WIDGET_KEY=hv_a1b2c3d4e5f6a1b2c3d4e5f6 swift test --filter LiveIntegrationTests
```

Loads the widget settings and performs a real socket handshake. It creates no
conversation — Hive opens a session only on the first message — but agents
will briefly see a visitor appear in their presence panel.

## Protocol

The wire format is documented in [PROTOCOL.md](PROTOCOL.md). Read it if you
are building your own client, debugging, or working on the Kotlin SDK, which
implements the same contract.

## Versioning

Semantic versioning from 1.0. While on `0.x` the API may change between minor
versions — pin exactly if that matters to you.

## Licence

MIT. See [LICENSE](LICENSE).
