#!/usr/bin/env bash
# AROI Validator - Legacy Uncompressed Backup Cleaner
# Removes ONLY legacy timestamped uncompressed backup copies:
#   - Local:  $BACKUP_DIR/backup-YYYY-MM-DD_HHMMSS
#   - Remote: $bucket/_backups/YYYY-MM-DD_HHMMSS/
#
# Never touches backups/cron/, local-archive/, or zstd monthly backups
# (_backups/aroi-YYYYMM.tar.zst and _backups/aroi-YYYYMM.list).
#
# Usage:
#   ./prune-backups.sh [--dry-run] [--keep N] [--provider all|local|do|r2] [--tpslimit N] [--force]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
init_paths
load_config || true

BACKUP_DIR="${BACKUP_DIR:-$DEPLOY_DIR/backups}"
ARCHIVE_DIR="${ARCHIVE_DIR:-$DEPLOY_DIR/local-archive}"
RCLONE="${RCLONE_PATH:-$(command -v rclone 2>/dev/null || echo "$HOME/bin/rclone")}"

DRY_RUN=false
FORCE=false
PROVIDER="all"
KEEP_LEGACY_BACKUPS="${KEEP_LEGACY_BACKUPS:-0}"
TPSLIMIT="${DO_PURGE_TPSLIMIT:-}"

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --dry-run             Show what would be removed without deleting
  --keep N              Number of newest legacy backups to retain (default: $KEEP_LEGACY_BACKUPS)
  --provider TARGET     One of: all, local, do, r2 (default: all)
  --tpslimit N          Limit rclone API transactions/sec for remote purges
  --force               Allow deleting all remote legacy backups even if no .tar.zst exists remotely
  --help, -h            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --keep)
            [[ $# -ge 2 ]] || { echo "ERROR: --keep requires a non-negative integer" >&2; exit 2; }
            KEEP_LEGACY_BACKUPS="$2"
            shift 2
            ;;
        --provider)
            [[ $# -ge 2 ]] || { echo "ERROR: --provider requires a value" >&2; exit 2; }
            case "$2" in
                all|local|do|r2) PROVIDER="$2" ;;
                *) echo "ERROR: invalid --provider '$2' (expected all|local|do|r2)" >&2; exit 2 ;;
            esac
            shift 2
            ;;
        --tpslimit)
            [[ $# -ge 2 ]] || { echo "ERROR: --tpslimit requires a positive integer" >&2; exit 2; }
            TPSLIMIT="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# Validate argument/environment integers without Bash arithmetic overflow
raw_keep=$KEEP_LEGACY_BACKUPS
if ! KEEP_LEGACY_BACKUPS=$(parse_int_in_range "$raw_keep" 0 3650); then
    echo "ERROR: invalid KEEP_LEGACY_BACKUPS='$raw_keep' (expected integer 0-3650)" >&2
    exit 2
fi

if [[ -n "$TPSLIMIT" ]]; then
    raw_tps=$TPSLIMIT
    if ! TPSLIMIT=$(parse_int_in_range "$raw_tps" 1 10000); then
        echo "ERROR: invalid DO_PURGE_TPSLIMIT/tpslimit='$raw_tps' (expected integer 1-10000)" >&2
        exit 2
    fi
fi

log() { echo "[PRUNE] [$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
count_lines() { local c; c=$(grep -c . <<< "$1" 2>/dev/null) || c=0; echo "$c"; }

ERRORS=0

prune_local() {
    [[ -d "$BACKUP_DIR" ]] || { log "Local: backup directory not present ($BACKUP_DIR)"; return 0; }

    local raw_dirs all
    if ! raw_dirs=$(
        cd "$BACKUP_DIR" || exit 1
        find . -maxdepth 1 -type d -name 'backup-*'
    ); then
        log "ERROR: failed scanning local backup directory ($BACKUP_DIR)"
        ERRORS=$((ERRORS + 1))
        return 1
    fi
    all=$(printf '%s\n' "$raw_dirs" \
        | sed 's|^\./||' \
        | grep -E '^backup-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' \
        | LC_ALL=C sort -r || true)
    local count
    count=$(count_lines "$all")

    if (( count <= KEEP_LEGACY_BACKUPS )); then
        log "Local: $count legacy backup(s) (keeping $KEEP_LEGACY_BACKUPS)"
        return 0
    fi

    local to_delete
    to_delete=$(printf '%s\n' "$all" | tail -n +$((KEEP_LEGACY_BACKUPS + 1)))
    log "Local: $count legacy backup(s) found, pruning $(count_lines "$to_delete") (keeping $KEEP_LEGACY_BACKUPS)..."

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        local dir="$BACKUP_DIR/$name"
        local size
        size=$(du -sh "$dir" 2>/dev/null | cut -f1) || size="?"
        if $DRY_RUN; then
            log "[DRY-RUN] Would remove local: $name ($size)"
        else
            find "$dir" -type d ! -perm -u=rwx -exec chmod u+rwx {} + 2>/dev/null || true
            if rm -rf "$dir"; then
                log "  Removed local: $name ($size)"
            else
                log "  ERROR: failed to remove local $name"
                ERRORS=$((ERRORS + 1))
            fi
        fi
    done <<< "$to_delete"

    $DRY_RUN || log "Local legacy prune finished"
}

prune_remote() {
    local label=$1 bucket=$2
    [[ -x "$RCLONE" ]] || { log "ERROR: rclone not found at $RCLONE"; ERRORS=$((ERRORS + 1)); return 1; }

    if ! $DRY_RUN && (( KEEP_LEGACY_BACKUPS == 0 )) && ! $FORCE; then
        local zst_check
        zst_check=$("$RCLONE" lsf "$bucket/_backups/" --max-depth 1 --files-only --include "aroi-*.tar.zst" 2>/dev/null || true)
        if [[ -z "$zst_check" ]]; then
            log "ERROR: refusing to remove all legacy $label backups because no aroi-*.tar.zst exists in $bucket/_backups/ (pass --force to override)"
            ERRORS=$((ERRORS + 1))
            return 1
        fi
    fi

    local raw_dirs all
    if ! raw_dirs=$("$RCLONE" lsf "$bucket/_backups/" --max-depth 1 --dirs-only 2>&1); then
        log "ERROR: failed listing $label _backups/: ${raw_dirs%%$'\n'*}"
        ERRORS=$((ERRORS + 1))
        return 1
    fi

    all=$(printf '%s\n' "$raw_dirs" \
        | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}/$' \
        | LC_ALL=C sort -r || true)
    local count
    count=$(count_lines "$all")

    if (( count <= KEEP_LEGACY_BACKUPS )); then
        log "$label: $count legacy backup(s) (keeping $KEEP_LEGACY_BACKUPS)"
        return 0
    fi

    local to_delete
    to_delete=$(printf '%s\n' "$all" | tail -n +$((KEEP_LEGACY_BACKUPS + 1)))
    log "$label: $count legacy backup(s) found, pruning $(count_lines "$to_delete") (keeping $KEEP_LEGACY_BACKUPS)..."

    local -a extra_opts=()
    if [[ -n "$TPSLIMIT" ]]; then
        extra_opts+=("--tpslimit=$TPSLIMIT" "--tpslimit-burst=$TPSLIMIT")
    fi

    local failed_here=0
    while IFS= read -r backup; do
        [[ -z "$backup" ]] && continue
        if $DRY_RUN; then
            log "[DRY-RUN] Would purge: $label/_backups/$backup"
        else
            local err_out
            if err_out=$("$RCLONE" purge "$bucket/_backups/$backup" "${extra_opts[@]}" 2>&1); then
                log "  Removed: $label/_backups/$backup"
            else
                log "  ERROR: failed to purge $label/_backups/$backup (${err_out%%$'\n'*})"
                failed_here=$((failed_here + 1))
                ERRORS=$((ERRORS + 1))
            fi
        fi
    done <<< "$to_delete"

    if ! $DRY_RUN && (( failed_here == 0 )); then
        log "✅ $label legacy prune done"
    elif ! $DRY_RUN; then
        log "⚠ $label legacy prune completed with $failed_here failure(s)"
    fi
}

LOCK_FILE="$DEPLOY_DIR/logs/prune.lock"
mkdir -p "$DEPLOY_DIR/logs"
exec 9>>"$LOCK_FILE"
if ! flock -n 9; then
    log "Another prune is running ($(lock_holder "$LOCK_FILE")), skipping"
    exit 0
fi
note_lock_holder "$LOCK_FILE"

log "Starting (provider=$PROVIDER, keep_legacy=$KEEP_LEGACY_BACKUPS, dry_run=$DRY_RUN)..."

if [[ "$PROVIDER" == "all" || "$PROVIDER" == "local" ]]; then
    prune_local || true
fi
if [[ "$PROVIDER" == "all" || "$PROVIDER" == "do" ]]; then
    if [[ -n "${DO_SPACES_BUCKET:-}" ]]; then
        DO_URI=$(resolve_do_bucket)
        prune_remote "DO" "$DO_URI" || true
    elif [[ "$PROVIDER" == "do" ]]; then
        log "ERROR: DO_SPACES_BUCKET is not set"
        ERRORS=$((ERRORS + 1))
    fi
fi
if [[ "$PROVIDER" == "all" || "$PROVIDER" == "r2" ]]; then
    if [[ -n "${R2_BUCKET:-}" ]]; then
        R2_URI=$(resolve_r2_bucket)
        prune_remote "R2" "$R2_URI" || true
    elif [[ "$PROVIDER" == "r2" ]]; then
        log "ERROR: R2_BUCKET is not set"
        ERRORS=$((ERRORS + 1))
    fi
fi

log "Finished (errors=$ERRORS)"
(( ERRORS == 0 ))
