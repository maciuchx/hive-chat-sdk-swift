# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this package follows
semantic versioning from 1.0 onwards.

## [Unreleased]

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
