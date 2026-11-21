#!/usr/bin/env bash
# AROI Validator - Multi-Copy Parity Verification & Backfill
# Checks parity across:
#   - Local archives (local-archive/aroi-*.tar.zst + .list)
#   - Local live current month (public/aroi_validation_*.json + files.json)
#   - DigitalOcean Spaces (live JSONs + _backups/aroi-*.tar.zst)
#   - Cloudflare R2 (live JSONs + _backups/aroi-*.tar.zst)
#
# Usage:
#   ./verify-sync.sh [--fix] [--verify-zstd]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
init_paths
load_config || true

PUBLIC_DIR="${OUTPUT_DIR:-$DEPLOY_DIR/public}"
ARCHIVE_DIR="${ARCHIVE_DIR:-$DEPLOY_DIR/local-archive}"
LOG_DIR="$DEPLOY_DIR/logs"
STAGE_DIR="$DEPLOY_DIR/tmp"
RCLONE="${RCLONE_PATH:-$(command -v rclone 2>/dev/null || echo "$HOME/bin/rclone")}"
ZSTD_LONG=$(validate_int_range "ZSTD_LONG" "${ZSTD_LONG:-27}" 10 27 27)
ZSTD_DEC_LONG=$(zstd_decode_long "$ZSTD_LONG")

: "${DO_ENABLED:=false}" "${R2_ENABLED:=false}"

FIX_MODE=false
VERIFY_ZSTD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix) FIX_MODE=true; shift ;;
        --verify-zstd) VERIFY_ZSTD=true; shift ;;
        --help|-h)
            echo "Usage: $0 [--fix] [--verify-zstd]"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            exit 2
            ;;
    esac
done

for cmd in jq zstd tar; do
    require_cmd "$cmd" || exit 1
done
if [[ "$DO_ENABLED" == "true" || "$R2_ENABLED" == "true" ]]; then
    [[ -x "$RCLONE" ]] || { log_error "rclone not found at $RCLONE"; exit 1; }
fi

mkdir -p "$PUBLIC_DIR" "$ARCHIVE_DIR" "$LOG_DIR" "$STAGE_DIR"
WORK=$(mktemp -d "$STAGE_DIR/verify-sync.XXXXXX")
# shellcheck disable=SC2329  # invoked via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

ERRORS=0

# List 0-byte canonical or matching validation filenames in PUBLIC_DIR
list_local_zero() {
    (
        cd "$PUBLIC_DIR"
        find . -maxdepth 1 -name 'aroi_validation_*.json' -type f -size 0c 2>/dev/null \
            | sed 's|^\./||' \
            | LC_ALL=C sort -u || true
    )
}

# List sorted unique YYYYMM backup months having either a .tar.zst or .list in ARCHIVE_DIR.
# Writes output to out_file and returns non-zero if ARCHIVE_DIR cannot be scanned.
list_local_backup_months() {
    local out_file=$1 raw_find
    : > "$out_file"
    [[ -d "$ARCHIVE_DIR" ]] || return 0
    if ! raw_find=$(cd "$ARCHIVE_DIR" && find . -maxdepth 1 \( -name 'aroi-*.tar.zst' -o -name 'aroi-*.list' \) -type f); then
        return 1
    fi
    [[ -n "$raw_find" ]] || return 0
    printf '%s\n' "$raw_find" \
        | sed -E 's#^\./aroi-([0-9]{6})\.(tar\.zst|list)$#\1#' \
        | { grep -E '^[0-9]{6}$' || true; } \
        | LC_ALL=C sort -u > "$out_file"
}

# Collect local expected dataset from local-archive/*.list + non-empty public/*.json.
# Fails loudly on scan, read, or sort errors so parity/repair never run on a truncated set.
collect_local_expected() {
    local raw_file="$WORK/expected-raw.txt" lists_file="$WORK/expected-lists.bin"
    local lf grep_rc read_err=0
    : > "$raw_file"
    if [[ -d "$ARCHIVE_DIR" ]]; then
        if ! find "$ARCHIVE_DIR" -maxdepth 1 -name 'aroi-*.list' -type f -print0 > "$lists_file"; then
            return 1
        fi
        while IFS= read -r -d '' lf; do
            grep_rc=0
            grep -E "$AROI_JSON_REGEX" "$lf" >> "$raw_file" || grep_rc=$?
            if (( grep_rc > 1 )); then
                read_err=1
                break
            fi
        done < "$lists_file"
        rm -f "$lists_file"
        (( read_err == 0 )) || return 1
    fi
    list_nonempty_validation_files "$PUBLIC_DIR" >> "$raw_file" || return 1
    LC_ALL=C sort -u "$raw_file" > "$WORK/local-expected.txt" || return 1
}

# List live JSONs (non-empty and 0-byte separately) + _backups/ (with MD5) from a remote bucket.
# Leaves output files present only when both live and _backups/ listings succeed.
scan_remote() {
    local name=$1 bucket=$2 live_ok=$3 live_zero=$4 backups_out=$5
    local raw_live raw_bk
    raw_live="$WORK/${name}-raw-live.txt"
    raw_bk="$WORK/${name}-raw-bk.txt"

    rm -f "$live_ok" "$live_zero" "$backups_out"

    if ! "$RCLONE" lsf "$bucket" --max-depth 1 --files-only --format sp > "$raw_live" 2>"$WORK/${name}.err"; then
        echo "✗ $name: failed listing $bucket ($(head -n 1 "$WORK/${name}.err"))"
        return 1
    fi
    if ! "$RCLONE" lsf "$bucket/_backups/" --max-depth 1 --files-only --format shp > "$raw_bk" 2>"$WORK/${name}-bk.err"; then
        echo "✗ $name: failed listing $bucket/_backups/ ($(head -n 1 "$WORK/${name}-bk.err"))"
        return 1
    fi

    awk -F';' '$1+0 > 0 {print $2}' "$raw_live" | { grep -E "$AROI_JSON_REGEX" || true; } | LC_ALL=C sort -u > "$live_ok"
    awk -F';' '$1+0 == 0 {print $2}' "$raw_live" | { grep -E "$AROI_JSON_REGEX" || true; } | LC_ALL=C sort -u > "$live_zero"
    LC_ALL=C sort -u "$raw_bk" > "$backups_out"
}

# Safely install verified non-empty files from src_dir into PUBLIC_DIR only when
# the destination file does not yet exist or is confirmed 0 bytes.
install_missing_or_empty_local() {
    local src_dir=$1 list_file=$2
    local fn installed=0 rc=0

    [[ -s "$list_file" ]] || return 0
    exec 7>>"$LOG_DIR/public.lock"
    if ! flock -w "$PUBLIC_LOCK_WAIT" 7; then
        exec 7>&-
        echo "  ✗ public.lock held while repairing local public/ files"
        return 1
    fi
    note_lock_holder "$LOG_DIR/public.lock"
    clean_publish_temps "$PUBLIC_DIR"

    while IFS= read -r fn; do
        [[ "$fn" =~ $AROI_JSON_REGEX ]] || continue
        [[ -f "$src_dir/$fn" && ! -L "$src_dir/$fn" && -s "$src_dir/$fn" ]] || continue
        if [[ ! -e "$PUBLIC_DIR/$fn" || ! -s "$PUBLIC_DIR/$fn" ]]; then
            if atomic_install_file "$src_dir/$fn" "$PUBLIC_DIR/$fn" 644; then
                installed=$((installed + 1))
            else
                echo "  ✗ Failed installing repaired file $PUBLIC_DIR/$fn"
                rc=1
            fi
        fi
    done < "$list_file"

    exec 7>&-
    (( installed == 0 )) || echo "  ✓ Installed/repaired $installed file(s) into public/"
    return "$rc"
}

# Recover remote -> local extra files and repair confirmed 0-byte files in PUBLIC_DIR
# without overwriting existing non-empty local files.
repair_local_from_sources() {
    local scan_do_ok=$1 scan_r2_ok=$2
    local -a providers=() buckets=() live_files=()
    if [[ "$scan_do_ok" == "true" ]]; then
        providers+=("do"); buckets+=("$DO_BUCKET"); live_files+=("$WORK/do-live.txt")
    fi
    if [[ "$scan_r2_ok" == "true" ]]; then
        providers+=("r2"); buckets+=("$R2_BUCKET_URI"); live_files+=("$WORK/r2-live.txt")
    fi

    list_local_zero > "$WORK/local-zero-init.txt"

    local idx prov bucket live_file extra ec dl_dir
    for idx in "${!providers[@]}"; do
        prov="${providers[$idx]}"
        bucket="${buckets[$idx]}"
        live_file="${live_files[$idx]}"
        extra="$WORK/extra-${prov}.txt"
        {
            comm -13 "$WORK/local-expected.txt" "$live_file"
            if [[ -s "$WORK/local-zero-init.txt" ]]; then
                comm -12 "$WORK/local-zero-init.txt" "$live_file"
            fi
        } | LC_ALL=C sort -u > "$extra"
        [[ -s "$extra" ]] || continue
        ec=$(wc -l < "$extra" | tr -d '[:space:]')
        echo "  → Downloading $ec file(s) missing locally (or replacing 0-byte local copies) from $prov to public/..."
        dl_dir=$(mktemp -d "$WORK/dl-local-${prov}.XXXXXX")
        if "$RCLONE" copy "$bucket" "$dl_dir" --files-from "$extra" --no-traverse; then
            install_missing_or_empty_local "$dl_dir" "$extra" || ERRORS=$((ERRORS + 1))
        else
            echo "  ✗ Download from $prov failed"
            ERRORS=$((ERRORS + 1))
        fi
        rm -rf "$dl_dir"
        collect_local_expected
        list_local_zero > "$WORK/local-zero-init.txt"
    done

    # Also attempt recovering any remaining 0-byte local files from local-archive/*.tar.zst
    local rem_zero
    rem_zero=$(list_local_zero)
    if [[ -n "$rem_zero" ]]; then
        local ym zst want_ym members_ym present_ym ext_dir rc fn
        while IFS= read -r ym; do
            [[ -z "$ym" ]] && continue
            zst="$ARCHIVE_DIR/aroi-${ym}.tar.zst"
            [[ -s "$zst" ]] || continue
            want_ym="$WORK/local-zero-${ym}.txt"
            printf '%s\n' "$rem_zero" | grep -E "^aroi_validation_${ym}[0-9]{2}_[0-9]{6}\.json$" | LC_ALL=C sort -u > "$want_ym" || true
            [[ -s "$want_ym" ]] || continue
            members_ym="$WORK/local-members-${ym}.txt"
            present_ym="$WORK/local-present-${ym}.txt"
            if ! list_archive_members "$zst" "$members_ym"; then
                echo "  ⚠ Failed reading archive index for 0-byte local repair ($zst)"
                continue
            fi
            comm -12 "$want_ym" "$members_ym" > "$present_ym"
            [[ -s "$present_ym" ]] || continue
            ext_dir=$(mktemp -d "$WORK/repair-local-${ym}.XXXXXX")
            rc=0
            zstd -dc --long="$ZSTD_DEC_LONG" "$zst" 2>/dev/null | tar -C "$ext_dir" -xf - -T "$present_ym" 2>/dev/null || rc=$?
            if [[ $rc -eq 0 ]]; then
                while IFS= read -r fn; do
                    if [[ ! -f "$ext_dir/$fn" || -L "$ext_dir/$fn" || ! -s "$ext_dir/$fn" ]]; then
                        rm -f "$ext_dir/$fn"
                    fi
                done < "$present_ym"
                install_missing_or_empty_local "$ext_dir" "$present_ym" || ERRORS=$((ERRORS + 1))
            else
                echo "  ⚠ Failed extracting 0-byte local repair for $ym from $zst"
            fi
            rm -rf "$ext_dir"
        done < <(printf '%s\n' "$rem_zero" | sed -E 's/^aroi_validation_([0-9]{6}).*/\1/' | LC_ALL=C sort -u)
    fi
}

# Materialize missing hourly JSONs from public/, local-archive/*.tar.zst, or healthy peer
# into $stage and copy to target_bucket (replacing ONLY confirmed remote_zero keys and keeping
# --ignore-existing for absent keys). Verifies full missing_file parity afterwards.
backfill_remote_live() {
    local target_name=$1 target_bucket=$2 missing_file=$3 remote_zero=$4 source_bucket=${5:-}
    local stage="$WORK/backfill-$target_name"
    mkdir -p "$stage"

    local -a need_from_archive=()
    local -a need_from_remote=()
    local fn
    while IFS= read -r fn; do
        [[ -z "$fn" ]] && continue
        if [[ -s "$PUBLIC_DIR/$fn" ]]; then
            ln "$PUBLIC_DIR/$fn" "$stage/$fn" 2>/dev/null || cp -p "$PUBLIC_DIR/$fn" "$stage/$fn"
        else
            need_from_archive+=("$fn")
        fi
    done < "$missing_file"

    if (( ${#need_from_archive[@]} > 0 )); then
        # Group by YYYYMM and extract matching members into a separate temp dir per month
        local ym zst want members_file want_present ext_dir rc
        while IFS= read -r ym; do
            [[ -z "$ym" ]] && continue
            zst="$ARCHIVE_DIR/aroi-${ym}.tar.zst"
            want="$WORK/want-${target_name}-${ym}.txt"
            printf '%s\n' "${need_from_archive[@]}" | grep "^aroi_validation_${ym}" | LC_ALL=C sort -u > "$want" || true
            if [[ -s "$zst" && -s "$want" ]]; then
                members_file="$WORK/members-${target_name}-${ym}.txt"
                want_present="$WORK/present-${target_name}-${ym}.txt"
                if ! list_archive_members "$zst" "$members_file"; then
                    echo "  ⚠ Failed reading archive index for $ym ($zst); skipping archive extraction"
                    continue
                fi
                comm -12 "$want" "$members_file" > "$want_present"
                [[ -s "$want_present" ]] || continue
                ext_dir=$(mktemp -d "$WORK/extract-${target_name}-${ym}.XXXXXX")
                rc=0
                zstd -dc --long="$ZSTD_DEC_LONG" "$zst" 2>/dev/null | tar -C "$ext_dir" -xf - -T "$want_present" 2>/dev/null || rc=$?
                if [[ $rc -eq 0 ]]; then
                    while IFS= read -r fn; do
                        [[ -z "$fn" ]] && continue
                        if [[ -f "$ext_dir/$fn" && ! -L "$ext_dir/$fn" && -s "$ext_dir/$fn" ]]; then
                            mv -f "$ext_dir/$fn" "$stage/$fn"
                        fi
                    done < "$want_present"
                else
                    echo "  ⚠ Archive extraction failed for $ym ($zst); discarding partial files"
                fi
                rm -rf "$ext_dir"
            fi
        done < <(printf '%s\n' "${need_from_archive[@]}" | sed -E 's/^aroi_validation_([0-9]{6}).*/\1/' | LC_ALL=C sort -u)

        for fn in "${need_from_archive[@]}"; do
            [[ -s "$stage/$fn" ]] || need_from_remote+=("$fn")
        done
        if (( ${#need_from_remote[@]} > 0 )) && [[ -n "$source_bucket" ]]; then
            local dl_list="$WORK/dl-${target_name}.txt"
            local peer_dir
            peer_dir=$(mktemp -d "$WORK/peer-dl-${target_name}.XXXXXX")
            printf '%s\n' "${need_from_remote[@]}" > "$dl_list"
            if "$RCLONE" copy "$source_bucket" "$peer_dir" --files-from "$dl_list" --no-traverse; then
                for fn in "${need_from_remote[@]}"; do
                    if [[ -f "$peer_dir/$fn" && ! -L "$peer_dir/$fn" && -s "$peer_dir/$fn" ]]; then
                        mv -f "$peer_dir/$fn" "$stage/$fn"
                    fi
                done
            fi
            rm -rf "$peer_dir"
        fi
    fi

    local ready="$WORK/ready-${target_name}.txt"
    list_nonempty_validation_files "$stage" > "$ready"

    local unrecovered="$WORK/unrecovered-${target_name}.txt"
    comm -23 "$missing_file" "$ready" > "$unrecovered"
    if [[ -s "$unrecovered" ]]; then
        echo "  ✗ Unable to stage $(wc -l < "$unrecovered" | tr -d '[:space:]') missing file(s) for $target_name:"
        sed 's/^/      /' "$unrecovered"
    fi

    if [[ ! -s "$ready" ]]; then
        echo "  ✗ No local/source copies found to backfill $target_name"
        return 1
    fi

    local ready_zero="$WORK/ready-zero-${target_name}.txt"
    local ready_absent="$WORK/ready-absent-${target_name}.txt"
    comm -12 "$ready" "$remote_zero" > "$ready_zero"
    comm -23 "$ready" "$remote_zero" > "$ready_absent"

    if [[ -s "$ready_absent" ]]; then
        echo "  → Backfilling $(wc -l < "$ready_absent" | tr -d '[:space:]') missing live file(s) to $target_name..."
        "$RCLONE" copy "$stage" "$target_bucket" --files-from "$ready_absent" --no-traverse --s3-no-check-bucket --ignore-existing || return 1
    fi
    if [[ -s "$ready_zero" ]]; then
        local target_lower upload_lock raw_zero_check fresh_zero still_zero
        target_lower=$(printf '%s' "$target_name" | tr '[:upper:]' '[:lower:]')
        upload_lock="$LOG_DIR/upload-${target_lower}.lock"
        exec 8>>"$upload_lock"
        if ! flock -w 300 8; then
            exec 8>&-
            echo "  ✗ Upload lock busy after 300s; skipping 0-byte replacement for $target_name"
            return 1
        fi
        note_lock_holder "$upload_lock"
        if ! raw_zero_check=$("$RCLONE" lsf "$target_bucket" --max-depth 1 --files-only --format sp 2>/dev/null); then
            exec 8>&-
            echo "  ✗ Failed re-checking 0-byte objects under lock for $target_name"
            return 1
        fi
        fresh_zero="$WORK/fresh-zero-${target_name}.txt"
        still_zero="$WORK/still-zero-${target_name}.txt"
        printf '%s\n' "$raw_zero_check" | awk -F';' '$1+0 == 0 {print $2}' | { grep -E "$AROI_JSON_REGEX" || true; } | LC_ALL=C sort -u > "$fresh_zero"
        comm -12 "$ready_zero" "$fresh_zero" > "$still_zero"
        if [[ -s "$still_zero" ]]; then
            echo "  ↻ Replacing $(wc -l < "$still_zero" | tr -d '[:space:]') confirmed 0-byte live file(s) in $target_name..."
            if ! "$RCLONE" copy "$stage" "$target_bucket" --files-from "$still_zero" --no-traverse --s3-no-check-bucket; then
                exec 8>&-
                return 1
            fi
        fi
        exec 8>&-
    fi

    # Re-verify full requested missing_file against remote live bucket
    local raw_recheck recheck_live still_missing
    if ! raw_recheck=$("$RCLONE" lsf "$target_bucket" --max-depth 1 --files-only --format sp 2>/dev/null); then
        echo "  ✗ Failed re-listing $target_bucket after backfill"
        return 1
    fi
    recheck_live="$WORK/recheck-live-${target_name}.txt"
    still_missing="$WORK/still-missing-${target_name}.txt"
    printf '%s\n' "$raw_recheck" | awk -F';' '$1+0 > 0 {print $2}' | { grep -E "$AROI_JSON_REGEX" || true; } | LC_ALL=C sort -u > "$recheck_live"
    comm -23 "$missing_file" "$recheck_live" > "$still_missing"
    if [[ -s "$still_missing" ]]; then
        echo "  ✗ $target_name still missing $(wc -l < "$still_missing" | tr -d '[:space:]') live file(s) after backfill:"
        sed 's/^/      /' "$still_missing"
        return 1
    fi
    return 0
}

echo "=== AROI Validator Parity Audit ($(date)) ==="

# 1. Local 0-byte check (reported immediately in audit mode; repaired then rechecked in --fix mode)
local_zero=$(list_local_zero)
if [[ -n "$local_zero" ]] && ! $FIX_MODE; then
    echo "✗ Local public/ contains 0-byte JSON(s):"
    printf '    %s\n' "$local_zero"
    ERRORS=$((ERRORS + 1))
elif [[ -n "$local_zero" ]]; then
    echo "⚠ Local public/ contains 0-byte JSON(s); attempting repair..."
fi

# 2. Validate local monthly backup pairs (always before remote backup repair; also under --verify-zstd).
# Captures consistent pairs into $WORK/validated-pairs/ under archive.lock so validation, upload,
# and post-repair rechecks inspect one unchanging generation.
VALIDATED_PAIR_DIR="$WORK/validated-pairs"
mkdir -p "$VALIDATED_PAIR_DIR"

validate_local_backup_pairs() {
    : > "$WORK/valid-backup-months.txt"
    local archive_lock="$LOG_DIR/archive.lock"
    exec 5>>"$archive_lock"
    if ! flock -w 300 5; then
        exec 5>&-
        echo "✗ archive.lock busy after 300s; cannot snapshot local backup pairs"
        ERRORS=$((ERRORS + 1))
        return 1
    fi
    note_lock_holder "$archive_lock"

    if ! list_local_backup_months "$WORK/all-backup-months.txt"; then
        exec 5>&-
        echo "✗ Failed scanning local archive directory: $ARCHIVE_DIR"
        ERRORS=$((ERRORS + 1))
        return 1
    fi

    local ym name
    while IFS= read -r ym; do
        [[ -z "$ym" ]] && continue
        for name in "aroi-${ym}.tar.zst" "aroi-${ym}.list"; do
            if [[ -e "$ARCHIVE_DIR/$name" ]]; then
                ln "$ARCHIVE_DIR/$name" "$VALIDATED_PAIR_DIR/$name" 2>/dev/null \
                    || cp -p "$ARCHIVE_DIR/$name" "$VALIDATED_PAIR_DIR/$name" || {
                    exec 5>&-
                    echo "✗ Failed snapshotting local backup artifact: $ARCHIVE_DIR/$name"
                    ERRORS=$((ERRORS + 1))
                    return 1
                }
            fi
        done
    done < "$WORK/all-backup-months.txt"
    exec 5>&-

    while IFS= read -r ym; do
        [[ -z "$ym" ]] && continue
        if verify_local_backup_pair "$VALIDATED_PAIR_DIR" "$ym" "$WORK"; then
            echo "$ym" >> "$WORK/valid-backup-months.txt"
        else
            ERRORS=$((ERRORS + 1))
        fi
    done < "$WORK/all-backup-months.txt"
}

if $VERIFY_ZSTD || [[ "$DO_ENABLED" == "true" || "$R2_ENABLED" == "true" ]]; then
    validate_local_backup_pairs || true
else
    : > "$WORK/valid-backup-months.txt"
fi

if ! collect_local_expected; then
    echo "✗ Failed collecting local expected dataset; aborting parity checks"
    ERRORS=$((ERRORS + 1))
    exit 1
fi
expected_count=$(wc -l < "$WORK/local-expected.txt" | tr -d '[:space:]')
echo "Local expected hourly JSONs: $expected_count"

# 3. Scan remote buckets separately so one provider failure never blocks auditing the peer
DO_BUCKET=""
R2_BUCKET_URI=""
DO_SCAN_OK=false
R2_SCAN_OK=false

if [[ "$DO_ENABLED" == "true" ]]; then
    if DO_BUCKET=$(resolve_do_bucket) \
        && scan_remote "do" "$DO_BUCKET" "$WORK/do-live.txt" "$WORK/do-zero.txt" "$WORK/do-backups.txt"; then
        DO_SCAN_OK=true
        echo "DO Spaces live JSONs: $(wc -l < "$WORK/do-live.txt" | tr -d '[:space:]')"
        if [[ -s "$WORK/do-zero.txt" ]]; then
            if $FIX_MODE; then
                echo "⚠ DO Spaces has 0-byte live JSON(s); attempting repair..."
            else
                echo "✗ DO Spaces has 0-byte live JSON(s):"
                sed 's/^/    /' "$WORK/do-zero.txt"
                ERRORS=$((ERRORS + 1))
            fi
        fi
    else
        ERRORS=$((ERRORS + 1))
    fi
fi

if [[ "$R2_ENABLED" == "true" ]]; then
    if R2_BUCKET_URI=$(resolve_r2_bucket) \
        && scan_remote "r2" "$R2_BUCKET_URI" "$WORK/r2-live.txt" "$WORK/r2-zero.txt" "$WORK/r2-backups.txt"; then
        R2_SCAN_OK=true
        echo "R2 live JSONs:        $(wc -l < "$WORK/r2-live.txt" | tr -d '[:space:]')"
        if [[ -s "$WORK/r2-zero.txt" ]]; then
            if $FIX_MODE; then
                echo "⚠ R2 has 0-byte live JSON(s); attempting repair..."
            else
                echo "✗ R2 has 0-byte live JSON(s):"
                sed 's/^/    /' "$WORK/r2-zero.txt"
                ERRORS=$((ERRORS + 1))
            fi
        fi
    else
        ERRORS=$((ERRORS + 1))
    fi
fi

# 4a. Check/repair remote -> local extras & local 0-byte files before remote parity backfill
if $FIX_MODE; then
    repair_local_from_sources "$DO_SCAN_OK" "$R2_SCAN_OK"
    if ! collect_local_expected; then
        echo "✗ Failed re-collecting local expected dataset after repair; aborting parity checks"
        ERRORS=$((ERRORS + 1))
        exit 1
    fi
    expected_count=$(wc -l < "$WORK/local-expected.txt" | tr -d '[:space:]')
    rem_zero=$(list_local_zero)
    if [[ -n "$rem_zero" ]]; then
        echo "✗ Local public/ still contains 0-byte JSON(s) after repair:"
        printf '    %s\n' "$rem_zero"
        ERRORS=$((ERRORS + 1))
    fi
else
    if [[ "$DO_SCAN_OK" == "true" ]]; then
        comm -13 "$WORK/local-expected.txt" "$WORK/do-live.txt" > "$WORK/extra-do.txt"
        if [[ -s "$WORK/extra-do.txt" ]]; then
            echo "⚠ DO has $(wc -l < "$WORK/extra-do.txt" | tr -d '[:space:]') live JSON(s) absent from local archive/public"
            ERRORS=$((ERRORS + 1))
        fi
    fi
    if [[ "$R2_SCAN_OK" == "true" ]]; then
        comm -13 "$WORK/local-expected.txt" "$WORK/r2-live.txt" > "$WORK/extra-r2.txt"
        if [[ -s "$WORK/extra-r2.txt" ]]; then
            echo "⚠ R2 has $(wc -l < "$WORK/extra-r2.txt" | tr -d '[:space:]') live JSON(s) absent from local archive/public"
            ERRORS=$((ERRORS + 1))
        fi
    fi
fi

# 4b. Compare live sets & zstd backup pairs and backfill in --fix mode
check_provider_parity() {
    local name=$1 bucket=$2 live_file=$3 zero_file=$4 backups_file=$5 peer_bucket=${6:-}
    local missing="$WORK/missing-${name}.txt"
    comm -23 "$WORK/local-expected.txt" "$live_file" > "$missing"
    if [[ -s "$missing" ]]; then
        local mc
        mc=$(wc -l < "$missing" | tr -d '[:space:]')
        echo "⚠ $name missing $mc expected live JSON(s)"
        if $FIX_MODE; then
            backfill_remote_live "$name" "$bucket" "$missing" "$zero_file" "$peer_bucket" || ERRORS=$((ERRORS + 1))
        else
            ERRORS=$((ERRORS + 1))
        fi
    fi

    # Re-check 0-byte live objects in --fix mode (catches any 0-byte key absent from local-expected)
    if $FIX_MODE && [[ -s "$zero_file" ]]; then
        local raw_post post_zero
        if raw_post=$("$RCLONE" lsf "$bucket" --max-depth 1 --files-only --format sp 2>/dev/null); then
            post_zero="$WORK/post-zero-${name}.txt"
            printf '%s\n' "$raw_post" | awk -F';' '$1+0 == 0 {print $2}' | { grep -E "$AROI_JSON_REGEX" || true; } | LC_ALL=C sort -u > "$post_zero"
            if [[ -s "$post_zero" ]]; then
                echo "✗ $name still has 0-byte live JSON(s) after repair:"
                sed 's/^/    /' "$post_zero"
                ERRORS=$((ERRORS + 1))
            fi
        else
            ERRORS=$((ERRORS + 1))
        fi
    fi

    # Verify valid local zstd backup archives & .list manifests against $bucket/_backups/
    # using the locked-captured VALIDATED_PAIR_DIR generation for check, repair upload, and recheck.
    local -a mismatched_months=()
    local ym
    while IFS= read -r ym; do
        [[ -z "$ym" ]] && continue
        if ! verify_remote_backup_pair "$RCLONE" "$name" "$bucket" "$ym" "$VALIDATED_PAIR_DIR" "$backups_file" "$WORK"; then
            mismatched_months+=("$ym")
        fi
    done < "$WORK/valid-backup-months.txt"

    if (( ${#mismatched_months[@]} > 0 )); then
        if $FIX_MODE; then
            local name_lower upload_script repair_failed=false
            name_lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
            upload_script="$SCRIPT_DIR/upload-${name_lower}.sh"
            if [[ ! -x "$upload_script" ]]; then
                ERRORS=$((ERRORS + 1))
            else
                for ym in "${mismatched_months[@]}"; do
                    if ! "$upload_script" --repair-backups "$ym" "$VALIDATED_PAIR_DIR"; then
                        ERRORS=$((ERRORS + 1))
                        repair_failed=true
                    fi
                done
                if [[ "$repair_failed" != "true" ]]; then
                    local recheck_bk="$WORK/recheck-${name_lower}-backups.txt"
                    if "$RCLONE" lsf "$bucket/_backups/" --max-depth 1 --files-only --format shp > "$recheck_bk" 2>/dev/null; then
                        for ym in "${mismatched_months[@]}"; do
                            if ! verify_remote_backup_pair "$RCLONE" "$name" "$bucket" "$ym" "$VALIDATED_PAIR_DIR" "$recheck_bk" "$WORK"; then
                                ERRORS=$((ERRORS + 1))
                            fi
                        done
                    else
                        ERRORS=$((ERRORS + 1))
                    fi
                fi
            fi
        else
            ERRORS=$((ERRORS + 1))
        fi
    fi
}

if [[ "$DO_SCAN_OK" == "true" ]]; then
    peer=""
    [[ "$R2_SCAN_OK" == "true" ]] && peer="$R2_BUCKET_URI"
    check_provider_parity "DO" "$DO_BUCKET" "$WORK/do-live.txt" "$WORK/do-zero.txt" "$WORK/do-backups.txt" "$peer"
fi
if [[ "$R2_SCAN_OK" == "true" ]]; then
    peer=""
    [[ "$DO_SCAN_OK" == "true" ]] && peer="$DO_BUCKET"
    check_provider_parity "R2" "$R2_BUCKET_URI" "$WORK/r2-live.txt" "$WORK/r2-zero.txt" "$WORK/r2-backups.txt" "$peer"
fi

# 5. Validate public/files.json as a single JSON array document of unique canonical filenames
files_json_valid=false
: > "$WORK/files-json.txt"
if [[ -s "$PUBLIC_DIR/files.json" ]] \
    && jq -se --arg re "$AROI_JSON_REGEX" \
        'length == 1 and (.[0] | type == "array" and all(.[]; (type == "string") and test($re)) and (length == (unique | length)))' \
        "$PUBLIC_DIR/files.json" >/dev/null 2>&1; then
    jq -rs '.[0][]' "$PUBLIC_DIR/files.json" | LC_ALL=C sort -u > "$WORK/files-json.txt"
    files_json_valid=true
fi

if [[ "$files_json_valid" != "true" ]] || ! cmp -s "$WORK/local-expected.txt" "$WORK/files-json.txt"; then
    echo "⚠ public/files.json differs from local expected set or has invalid schema (valid_array=$files_json_valid, files.json=$(wc -l < "$WORK/files-json.txt" | tr -d '[:space:]'), expected=$expected_count)"
    if $FIX_MODE; then
        exec 7>>"$LOG_DIR/public.lock"
        if flock -w "$PUBLIC_LOCK_WAIT" 7; then
            note_lock_holder "$LOG_DIR/public.lock"
            if build_files_manifest "$PUBLIC_DIR" "$ARCHIVE_DIR" "$STAGE_DIR"; then
                echo "  ✓ Rebuilt public/files.json"
            else
                echo "  ✗ Failed rebuilding public/files.json"
                ERRORS=$((ERRORS + 1))
            fi
            exec 7>&-
        else
            exec 7>&-
            ERRORS=$((ERRORS + 1))
        fi
    else
        ERRORS=$((ERRORS + 1))
    fi
fi

# 6. Refresh destination-scoped ledgers + metadata in --fix mode for scanned providers
if $FIX_MODE; then
    if [[ "$DO_ENABLED" == "true" && "$DO_SCAN_OK" == "true" ]]; then
        if raw_do=$("$RCLONE" lsf "$DO_BUCKET" --max-depth 1 --files-only --format sp 2>/dev/null); then
            printf '%s\n' "$raw_do" | awk -F';' '$1+0 > 0 {print $2}' | { grep -E "$AROI_JSON_REGEX" || true; } \
                | LC_ALL=C sort -u > "$WORK/ledger-do.entries"
            write_upload_ledger "$LOG_DIR/uploaded-do.txt" "$DO_BUCKET" "$WORK/ledger-do.entries" || ERRORS=$((ERRORS + 1))
        else
            ERRORS=$((ERRORS + 1))
        fi
        "$SCRIPT_DIR/upload-do.sh" "$PUBLIC_DIR" || ERRORS=$((ERRORS + 1))
    fi
    if [[ "$R2_ENABLED" == "true" && "$R2_SCAN_OK" == "true" ]]; then
        if raw_r2=$("$RCLONE" lsf "$R2_BUCKET_URI" --max-depth 1 --files-only --format sp 2>/dev/null); then
            printf '%s\n' "$raw_r2" | awk -F';' '$1+0 > 0 {print $2}' | { grep -E "$AROI_JSON_REGEX" || true; } \
                | LC_ALL=C sort -u > "$WORK/ledger-r2.entries"
            write_upload_ledger "$LOG_DIR/uploaded-r2.txt" "$R2_BUCKET_URI" "$WORK/ledger-r2.entries" || ERRORS=$((ERRORS + 1))
        else
            ERRORS=$((ERRORS + 1))
        fi
        "$SCRIPT_DIR/upload-r2.sh" "$PUBLIC_DIR" || ERRORS=$((ERRORS + 1))
    fi
fi

if (( ERRORS == 0 )); then
    echo "✅ Parity check passed (0 issues)"
    exit 0
fi

echo "❌ Parity check found $ERRORS issue(s)"
exit 1
