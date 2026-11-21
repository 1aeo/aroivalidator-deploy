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
ZSTD_DEC_LONG=$(zstd_decode_long "$ZSTD_LONG")
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
RUN_SNAP_ROOT=$(mktemp -d "$STAGE_DIR/verified-snaps.XXXXXX")
# shellcheck disable=SC2329  # invoked via trap
cleanup_compress() { rm -rf "${RUN_SNAP_ROOT:-}"; }
trap cleanup_compress EXIT
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
# When ident_file is provided, records "<dev>:<ino>\t<filename>" for each source file under public.lock.
snapshot_month_files() {
    local month=$1 snap_dir=$2 ident_file=${3:-}
    local scan_list rc=0 scan_rc=0 fn dev_ino

    exec 7>>"$PUBLIC_LOCK"
    if ! flock -w "$COMPRESS_LOCK_WAIT" 7; then
        echo "ERROR: public.lock still held after ${COMPRESS_LOCK_WAIT}s ($(lock_holder "$PUBLIC_LOCK"))."
        exec 7>&-
        return 1
    fi
    note_lock_holder "$PUBLIC_LOCK"
    clean_stage_dir "$STAGE_DIR"
    clean_publish_temps "$PUBLIC_DIR"

    [[ -z "$ident_file" ]] || : > "$ident_file"
    scan_list=$(mktemp "$(dirname "$snap_dir")/.aroi-tmp.scan.XXXXXX") || { exec 7>&-; return 1; }
    if [[ -d "$PUBLIC_DIR" ]]; then
        if ! (
            cd "$PUBLIC_DIR" || exit 1
            find . -maxdepth 1 -name "aroi_validation_${month}*.json" -type f -size +0c > "$scan_list"
        ); then
            scan_rc=1
        fi
        if [[ $scan_rc -ne 0 ]]; then
            echo "  ✗ Failed scanning $PUBLIC_DIR for $month"
            rm -f "$scan_list"
            exec 7>&-
            return 1
        fi
        while IFS= read -r fn; do
            fn=${fn#./}
            [[ "$fn" =~ ^aroi_validation_${month}[0-9]{2}_[0-9]{6}\.json$ ]] || continue
            if [[ -n "$ident_file" ]]; then
                if ! dev_ino=$(file_dev_ino "$PUBLIC_DIR/$fn"); then
                    echo "  ✗ Failed reading inode metadata for $fn ($month)"
                    rc=1
                    break
                fi
            fi
            if ! ln "$PUBLIC_DIR/$fn" "$snap_dir/$fn" 2>/dev/null && ! cp -p "$PUBLIC_DIR/$fn" "$snap_dir/$fn"; then
                echo "  ✗ Failed snapshotting $fn for $month"
                rc=1
                break
            fi
            [[ -z "$ident_file" ]] || printf '%s\t%s\n' "$dev_ino" "$fn" >> "$ident_file"
        done < "$scan_list"
    fi

    rm -f "$scan_list"
    exec 7>&-
    return "$rc"
}

# Recover missing monthly members into snap_dir from verified remote _backups/aroi-YYYYMM.{tar.zst,list}.
# Checks surviving remote manifests even if the tarball is missing, verifies overlapping public/ contents
# against recovered tarballs, and allows an empty first-time build only when no remote artifacts exist.
recover_remote_archive() {
    local month=$1 want_file=$2 snap_dir=$3 work_dir=$4 recover_all_if_present=${5:-false}
    local required_file="$work_dir/recover-required-${month}.txt"
    local init_file="$work_dir/recover-init-${month}.txt"
    local still_missing="$work_dir/recover-missing-${month}.txt"

    list_nonempty_validation_files "$snap_dir" > "$init_file" || return 1
    if [[ -s "$want_file" ]]; then
        LC_ALL=C sort -u "$want_file" > "$required_file"
    else
        : > "$required_file"
    fi
    comm -23 "$required_file" "$init_file" > "$still_missing"

    if [[ "$NO_UPLOAD" == "true" ]] || [[ "$DO_ENABLED" != "true" && "$R2_ENABLED" != "true" ]]; then
        [[ "$recover_all_if_present" != "true" && ! -s "$still_missing" ]] && return 0
        return 1
    fi

    local -a providers=()
    local -a buckets=()
    local b any_error=false
    if [[ "$DO_ENABLED" == "true" ]]; then
        if b=$(resolve_do_bucket); then
            providers+=("DO"); buckets+=("$b")
        else
            any_error=true
        fi
    fi
    if [[ "$R2_ENABLED" == "true" ]]; then
        if b=$(resolve_r2_bucket); then
            providers+=("R2"); buckets+=("$b")
        else
            any_error=true
        fi
    fi
    if (( ${#providers[@]} == 0 )); then
        [[ "$recover_all_if_present" != "true" && ! -s "$still_missing" ]] && return 0
        return 1
    fi

    local archive_name="aroi-${month}.tar.zst"
    local list_name="aroi-${month}.list"
    local idx prov bucket
    local dl_dir lsf_out has_zst has_list grep_rc

    for idx in "${!providers[@]}"; do
        prov="${providers[$idx]}"
        bucket="${buckets[$idx]}"
        if [[ "$recover_all_if_present" != "true" && ! -s "$still_missing" ]]; then
            break
        fi

        if ! lsf_out=$("$RCLONE" lsf "$bucket/_backups/" --max-depth 1 --files-only --include "aroi-${month}.*" 2>/dev/null); then
            any_error=true
            continue
        fi
        has_zst=false
        has_list=false
        grep -qxF "$archive_name" <<< "$lsf_out" && has_zst=true
        grep -qxF "$list_name" <<< "$lsf_out" && has_list=true
        [[ "$has_zst" == "true" || "$has_list" == "true" ]] || continue

        dl_dir=$(mktemp -d "$work_dir/recover-${prov}-${month}.XXXXXX")
        : > "$dl_dir/want.txt"
        [[ "$has_zst" == "true" ]] && echo "$archive_name" >> "$dl_dir/want.txt"
        [[ "$has_list" == "true" ]] && echo "$list_name" >> "$dl_dir/want.txt"

        if ! "$RCLONE" copy "$bucket/_backups" "$dl_dir" --files-from "$dl_dir/want.txt" --no-traverse >/dev/null 2>&1; then
            any_error=true
            rm -rf "$dl_dir"
            continue
        fi

        if [[ "$has_list" == "true" ]]; then
            if [[ ! -s "$dl_dir/$list_name" ]]; then
                any_error=true
            else
                grep_rc=0
                grep -E "^aroi_validation_${month}[0-9]{2}_[0-9]{6}\.json$" "$dl_dir/$list_name" > "$dl_dir/remote_list_entries.txt" || grep_rc=$?
                if (( grep_rc > 1 )); then
                    any_error=true
                elif [[ -s "$dl_dir/remote_list_entries.txt" ]]; then
                    cat "$dl_dir/remote_list_entries.txt" >> "$required_file"
                    LC_ALL=C sort -u "$required_file" -o "$required_file"
                else
                    any_error=true
                fi
            fi
        fi

        list_nonempty_validation_files "$snap_dir" > "$work_dir/snap-cur-${month}.txt" || { rm -rf "$dl_dir"; return 1; }
        comm -23 "$required_file" "$work_dir/snap-cur-${month}.txt" > "$still_missing"

        if [[ "$has_zst" == "true" ]]; then
            if [[ ! -s "$dl_dir/$archive_name" ]] \
                || ! zstd -t --long="$ZSTD_DEC_LONG" "$dl_dir/$archive_name" >/dev/null 2>&1 \
                || ! list_archive_members "$dl_dir/$archive_name" "$dl_dir/all_members.txt"; then
                any_error=true
                rm -rf "$dl_dir"
                continue
            fi

            local rem_members="$dl_dir/members.txt" rem_overlap="$dl_dir/overlap.txt" rc fn
            grep -E "^aroi_validation_${month}[0-9]{2}_[0-9]{6}\.json$" "$dl_dir/all_members.txt" \
                | LC_ALL=C sort -u > "$rem_members" || true

            # Check overlapping snapshot/recovered files against the remote archive before rebuilding
            comm -12 "$work_dir/snap-cur-${month}.txt" "$rem_members" > "$rem_overlap"
            if [[ -s "$rem_overlap" ]]; then
                local cmp_dir="$dl_dir/cmp-overlap"
                mkdir -p "$cmp_dir"
                rc=0
                zstd -dc --long="$ZSTD_DEC_LONG" "$dl_dir/$archive_name" 2>/dev/null \
                    | tar -C "$cmp_dir" -xf - -T "$rem_overlap" 2>/dev/null || rc=$?
                if [[ $rc -ne 0 ]]; then
                    any_error=true
                    rm -rf "$dl_dir"
                    continue
                fi
                while IFS= read -r fn; do
                    [[ -z "$fn" ]] && continue
                    if [[ ! -f "$cmp_dir/$fn" || -L "$cmp_dir/$fn" || ! -f "$snap_dir/$fn" || -L "$snap_dir/$fn" ]] \
                        || ! cmp -s "$snap_dir/$fn" "$cmp_dir/$fn"; then
                        echo "  ✗ Content conflict for $fn ($month): public/ differs from remote $prov backup; retaining public file"
                        rm -rf "$dl_dir"
                        return 1
                    fi
                done < "$rem_overlap"
            fi

            local to_ext="$dl_dir/to_extract.txt"
            if [[ "$recover_all_if_present" == "true" ]]; then
                comm -23 "$rem_members" "$work_dir/snap-cur-${month}.txt" > "$to_ext"
                if [[ -s "$still_missing" ]]; then
                    comm -12 "$still_missing" "$rem_members" >> "$to_ext"
                    LC_ALL=C sort -u "$to_ext" -o "$to_ext"
                fi
            else
                comm -12 "$still_missing" "$rem_members" > "$to_ext"
            fi

            if [[ -s "$to_ext" ]]; then
                local ext_dir="$dl_dir/ext" all_ok=true
                mkdir -p "$ext_dir"
                rc=0
                zstd -dc --long="$ZSTD_DEC_LONG" "$dl_dir/$archive_name" 2>/dev/null \
                    | tar -C "$ext_dir" -xf - -T "$to_ext" 2>/dev/null || rc=$?
                if [[ $rc -ne 0 ]]; then
                    any_error=true
                    rm -rf "$dl_dir"
                    continue
                fi
                while IFS= read -r fn; do
                    [[ -z "$fn" ]] && continue
                    if [[ ! -f "$ext_dir/$fn" || -L "$ext_dir/$fn" || ! -s "$ext_dir/$fn" ]]; then
                        all_ok=false
                        break
                    fi
                done < "$to_ext"
                if [[ "$all_ok" != "true" ]]; then
                    any_error=true
                    rm -rf "$dl_dir"
                    continue
                fi
                while IFS= read -r fn; do
                    [[ -z "$fn" ]] && continue
                    mv -f "$ext_dir/$fn" "$snap_dir/$fn"
                done < "$to_ext"
                echo "  Recovered $(wc -l < "$to_ext" | tr -d '[:space:]') member(s) for $month from $prov backup"
            fi
        fi

        rm -rf "$dl_dir"

        list_nonempty_validation_files "$snap_dir" > "$work_dir/snap-now.txt" || return 1
        comm -23 "$required_file" "$work_dir/snap-now.txt" > "$still_missing"
    done

    if [[ -s "$still_missing" ]]; then
        return 1
    fi
    if [[ "$recover_all_if_present" == "true" && "$any_error" == "true" ]]; then
        return 1
    fi
    return 0
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

    local work_dir snap_dir snap_verify_dir snap_ident
    work_dir=$(mktemp -d "$STAGE_DIR/compress-${month}.XXXXXX")
    snap_dir="$work_dir/snap"
    snap_verify_dir="$RUN_SNAP_ROOT/$month"
    snap_ident="$RUN_SNAP_ROOT/${month}.ident"
    mkdir -p "$snap_dir"
    rm -rf "$snap_verify_dir" "$snap_ident"
    mkdir -p "$snap_verify_dir"

    if ! snapshot_month_files "$month" "$snap_dir" "$snap_ident"; then
        rm -rf "$work_dir" "$snap_verify_dir" "$snap_ident"
        return 1
    fi

    list_nonempty_validation_files "$snap_dir" > "$work_dir/snap.txt"
    local fn rc
    while IFS= read -r fn; do
        [[ -z "$fn" ]] && continue
        if ! ln "$snap_dir/$fn" "$snap_verify_dir/$fn" 2>/dev/null && ! cp -p "$snap_dir/$fn" "$snap_verify_dir/$fn"; then
            echo "  ✗ Failed retaining verification snapshot for $fn"
            rm -rf "$work_dir" "$snap_verify_dir"
            return 1
        fi
    done < "$work_dir/snap.txt"

    if [[ -s "$list_path" ]]; then
        grep -E "^aroi_validation_${month}[0-9]{2}_[0-9]{6}\.json$" "$list_path" 2>/dev/null \
            | LC_ALL=C sort -u > "$work_dir/prev_list.txt" || true
    else
        : > "$work_dir/prev_list.txt"
    fi

    local archive_valid=false
    : > "$work_dir/archive_members.txt"

    # Preserve any previously archived members not currently in public/
    if [[ -e "$archive_path" ]]; then
        if [[ -s "$archive_path" ]] \
            && zstd -t --long="$ZSTD_DEC_LONG" "$archive_path" >/dev/null 2>&1 \
            && list_archive_members "$archive_path" "$work_dir/archive_members.txt"; then
            archive_valid=true
            grep -E "^aroi_validation_${month}[0-9]{2}_[0-9]{6}\.json$" "$work_dir/archive_members.txt" \
                | LC_ALL=C sort -u > "$work_dir/existing.txt" || true

            # Verify no public/ file silently diverges in content under an already-archived filename
            comm -12 "$work_dir/snap.txt" "$work_dir/existing.txt" > "$work_dir/overlap.txt"
            if [[ -s "$work_dir/overlap.txt" ]]; then
                local cmp_dir="$work_dir/overlap-cmp"
                mkdir -p "$cmp_dir"
                rc=0
                zstd -dc --long="$ZSTD_DEC_LONG" "$archive_path" 2>/dev/null \
                    | tar -C "$cmp_dir" -xf - -T "$work_dir/overlap.txt" 2>/dev/null || rc=$?
                if [[ $rc -ne 0 ]]; then
                    echo "  ✗ Failed reading archived copies to verify overlapping files for $month"
                    rm -rf "$work_dir" "$snap_verify_dir"
                    return 1
                fi
                while IFS= read -r fn; do
                    [[ -z "$fn" ]] && continue
                    if [[ ! -f "$cmp_dir/$fn" || -L "$cmp_dir/$fn" || ! -f "$snap_dir/$fn" || -L "$snap_dir/$fn" ]] \
                        || ! cmp -s "$snap_dir/$fn" "$cmp_dir/$fn"; then
                        echo "  ✗ Content conflict for $fn ($month): public/ differs from existing $archive_name; retaining public file"
                        rm -rf "$work_dir" "$snap_verify_dir"
                        return 1
                    fi
                done < "$work_dir/overlap.txt"
            fi

            comm -23 "$work_dir/existing.txt" "$work_dir/snap.txt" > "$work_dir/missing_from_snap.txt"
            if [[ -s "$work_dir/missing_from_snap.txt" ]]; then
                local ext_dir="$work_dir/existing-ext"
                mkdir -p "$ext_dir"
                echo "  Restoring $(wc -l < "$work_dir/missing_from_snap.txt" | tr -d '[:space:]') previously archived file(s) for $month"
                rc=0
                zstd -dc --long="$ZSTD_DEC_LONG" "$archive_path" 2>/dev/null \
                    | tar -C "$ext_dir" -xf - -T "$work_dir/missing_from_snap.txt" 2>/dev/null || rc=$?
                if [[ $rc -ne 0 ]]; then
                    echo "  ✗ Failed extracting existing members from $archive_name"
                    rm -rf "$work_dir" "$snap_verify_dir"
                    return 1
                fi
                while IFS= read -r fn; do
                    [[ -z "$fn" ]] && continue
                    if [[ ! -f "$ext_dir/$fn" || -L "$ext_dir/$fn" || ! -s "$ext_dir/$fn" ]]; then
                        echo "  ✗ Extracted invalid/empty member $fn from $archive_name"
                        rm -rf "$work_dir" "$snap_verify_dir"
                        return 1
                    fi
                    mv -f "$ext_dir/$fn" "$snap_dir/$fn"
                done < "$work_dir/missing_from_snap.txt"
            fi
        else
            echo "  ⚠ Existing $archive_name failed integrity/listing check"
            comm -23 "$work_dir/prev_list.txt" "$work_dir/snap.txt" > "$work_dir/lost_members.txt"
            if [[ -s "$work_dir/lost_members.txt" ]]; then
                if ! recover_remote_archive "$month" "$work_dir/lost_members.txt" "$snap_dir" "$work_dir" "false"; then
                    echo "  ✗ Cannot recover missing previously archived member(s) for $month; refusing partial rebuild"
                    rm -rf "$work_dir" "$snap_verify_dir"
                    return 1
                fi
            elif [[ ! -s "$work_dir/prev_list.txt" ]]; then
                if ! recover_remote_archive "$month" "$work_dir/lost_members.txt" "$snap_dir" "$work_dir" "true"; then
                    echo "  ✗ Cannot verify/recover remote backup for $month after corrupt local archive"
                    rm -rf "$work_dir" "$snap_verify_dir"
                    return 1
                fi
            fi
        fi
    elif [[ ! -s "$work_dir/prev_list.txt" && "$NO_UPLOAD" != "true" ]] && [[ "$DO_ENABLED" == "true" || "$R2_ENABLED" == "true" ]]; then
        # Both local artifacts are missing/empty: verify remote _backups/ has no prior archive before first build
        : > "$work_dir/lost_members.txt"
        if ! recover_remote_archive "$month" "$work_dir/lost_members.txt" "$snap_dir" "$work_dir" "true"; then
            echo "  ✗ Cannot verify remote backup history for $month while local archive artifacts are absent"
            rm -rf "$work_dir" "$snap_verify_dir"
            return 1
        fi
    fi

    list_nonempty_validation_files "$snap_dir" > "$work_dir/expected.txt"

    # Guard against any manifest-recorded member missing from both snap_dir and valid local tar
    comm -23 "$work_dir/prev_list.txt" "$work_dir/expected.txt" > "$work_dir/still_missing.txt"
    if [[ -s "$work_dir/still_missing.txt" ]]; then
        if ! recover_remote_archive "$month" "$work_dir/still_missing.txt" "$snap_dir" "$work_dir" "false"; then
            echo "  ✗ Local $list_name lists $(wc -l < "$work_dir/still_missing.txt" | tr -d '[:space:]') member(s) absent from snapshot and recovery"
            rm -rf "$work_dir" "$snap_verify_dir"
            return 1
        fi
        list_nonempty_validation_files "$snap_dir" > "$work_dir/expected.txt"
    fi

    if [[ ! -s "$work_dir/expected.txt" ]]; then
        rm -rf "$work_dir" "$snap_verify_dir"
        return 0
    fi

    local file_count
    file_count=$(wc -l < "$work_dir/expected.txt" | tr -d '[:space:]')

    if [[ "$archive_valid" == "true" && -s "$archive_path" && -s "$list_path" ]] \
        && cmp -s "$work_dir/expected.txt" "$work_dir/archive_members.txt" \
        && cmp -s "$work_dir/expected.txt" "$list_path"; then
        echo "  ✓ $archive_name already current ($file_count files)"
        ARCHIVED_MONTHS+=("$month")
        rm -rf "$work_dir"
        return 0
    fi

    echo "Processing month $month ($file_count files)..."
    local tmp_archive="$work_dir/$archive_name"
    rc=0
    tar cf - -C "$snap_dir" -T "$work_dir/expected.txt" \
        | zstd -T0 "-${ZSTD_LEVEL}" "--long=${ZSTD_LONG}" -q -o "$tmp_archive" || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "  ✗ zstd compression failed for $month"
        rm -rf "$work_dir"
        return 1
    fi

    if ! zstd -t --long="$ZSTD_DEC_LONG" "$tmp_archive" >/dev/null 2>&1; then
        echo "  ✗ zstd integrity verification failed for $archive_name"
        rm -rf "$work_dir"
        return 1
    fi

    if ! list_archive_members "$tmp_archive" "$work_dir/actual.txt"; then
        echo "  ✗ tar listing verification failed for $archive_name"
        rm -rf "$work_dir"
        return 1
    fi

    if ! cmp -s "$work_dir/expected.txt" "$work_dir/actual.txt"; then
        echo "  ✗ Archive member mismatch for $archive_name (expected $file_count files)"
        rm -rf "$work_dir"
        return 1
    fi

    local archive_lock="$LOG_DIR/archive.lock"
    exec 5>>"$archive_lock"
    if ! flock -w "$COMPRESS_LOCK_WAIT" 5; then
        exec 5>&-
        echo "  ✗ archive.lock still held after ${COMPRESS_LOCK_WAIT}s; cannot install $archive_name"
        rm -rf "$work_dir" "$snap_verify_dir" "$snap_ident"
        return 1
    fi
    note_lock_holder "$archive_lock"
    if ! atomic_install_file "$tmp_archive" "$archive_path" 644 \
        || ! atomic_install_file "$work_dir/expected.txt" "$list_path" 644; then
        exec 5>&-
        echo "  ✗ Failed installing $archive_name or $list_name"
        rm -rf "$work_dir" "$snap_verify_dir" "$snap_ident"
        return 1
    fi
    exec 5>&-

    local archive_size
    archive_size=$(du -sh "$archive_path" 2>/dev/null | cut -f1) || archive_size="?"
    echo "  ✓ Archived $file_count files → $archive_name ($archive_size)"
    ARCHIVED_MONTHS+=("$month")
    rm -rf "$work_dir"
    return 0
}

# List top-level live JSONs (non-empty and 0-byte separately) and _backups/ (with MD5) per provider.
fetch_remote_state() {
    local provider=$1 bucket=$2 out_live=$3 out_zero=$4 out_backups=$5
    local raw_live="${out_live}.raw" raw_bk="${out_backups}.raw"
    echo "Listing remote state for $provider ($bucket)..."
    if ! "$RCLONE" lsf "$bucket" --max-depth 1 --files-only --format sp > "$raw_live" 2>/dev/null; then
        echo "  ✗ Failed listing live files in $bucket"
        rm -f "$raw_live" "$raw_bk"
        return 1
    fi
    awk -F';' '$1+0 > 0 {print $2}' "$raw_live" | { grep -E "$AROI_JSON_REGEX" || true; } | LC_ALL=C sort -u > "$out_live"
    awk -F';' '$1+0 == 0 {print $2}' "$raw_live" | { grep -E "$AROI_JSON_REGEX" || true; } | LC_ALL=C sort -u > "$out_zero"

    if ! "$RCLONE" lsf "$bucket/_backups/" --max-depth 1 --files-only --format shp > "$raw_bk" 2>/dev/null; then
        echo "  ✗ Failed listing _backups/ in $bucket"
        rm -f "$raw_live" "$raw_bk"
        return 1
    fi
    LC_ALL=C sort -u "$raw_bk" > "$out_backups"
    rm -f "$raw_live" "$raw_bk"
    return 0
}

# Verify a completed month has 100% non-empty live files (backfilling absent keys with
# --ignore-existing and replacing confirmed 0-byte keys from public/) and matching
# _backups/aroi-YYYYMM.{tar.zst,list} pairs on a provider.
verify_completed_month_provider() {
    local provider=$1 bucket=$2 month=$3 list_file=$4
    local remote_live=$5 remote_zero=$6 remote_backups=$7 work_dir=$8
    local snap_ref="$RUN_SNAP_ROOT/$month"
    local missing_file="$work_dir/missing-${provider}-${month}.txt"

    comm -23 "$list_file" "$remote_live" > "$missing_file"
    if [[ -s "$missing_file" ]]; then
        local missing_count
        missing_count=$(wc -l < "$missing_file" | tr -d '[:space:]')
        echo "  ⚠ $provider missing $missing_count non-empty live file(s) for $month; attempting backfill from verified snapshot..."
        local can_backfill="$work_dir/backfill-${provider}-${month}.txt"
        : > "$can_backfill"
        local fn
        while IFS= read -r fn; do
            [[ -f "$snap_ref/$fn" && ! -L "$snap_ref/$fn" && -s "$snap_ref/$fn" ]] && echo "$fn" >> "$can_backfill"
        done < "$missing_file"

        if [[ ! -s "$can_backfill" ]] || [[ $(wc -l < "$can_backfill") -ne "$missing_count" ]]; then
            echo "  ✗ Cannot backfill all missing files from verified snapshot for $provider ($month)"
            return 1
        fi
        LC_ALL=C sort -u "$can_backfill" -o "$can_backfill"

        local replace_zero="$work_dir/backfill-zero-${provider}-${month}.txt"
        local append_absent="$work_dir/backfill-absent-${provider}-${month}.txt"
        comm -12 "$can_backfill" "$remote_zero" > "$replace_zero"
        comm -23 "$can_backfill" "$remote_zero" > "$append_absent"

        if [[ -s "$append_absent" ]]; then
            if ! "$RCLONE" copy "$snap_ref" "$bucket" --files-from "$append_absent" --no-traverse --ignore-existing >/dev/null 2>&1; then
                echo "  ✗ Backfill upload failed for $provider ($month)"
                return 1
            fi
        fi
        if [[ -s "$replace_zero" ]]; then
            local prov_lower upload_lock raw_zero_check fresh_zero still_zero
            prov_lower=$(printf '%s' "$provider" | tr '[:upper:]' '[:lower:]')
            upload_lock="$LOG_DIR/upload-${prov_lower}.lock"
            exec 8>>"$upload_lock"
            if ! flock -w 300 8; then
                exec 8>&-
                echo "  ✗ Upload lock busy after 300s; skipping 0-byte replacement for $provider ($month)"
                return 1
            fi
            note_lock_holder "$upload_lock"
            if ! raw_zero_check=$("$RCLONE" lsf "$bucket" --max-depth 1 --files-only --format sp --include "aroi_validation_${month}*.json" 2>/dev/null); then
                exec 8>&-
                echo "  ✗ Failed re-checking 0-byte objects under lock for $provider ($month)"
                return 1
            fi
            fresh_zero="$work_dir/fresh-zero-${provider}-${month}.txt"
            still_zero="$work_dir/still-zero-${provider}-${month}.txt"
            printf '%s\n' "$raw_zero_check" | awk -F';' '$1+0 == 0 {print $2}' | { grep -E "$AROI_JSON_REGEX" || true; } | LC_ALL=C sort -u > "$fresh_zero"
            comm -12 "$replace_zero" "$fresh_zero" > "$still_zero"
            if [[ -s "$still_zero" ]]; then
                echo "  ↻ Replacing $(wc -l < "$still_zero" | tr -d '[:space:]') confirmed 0-byte object(s) in $provider ($month)..."
                if ! "$RCLONE" copy "$snap_ref" "$bucket" --files-from "$still_zero" --no-traverse >/dev/null 2>&1; then
                    exec 8>&-
                    echo "  ✗ Zero-byte replacement upload failed for $provider ($month)"
                    return 1
                fi
            fi
            exec 8>&-
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

    verify_remote_backup_pair "$RCLONE" "$provider" "$bucket" "$month" "$ARCHIVE_DIR" "$remote_backups" "$work_dir" || return 1
    return 0
}

# Safely remove uncompressed files for a verified completed month from public/.
# Under public.lock, checks each file's recorded dev:ino and bytes match the verified snapshot.
prune_completed_month_local() {
    local month=$1 list_file=$2
    local snap_ref="$RUN_SNAP_ROOT/$month"
    local snap_ident="$RUN_SNAP_ROOT/${month}.ident"
    local removed=0 failed=0 kept_changed=0 fn manifest_rc=0

    exec 7>>"$PUBLIC_LOCK"
    if ! flock -w "$COMPRESS_LOCK_WAIT" 7; then
        echo "  ✗ public.lock still held after ${COMPRESS_LOCK_WAIT}s; keeping local files for $month"
        exec 7>&-
        return 1
    fi
    note_lock_holder "$PUBLIC_LOCK"

    while IFS= read -r fn; do
        [[ "$fn" =~ ^aroi_validation_${month}[0-9]{2}_[0-9]{6}\.json$ ]] || continue
        if [[ -e "$PUBLIC_DIR/$fn" || -L "$PUBLIC_DIR/$fn" ]]; then
            local generation_matches=false expected_dev_ino="" cur_dev_ino=""
            if [[ -f "$PUBLIC_DIR/$fn" && ! -L "$PUBLIC_DIR/$fn" && -f "$snap_ref/$fn" && -s "$snap_ident" ]]; then
                expected_dev_ino=$(awk -F'\t' -v target="$fn" '$2 == target {print $1; exit}' "$snap_ident")
                cur_dev_ino=$(file_dev_ino "$PUBLIC_DIR/$fn" 2>/dev/null || true)
                if [[ -n "$expected_dev_ino" && "$cur_dev_ino" == "$expected_dev_ino" ]] \
                    && cmp -s "$PUBLIC_DIR/$fn" "$snap_ref/$fn"; then
                    generation_matches=true
                fi
            fi

            if [[ "$generation_matches" == "true" ]]; then
                if rm -f "$PUBLIC_DIR/$fn"; then
                    removed=$((removed + 1))
                else
                    echo "  ✗ Failed removing $PUBLIC_DIR/$fn"
                    failed=$((failed + 1))
                fi
            else
                echo "  ⚠ Retaining $fn in public/: file modified or replaced after snapshot verification"
                kept_changed=$((kept_changed + 1))
            fi
        fi
    done < "$list_file"

    build_files_manifest "$PUBLIC_DIR" "$ARCHIVE_DIR" "$STAGE_DIR" || manifest_rc=$?
    exec 7>&-

    if (( failed > 0 || kept_changed > 0 )) || [[ $manifest_rc -ne 0 ]]; then
        echo "  ✗ Local cleanup incomplete for $month (removed=$removed, retained=$kept_changed, failed=$failed, manifest_rc=$manifest_rc)"
        return 1
    fi

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
            if ! DO_BUCKET=$(resolve_do_bucket) || ! fetch_remote_state "DO" "$DO_BUCKET" "$VERIFY_WORK/do-live.txt" "$VERIFY_WORK/do-zero.txt" "$VERIFY_WORK/do-backups.txt"; then
                REMOTE_OK=false
                ERRORS=$((ERRORS + 1))
            fi
        fi
        if [[ "$R2_ENABLED" == "true" ]]; then
            if ! R2_BUCKET_URI=$(resolve_r2_bucket) || ! fetch_remote_state "R2" "$R2_BUCKET_URI" "$VERIFY_WORK/r2-live.txt" "$VERIFY_WORK/r2-zero.txt" "$VERIFY_WORK/r2-backups.txt"; then
                REMOTE_OK=false
                ERRORS=$((ERRORS + 1))
            fi
        fi

        if [[ "$REMOTE_OK" == "true" ]]; then
            for MONTH in "${COMPLETED_CANDIDATES[@]}"; do
                is_month_failed "$MONTH" && continue
                LIST_PATH="$ARCHIVE_DIR/aroi-${MONTH}.list"
                if ! verify_local_backup_pair "$ARCHIVE_DIR" "$MONTH" "$VERIFY_WORK"; then
                    echo "  ✗ Local verification failed for $MONTH; keeping files in public/"
                    ERRORS=$((ERRORS + 1))
                    continue
                fi

                MONTH_VERIFIED=true
                if [[ "$DO_ENABLED" == "true" ]]; then
                    if ! verify_completed_month_provider "DO" "$DO_BUCKET" "$MONTH" "$LIST_PATH" \
                        "$VERIFY_WORK/do-live.txt" "$VERIFY_WORK/do-zero.txt" "$VERIFY_WORK/do-backups.txt" "$VERIFY_WORK"; then
                        MONTH_VERIFIED=false
                    fi
                fi
                if [[ "$R2_ENABLED" == "true" && "$MONTH_VERIFIED" == "true" ]]; then
                    if ! verify_completed_month_provider "R2" "$R2_BUCKET_URI" "$MONTH" "$LIST_PATH" \
                        "$VERIFY_WORK/r2-live.txt" "$VERIFY_WORK/r2-zero.txt" "$VERIFY_WORK/r2-backups.txt" "$VERIFY_WORK"; then
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
    CRON_LOG_LOCK="$LOG_DIR/cron-log.lock"
    exec 6>>"$CRON_LOG_LOCK"
    if flock -x -w 300 6; then
        note_lock_holder "$CRON_LOG_LOCK"
        LOG_SIZE=$(file_size_bytes "$LOG_DIR/cron.log" || echo 0)
        [[ "$LOG_SIZE" =~ ^[0-9]+$ ]] || LOG_SIZE=0
        LOG_SIZE_MB=$((LOG_SIZE / 1048576))

        if (( LOG_SIZE_MB > 50 )); then
            DATE_PART=$(date +%Y-%m)
            LOG_ARCHIVE_NAME="cron-${DATE_PART}.log.zst"
            if [[ -e "$LOG_DIR/archives/$LOG_ARCHIVE_NAME" ]]; then
                LOG_ARCHIVE_NAME="cron-$(date +%Y-%m-%d_%H%M%S).log.zst"
            fi
            LOG_WORK=$(mktemp -d "$LOG_DIR/archives/.aroi-logwork.XXXXXX")
            TMP_LOG_ZST="$LOG_WORK/$LOG_ARCHIVE_NAME"
            echo "cron.log is ${LOG_SIZE_MB}MB, compressing with zstd..."
            if zstd -T0 "-${ZSTD_LEVEL}" -q -c "$LOG_DIR/cron.log" > "$TMP_LOG_ZST" && zstd -t "$TMP_LOG_ZST" >/dev/null 2>&1; then
                chmod 644 "$TMP_LOG_ZST"
                mv -f "$TMP_LOG_ZST" "$LOG_DIR/archives/$LOG_ARCHIVE_NAME"
                # Truncate in place under exclusive cron-log.lock so no batch append is lost
                tail -n 500 "$LOG_DIR/cron.log" > "$LOG_WORK/tail.log" || true
                cat "$LOG_WORK/tail.log" > "$LOG_DIR/cron.log"
                echo "  ✓ Compressed to $LOG_ARCHIVE_NAME"
            else
                echo "  ✗ cron.log zstd compression failed"
                ERRORS=$((ERRORS + 1))
            fi
            rm -rf "$LOG_WORK"
        else
            echo "cron.log is ${LOG_SIZE_MB}MB (under 50MB threshold)"
        fi
        exec 6>&-
    else
        exec 6>&-
        echo "ERROR: cron-log.lock busy after 300s; skipping cron.log rotation"
        ERRORS=$((ERRORS + 1))
    fi
fi

# === Step 5: Ensure files.json Manifest is Up to Date ===
echo "Updating file manifest..."
exec 7>>"$PUBLIC_LOCK"
if flock -w "$COMPRESS_LOCK_WAIT" 7; then
    note_lock_holder "$PUBLIC_LOCK"
    build_files_manifest "$PUBLIC_DIR" "$ARCHIVE_DIR" "$STAGE_DIR" || ERRORS=$((ERRORS + 1))
    exec 7>&-
else
    exec 7>&-
    echo "ERROR: public.lock held while updating manifest"
    ERRORS=$((ERRORS + 1))
fi

if (( ERRORS == 0 )); then
    if [[ "$NO_UPLOAD" != "true" && -z "$TARGET_MONTH" ]]; then
        TMP_MARKER=$(mktemp "$LOG_DIR/.aroi-tmp.date.XXXXXX")
        date '+%Y-%m-%d' > "$TMP_MARKER"
        chmod 644 "$TMP_MARKER"
        mv -f "$TMP_MARKER" "$LOG_DIR/last-archive-date"
    fi
    echo "Archival completed at $(date)"
    echo ""
    exit 0
fi

echo "Archival completed with $ERRORS error(s) at $(date)"
echo ""
exit 1
