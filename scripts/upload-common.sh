#!/usr/bin/env bash
# AROI Validator - Common Upload Functions
# Shared by upload-do.sh and upload-r2.sh
# Uses unique remote names (aroi-r2, aroi-spaces) to avoid config conflicts.

set -euo pipefail

# Remote names (unique to this project)
AROI_R2_REMOTE="aroi-r2"
AROI_DO_REMOTE="aroi-spaces"

# Logging
log()         { echo "[$(date '+%H:%M:%S')]${STORAGE_NAME:+ [$STORAGE_NAME]} $1"; }
log_error()   { echo "[$(date '+%H:%M:%S')] ❌ $1" >&2; }
log_success() { echo "[$(date '+%H:%M:%S')] ✅ $1"; }

# Security: Validate config.env before sourcing
validate_config() {
    local config_file="$1"
    [[ -f "$config_file" ]] || return 1
    # Check config file is not world-writable
    local perms
    perms=$(stat -c '%a' "$config_file" 2>/dev/null || echo "644")
    if [[ "${perms: -1}" != "0" && "${perms: -1}" != "4" ]]; then
        log_error "Warning: $config_file has insecure permissions ($perms). Consider: chmod 600 $config_file"
    fi
    return 0
}

# Initialize paths and config
init_upload() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
    if [[ -f "$DEPLOY_DIR/config.env" ]]; then
        validate_config "$DEPLOY_DIR/config.env"
        source "$DEPLOY_DIR/config.env"
    fi
    
    SOURCE_DIR="${1:-${OUTPUT_DIR:-$DEPLOY_DIR/public}}"
    BACKUP_DIR="${BACKUP_DIR:-$DEPLOY_DIR/backups}"
    LOG_DIR="$DEPLOY_DIR/logs"
    RCLONE="${RCLONE_PATH:-$(command -v rclone 2>/dev/null || echo "$HOME/bin/rclone")}"
    TODAY=$(date '+%Y-%m-%d')
    TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')
    
    mkdir -p "$LOG_DIR" "$BACKUP_DIR"
    
    # Rclone defaults (can override per-backend)
    : "${TRANSFERS:=64}" "${CHECKERS:=128}" "${BUFFER:=64M}" "${S3_CONC:=16}" "${S3_CHUNK:=16M}"
}

check_rclone() {
    [[ -x "$RCLONE" ]] || { log_error "rclone not found at $RCLONE"; return 1; }
}

rclone_opts() {
    echo "--transfers=$TRANSFERS --checkers=$CHECKERS --buffer-size=$BUFFER"
    echo "--s3-upload-concurrency=$S3_CONC --s3-chunk-size=$S3_CHUNK"
    echo "--fast-list --stats=10s --stats-one-line --log-level=NOTICE"
    echo "--retries=5 --retries-sleep=2s --low-level-retries=10"
}

# Remote setup (creates if not exists)
ensure_remote() {
    local name=$1 provider=$2; shift 2
    $RCLONE listremotes 2>/dev/null | grep -q "^${name}:$" && return 0
    log "Creating remote '$name'..."
    $RCLONE config create "$name" s3 provider="$provider" "$@" --non-interactive >/dev/null
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
    # Security: Build options array to avoid word splitting issues
    local -a opts_array
    readarray -t opts_array < <(rclone_opts)
    
    if [[ "$type" == "local" ]]; then
        target="$BACKUP_DIR/backup-$TIMESTAMP"
        log "Local backup → $target"
        mkdir -p "$target"
        "$RCLONE" sync "$bucket" "$target" --exclude "_backups/**" "${opts_array[@]}" 2>&1 | head -5
    else
        target="$bucket/_backups/$TIMESTAMP"
        log "Remote backup → $target"
        "$RCLONE" sync "$bucket" "$target" --exclude "_backups/**" "${opts_array[@]}" 2>&1 | head -5
    fi
    echo "$TODAY" > "$marker"
    log_success "${type^} backup done"
}

# Main upload function
do_upload() {
    local bucket="$1"
    # Security: Build options array to avoid word splitting issues
    local -a opts_array
    readarray -t opts_array < <(rclone_opts)
    
    log "Syncing $SOURCE_DIR → $bucket"
    "$RCLONE" sync "$SOURCE_DIR" "$bucket" --exclude "_backups/**" --exclude "index.html" "${opts_array[@]}" 2>&1 | head -10
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
    echo "📦 ${storage}: $($RCLONE lsf "$bucket/_backups/" --dirs-only 2>/dev/null | sort -r | head -3 | tr '\n' ' ' || echo none)"
    echo "📅 Last local: $(cat "$local_marker" 2>/dev/null || echo never)"
    echo "📅 Last ${storage}: $(cat "$remote_marker" 2>/dev/null || echo never)"
}
