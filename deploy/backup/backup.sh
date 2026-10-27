#!/bin/sh
# Encrypted nightly backups of the database and media blobs with restic.
#   backup.sh loop      run every day at BACKUP_HOUR (default)
#   backup.sh now       run one backup immediately
#   backup.sh restore   restore the latest snapshot into /restore
set -eu

printf '%s:%s:%s:%s:%s\n' "$PGHOST" 5432 "$PGDATABASE" "$PGUSER" "$(cat /run/secrets/postgres_password)" > /tmp/pgpass
chmod 600 /tmp/pgpass

init_repo() {
  restic cat config >/dev/null 2>&1 || restic init
}

run_backup() {
  echo "$(date -Iseconds) backup starting"
  init_repo
  # Media blobs are already end-to-end encrypted; restic encrypts again at rest.
  pg_dump --format=custom --no-owner | restic backup --stdin --stdin-filename asgard.pgdump --tag db
  restic backup /media --tag media
  restic forget --prune --keep-daily "${BACKUP_KEEP_DAILY:-14}" --keep-weekly "${BACKUP_KEEP_WEEKLY:-8}" --keep-monthly "${BACKUP_KEEP_MONTHLY:-12}"
  restic check --read-data-subset=1% || echo "warning: restic check reported problems"
  echo "$(date -Iseconds) backup finished"
}

case "${1:-loop}" in
  now) run_backup ;;
  restore)
    restic restore latest --target /restore
    echo "Restored to /restore. Load the database with: pg_restore --clean -d asgard /restore/asgard.pgdump"
    ;;
  loop)
    while true; do
      now=$(date +%s)
      next=$(date -d "$(date +%Y-%m-%d) $(printf %02d "${BACKUP_HOUR:-3}"):00" +%s 2>/dev/null || echo $((now + 86400)))
      [ "$next" -le "$now" ] && next=$((next + 86400))
      echo "next backup in $(( (next - now) / 60 )) minutes"
      sleep $((next - now))
      run_backup || echo "backup failed"
    done
    ;;
esac
