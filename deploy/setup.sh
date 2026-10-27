#!/bin/sh
# Generates every secret Asgard needs into ./secrets and creates .env.
# Safe to re-run: existing secrets are kept.
set -eu
cd "$(dirname "$0")"
umask 077
mkdir -p secrets/push data/backups

rand() { openssl rand -base64 "$1" | tr -d '\n/+=' | cut -c1-"$2"; }
make_secret() { [ -s "secrets/$1" ] || { printf '%s' "$2" > "secrets/$1"; echo "created secrets/$1"; }; }

make_secret postgres_password "$(rand 32 40)"
make_secret database_url "postgres://asgard:$(cat secrets/postgres_password)@postgres:5432/asgard?sslmode=disable"
make_secret master_key "$(openssl rand -base64 32 | tr -d '\n')"
make_secret livekit_api_key "API$(rand 12 12)"
make_secret livekit_api_secret "$(rand 48 48)"
make_secret restic_password "$(rand 32 40)"
[ -e secrets/bootstrap_invite ] || : > secrets/bootstrap_invite
[ -s secrets/livekit_keys.yaml ] || {
  printf '%s: %s\n' "$(cat secrets/livekit_api_key)" "$(cat secrets/livekit_api_secret)" > secrets/livekit_keys.yaml
  echo "created secrets/livekit_keys.yaml"
}
# The secrets folder is private to you (0700). Files inside are 0644 because
# containers read them as their own non-root users through bind mounts.
chmod 700 secrets
find secrets -maxdepth 1 -type f ! -name README.md -exec chmod 644 {} +
# LiveKit refuses key files that are readable by others.
chmod 600 secrets/livekit_keys.yaml

if [ ! -f .env ]; then
  cp .env.example .env
  echo "created .env — edit ASGARD_DOMAIN, LIVEKIT_DOMAIN and ACME_EMAIL"
fi

cat <<MSG

Next:
  1. Point DNS A/AAAA records for ASGARD_DOMAIN and LIVEKIT_DOMAIN at this machine.
  2. Forward TCP 80, 443, 7881 and UDP 443, 3478, 50000-50200 on your router.
  3. docker compose up -d --build
  4. docker compose logs asgard | grep invite   # your first admin invite code

Back up secrets/restic_password and secrets/master_key somewhere safe (password manager).
Without restic_password your backups cannot be restored.
MSG
