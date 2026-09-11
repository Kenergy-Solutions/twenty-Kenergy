#!/usr/bin/env bash
#
# Naechtliches Postgres-Backup nach S3.
#
# Aufruf ueber cron (siehe README). Laeuft auf dem Server, nicht lokal.
# Bricht bei jedem Fehler ab, damit ein stilles Teil-Backup nicht als
# Erfolg durchgeht.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
set -a
source "$SCRIPT_DIR/.env"
set +a

: "${PG_DATABASE_USER:?PG_DATABASE_USER fehlt in .env}"
: "${PG_DATABASE_NAME:?PG_DATABASE_NAME fehlt in .env}"
: "${BACKUP_S3_BUCKET:?BACKUP_S3_BUCKET fehlt in .env}"

RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
TIMESTAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
ARCHIVE="twenty-${TIMESTAMP}.sql.gz"
TMP_DIR="$(mktemp -d)"
TMP_FILE="$TMP_DIR/$ARCHIVE"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

log() { echo "[$(date -u +%FT%TZ)] $*"; }

# Cron startet mit einem minimalen PATH ohne ~/.local/bin. Ohne diese
# Aufloesung laeuft das Skript interaktiv, aber nachts nicht.
AWS_CLI="$(command -v aws || true)"
if [ -z "$AWS_CLI" ] && [ -x "$HOME/.local/bin/aws" ]; then
	AWS_CLI="$HOME/.local/bin/aws"
fi
if [ -z "$AWS_CLI" ]; then
	log "FEHLER: aws nicht gefunden (weder im PATH noch unter ~/.local/bin)"
	exit 1
fi

log "Dump startet: Datenbank $PG_DATABASE_NAME"

# pg_dump laeuft im db-Container, damit auf dem Host kein Client noetig ist
# und die Version immer zum Server passt.
docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T db \
	pg_dump --username "$PG_DATABASE_USER" --dbname "$PG_DATABASE_NAME" \
	--format=plain --no-owner --no-privileges \
	| gzip -9 > "$TMP_FILE"

if [ ! -s "$TMP_FILE" ]; then
	log "FEHLER: Dump ist leer, Abbruch"
	exit 1
fi

# Ein gueltiges gzip, das beim Entpacken bricht, waere sonst erst bei der
# Wiederherstellung aufgefallen.
if ! gzip --test "$TMP_FILE"; then
	log "FEHLER: Archiv ist beschaedigt, Abbruch"
	exit 1
fi

SIZE="$(du -h "$TMP_FILE" | cut -f1)"
log "Dump fertig: $ARCHIVE ($SIZE)"

"$AWS_CLI" s3 cp "$TMP_FILE" "s3://${BACKUP_S3_BUCKET}/postgres/${ARCHIVE}" \
	--storage-class STANDARD_IA

log "Hochgeladen nach s3://${BACKUP_S3_BUCKET}/postgres/${ARCHIVE}"

# Aufbewahrungsfrist. Wird nur angewendet, wenn die Bucket-Lifecycle-Regel
# nicht ohnehin schon aufraeumt; doppelt schadet hier nicht.
CUTOFF="$(date -u -d "${RETENTION_DAYS} days ago" +%Y-%m-%d 2>/dev/null \
	|| date -u -v-"${RETENTION_DAYS}"d +%Y-%m-%d)"

"$AWS_CLI" s3 ls "s3://${BACKUP_S3_BUCKET}/postgres/" \
	| awk -v cutoff="$CUTOFF" '$1 < cutoff { print $4 }' \
	| while read -r old; do
		[ -n "$old" ] || continue
		log "Loesche altes Backup: $old"
		"$AWS_CLI" s3 rm "s3://${BACKUP_S3_BUCKET}/postgres/${old}"
	done

log "Backup abgeschlossen"
