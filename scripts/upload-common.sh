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

# Initialize paths, rclone binary, and upload defaults from config.env.
init_upload() {
    init_paths 2  # Use grandparent caller's location
    load_config || true

    SOURCE_DIR="${1:-${OUTPUT_DIR:-$DEPLOY_DIR/public}}"
    ARCHIVE_DIR="${ARCHIVE_DIR:-$DEPLOY_DIR/local-archive}"
    LOG_DIR="$DEPLOY_DIR/logs"
    STAGE_DIR="$DEPLOY_DIR/tmp"  # same filesystem as public/: upload snapshots are hard links
    RCLONE="${RCLONE_PATH:-$(command -v rclone 2>/dev/null || echo "$HOME/bin/rclone")}"

    mkdir -p "$LOG_DIR" "$ARCHIVE_DIR" "$STAGE_DIR"

    # Rclone defaults (apply provider-specific config.env settings after load_config)
    if [[ "${STORAGE_NAME:-}" == "DO-Spaces" ]]; then
        TRANSFERS="${DO_RCLONE_TRANSFERS:-${TRANSFERS:-56}}"
        CHECKERS="${DO_RCLONE_CHECKERS:-${CHECKERS:-80}}"
    elif [[ "${STORAGE_NAME:-}" == "R2" ]]; then
        TRANSFERS="${RCLONE_TRANSFERS:-${TRANSFERS:-128}}"
        CHECKERS="${RCLONE_CHECKERS:-${CHECKERS:-256}}"
    fi
    : "${TRANSFERS:=64}" "${CHECKERS:=128}" "${BUFFER:=64M}" "${S3_CONC:=16}" "${S3_CHUNK:=16M}"
    TRANSFERS=$(validate_int_range "TRANSFERS" "$TRANSFERS" 1 512 64)
    CHECKERS=$(validate_int_range "CHECKERS" "$CHECKERS" 1 1024 128)
    S3_CONC=$(validate_int_range "S3_CONC" "$S3_CONC" 1 128 16)

    # All uploads use explicit --files-from + --no-traverse so S3 listings of
    # historical objects or _backups/ prefixes are never traversed per run.
    RCLONE_OPTS_ARRAY=(
        "--transfers=$TRANSFERS" "--checkers=$CHECKERS" "--buffer-size=$BUFFER"
        "--s3-upload-concurrency=$S3_CONC" "--s3-chunk-size=$S3_CHUNK"
        "--no-traverse" "--stats=10s" "--stats-one-line" "--log-level=NOTICE"
        "--retries=5" "--retries-sleep=2s" "--low-level-retries=10"
    )
}

# Acquire per-provider upload lock (fd 8). By default (wait_seconds=0), returns
# $UPLOAD_SKIPPED if a previous upload to this provider is still running.
# Passing wait_seconds > 0 waits up to that duration (used for backup uploads).
lock_upload() {
    local provider=$1 wait_seconds=${2:-0}
    local lock="$LOG_DIR/upload-${provider}.lock"
    exec 8>>"$lock"
    if [[ "$wait_seconds" -gt 0 ]]; then
        if ! flock -w "$wait_seconds" 8; then
            log_error "Upload lock busy after ${wait_seconds}s ($(lock_holder "$lock"))"
            exit 1
        fi
    else
        if ! flock -n 8; then
            log "Skipping upload: previous still running ($(lock_holder "$lock"))"
            exit "$UPLOAD_SKIPPED"
        fi
    fi
    note_lock_holder "$lock"
    # This provider's snapshot (see snapshot_source). One left by a killed upload is
    # removed here: holding the lock means no rclone of that upload still reads it.
    UPLOAD_SNAP="$STAGE_DIR/upload-${provider}.snap"
    remove_snapshot "$UPLOAD_SNAP" || true
}

# Remove an upload snapshot. cp -al copies directory modes from public/,
# so a read-only directory would make rm -rf fail. The directories are the
# snapshot's own: make them writable first. Never chmod files (hard links).
remove_snapshot() {
    local snap=$1 err
    [[ -n "$snap" ]] || return 0
    [[ -e "$snap" || -L "$snap" ]] || return 0
    find "$snap" -type d ! -perm -u=rwx -exec chmod u+rwx {} \; 2>/dev/null || true
    err=$(rm -rf "$snap" 2>&1) && return 0
    log "WARNING: cannot remove snapshot $snap (${err%%$'\n'*})"
    return 1
}

# Take a hard-link snapshot of SOURCE_DIR under public.lock (so never mid-publish) and
# set SYNC_SOURCE to it. Publishes and compress-old-data.sh only rename new files into
# public/ and never write in place, so the snapshot's files cannot change while rclone
# reads them. Falls back to SOURCE_DIR (with a warning) if the snapshot cannot be made.
snapshot_source() {
    local lock="$LOG_DIR/public.lock" err
    SYNC_SOURCE="$SOURCE_DIR"
    mkdir -p "$STAGE_DIR"
    if [[ -e "$UPLOAD_SNAP" || -L "$UPLOAD_SNAP" ]]; then
        log "WARNING: $UPLOAD_SNAP still present - uploading from $SOURCE_DIR directly"
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
        log "WARNING: snapshot failed (${err%%$'\n'*}); uploading from $SOURCE_DIR directly"
        remove_snapshot "$UPLOAD_SNAP" || true
    fi
    exec 7>&-
}

# Verify rclone binary exists and is executable.
check_rclone() {
    [[ -x "$RCLONE" ]] || { log_error "rclone not found at $RCLONE"; return 1; }
}

# Configure an rclone S3 remote if it does not already exist.
ensure_remote() {
    local name=$1 provider=$2; shift 2
    "$RCLONE" listremotes 2>/dev/null | grep -q "^${name}:$" && return 0
    log "Creating remote '$name'..."
    "$RCLONE" config create "$name" s3 provider="$provider" "$@" --non-interactive >/dev/null
    log_success "Remote '$name' configured"
}

# Ensure Cloudflare R2 rclone remote is configured.
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

# Ensure DigitalOcean Spaces rclone remote is configured.
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

# Print the first 10 and last 5 lines of rclone's output while draining stdin
# so rclone is never killed by SIGPIPE mid-transfer.
rclone_summary() {
    awk -v h=10 -v t=5 '
        NR <= h { print; fflush(); next }
        { last[NR % t] = $0 }
        END {
            if (NR > h + t) print "... (" (NR - h - t) " line(s) omitted)"
            for (i = (NR > h + t ? NR - t + 1 : h + 1); i <= NR; i++) print last[i % t]
        }'
}

# Append-only live bucket upload using per-provider ledger:
#   1. Copies un-uploaded non-empty aroi_validation_*.json files with --ignore-existing.
#   2. Updates the provider ledger only after rclone copy exits 0.
#   3. Always uploads latest.json and files.json (overwriting remote metadata).
do_upload() {
    local bucket=$1 provider_id=$2 full_copy=${3:-false}
    local rc=0 ledger_file work_dir local_list pending_file meta_file tmp_ledger pending_count mf

    snapshot_source || return 1

    ledger_file="$LOG_DIR/uploaded-${provider_id}.txt"
    work_dir=$(mktemp -d "$STAGE_DIR/upload-${provider_id}.XXXXXX")
    local_list="$work_dir/local.txt"
    pending_file="$work_dir/pending.txt"
    meta_file="$work_dir/meta.txt"
    tmp_ledger="$work_dir/ledger.txt"

    list_nonempty_validation_files "$SYNC_SOURCE" > "$local_list"

    if [[ "$full_copy" == "true" || ! -s "$ledger_file" ]]; then
        cp "$local_list" "$pending_file"
    else
        grep -E "$AROI_JSON_REGEX" "$ledger_file" 2>/dev/null | LC_ALL=C sort -u > "$tmp_ledger" || true
        comm -23 "$local_list" "$tmp_ledger" > "$pending_file"
    fi

    if [[ -s "$pending_file" ]]; then
        pending_count=$(wc -l < "$pending_file" | tr -d '[:space:]')
        log "Copying $pending_count validation file(s) → $bucket"
        "$RCLONE" copy "$SYNC_SOURCE" "$bucket" \
            --files-from "$pending_file" --ignore-existing \
            "${RCLONE_OPTS_ARRAY[@]}" 2>&1 | rclone_summary || rc=${PIPESTATUS[0]}
        if [[ $rc -ne 0 ]]; then
            log_error "Copy to $bucket failed (rclone exit $rc)"
            rm -rf "$work_dir"
            remove_snapshot "$UPLOAD_SNAP" || true
            return "$rc"
        fi
        {
            [[ -f "$ledger_file" ]] && grep -E "$AROI_JSON_REGEX" "$ledger_file" 2>/dev/null || true
            cat "$pending_file"
        } | LC_ALL=C sort -u > "$work_dir/ledger.new"
        chmod 644 "$work_dir/ledger.new"
        mv -f "$work_dir/ledger.new" "$ledger_file"
    else
        log "No new hourly JSON files to copy"
    fi

    : > "$meta_file"
    for mf in latest.json files.json; do
        [[ -s "$SYNC_SOURCE/$mf" ]] && echo "$mf" >> "$meta_file"
    done

    if [[ -s "$meta_file" ]]; then
        log "Updating metadata → $bucket"
        "$RCLONE" copy "$SYNC_SOURCE" "$bucket" \
            --files-from "$meta_file" \
            "${RCLONE_OPTS_ARRAY[@]}" 2>&1 | rclone_summary || rc=${PIPESTATUS[0]}
        if [[ $rc -ne 0 ]]; then
            log_error "Metadata copy to $bucket failed (rclone exit $rc)"
            rm -rf "$work_dir"
            remove_snapshot "$UPLOAD_SNAP" || true
            return "$rc"
        fi
    fi

    rm -rf "$work_dir"
    remove_snapshot "$UPLOAD_SNAP" || true
    log_success "Upload complete"
}

# Upload monthly zstd archives and their .list manifests from ARCHIVE_DIR to
# $bucket/_backups/ (never deletes remote backup objects).
upload_zstd_backups() {
    local bucket=$1 month=${2:-}
    local list_file rc=0 count=0 name

    if [[ -n "$month" ]]; then
        validate_pattern "$month" '^[0-9]{6}$' "month" || return 1
    fi
    [[ -d "$ARCHIVE_DIR" ]] || { log_error "Archive directory not found: $ARCHIVE_DIR"; return 1; }

    list_file=$(mktemp "$STAGE_DIR/backup-files.XXXXXX")
    if [[ -n "$month" ]]; then
        for name in "aroi-${month}.tar.zst" "aroi-${month}.list"; do
            if [[ ! -s "$ARCHIVE_DIR/$name" ]]; then
                log_error "Missing or empty backup artifact: $ARCHIVE_DIR/$name"
                rm -f "$list_file"
                return 1
            fi
            echo "$name" >> "$list_file"
        done
    else
        (
            cd "$ARCHIVE_DIR"
            find . -maxdepth 1 \( -name 'aroi-*.tar.zst' -o -name 'aroi-*.list' \) -type f -size +0c 2>/dev/null \
                | sed 's|^\./||' \
                | grep -E '^aroi-[0-9]{6}\.(tar\.zst|list)$' \
                | LC_ALL=C sort -u || true
        ) > "$list_file"
        if [[ ! -s "$list_file" ]]; then
            log "No zstd archives found in $ARCHIVE_DIR"
            rm -f "$list_file"
            return 0
        fi
    fi

    count=$(wc -l < "$list_file" | tr -d '[:space:]')
    log "Uploading $count zstd backup artifact(s) → $bucket/_backups/"
    "$RCLONE" copy "$ARCHIVE_DIR" "$bucket/_backups" \
        --files-from "$list_file" \
        "${RCLONE_OPTS_ARRAY[@]}" 2>&1 | rclone_summary || rc=${PIPESTATUS[0]}
    rm -f "$list_file"
    if [[ $rc -ne 0 ]]; then
        log_error "Backup archive upload to $bucket/_backups failed (rclone exit $rc)"
        return "$rc"
    fi
    log_success "Uploaded zstd backup(s) to $bucket/_backups"
}

# List local and remote zstd backup archives.
list_backups() {
    local bucket=$1 storage=$2
    echo "📦 Local ($ARCHIVE_DIR):"
    if [[ -d "$ARCHIVE_DIR" ]] && compgen -G "$ARCHIVE_DIR/aroi-*.tar.zst" >/dev/null 2>&1; then
        local zf
        while IFS= read -r zf; do
            [[ -n "$zf" ]] && printf '  %s\t%s\n' "$(du -sh "$zf" 2>/dev/null | cut -f1)" "$(basename "$zf")"
        done < <(find "$ARCHIVE_DIR" -maxdepth 1 -name 'aroi-*.tar.zst' -type f 2>/dev/null | LC_ALL=C sort | tail -12)
    else
        echo "  (none)"
    fi
    echo "📦 ${storage} ($bucket/_backups/):"
    "$RCLONE" lsf "$bucket/_backups/" --max-depth 1 --files-only --include "aroi-*.tar.zst" 2>/dev/null \
        | LC_ALL=C sort -r | head -12 || echo "  (none)"
}
