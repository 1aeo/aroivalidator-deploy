#!/usr/bin/env bash
# AROI Validator - Common Upload Functions
# Shared by upload-do.sh and upload-r2.sh
# Uses unique remote names (aroi-r2, aroi-spaces) to avoid config conflicts.

set -euo pipefail

# Source shared functions
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Remote names (unique to this project)
AROI_R2_REMOTE="aroi-r2"
AROI_DO_REMOTE="aroi-spaces"

# Cached rclone options (populated by init_upload)
declare -a RCLONE_OPTS_ARRAY=()

# Initialize paths and config
init_upload() {
    init_paths 2  # Use grandparent caller's location
    load_config || true
    
    SOURCE_DIR="${1:-${OUTPUT_DIR:-$DEPLOY_DIR/public}}"
    BACKUP_DIR="${BACKUP_DIR:-$DEPLOY_DIR/backups}"
    LOG_DIR="$DEPLOY_DIR/logs"
    STAGE_DIR="$DEPLOY_DIR/tmp"  # same filesystem as public/: upload snapshots are hard links
    RCLONE="${RCLONE_PATH:-$(command -v rclone 2>/dev/null || echo "$HOME/bin/rclone")}"
    TODAY=$(date '+%Y-%m-%d')
    TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')
    
    mkdir -p "$LOG_DIR" "$BACKUP_DIR"
    
    # Rclone defaults (can override per-backend)
    : "${TRANSFERS:=64}" "${CHECKERS:=128}" "${BUFFER:=64M}" "${S3_CONC:=16}" "${S3_CHUNK:=16M}"
    
    # Cache rclone options array once
    RCLONE_OPTS_ARRAY=(
        "--transfers=$TRANSFERS" "--checkers=$CHECKERS" "--buffer-size=$BUFFER"
        "--s3-upload-concurrency=$S3_CONC" "--s3-chunk-size=$S3_CHUNK"
        "--fast-list" "--stats=10s" "--stats-one-line" "--log-level=NOTICE"
        "--retries=5" "--retries-sleep=2s" "--low-level-retries=10"
    )
}

# Per-provider lock, held until this script and its rclone children exit, so a long
# backup/sync never overlaps the next upload to the same provider. A busy provider
# is skipped rather than waited for: rclone sync is idempotent, the next run catches up.
lock_upload() {
    local lock="$LOG_DIR/upload-$1.lock"
    exec 8>>"$lock"
    if ! flock -n 8; then
        log "Skipping upload: previous still running ($(lock_holder "$lock"))"
        exit "$UPLOAD_SKIPPED"
    fi
    note_lock_holder "$lock"
    # This provider's snapshot (see snapshot_source). One left by a killed upload is
    # removed here: holding the lock means no rclone of that upload still reads it.
    UPLOAD_SNAP="$STAGE_DIR/upload-$1.snap"
    remove_snapshot "$UPLOAD_SNAP" || true
}

# Remove an upload snapshot. cp -a gives its directories the modes of those in public/,
# so a read-only directory there (e.g. archives/ at 555) would make rm -rf fail, and
# with it every later upload to this provider. The directories are the snapshot's own:
# make them writable first. Never chmod its files: they are hard links to the published
# files and share their modes. Warns and returns 1 if it still cannot be removed.
remove_snapshot() {
    local snap=$1 err
    [[ -e "$snap" || -L "$snap" ]] || return 0
    find "$snap" -type d ! -perm -u=rwx -exec chmod u+rwx {} \; 2>/dev/null || true
    err=$(rm -rf "$snap" 2>&1) && return 0
    log "WARNING: cannot remove snapshot $snap (${err%%$'\n'*})"
    return 1
}

# Take a hard-link snapshot of SOURCE_DIR under public.lock (so never mid-publish) and
# set SYNC_SOURCE to it. Publishes and compress-old-data.sh only rename new files into
# public/ and never write in place, so the snapshot's files cannot change while rclone
# reads them. Syncing public/ itself, a publish during a long sync makes rclone fail
# the file ("corrupted on transfer"), skip deletions and retry the whole sync.
# Falls back to SOURCE_DIR (with a warning) if the snapshot cannot be made.
snapshot_source() {
    local lock="$LOG_DIR/public.lock" err
    SYNC_SOURCE="$SOURCE_DIR"
    mkdir -p "$STAGE_DIR"
    # lock_upload could not remove the last snapshot (and warned). Copying into it would
    # add back files since deleted from public/, and the sync would upload them again.
    if [[ -e "$UPLOAD_SNAP" || -L "$UPLOAD_SNAP" ]]; then
        log "WARNING: $UPLOAD_SNAP still present - syncing $SOURCE_DIR directly"
        UPLOAD_SNAP=""
        return 0
    fi
    exec 7>>"$lock"
    if ! flock -w "$PUBLIC_LOCK_WAIT" 7; then
        log_error "Not uploading: public.lock still held after ${PUBLIC_LOCK_WAIT}s ($(lock_holder "$lock"))"
        exec 7>&-
        return 1
    fi
    note_lock_holder "$lock"
    if err=$(cp -al "$SOURCE_DIR/." "$UPLOAD_SNAP" 2>&1); then  # "/.": follow a symlinked SOURCE_DIR
        SYNC_SOURCE="$UPLOAD_SNAP"
    else
        log "WARNING: snapshot failed (${err%%$'\n'*}) - syncing $SOURCE_DIR directly"
        remove_snapshot "$UPLOAD_SNAP" || true
    fi
    exec 7>&-
}

check_rclone() {
    [[ -x "$RCLONE" ]] || { log_error "rclone not found at $RCLONE"; return 1; }
}

# Remote setup (creates if not exists)
ensure_remote() {
    local name=$1 provider=$2; shift 2
    "$RCLONE" listremotes 2>/dev/null | grep -q "^${name}:$" && return 0
    log "Creating remote '$name'..."
    "$RCLONE" config create "$name" s3 provider="$provider" "$@" --non-interactive >/dev/null
    log_success "Remote '$name' configured"
}

ensure_r2_remote() {
    [[ -n "${R2_ACCESS_KEY_ID:-}" && -n "${R2_SECRET_ACCESS_KEY:-}" && -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]] || {
        log_error "R2 credentials not set"; return 1
    }
    ensure_remote "$AROI_R2_REMOTE" Cloudflare \
        access_key_id="$R2_ACCESS_KEY_ID" \
        secret_access_key="$R2_SECRET_ACCESS_KEY" \
        endpoint="https://${CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com" \
        acl=private
}

ensure_do_remote() {
    [[ -n "${DO_SPACES_KEY:-}" && -n "${DO_SPACES_SECRET:-}" ]] || {
        log_error "DO credentials not set"; return 1
    }
    ensure_remote "$AROI_DO_REMOTE" DigitalOcean \
        access_key_id="$DO_SPACES_KEY" \
        secret_access_key="$DO_SPACES_SECRET" \
        endpoint="${DO_SPACES_REGION:-nyc3}.digitaloceanspaces.com" \
        acl=public-read no_check_bucket=true
}

# Backup if not done today (returns 0 if backup made, 1 if skipped)
maybe_backup() {
    local bucket="$1" marker="$2" type="$3" force="${4:-false}"
    [[ "$force" == "true" ]] || { [[ -f "$marker" && "$(cat "$marker")" == "$TODAY" ]] && return 1; }
    
    local target
    if [[ "$type" == "local" ]]; then
        target="$BACKUP_DIR/backup-$TIMESTAMP"
        log "Local backup → $target"
        mkdir -p "$target"
        "$RCLONE" sync "$bucket" "$target" --exclude "_backups/**" "${RCLONE_OPTS_ARRAY[@]}" 2>&1 | head -5
    else
        target="$bucket/_backups/$TIMESTAMP"
        log "Remote backup → $target"
        "$RCLONE" sync "$bucket" "$target" --exclude "_backups/**" "${RCLONE_OPTS_ARRAY[@]}" 2>&1 | head -5
    fi
    echo "$TODAY" > "$marker"
    log_success "${type^} backup done"
}

# Main upload function
do_upload() {
    local bucket="$1" rc=0
    snapshot_source || return 1
    log "Syncing $SYNC_SOURCE → $bucket"
    "$RCLONE" sync "$SYNC_SOURCE" "$bucket" --exclude "_backups/**" --exclude "index.html" "${RCLONE_OPTS_ARRAY[@]}" 2>&1 | head -10 || rc=$?
    # Not an EXIT trap: that would also run if this script is killed while its rclone
    # keeps reading the snapshot. A leftover is removed by the next lock_upload.
    remove_snapshot "$UPLOAD_SNAP" || true
    [[ $rc -eq 0 ]] || return "$rc"
    log_success "Upload complete"
}

# List backups helper
list_backups() {
    local bucket="$1"
    local storage="$2"
    local storage_lower=$(echo "$storage" | tr '[:upper:]' '[:lower:]')
    local local_marker="$LOG_DIR/last-${storage_lower}-local-backup-date"
    local remote_marker="$LOG_DIR/last-${storage_lower}-backup-date"
    
    echo "📦 Local: $(ls -1dt "$BACKUP_DIR"/backup-* 2>/dev/null | head -3 | tr '\n' ' ' || echo none)"
    echo "📦 ${storage}: $("$RCLONE" lsf "$bucket/_backups/" --dirs-only 2>/dev/null | sort -r | head -3 | tr '\n' ' ' || echo none)"
    echo "📅 Last local: $(cat "$local_marker" 2>/dev/null || echo never)"
    echo "📅 Last ${storage}: $(cat "$remote_marker" 2>/dev/null || echo never)"
}
