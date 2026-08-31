# Hive live chat — visitor protocol

The wire contract between a customer-facing client and Hive. Both official
SDKs (Swift, Kotlin) and the web widget implement this; write your own client
against it if you need to.

> **This is a versioned public contract.** A shipped mobile app cannot be
> updated the way `widget.js` can — App Store builds live on devices for
> months. Anything here that changes incompatibly breaks apps in the field, so
> treat additions as safe and removals as breaking.

---

## 1. Transport

Socket.IO v4 over Engine.IO v4, WebSocket only.

```
wss://hivehd.app/api/socket.io/?EIO=4&transport=websocket
namespace: /livechat/visitor
```

The SDKs speak the protocol directly rather than depending on a Socket.IO
client library; the useful subset is OPEN → namespace CONNECT → EVENT frames,
plus ping/pong and reconnection.

**Long-polling is not used.** The web widget keeps it as a fallback; native
clients skip it.

### Handshake

Auth travels in the Socket.IO CONNECT packet (`40/livechat/visitor,{…}`):

| Field | Required | Notes |
|---|---|---|
| `widgetKey` | ✅ | Public widget key. No `widgetKey` → immediate disconnect; unknown key → `error` event then disconnect. |
| `visitorToken` | — | Stable per-device id. **This is what makes history work** — the same token gets the conversation back. Mint `v_<random><base36 time>` on first run and persist it. |
| `name`, `email` | — | Display identity. Unverified (see [Identity](#identity)). |
| `handoffCode` | — | One-time code from a "continue this chat here" link. Single use. |
| `consentText` | — | Exact wording the customer agreed to. Stored as the audit trail. |
| `pageUrl`, `pageTitle`, `referrer` | — | What the agent panel shows as context. Native clients send `app://<bundle id>` and the app's display name. |

There is **no domain or origin allowlist** — a native client connects with the
widget key alone.

---

## 2. Sessions are created lazily

Connecting does **not** create a conversation. The server opens a session on
the customer's **first message**, which is why merely opening a chat screen
does not spawn empty tickets for agents.

Consequences for a client:

- `sessionID` is `null` until the first message is sent.
- Anything needing a session (`chat:handoff:create`, transcript email) fails
  until then, with a message saying so.
- On reconnect the server resumes the existing session rather than creating a
  second one, matched on `visitorToken`.

---

## 3. Events — server → client

| Event | Payload | Meaning |
|---|---|---|
| `chat:session` | `{ sessionId, welcome_message }` | Session id, or `null` if not created yet. |
| `chat:restore` | `{ sessionId, status, messages[] }` | **Always fires after connect**, with `sessionId: null` when there is nothing to resume. Up to 200 messages, oldest first. Rebuild the thread from this — do not append, or a reconnect duplicates it. |
| `chat:message` | message object | New message either way; the server echoes the customer's own back. |
| `chat:typing` | `{ typing, name }` | Agent typing state. |
| `chat:read` | `{ sessionId, messageIds[], readBy }` | Agent read the customer's messages. |
| `chat:transfer` | `{ message }` | Being connected to a human. Show as a system line. |
| `chat:offline` | `{ message }` | Nobody available — collect an email instead. Fires *mid-chat*, not on connect. |
| `chat:queue-position` | `{ sessionId, position, ahead, total }` | 1-based place in the queue. |
| `chat:ended` | `{ sessionId }` | Conversation closed. The next customer message reopens it. |
| `chat:reactions` | `{ message_id, reactions[] }` | Full reaction set for one message, with a `mine` flag for this viewer. |
| `chat:message:enriched` | `{ messageId, metadata }` | Link previews arriving after the fact — `metadata.url_previews[]`. |
| `agents:status` | `{ online, count }` | Whether any human is available. |
| `visitor:name` | `{ name }` | Server-resolved display name. |
| `visitor:invite` | `{ sessionId, message, agentName }` | Agent reached out first. The message itself follows as a normal `chat:message`. |
| `csat:request` | `{ sessionId, prompt }` | Ask for a rating. |
| `csat:received` | — | Rating stored. |
| `chat:handoff:adopted` | `{ visitorToken, sessionId }` | Handoff code accepted. **Adopt the returned token as your own** and persist it. |
| `chat:handoff:invalid` | `{}` | Code was spent or expired. |

### Message object

```jsonc
{
  "id": "cmsg_…",
  "session_id": "csess_…",
  "sender_type": "visitor" | "agent" | "bot" | "system",
  "sender_name": "Sarah",
  "body": "…",                    // see §5
  "created_at": "2026-08-31T10:00:00.000Z",
  "read": false,                  // restore only
  "reactions": [{ "emoji": "👍", "count": 2, "mine": true }]
}
```

**`bot` must be rendered exactly like `agent`.** The server already maps it
that way on the live path; a client that styles them differently leaks which
replies were automated.

**Timestamps come in two shapes.** The socket path sends ISO-8601 *with*
fractional seconds; the restore path (straight from MySQL) sends them
*without*. Parse both — a client that handles one silently stamps half the
thread 1970 and sorts the conversation inside out.

---

## 4. Events — client → server

| Event | Payload | Notes |
|---|---|---|
| `chat:message` | `{ body }` | Creates the session if there isn't one. |
| `chat:typing` | `{ typing, text? }` | `text` shows the agent what is being typed live — send it only if you mean to. |
| `chat:read` | — | Marks all agent/bot messages read. |
| `visitor:info` | `{ name, email }` | Update identity mid-conversation. |
| `visitor:email` | `{ email }` | Email only — what the offline form collects. |
| `chat:request-human` | — | Escalate off the bot into the queue. |
| `chat:end` | — | Close the conversation. Idempotent. |
| `chat:reaction:toggle` | `{ messageId, emoji }` | Toggles: same emoji twice removes it. |
| `csat:submit` | `{ rating, comment? }` | Rating clamped to 1–5. |
| `chat:handoff:create` | `{ pageUrl? }` + **ack** | Ack: `{ ok, code, url, qrSvg, expiresInMinutes }` or `{ ok: false, error }`. Requires a session. |
| `page:update` | `{ url, title }` | Web navigation tracking. Native clients may send screen names. |
| `cart:update` | `{ items, total, currency, count }` | Shopify cart mirroring. |

`chat:handoff:create` is the **only** visitor event using an ack callback.

---

## 5. Message bodies: the sentinel format

Rich content is encoded as a **sentinel-prefixed string** in `body`, not as a
structured field. The marker sits at the very start; JSON follows. Some
producers append `__END__`, some do not — **always strip a trailing `__END__`,
never require one.**

| Sentinel | Direction | Payload |
|---|---|---|
| `__PRODUCT_CARD__` | → client | `{ title, description?, image_url?, buy_url?, price?, variants[]?, message?, agent_name? }` |
| `__ARTICLE_CARD__` | → client | `{ id, title, excerpt?, slug?, agent_name? }` |
| `__CHAT_FORM__` | → client | `{ form_id?, name, description?, fields[] }` + `__END__` |
| `__FORM_RESPONSE__` | ← client | `{ form_id?, form_name, entries[{key,label,value}] }` + `__END__` |
| `__VISITOR_FILE__` | ← client | `{ url, contentType, name, uploading? }` |
| `__META_ATTACHMENT__` | → client | `{ type: image\|video\|audio\|file, url, name }` + `__END__` |

Form field types: `text`, `email`, `number`, `textarea`, `select`, `checkbox`.
**Decode an unknown type as `text`** rather than failing the card.

`price` arrives as a JSON **number** from the bot and as a **string** from the
agent product picker. Accept both. With no top-level `price`, fall back to the
cheapest in-stock variant.

`__META_ATTACHMENT__` URLs are **host-relative** (`/uploads/livechat/…`) —
resolve against the host.

### Bookkeeping prefixes

Not content, but they arrive in the same field:

| Prefix | Handling |
|---|---|
| `OFFLINE_EMAIL_SENT::` | **Drop the message entirely.** Never shown. |
| `OFFLINE_HANDOFF::` | Strip the prefix, show the rest. |
| `BOT_FALLBACK::` | Strip the prefix, show the rest. |

### Forward compatibility

A client **must** tolerate a sentinel it does not recognise: render nothing
rather than the raw marker, and never crash. New content types get added to
the server without waiting for every app in the App Store to catch up.

---

## 6. REST endpoints

All unauthenticated; the widget key is the only credential. Mounted at both
`/livechat/…` and `/api/livechat/…` — **prefer `/api`**, which is the prefix
guaranteed to be proxied.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/livechat/widget-config/:widgetKey` | Branding, welcome text, online state, featured articles. `{ widget_enabled: false }` alone means switched off. |
| `GET` | `/api/livechat/widget-kb-search?widget_key=&q=` | Help article search → `{ results[] }`. |
| `GET` | `/api/livechat/widget-article/:id` | One article → `{ id, title, html, helpful_count, not_helpful_count }`. |
| `POST` | `/api/livechat/widget-upload` | Multipart: `file` + `widgetKey`. → `{ url, name, size, contentType }`. **5 MB cap**, 413 above it. |
| `GET` | `/api/livechat/widget-transcript/:sessionId` | Transcript. |
| `POST` | `/api/livechat/widget-transcript/:sessionId/email` | `{ visitor_token, email }`. The token must match the session. |

### Sending a file

1. `POST` the bytes to `widget-upload`.
2. Emit `chat:message` with body
   `__VISITOR_FILE__{"url":…,"contentType":…,"name":…}`.

The upload alone does not put anything in the conversation.

---

## 7. Reconnection

The server tolerates reconnects by design, and clients must expect them:
Cloudflare closes idle WebSockets after ~100 s, and mobile OSes kill sockets
the moment an app backgrounds.

- Reconnect with the **same `visitorToken`** and the conversation resumes.
- A bare disconnect does **not** end the chat. Bot-mode chats get a 60 s grace
  window before the sweeper may close them; chats waiting on or talking to a
  human stay open regardless.
- `chat:restore` fires again on every reconnect — **rebuild, don't append**.
- Use backoff with jitter. An edge drop disconnects every client at once, and
  a fixed delay marches them all back in lockstep.
- On mobile, force a fresh socket when the app foregrounds rather than
  trusting the old one. A suspended WebSocket often looks alive until a write
  fails — which, on a screen that only reads, is never.

---

## 8. Identity

**Today, identity is unverified.** `name` and `email` are taken at face value.
Fine for an anonymous web widget where nothing is claimed; weaker in a
signed-in app, where a customer's name appearing next to a conversation
implies the app vouched for it.

**Planned:** an HMAC signature over the customer id, computed on the
merchant's backend with a per-widget secret that never ships in the app —
the pattern Intercom and Zendesk use. Until then:

- Do not treat the name/email on a conversation as proof of who is talking.
- Do not put anything in identity fields you would not show a stranger.

---

## 9. Known gaps

Real, and unlikely to be what you assume:

- **No push notifications.** No APNs/FCM anywhere in Hive. A backgrounded app
  is a disconnected app.
- **The web widget does not render `__META_ATTACHMENT__`.** An agent who sends
  a file to a *web* visitor shows them raw sentinel text. The SDKs render it
  properly; the widget needs the same fix.
- **No visitor-side edit or delete.**
- **Rate limiting is not documented** and should not be assumed absent.
