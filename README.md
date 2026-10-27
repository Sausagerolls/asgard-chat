<p align="center"><img src="design/icon/icon-light.png" width="128" alt="Asgard Chat icon"></p>

# Asgard Chat

Private, end-to-end encrypted messaging on a server you own. Native SwiftUI
app for iPhone and iPad (iOS 26, Liquid Glass) with CarPlay, Siri, widgets and
Live Activities, a Go server that runs anywhere Docker does, and Android, web,
Mac and Watch clients on the way.

## Features

**Messaging** — DMs, groups, channels and communities with roles; replies, threads,
reactions, edits, delete for everyone, pins, stars, forwarding, mentions, read
receipts, typing and presence; disappearing and view-once messages; scheduled
and silent sends; polls, events with RSVP, live location; voice notes with
waveforms and playback speed; photos, videos and files; link previews generated
on-device; drafts, folders, archive, mute, chat lock with Face ID; saved messages.

**Social** — 24-hour encrypted stories with audiences and view lists; broadcast
channels with comment threads; communities of groups with announcements.

**Calls** — 1:1 and group voice/video over LiveKit with end-to-end media
encryption, CallKit ringing, screen share, Dynamic Island Live Activity.

**Apple platform** — CarPlay communication app, Siri send/read/call, App
Shortcuts, Focus filters, communication notifications with avatars and inline
reply, share extension, Home/Lock Screen widgets, Control Center control,
on-device Apple Intelligence ("Catch me up" summaries and smart replies).

**Server** — invite-only accounts, linked devices via QR, bots and incoming
webhooks, web admin panel at `/admin`, `asgard` CLI, audit log, storage quotas,
APNs/FCM push, nightly encrypted backups with restic.

## Encryption

Every message, attachment, reaction, edit, poll vote and story is encrypted on
the sending device with a fresh key, wrapped for each recipient device
(X25519 + HKDF + ChaCha20-Poly1305) and signed (Ed25519). The server stores
ciphertext and routing metadata only. See [docs/PROTOCOL.md](docs/PROTOCOL.md)
for the wire format and its limits: v1 does not yet provide post-compromise
security (MLS is planned) and has not been audited.

## Repository

| Path | What |
|---|---|
| `server/` | Go server: API, WebSocket, push, jobs, admin UI, CLI |
| `deploy/` | Docker Compose stack: Caddy, Asgard, Postgres, LiveKit, backups |
| `ios/` | SwiftUI app, extensions and the `AsgardKit` Swift package |
| `android/`, `web/` | Planned clients (see roadmap) |
| `design/icon/` | App icon source (`render_icon.swift`) and renders |
| `docs/` | Protocol and roadmap |

## Self-hosting

Requirements: a machine with Docker, a domain, ports 80/443 (TCP+UDP),
7881/TCP, 3478/UDP and 50000-50200/UDP forwarded to it.

```sh
cd deploy
./setup.sh                 # generates secrets into deploy/secrets (gitignored) and .env
$EDITOR .env               # set ASGARD_DOMAIN, LIVEKIT_DOMAIN, ACME_EMAIL
docker compose up -d --build
docker compose logs asgard | grep invite    # first admin invite code
```

Open the app, enter `https://your-domain`, and sign up with that code. The
first account becomes the server admin. Manage the server at
`https://your-domain/admin` or with the CLI:

```sh
docker compose exec asgard asgard invite create -uses 5 -hours 72 -note "Family"
docker compose exec asgard asgard user list
docker compose exec backup backup.sh now
```

### Push notifications

1. developer.apple.com › Keys › new key with *Apple Push Notifications service*.
2. Save `AuthKey_XXXXXXXXXX.p8` into `deploy/secrets/push/`.
3. In `.env` set `APNS_KEY_FILE=/run/secrets/push/AuthKey_XXXXXXXXXX.p8`,
   `APNS_KEY_ID`, `APNS_TEAM_ID` (and `APNS_SANDBOX=true` for Xcode builds).
4. For Android, add a Firebase service-account JSON and `FCM_CREDENTIALS_FILE`.

Pushes carry only ciphertext for the receiving device.

### Backups

Nightly at `BACKUP_HOUR`, restic snapshots the database and media into
`BACKUP_DIR` (or S3/B2/SFTP via `RESTIC_REPOSITORY`). **Keep a copy of
`deploy/secrets/restic_password` and `master_key` off the server.** Restore:
`docker compose run --rm -v $PWD/restore:/restore backup restore`.

## Building the iOS app

Requires Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd ios
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set DEVELOPMENT_TEAM
xcodegen generate
open AsgardChat.xcodeproj
```

Run with the `-demo` launch argument (or tap *Explore the demo*) to use the
built-in demo world without a server.

Capabilities used: App Groups, Keychain Sharing, Push, Siri, Communication
Notifications, Time Sensitive, Associated Domains, Focus. **CarPlay** needs the
`com.apple.developer.carplay-communication` entitlement, which Apple grants on
request: developer.apple.com/contact/carplay. Until approved, remove that key
from `project.yml` to build for devices.

## Development

```sh
# Server tests (integration tests need a throwaway Postgres)
docker run --rm -d -p 55432:5432 -e POSTGRES_PASSWORD=test --name asgard-test-db postgres:17-alpine
cd server && ASGARD_TEST_DATABASE_URL="postgres://postgres:test@localhost:55432/postgres?sslmode=disable" go test ./...

# Swift package tests, including Go<->Swift crypto vectors
cd ios/Packages/AsgardKit && swift test

# Enable the secret-scanning pre-commit hook
git config core.hooksPath .githooks && brew install gitleaks
```

## License

[AGPL-3.0](LICENSE).
