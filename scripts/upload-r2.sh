#!/usr/bin/env bash
# AROI Validator - Upload to Cloudflare R2 (Backup)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/upload-common.sh"

STORAGE_NAME="R2"
# R2 handles high parallelism well
TRANSFERS="${RCLONE_TRANSFERS:-128}"
CHECKERS="${RCLONE_CHECKERS:-256}"

case "${1:-}" in
    --list-backups) init_upload; check_rclone; ensure_r2_remote
        list_backups "${AROI_R2_REMOTE}:${R2_BUCKET:?}" "R2"; exit 0 ;;
    --help|-h) echo "Usage: $0 [source_dir] | --list-backups | --force-backup [source]"; exit 0 ;;
    --force-backup) FORCE=true; shift; init_upload "${1:-}" ;;
    *) FORCE=false; init_upload "${1:-}" ;;
esac

check_rclone || exit 1
[[ -d "$SOURCE_DIR" ]] || { log_error "Source not found: $SOURCE_DIR"; exit 1; }
ensure_r2_remote || exit 1

BUCKET="${AROI_R2_REMOTE}:${R2_BUCKET:?}"
log "☁️  R2: ${R2_BUCKET} | $TRANSFERS transfers"

maybe_backup "$BUCKET" "$LOG_DIR/last-r2-local-backup-date" local "$FORCE" || true
maybe_backup "$BUCKET" "$LOG_DIR/last-r2-backup-date" remote "$FORCE" || true
do_upload "$BUCKET"

log_success "R2 sync complete"
