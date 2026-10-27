# Secrets

Everything in this folder except this README is gitignored. `../setup.sh`
creates the files below. Never commit them; the repository is public.

| File | Used by | Notes |
|---|---|---|
| `postgres_password` | postgres, backup | |
| `database_url` | asgard | contains the postgres password |
| `master_key` | asgard | 32 bytes base64. Encrypts server-side bot/webhook keys. Changing it breaks existing webhooks. |
| `livekit_api_key`, `livekit_api_secret`, `livekit_keys.yaml` | livekit, asgard | |
| `restic_password` | backup | **Store a copy off this machine.** Backups are useless without it. |
| `bootstrap_invite` | asgard | optional fixed first admin invite code; empty = random |
| `push/AuthKey_XXXXXXXXXX.p8` | asgard | APNs auth key from developer.apple.com > Keys. Enable "Apple Push Notifications service". |
| `push/fcm-service-account.json` | asgard | Firebase console > Project settings > Service accounts > Generate key |

If a secret leaks, rotate it: delete the file, re-run `setup.sh`, then
`docker compose up -d --force-recreate`. Rotating `postgres_password` also
requires `ALTER USER asgard PASSWORD '...'` inside the database first.

The pre-commit hook (`git config core.hooksPath .githooks`) runs gitleaks to
catch secrets before they reach GitHub.
