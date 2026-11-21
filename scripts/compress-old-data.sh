#!/usr/bin/env bash
# AROI Validator - Monthly & Daily Zstd Archival + Log Compression
#
# Creates highly compressed monthly zstd archives (aroi-YYYYMM.tar.zst + .list)
# in local-archive/, uploads them to DO Spaces and R2 _backups/, and removes
# completed-month uncompressed JSONs from public/ ONLY after verifying:
#   1. Local .tar.zst passes zstd integrity + exact tar member verification.
#   2. Both DO Spaces and R2 (when enabled) hold every hourly JSON live AND
#      hold matching _backups/aroi-YYYYMM.tar.zst archives.
#
# Usage:
#   ./compress-old-data.sh                 # Full run: archive months, verify+prune completed, rotate logs
#   ./compress-old-data.sh --daily         # Daily run: archive/refresh months, verify+prune completed
#   ./compress-old-data.sh --month YYYYMM  # Archive (and verify+prune if completed) a specific month
#   ./compress-old-data.sh --no-upload     # Build local archives only (skips remote upload & local deletion)

set -euo pipefail

# Security: Use safe umask for created files
umask 077

# Source shared functions and initialize paths
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
init_paths
load_config || true

PUBLIC_DIR="${OUTPUT_DIR:-$DEPLOY_DIR/public}"
ARCHIVE_DIR="${ARCHIVE_DIR:-$DEPLOY_DIR/local-archive}"
LOG_DIR="$DEPLOY_DIR/logs"
STAGE_DIR="$DEPLOY_DIR/tmp"  # same filesystem as public/ and local-archive/
RCLONE="${RCLONE_PATH:-$(command -v rclone 2>/dev/null || echo "$HOME/bin/rclone")}"

: "${DO_ENABLED:=false}" "${R2_ENABLED:=false}"
ZSTD_LEVEL=$(validate_int_range "ZSTD_LEVEL" "${ZSTD_LEVEL:-12}" 1 19 12)
ZSTD_LONG=$(validate_int_range "ZSTD_LONG" "${ZSTD_LONG:-27}" 10 27 27)
MIN_FREE_GB=$(validate_int_range "MIN_FREE_GB" "${MIN_FREE_GB:-5}" 1 1000 5)

DAILY_MODE=false
NO_UPLOAD=false
TARGET_MONTH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --daily)
            DAILY_MODE=true
            shift
            ;;
        --no-upload)
            NO_UPLOAD=true
            shift
            ;;
        --month)
            [[ $# -ge 2 ]] || { echo "ERROR: --month requires YYYYMM" >&2; exit 2; }
            validate_pattern "$2" '^[0-9]{6}$' "month" || exit 2
            TARGET_MONTH="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--daily] [--month YYYYMM] [--no-upload]"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            exit 2
            ;;
    esac
done

echo "========================================="
echo "Data Archival - $(date)"
echo "========================================="

# Dependencies
for cmd in zstd tar jq; do
    require_cmd "$cmd" || exit 1
done
if [[ "$NO_UPLOAD" != "true" ]] && [[ "$DO_ENABLED" == "true" || "$R2_ENABLED" == "true" ]]; then
    [[ -x "$RCLONE" ]] || { log_error "rclone not found at $RCLONE"; exit 1; }
fi

mkdir -p "$PUBLIC_DIR" "$ARCHIVE_DIR" "$LOG_DIR/archives" "$STAGE_DIR"
chmod 755 "$PUBLIC_DIR" "$ARCHIVE_DIR" "$LOG_DIR/archives"

# Prevent concurrent archival runs (daily hook vs monthly cron)
COMPRESS_LOCK="$LOG_DIR/compress.lock"
exec 9>>"$COMPRESS_LOCK"
if ! flock -n 9; then
    echo "Already running (another compress instance holds lock: $(lock_holder "$COMPRESS_LOCK")) - skipping"
    exit 0
fi
note_lock_holder "$COMPRESS_LOCK"

# Check available disk space
AVAILABLE=$(available_gb "$DEPLOY_DIR")
if [[ -z "$AVAILABLE" ]] || (( AVAILABLE < MIN_FREE_GB )); then
    echo "ERROR: Less than ${MIN_FREE_GB}GB free disk space (${AVAILABLE:-?}GB free). Aborting."
    exit 1
fi

COMPRESS_LOCK_WAIT=3600
PUBLIC_LOCK="$LOG_DIR/public.lock"
CURRENT_MONTH=$(date '+%Y%m')
ERRORS=0
FAILED_MONTHS=" "
declare -a ARCHIVED_MONTHS=()
declare -a COMPLETED_CANDIDATES=()

mark_month_failed() {
    case "$FAILED_MONTHS" in
        *" $1 "*) ;;
        *) FAILED_MONTHS="${FAILED_MONTHS}$1 " ;;
    esac
}

is_month_failed() {
    case "$FAILED_MONTHS" in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# Snapshot a month's non-empty files from PUBLIC_DIR into snap_dir using hard links
# (cross-device fallback to cp -p), holding public.lock only for the directory scan/link.
snapshot_month_files() {
    local month=$1 snap_dir=$2
    exec 7>>"$PUBLIC_LOCK"
    if ! flock -w "$COMPRESS_LOCK_WAIT" 7; then
        echo "ERROR: public.lock still held after ${COMPRESS_LOCK_WAIT}s ($(lock_holder "$PUBLIC_LOCK"))."
        exec 7>&-
        return 1
    fi
    note_lock_holder "$PUBLIC_LOCK"
    clean_stage_dir "$STAGE_DIR"

    if [[ -d "$PUBLIC_DIR" ]]; then
        (
            cd "$PUBLIC_DIR"
            find . -maxdepth 1 -name "aroi_validation_${month}*.json" -type f -size +0c 2>/dev/null \
                | sed 's|^\./||' \
                | { grep -E "^aroi_validation_${month}[0-9]{2}_[0-9]{6}\.json$" || true; } \
                | while IFS= read -r fn; do
                    ln "$PUBLIC_DIR/$fn" "$snap_dir/$fn" 2>/dev/null || cp -p "$PUBLIC_DIR/$fn" "$snap_dir/$fn"
                done
        )
    fi
    exec 7>&-
}

# Build and verify local-archive/aroi-YYYYMM.tar.zst and aroi-YYYYMM.list.
# Merges any existing archive members not present in public/ so incremental
# rollovers never drop previously archived hourly files.
archive_month() {
    local month=$1
    local archive_name="aroi-${month}.tar.zst"
    local list_name="aroi-${month}.list"
    local archive_path="$ARCHIVE_DIR/$archive_name"
    local list_path="$ARCHIVE_DIR/$list_name"

    local work_dir snap_dir
    work_dir=$(mktemp -d "$STAGE_DIR/compress-${month}.XXXXXX")
    snap_dir="$work_dir/snap"
    mkdir -p "$snap_dir"

    if ! snapshot_month_files "$month" "$snap_dir"; then
        rm -rf "$work_dir"
        return 1
    fi

    # Preserve any previously archived members not currently in public/
    if [[ -s "$archive_path" ]]; then
        if zstd -t "$archive_path" >/dev/null 2>&1; then
            list_nonempty_validation_files "$snap_dir" > "$work_dir/snap.txt"
            zstd -dc --long="$ZSTD_LONG" "$archive_path" | tar tf - 2>/dev/null \
                | grep -E "^aroi_validation_${month}[0-9]{2}_[0-9]{6}\.json$" \
                | LC_ALL=C sort -u > "$work_dir/existing.txt" || true
            comm -23 "$work_dir/existing.txt" "$work_dir/snap.txt" > "$work_dir/missing_from_snap.txt"
            if [[ -s "$work_dir/missing_from_snap.txt" ]]; then
                echo "  Restoring $(wc -l < "$work_dir/missing_from_snap.txt" | tr -d '[:space:]') previously archived file(s) for $month"
                if ! zstd -dc --long="$ZSTD_LONG" "$archive_path" | tar -C "$snap_dir" -xf - -T "$work_dir/missing_from_snap.txt"; then
                    echo "  ✗ Failed extracting existing members from $archive_name"
                    rm -rf "$work_dir"
                    return 1
                fi
            fi
        else
            echo "  ⚠ Existing $archive_name failed zstd -t; rebuilding from public/"
        fi
    fi

    list_nonempty_validation_files "$snap_dir" > "$work_dir/expected.txt"
    if [[ ! -s "$work_dir/expected.txt" ]]; then
        rm -rf "$work_dir"
        return 0
    fi

    local file_count
    file_count=$(wc -l < "$work_dir/expected.txt" | tr -d '[:space:]')

    if [[ -s "$archive_path" && -s "$list_path" ]] \
        && cmp -s "$work_dir/expected.txt" "$list_path" \
        && zstd -t "$archive_path" >/dev/null 2>&1; then
        echo "  ✓ $archive_name already current ($file_count files)"
        ARCHIVED_MONTHS+=("$month")
        rm -rf "$work_dir"
        return 0
    fi

    echo "Processing month $month ($file_count files)..."
    local tmp_archive="$work_dir/$archive_name"
    if ! tar cf - -C "$snap_dir" -T "$work_dir/expected.txt" \
        | zstd -T0 "-${ZSTD_LEVEL}" "--long=${ZSTD_LONG}" -q -o "$tmp_archive"; then
        echo "  ✗ zstd compression failed for $month"
        rm -rf "$work_dir"
        return 1
    fi

    if ! zstd -t "$tmp_archive" >/dev/null 2>&1; then
        echo "  ✗ zstd integrity verification failed for $archive_name"
        rm -rf "$work_dir"
        return 1
    fi

    if ! zstd -dc --long="$ZSTD_LONG" "$tmp_archive" | tar tf - 2>/dev/null \
        | LC_ALL=C sort -u > "$work_dir/actual.txt"; then
        echo "  ✗ tar listing verification failed for $archive_name"
        rm -rf "$work_dir"
        return 1
    fi

    if ! cmp -s "$work_dir/expected.txt" "$work_dir/actual.txt"; then
        echo "  ✗ Archive member mismatch for $archive_name (expected $file_count files)"
        rm -rf "$work_dir"
        return 1
    fi

    chmod 644 "$tmp_archive" "$work_dir/expected.txt"
    mv -f "$tmp_archive" "$archive_path"
    mv -f "$work_dir/expected.txt" "$list_path"
    local archive_size
    archive_size=$(du -sh "$archive_path" 2>/dev/null | cut -f1) || archive_size="?"
    echo "  ✓ Archived $file_count files → $archive_name ($archive_size)"
    ARCHIVED_MONTHS+=("$month")
    rm -rf "$work_dir"
    return 0
}

# List top-level non-empty live JSONs and _backups/ artifacts once per provider.
fetch_remote_state() {
    local provider=$1 bucket=$2 out_live=$3 out_backups=$4
    local raw_live="${out_live}.raw" raw_bk="${out_backups}.raw"
    echo "Listing remote state for $provider ($bucket)..."
    if ! "$RCLONE" lsf "$bucket" --max-depth 1 --files-only --format sp > "$raw_live" 2>/dev/null; then
        echo "  ✗ Failed listing live files in $bucket"
        rm -f "$raw_live" "$raw_bk"
        return 1
    fi
    awk -F';' '$1+0 > 0 {print $2}' "$raw_live" | { grep -E "$AROI_JSON_REGEX" || true; } | LC_ALL=C sort -u > "$out_live"

    if ! "$RCLONE" lsf "$bucket/_backups/" --max-depth 1 --files-only --format sp > "$raw_bk" 2>/dev/null; then
        echo "  ✗ Failed listing _backups/ in $bucket"
        rm -f "$raw_live" "$raw_bk"
        return 1
    fi
    LC_ALL=C sort -u "$raw_bk" > "$out_backups"
    rm -f "$raw_live" "$raw_bk"
    return 0
}

# Verify a completed month has 100% live files (backfilling from public/ if needed)
# and matching _backups/aroi-YYYYMM.tar.zst byte size on a provider.
verify_completed_month_provider() {
    local provider=$1 bucket=$2 month=$3 list_file=$4 local_zst_size=$5
    local remote_live=$6 remote_backups=$7 work_dir=$8
    local missing_file="$work_dir/missing-${provider}-${month}.txt"

    comm -23 "$list_file" "$remote_live" > "$missing_file"
    if [[ -s "$missing_file" ]]; then
        local missing_count
        missing_count=$(wc -l < "$missing_file" | tr -d '[:space:]')
        echo "  ⚠ $provider missing $missing_count live file(s) for $month; attempting backfill from public/..."
        local can_backfill="$work_dir/backfill-${provider}-${month}.txt"
        : > "$can_backfill"
        while IFS= read -r fn; do
            [[ -s "$PUBLIC_DIR/$fn" ]] && echo "$fn" >> "$can_backfill"
        done < "$missing_file"

        if [[ ! -s "$can_backfill" ]] || [[ $(wc -l < "$can_backfill") -ne "$missing_count" ]]; then
            echo "  ✗ Cannot backfill all missing files from public/ for $provider ($month)"
            return 1
        fi
        if ! "$RCLONE" copy "$PUBLIC_DIR" "$bucket" --files-from "$can_backfill" --no-traverse --ignore-existing >/dev/null 2>&1; then
            echo "  ✗ Backfill upload failed for $provider ($month)"
            return 1
        fi
        # Re-verify backfilled non-empty files now exist live remotely
        local raw_recheck recheck
        if ! raw_recheck=$("$RCLONE" lsf "$bucket" --max-depth 1 --files-only --format sp --include "aroi_validation_${month}*.json" 2>/dev/null); then
            echo "  ✗ Failed re-listing remote live files for $provider ($month)"
            return 1
        fi
        recheck=$(printf '%s\n' "$raw_recheck" | awk -F';' '$1+0 > 0 {print $2}' | LC_ALL=C sort -u || true)
        if [[ -n $(comm -23 "$list_file" <(printf '%s\n' "$recheck")) ]]; then
            echo "  ✗ Remote live verification still incomplete for $provider ($month)"
            return 1
        fi
    fi

    # Verify _backups/aroi-YYYYMM.tar.zst size and aroi-YYYYMM.list presence
    local remote_zst_size
    remote_zst_size=$(awk -F';' -v name="aroi-${month}.tar.zst" '$2 == name {print $1}' "$remote_backups")
    if [[ -z "$remote_zst_size" ]] || [[ "$remote_zst_size" != "$local_zst_size" ]]; then
        echo "  ✗ $provider _backups/aroi-${month}.tar.zst size mismatch (local=${local_zst_size}, remote=${remote_zst_size:-missing})"
        return 1
    fi
    if ! grep -qE "^[1-9][0-9]*;aroi-${month}\.list$" "$remote_backups"; then
        echo "  ✗ $provider _backups/aroi-${month}.list missing or empty"
        return 1
    fi

    return 0
}

# Safely remove uncompressed files for a verified completed month from public/.
prune_completed_month_local() {
    local month=$1 list_file=$2
    local removed=0

    exec 7>>"$PUBLIC_LOCK"
    if ! flock -w "$COMPRESS_LOCK_WAIT" 7; then
        echo "  ✗ public.lock still held after ${COMPRESS_LOCK_WAIT}s; keeping local files for $month"
        exec 7>&-
        return 1
    fi
    note_lock_holder "$PUBLIC_LOCK"

    while IFS= read -r fn; do
        [[ "$fn" =~ ^aroi_validation_${month}[0-9]{2}_[0-9]{6}\.json$ ]] || continue
        if [[ -e "$PUBLIC_DIR/$fn" ]]; then
            rm -f "$PUBLIC_DIR/$fn"
            removed=$((removed + 1))
        fi
    done < "$list_file"

    build_files_manifest "$PUBLIC_DIR" "$ARCHIVE_DIR" "$STAGE_DIR"
    exec 7>&-

    echo "  ✓ Verified 3 copies and removed $removed uncompressed file(s) from public/ for $month"
    return 0
}

# === Step 1: Discover and Archive Months ===
declare -a MONTHS_TO_PROCESS=()
if [[ -n "$TARGET_MONTH" ]]; then
    MONTHS_TO_PROCESS=("$TARGET_MONTH")
else
    while IFS= read -r m; do
        [[ -n "$m" ]] && MONTHS_TO_PROCESS+=("$m")
    done < <(list_nonempty_validation_files "$PUBLIC_DIR" | sed -E 's/^aroi_validation_([0-9]{6}).*/\1/' | LC_ALL=C sort -u)
fi

if [[ ${#MONTHS_TO_PROCESS[@]} -gt 0 ]]; then
    for MONTH in "${MONTHS_TO_PROCESS[@]}"; do
        if ! archive_month "$MONTH"; then
            mark_month_failed "$MONTH"
            ERRORS=$((ERRORS + 1))
        elif [[ "$MONTH" < "$CURRENT_MONTH" ]]; then
            COMPLETED_CANDIDATES+=("$MONTH")
        fi
    done
else
    echo "No hourly JSON files currently in $PUBLIC_DIR"
fi

# === Step 2: Upload Zstd Backup Artifacts ===
if [[ "$NO_UPLOAD" != "true" ]] && [[ ${#ARCHIVED_MONTHS[@]} -gt 0 ]]; then
    for MONTH in "${ARCHIVED_MONTHS[@]}"; do
        if [[ "$DO_ENABLED" == "true" ]]; then
            if ! "$SCRIPT_DIR/upload-do.sh" --upload-backups "$MONTH"; then
                echo "  ✗ DO backup upload failed for $MONTH"
                mark_month_failed "$MONTH"
                ERRORS=$((ERRORS + 1))
            fi
        fi
        if [[ "$R2_ENABLED" == "true" ]]; then
            if ! "$SCRIPT_DIR/upload-r2.sh" --upload-backups "$MONTH"; then
                echo "  ✗ R2 backup upload failed for $MONTH"
                mark_month_failed "$MONTH"
                ERRORS=$((ERRORS + 1))
            fi
        fi
    done
fi

# === Step 3: 3-Copy Verification Gate & Local Cleanup for Completed Months ===
if [[ "$NO_UPLOAD" != "true" ]] && [[ ${#COMPLETED_CANDIDATES[@]} -gt 0 ]]; then
    if [[ "$DO_ENABLED" != "true" && "$R2_ENABLED" != "true" ]]; then
        echo "Skipping completed-month local deletion: no cloud storage enabled"
    else
        VERIFY_WORK=$(mktemp -d "$STAGE_DIR/verify-archive.XXXXXX")
        REMOTE_OK=true
        if [[ "$DO_ENABLED" == "true" ]]; then
            DO_BUCKET="${AROI_DO_REMOTE:-aroi-spaces}:${DO_SPACES_BUCKET:?}"
            if ! fetch_remote_state "DO" "$DO_BUCKET" "$VERIFY_WORK/do-live.txt" "$VERIFY_WORK/do-backups.txt"; then
                REMOTE_OK=false
                ERRORS=$((ERRORS + 1))
            fi
        fi
        if [[ "$R2_ENABLED" == "true" ]]; then
            R2_BUCKET_URI="${AROI_R2_REMOTE:-aroi-r2}:${R2_BUCKET:?}"
            if ! fetch_remote_state "R2" "$R2_BUCKET_URI" "$VERIFY_WORK/r2-live.txt" "$VERIFY_WORK/r2-backups.txt"; then
                REMOTE_OK=false
                ERRORS=$((ERRORS + 1))
            fi
        fi

        if [[ "$REMOTE_OK" == "true" ]]; then
            for MONTH in "${COMPLETED_CANDIDATES[@]}"; do
                is_month_failed "$MONTH" && continue
                ARCHIVE_PATH="$ARCHIVE_DIR/aroi-${MONTH}.tar.zst"
                LIST_PATH="$ARCHIVE_DIR/aroi-${MONTH}.list"
                if [[ ! -s "$ARCHIVE_PATH" || ! -s "$LIST_PATH" ]] || ! zstd -t "$ARCHIVE_PATH" >/dev/null 2>&1; then
                    echo "  ✗ Local verification failed for $MONTH; keeping files in public/"
                    ERRORS=$((ERRORS + 1))
                    continue
                fi
                LOCAL_ZST_SIZE=$(file_size_bytes "$ARCHIVE_PATH")

                MONTH_VERIFIED=true
                if [[ "$DO_ENABLED" == "true" ]]; then
                    if ! verify_completed_month_provider "DO" "$DO_BUCKET" "$MONTH" "$LIST_PATH" "$LOCAL_ZST_SIZE" \
                        "$VERIFY_WORK/do-live.txt" "$VERIFY_WORK/do-backups.txt" "$VERIFY_WORK"; then
                        MONTH_VERIFIED=false
                    fi
                fi
                if [[ "$R2_ENABLED" == "true" && "$MONTH_VERIFIED" == "true" ]]; then
                    if ! verify_completed_month_provider "R2" "$R2_BUCKET_URI" "$MONTH" "$LIST_PATH" "$LOCAL_ZST_SIZE" \
                        "$VERIFY_WORK/r2-live.txt" "$VERIFY_WORK/r2-backups.txt" "$VERIFY_WORK"; then
                        MONTH_VERIFIED=false
                    fi
                fi

                if [[ "$MONTH_VERIFIED" == "true" ]]; then
                    prune_completed_month_local "$MONTH" "$LIST_PATH" || ERRORS=$((ERRORS + 1))
                else
                    echo "  ⚠ Retaining uncompressed $MONTH files in public/ until remote verification succeeds"
                    ERRORS=$((ERRORS + 1))
                fi
            done
        fi
        rm -rf "$VERIFY_WORK"
    fi
elif [[ "$NO_UPLOAD" == "true" && ${#COMPLETED_CANDIDATES[@]} -gt 0 ]]; then
    echo "Skipping completed-month local deletion (--no-upload set)"
fi

# === Step 4: Compress cron.log (if > 50 MB, monthly / non-daily mode) ===
if [[ "$DAILY_MODE" != "true" ]] && [[ -f "$LOG_DIR/cron.log" ]]; then
    echo "Checking cron.log size..."
    LOG_SIZE=$(file_size_bytes "$LOG_DIR/cron.log" || echo 0)
    [[ "$LOG_SIZE" =~ ^[0-9]+$ ]] || LOG_SIZE=0
    LOG_SIZE_MB=$((LOG_SIZE / 1048576))

    if (( LOG_SIZE_MB > 50 )); then
        DATE_PART=$(date +%Y-%m)
        LOG_ARCHIVE_NAME="cron-${DATE_PART}.log.zst"
        if [[ -e "$LOG_DIR/archives/$LOG_ARCHIVE_NAME" ]]; then
            LOG_ARCHIVE_NAME="cron-$(date +%Y-%m-%d_%H%M%S).log.zst"
        fi
        TMP_LOG_ZST=$(mktemp "$STAGE_DIR/cron-log.XXXXXX")
        echo "cron.log is ${LOG_SIZE_MB}MB, compressing with zstd..."
        if zstd -T0 "-${ZSTD_LEVEL}" -q -c "$LOG_DIR/cron.log" > "$TMP_LOG_ZST" && zstd -t "$TMP_LOG_ZST" >/dev/null 2>&1; then
            chmod 644 "$TMP_LOG_ZST"
            mv -f "$TMP_LOG_ZST" "$LOG_DIR/archives/$LOG_ARCHIVE_NAME"
            # Truncate in place so a running batch keeps appending to the open inode
            TEMP_TAIL=$(mktemp "$LOG_DIR/cron.log.XXXXXX")
            tail -500 "$LOG_DIR/cron.log" > "$TEMP_TAIL" || true
            cat "$TEMP_TAIL" > "$LOG_DIR/cron.log"
            rm -f "$TEMP_TAIL"
            echo "  ✓ Compressed to $LOG_ARCHIVE_NAME"
        else
            echo "  ✗ cron.log zstd compression failed"
            rm -f "$TMP_LOG_ZST"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo "cron.log is ${LOG_SIZE_MB}MB (under 50MB threshold)"
    fi
fi

# === Step 5: Ensure files.json Manifest is Up to Date ===
echo "Updating file manifest..."
exec 7>>"$PUBLIC_LOCK"
if flock -w "$COMPRESS_LOCK_WAIT" 7; then
    note_lock_holder "$PUBLIC_LOCK"
    build_files_manifest "$PUBLIC_DIR" "$ARCHIVE_DIR" "$STAGE_DIR"
    exec 7>&-
else
    exec 7>&-
    echo "ERROR: public.lock held while updating manifest"
    ERRORS=$((ERRORS + 1))
fi

if (( ERRORS == 0 )); then
    date '+%Y-%m-%d' > "$LOG_DIR/last-archive-date"
    echo "Archival completed at $(date)"
    echo ""
    exit 0
fi

echo "Archival completed with $ERRORS error(s) at $(date)"
echo ""
exit 1
