#!/usr/bin/env bash
# AROI Validator - Upload to DigitalOcean Spaces (Primary)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/upload-common.sh"

STORAGE_NAME="DO-Spaces"
# Lower parallelism for DO (rate limits: 240 HEAD/s, 150 PUT/s)
TRANSFERS="${DO_RCLONE_TRANSFERS:-56}"
CHECKERS="${DO_RCLONE_CHECKERS:-80}"

case "${1:-}" in
    --list-backups) init_upload; check_rclone; ensure_do_remote
        list_backups "${AROI_DO_REMOTE}:${DO_SPACES_BUCKET:?}" "DO"; exit 0 ;;
    --help|-h) echo "Usage: $0 [source_dir] | --list-backups | --force-backup [source]"; exit 0 ;;
    --force-backup) FORCE=true; shift; init_upload "${1:-}" ;;
    *) FORCE=false; init_upload "${1:-}" ;;
esac

check_rclone || exit 1
[[ -d "$SOURCE_DIR" ]] || { log_error "Source not found: $SOURCE_DIR"; exit 1; }
ensure_do_remote || exit 1

BUCKET="${AROI_DO_REMOTE}:${DO_SPACES_BUCKET:?}"
log "🌊 DO Spaces: ${DO_SPACES_BUCKET} | $TRANSFERS transfers"

maybe_backup "$BUCKET" "$LOG_DIR/last-do-local-backup-date" local "$FORCE" || true
maybe_backup "$BUCKET" "$LOG_DIR/last-do-backup-date" remote "$FORCE" || true
do_upload "$BUCKET"

log_success "DO Spaces sync complete"
