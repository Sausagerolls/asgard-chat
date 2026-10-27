# Asgard Chat Protocol v1

This document is the contract between the server (`server/`) and every client
(iOS, Android, web, watch). If code and this document disagree, fix one of them.

## 1. Trust model

- The server is trusted for **availability and metadata**, never for **content**.
- The server knows: usernames, display names, avatars, who is in which
  conversation, conversation titles/descriptions, timestamps, message sizes,
  device lists and push tokens. (Same class of metadata WhatsApp's servers see.)
- The server never sees: message text, media, reactions, poll options/votes,
  edits, story content, call media, location, voice notes, or file names.
- Every message is signed by the sending device. Clients verify the signature
  against the sender's published signing key, so the server cannot forge or
  alter messages. Clients show a safety-number change warning when a contact's
  device keys change.

### Known limitations of v1 (be honest in the UI and README)

v1 uses **sealed fan-out**: each message gets a fresh random key, wrapped
separately for every recipient device using an ephemeral X25519 key. This gives
confidentiality, integrity and sender authentication, and limits the blast
radius of a compromised message key to one message. It does **not** give
post-compromise security: if a device's long-term identity key leaks, an
attacker who also recorded traffic can decrypt messages sent to that device.
Phase 4 replaces fan-out with MLS (RFC 9420, via OpenMLS + UniFFI) without
changing the envelope transport described below — `alg` in the envelope header
selects the scheme.

v1 has not been audited.

## 2. Keys

Each **device** (not user) owns:

| Key | Type | Purpose |
|---|---|---|
| identity key | X25519 | receive wrapped message keys |
| signing key | Ed25519 | sign envelopes |

Private keys never leave the device (iOS: Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
shared with the notification extension via app group keychain access group;
Android: Keystore-wrapped). Public keys are uploaded on device registration.

Safety number for a pair of users = first 30 decimal digits of
`SHA-256(sorted(user_a_id || all_device_signing_keys_a) || sorted(user_b_id || ...))`,
shown in groups of 5, plus a QR code.

## 3. Message encryption

```
K          = 32 random bytes                       (message key)
aad        = utf8(conversation_id) || 0x00 || utf8(sender_device_id) || 0x00 || utf8(client_id)
body       = ChaCha20-Poly1305.seal(K, nonce=12 random, plaintext=content_json, aad)
ciphertext = nonce || body                          (CryptoKit "combined" format)
signature  = Ed25519.sign(signing_key, SHA-256(aad || ciphertext))
```

All UUIDs inside `aad` and wrap AAD are **lowercase** canonical strings
(`8-4-4-4-12`). Swift's `uuidString` is uppercase, so clients must lowercase.

For every recipient device D (including the sender's own other devices):

```
e          = fresh X25519 keypair
shared     = X25519(e.private, D.identity_key)
wk         = HKDF-SHA256(ikm=shared, salt=e.public || D.identity_key, info="asgard-wrap-v1", len=32)
wrapped    = e.public(32) || nonce(12) || ChaCha20-Poly1305.seal(wk, K, aad=utf8(client_id))
```

`wrapped` is always 92 bytes. Reference implementations:
`server/internal/e2ee` (Go, used by server-side bots) and
`ios/Shared/Crypto/E2EE.swift` (CryptoKit).

### Content JSON (`content_json`)

```jsonc
{
  "v": 1,
  "type": "text" | "media" | "voice" | "video_note" | "location" | "live_location"
        | "poll" | "vote" | "event" | "rsvp" | "reaction" | "edit" | "delete"
        | "sticker" | "gif" | "contact" | "call_key" | "system_note",
  "text": "string, markdown subset",
  "entities": [{"kind": "mention", "user_id": "...", "range": [0, 5]}],
  "reply_to": "message id",
  "target": "message id (reaction/edit/delete/vote/rsvp)",
  "emoji": "for reaction; empty string removes",
  "pinned": true,             // for kind=pin: false unpins
  "attachments": [{
     "media_id": "...", "mime": "image/heic", "size": 123, "name": "IMG.heic",
     "key": "base64 32 bytes", "digest": "base64 sha256 of ciphertext",
     "width": 0, "height": 0, "duration_ms": 0,
     "waveform": "base64 64 bytes 0-255", "blurhash": "...", "thumbnail": "base64 jpeg <= 8KB",
     "view_once": false
  }],
  "poll": {"question": "", "options": [{"id": "a", "text": ""}], "multiple": false, "anonymous": false, "closes_at": 0},
  "vote": {"option_ids": ["a"]},
  "event": {"title": "", "starts_at": 0, "ends_at": 0, "location": "", "notes": ""},
  "rsvp": {"status": "yes" | "no" | "maybe"},
  "location": {"lat": 0, "lon": 0, "accuracy": 0, "name": "", "live_until": 0},
  "link_previews": [{"url": "", "title": "", "description": "", "image": "base64 jpeg <= 16KB"}],
  "call_key": {"room": "", "key": "base64"},
  "forwarded": false,
  "silent": false
}
```

Link previews are generated **by the sender's device**, never the server, so
the server never learns URLs.

### Media

Files are encrypted on the device before upload, in 64 KiB chunks:

```
key        = 32 random bytes, nonce_prefix = 8 random bytes
chunk[i]   = ChaCha20-Poly1305.seal(key, nonce = nonce_prefix || uint32_be(i), chunk_plaintext, aad = uint32_be(i) || final_flag(1 byte))
blob       = "AGM1" || nonce_prefix || chunk[0] || chunk[1] || ...
```

The final chunk uses `final_flag = 1` to prevent truncation. The server stores
`blob` opaquely in S3-compatible storage (MinIO) and only learns its size.

## 4. Transport

- REST: `https://<host>/api/v1/...`, JSON, `Authorization: Bearer <session token>`.
- Realtime: `wss://<host>/api/v1/ws` with the same header (or `?token=` for browsers).
- Binary fields (`ciphertext`, `signature`, `wrapped_key`, keys) are base64 (std, padded).
- Times are RFC 3339 in JSON.
- Errors: `{"error": {"code": "invite_invalid", "message": "human readable"}}`.

### Sending

```
POST /api/v1/conversations/{id}/messages
{
  "client_id": "uuid chosen by the client (idempotency key)",
  "kind": "msg" | "edit" | "delete" | "reaction" | "vote" | "rsvp" | "pin",
  "target_id": "required for edit/delete/reaction/vote/rsvp",
  "thread_root_id": "optional",
  "ciphertext": "...", "signature": "...", "alg": "fanout-v1",
  "keys": {"<device_id>": "<wrapped_key>", ...},
  "expires_in": 0,           // seconds, disappearing; 0 = conversation default
  "send_at": null,           // RFC 3339 for scheduled send
  "view_once": false
}
```

The server checks that `keys` covers **exactly** the current device set of the
conversation's members. If not it answers `409 device_mismatch` with
`{"missing": [...], "extra": [...]}` and the client refreshes
`GET /conversations/{id}/devices`, re-wraps and retries. This guarantees no
device silently misses a message and no removed device keeps receiving them.

`kind=delete` additionally makes the server erase the target's ciphertext
(only the sender or a conversation admin may do this).

### Receiving

- Realtime event `message` with the envelope.
- `GET /api/v1/sync?after=<cursor>` returns every envelope addressed to this
  device after the cursor, oldest first, plus `next_cursor`. Clients call this
  on launch, on reconnect and from the notification service extension.
- `GET /api/v1/conversations/{id}/messages?before_seq=&limit=` for scrollback.

### Envelope (server -> client)

```json
{
  "id": "uuid", "conversation_id": "uuid", "seq": 42, "client_id": "uuid",
  "kind": "msg", "target_id": null, "thread_root_id": null,
  "sender_user_id": "uuid", "sender_device_id": "uuid",
  "ciphertext": "...", "signature": "...", "alg": "fanout-v1",
  "wrapped_key": "... for this device ...",
  "sent_at": "2026-10-27T12:00:00Z", "expires_at": null, "view_once": false,
  "deleted": false, "cursor": 1234
}
```

System envelopes (`kind = "system"`) are plaintext JSON in `system` and carry
membership/title/role changes; they have no `ciphertext`.

### Realtime events

Server -> client: `message`, `receipt`, `typing`, `presence`,
`conversation.updated`, `conversation.removed`, `member.updated`, `story`,
`call.ring`, `call.ended`, `device.added`, `keys.changed`.

Client -> server: `typing {conversation_id, state}`, `presence {state}`,
`ack {cursor}`, `read {conversation_id, seq}`, `ping`.

Frame format: `{"type": "...", "data": {...}}`.

## 5. Push

The server sends **content-free-by-default** pushes:

- iOS alert pushes are `mutable-content: 1`, carrying
  `{"c": conversation_id, "m": message_id, "e": envelope}` where `e` (the full
  envelope for that device) is included only when the payload stays under 3.5 KB.
  The Notification Service Extension decrypts locally and builds a
  communication notification (`INSendMessageIntent`) with sender avatar. If `e`
  is absent it calls `/sync`. The visible fallback body is "New message".
- iOS VoIP pushes (`<bundle>.voip` topic) ring CallKit for incoming calls.
- Android FCM data messages carry the same payload; the app decrypts in
  `FirebaseMessagingService` and posts a `MessagingStyle` notification, which
  is what Android Auto reads aloud.

APNs and FCM credentials live only in server secrets (see `deploy/secrets/README.md`).

## 6. Calls

`POST /api/v1/conversations/{id}/calls` creates/joins a LiveKit room and
returns `{url, token, room}`. Ringing other members uses VoIP push + realtime
`call.ring`. Call media is end-to-end encrypted with LiveKit's E2EE: the caller
generates a room key and distributes it as an encrypted `call_key` message.

## 7. Device linking

1. Existing device: `POST /api/v1/devices/link` -> `{code, expires_at}`, shows
   QR `asgard://link?host=<host>&code=<code>`.
2. New device scans, generates keys, `POST /api/v1/devices/link/claim`
   `{code, name, platform, identity_key, signing_key}` -> session.
3. Existing device is notified (`device.added`), and can stream an encrypted
   history bundle to the new device as a media blob, sending its key in a
   message addressed only to the new device.

## 8. Bots and webhooks

Bots are users with `is_bot = true`. A bot owned by the server ("server-side
bot") has its device private keys stored encrypted under `ASGARD_MASTER_KEY`, so
the server can encrypt webhook payloads to members. **Adding a server-side bot
to a conversation means the server can read that conversation** — clients show
a banner when one is present. External bots use the normal client protocol with
a bot token.

Incoming webhook: `POST /api/v1/hooks/{hook_id}/{secret}` with
`{"text": "...", "markdown": true}`.
