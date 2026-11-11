# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this package follows
semantic versioning from 1.0 onwards.

## [Unreleased]

## [0.9.1] — 2026-11-11

Needs a Hive server from the current release for the message acknowledgement,
voice uploads and the hosted handoff link.

### Fixed
- **Sent messages get their real id.** The server does not echo the
  customer's own message back, so the optimistic `local_…` copy kept its local
  id forever (reactions and read receipts on it never matched). `chat:message`
  is now sent with an acknowledgement: on success the message takes the
  server's id and is marked sent; on an error or no answer within 15 seconds it
  is marked failed. An echo, if one ever arrives, is still not shown twice.
- **Opening the chat no longer drops a healthy connection.** 0.4.0 said this
  was fixed, but `connect()` (which `HiveChatView` calls every time it appears)
  still tore down and re-handshook a live socket. It now does nothing when
  already connected or connecting, and only reconnects a socket that is down.
- **Cart quantities show in the dashboard.** `updateCart` now sends each item's
  quantity as `qty` (what the dashboard reads) as well as `quantity`. A cart
  set before the customer's first message is re-sent once the conversation
  starts, instead of being lost.
- **A chat an agent opens first is picked up properly.** The session id that
  comes with an agent's invitation is now adopted, so transcript email and
  device handoff work straight away.
- **Photos send reliably.** Picked photos were labelled JPEG but sent as-is —
  usually HEIC on an iPhone, which the server refuses, and often over 5MB.
  `HiveChatView` now always re-encodes them as JPEG (longest side 2048px,
  quality stepped down until under 5MB). The file picker offers images and
  PDFs only, and images picked from Files get the same conversion. Anything
  still over 5MB is refused with a clear message before uploading.

### Added
- `HiveChat.maximumUploadBytes` (5MB), the server's upload limit.

### Docs
- PROTOCOL.md: message acknowledgement, `chat:ended` from agents, `cart:update`
  item shape, accepted upload types, transcript parameters, the public
  `/livechat` REST prefix, server-built handoff links, translated restore, and
  how push works.

## [0.9.0] — 2026-10-15

### Added
- Verified customers: `identify(name:email:userId:userHash:)`. Your server signs
  the customer's email (or id) with the widget's identity secret; Hive checks
  it and marks the chat verified, so nobody can chat as someone else. Existing
  `identify(name:email:)` calls compile unchanged.

## [0.8.0] — 2026-08-31

### Deprecated
- `registerDeviceToken(_:)` / `unregisterDeviceToken(_:)` now do nothing but
  log. Hive no longer sends push notifications itself: an app that already has
  push ends up with two systems notifying one phone, and holding merchants'
  signing keys was a liability not worth carrying. Notify from your own backend
  instead — Hive tells it when a reply could not be delivered, by webhook or by
  a feed you poll.

## [0.7.0] — 2026-08-31

### Added
- `registerDeviceToken(_:)` / `unregisterDeviceToken(_:)` — Hive sends the push
  itself once your team pastes the app's APNs key into the dashboard. No
  endpoint of yours, no polling, nothing to configure on your domain. Takes the
  `Data` Apple hands you directly. Keyed on the visitor token, so it works for
  customers who never signed in.

## [0.6.0] — 2026-08-31

### Added
- `onMessageReceived` — fires when a message arrives from the team while your
  app is running, so you can raise an in-app banner or a local notification
  without any server involvement. Only live arrivals from the team: never the
  customer's own messages, and never the thread replayed on reconnect.

## [0.5.0] — 2026-08-31

### Fixed
- **`trackScreen(_:title:reference:)` and `updateCart(items:total:currency:)`
  now actually exist.** 0.4.0 shipped their documentation and `CartItem` but
  not the methods themselves — an edit failed to apply silently, and because
  nothing in the package called them the build stayed green all the way to a
  release. A new test calls every public method, so a missing one is now a
  compile error rather than something an integrator discovers.

### Changed
- The microphone gives way as soon as the message field is focused, not only
  once something is typed: a raised keyboard is intent enough. It returns when
  the keyboard is dismissed with nothing written.

## [0.4.0] — 2026-08-31

### Fixed
- **Opening the chat no longer says "Connecting…".** `connect()` reconnected
  unconditionally, so appearing on the chat screen tore down a perfectly
  healthy socket and re-handshook it. It now leaves a live connection alone.

### Added
- `trackScreen(_:title:reference:)` and `updateCart(items:total:currency:)` —
  give agents the browsing context and basket they already see for website
  customers. Without them the agent panel shows only "iOS app".
- **Attach a photo or file** from the composer — a photo picker and a file
  importer, offered separately because they are not the same experience.
- **Voice messages**, opt-in via `voiceMessagesEnabled` (needs
  `NSMicrophoneUsageDescription`). AAC-in-MP4, which the dashboard plays and
  WhatsApp accepts.

## [0.3.0] — 2026-08-31

### Added
- `HiveChatView(onProductTap:)` — handle a product-card tap yourself and push
  your own native product screen. Without it the card opened its `buyURL` in a
  browser, walking the customer out of the conversation they were having,
  which rather defeats a native chat.
- `HiveChatView(onOpenURL:)` — first refusal on every link in the thread.
  Return `true` when you have handled it, `false` to let a browser open it.

## [0.2.0] — 2026-08-31

### Fixed
- `HiveChat.init` is now `nonisolated`. It was implicitly main-actor isolated,
  so building a client anywhere natural — a `ViewModel.init`, an `App`
  struct's property initialiser, an `AppDelegate` — failed to compile under
  Swift 6 with "call to main actor-isolated initializer in a synchronous
  nonisolated context". Everything else stays main-actor bound, because views
  bind to it. Regression-tested from a nonisolated context, where only the
  compiler can catch a relapse.
- Removed a duplicate `Identifiable` conformance on `KnowledgeBaseArticle` and
  a redundant `await`, both of which put warnings in consumers' builds.
- Documented the widget key in the format Hive actually issues (`hv_` + 24 hex
  characters). The examples had shown an invented `wk_live_…` prefix, which
  gave integrators good reason to think they held the wrong credential.

### Changed
- **Minimum iOS is now 17.0** (was 16.0). HiveChatUI moved to the modern
  zero-parameter `onChange`; keeping its deprecated predecessor to support a
  four-year-old OS would have emitted warnings in every consumer's build that
  they could not fix. The `HiveChat` core target needs nothing newer than iOS
  13 and can be depended on alone; `0.1.x` supports iOS 16 throughout.

## [0.1.0] — 2026-08-31

First release. Implements the Hive visitor protocol as documented in
[PROTOCOL.md](PROTOCOL.md).

### Added
- `HiveChat` — connection, conversation state, and the full visitor event set:
  messages, typing, read receipts, reactions, queue position, transfers,
  offline handling, CSAT, device handoff.
- Dependency-free Socket.IO v4 client with ack support, exponential backoff
  with jitter, and foreground reconnection.
- Structured `MessageContent` covering every sentinel the server emits —
  product cards, article cards, forms, form responses, attachments — with an
  `unsupported` case so unknown future sentinels degrade rather than break.
- File upload with an optimistic local echo.
- Offline outbox: messages typed while disconnected are queued and flushed in
  order on reconnect.
- Help-centre search and article fetch; transcript by email.
- `HiveChatUI` — `HiveChatView`, a complete SwiftUI chat screen themed from
  the merchant's own widget settings.
