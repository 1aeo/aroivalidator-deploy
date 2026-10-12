#!/usr/bin/env bash
# AROI Validator - Prune Old Backups
# Removes old local and R2 backups (keeps last N)
#
# Usage:
#   ./prune-backups.sh              # Prune old backups
#   ./prune-backups.sh --dry-run    # Show what would be pruned

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_config || true

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

BACKUP_DIR="${BACKUP_DIR:-$DEPLOY_DIR/backups}"
RCLONE="${RCLONE_PATH:-$(command -v rclone 2>/dev/null || echo "$HOME/bin/rclone")}"
KEEP_BACKUPS="${KEEP_BACKUPS:-7}"
[[ "$KEEP_BACKUPS" -lt 1 ]] && KEEP_BACKUPS=1
PRUNE_THRESHOLD=$((KEEP_BACKUPS + 2))

log() { echo "[PRUNE] [$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
count_lines() { local c; c=$(echo "$1" | grep -c . 2>/dev/null) || c=0; echo "$c"; }

prune_local() {
    [[ -d "$BACKUP_DIR" ]] || return 0
    local all
    all=$(ls -1dt "$BACKUP_DIR"/backup-* 2>/dev/null) || return 0
    local count=$(count_lines "$all")

    if [[ "$count" -le "$PRUNE_THRESHOLD" ]]; then
        log "Local: $count backups (need >$PRUNE_THRESHOLD to prune)"
        return 0
    fi

    local to_delete
    to_delete=$(echo "$all" | tail -n +$((KEEP_BACKUPS + 1)))
    log "Local: $count found, pruning $(count_lines "$to_delete") (keeping $KEEP_BACKUPS)..."

    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        local size
        size=$(du -sh "$dir" 2>/dev/null | cut -f1) || size="?"
        if $DRY_RUN; then
            log "[DRY-RUN] Would remove: $(basename "$dir") ($size)"
        else
            rm -rf "$dir"
            log "  Removed: $(basename "$dir") ($size)"
        fi
    done <<< "$to_delete"

    $DRY_RUN || log "✅ Local prune done"
}

prune_r2() {
    [[ -n "${R2_BUCKET:-}" && -x "$RCLONE" ]] || return 0

    local bucket="aroi-r2:${R2_BUCKET}"
    local all
    all=$("$RCLONE" lsf "$bucket/_backups/" --dirs-only 2>/dev/null) || return 0
    local count=$(count_lines "$all")

    if [[ "$count" -le "$PRUNE_THRESHOLD" ]]; then
        log "R2: $count backups (need >$PRUNE_THRESHOLD to prune)"
        return 0
    fi

    local to_delete
    to_delete=$(echo "$all" | sort -r | tail -n +$((KEEP_BACKUPS + 1)))
    log "R2: $count found, pruning $(count_lines "$to_delete") (keeping $KEEP_BACKUPS)..."

    while IFS= read -r backup; do
        [[ -z "$backup" ]] && continue
        if $DRY_RUN; then
            log "[DRY-RUN] Would remove: R2/_backups/$backup"
        else
            "$RCLONE" purge "$bucket/_backups/$backup" 2>/dev/null || true
            log "  Removed: R2/_backups/$backup"
        fi
    done <<< "$to_delete"

    $DRY_RUN || log "✅ R2 prune done"
}

# One prune at a time: hourly runs overlap while they wait for their uploads
LOCK_FILE="$DEPLOY_DIR/logs/prune.lock"
mkdir -p "$DEPLOY_DIR/logs"
exec 9>>"$LOCK_FILE"
if ! flock -n 9; then
    log "Another prune is running ($(lock_holder "$LOCK_FILE")), skipping"
    exit 0
fi
note_lock_holder "$LOCK_FILE"

log "Starting (keep=$KEEP_BACKUPS, dry_run=$DRY_RUN)..."
prune_local
prune_r2
log "Finished"
