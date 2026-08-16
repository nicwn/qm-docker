#!/usr/bin/env bash
# Postgres backup — pg_dump + restic to a remote repo.
# Operator: set BACKUP_REPO (restic repo, e.g. sftp:storage-box:/qm-backups or
# b2:qm-backups) and POSTGRES_CONTAINER (the postgres container name) in .env.
# Run via the postgres-backup.timer unit.

set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
[ -f .env ] && set -a && . ./.env && set +a

: "${POSTGRES_CONTAINER:=postgres}"
: "${BACKUP_REPO:?set BACKUP_REPO in .env}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP="/tmp/qm-${STAMP}.dump"

echo "==> dumping ${POSTGRES_CONTAINER}"
docker exec "${POSTGRES_CONTAINER}" pg_dump -U qm qm --format=custom > "${DUMP}"

echo "==> restic snapshot to ${BACKUP_REPO}"
restic --repo "${BACKUP_REPO}" backup "${DUMP}" --tag "qm-${STAMP}"
restic --repo "${BACKUP_REPO}" forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

rm -f "${DUMP}"
echo "==> done ${STAMP}"
