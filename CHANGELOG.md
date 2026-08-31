# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this package follows
semantic versioning from 1.0 onwards.

## [Unreleased]

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
