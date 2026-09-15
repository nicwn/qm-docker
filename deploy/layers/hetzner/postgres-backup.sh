#!/usr/bin/env bash
# Postgres backup — pg_dump + restic to a remote repo.
# Operator: set BACKUP_REPO (restic repo, e.g. sftp:storage-box:/qm-backups or
# b2:qm-backups) and a NON-INTERACTIVE restic credential in the repo-root .env:
# RESTIC_PASSWORD_FILE (preferred) or RESTIC_PASSWORD. The timer has no terminal,
# so restic cannot prompt.
# Run via postgres-backup.service (timer). Invoke from the repo root so the .env
# path resolves (the service unit sets WorkingDirectory).

set -euo pipefail
[ -f .env ] || { echo "missing .env at repo root ($(pwd)/.env)" >&2; exit 1; }
# shellcheck disable=SC1091
set -a && . ./.env && set +a

: "${POSTGRES_CONTAINER:=postgres}"
: "${BACKUP_REPO:?set BACKUP_REPO in .env}"

if [ -z "${RESTIC_PASSWORD:-}" ] && [ -z "${RESTIC_PASSWORD_FILE:-}" ] && [ -z "${RESTIC_PASSWORD_COMMAND:-}" ]; then
	echo "no restic password source: set RESTIC_PASSWORD_FILE (preferred) or RESTIC_PASSWORD in .env" >&2
	exit 1
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP="$(mktemp "${TMPDIR:-/tmp}/qm-backup-XXXXXX.dump")"
chmod 600 "${DUMP}"
trap 'rm -f "${DUMP}"' EXIT

echo "==> dumping ${POSTGRES_CONTAINER}"
docker exec "${POSTGRES_CONTAINER}" pg_dump -U qm qm --format=custom > "${DUMP}"

echo "==> restic snapshot to ${BACKUP_REPO}"
restic --repo "${BACKUP_REPO}" backup "${DUMP}" --tag "qm-${STAMP}"
restic --repo "${BACKUP_REPO}" forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

echo "==> done ${STAMP}"
