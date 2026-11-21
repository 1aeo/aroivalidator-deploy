#!/usr/bin/env bash
# AROI Validator - Upload to DigitalOcean Spaces (Primary)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/upload-common.sh"

# shellcheck disable=SC2034  # used by upload-common.sh
STORAGE_NAME="DO-Spaces"

MODE="live"
FULL_COPY=false
BACKUP_MONTH=""
BACKUP_SRC_DIR=""
FORCE_BACKUPS=false

case "${1:-}" in
    --list-backups)
        init_upload; check_rclone; ensure_do_remote
        list_backups "${AROI_DO_REMOTE}:${DO_SPACES_BUCKET:?}" "DO"
        exit 0
        ;;
    --upload-backups)
        MODE="backups"
        BACKUP_MONTH="${2:-}"
        init_upload
        ;;
    --repair-backups)
        MODE="backups"
        FORCE_BACKUPS=true
        BACKUP_MONTH="${2:-}"
        BACKUP_SRC_DIR="${3:-}"
        init_upload
        ;;
    --full-copy)
        FULL_COPY=true
        init_upload "${2:-}"
        ;;
    --help|-h)
        echo "Usage: $0 [source_dir] | --full-copy [source_dir] | --upload-backups [YYYYMM] | --repair-backups [YYYYMM] [src_dir] | --list-backups"
        exit 0
        ;;
    --*)
        log_error "Unknown option: $1"
        exit 2
        ;;
    *)
        init_upload "${1:-}"
        ;;
esac

if [[ "$MODE" == "backups" ]]; then
    lock_upload "do" 300
    check_rclone || exit 1
    ensure_do_remote || exit 1
    BUCKET="${AROI_DO_REMOTE}:${DO_SPACES_BUCKET:?}"
    upload_zstd_backups "$BUCKET" "$BACKUP_MONTH" "$FORCE_BACKUPS" "$BACKUP_SRC_DIR"
    exit 0
fi

lock_upload "do" 0  # exits $UPLOAD_SKIPPED if the previous DO upload is still running
check_rclone || exit 1
[[ -d "$SOURCE_DIR" ]] || { log_error "Source not found: $SOURCE_DIR"; exit 1; }
ensure_do_remote || exit 1

BUCKET="${AROI_DO_REMOTE}:${DO_SPACES_BUCKET:?}"
log "🌊 DO Spaces: ${DO_SPACES_BUCKET} | $TRANSFERS transfers"

do_upload "$BUCKET" "do" "$FULL_COPY"

log_success "DO Spaces upload complete"
