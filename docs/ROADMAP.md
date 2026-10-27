# Roadmap

## Phase 1 — Server + iOS (done)
- [x] Go server, Docker Compose stack, backups, admin panel, CLI
- [x] v1 E2EE protocol with Go/Swift cross-implementation test vectors
- [x] iOS app: chats, groups, channels, communities, voice rooms, calls, settings, admin
- [x] CarPlay, Siri, App Intents, Focus filter, widgets, Live Activity, Control
- [x] Notification service extension (on-device decryption), share extension
- [x] On-device Apple Intelligence summaries and smart replies
- [ ] Verify on physical devices: push, VoIP, CarPlay (needs entitlement)

## Done since phase 1
- [x] Voice rooms in groups and channels; stories removed
- [x] Push credentials uploaded through the web admin
- [x] Message history sync with recovery key (QR), automatic on device link
- [x] Native macOS app
- [x] Android app: chats, voice rooms, calls, history sync, notifications, Android Auto

## Phase 2 — Android polish
- [ ] Shared protocol port (Tink/BouncyCastle X25519, Ed25519, ChaCha20-Poly1305) checked against `go_vector.json`
- [ ] Room database, WorkManager sync, FCM data messages
- [ ] MessagingStyle notifications with direct reply (Android Auto reads/replies through these)
- [ ] Android Auto: `CarAppService` messaging template, conversation shortcuts
- [ ] ConnectionService + LiveKit Android for calls
- [ ] Tablet layouts, Wear OS reply app

## Phase 3 — Web, Mac, Watch
- [ ] Web client (TypeScript, WebCrypto) served by the server
- [ ] macOS: native SwiftUI target sharing AsgardKit
- [ ] watchOS: inbox, dictation reply, quick reactions, complications

## Phase 4 — Protocol hardening
- [ ] MLS (RFC 9420) via OpenMLS + UniFFI for forward/post-compromise security
- [ ] Encrypted history transfer to newly linked devices
- [ ] Passkeys for sign-in
- [ ] External security review
