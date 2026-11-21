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

# Collect local expected dataset from local-archive/*.list + non-empty public/*.json
collect_local_expected() {
    {
        local lf
        while IFS= read -r -d '' lf; do
            grep -E "$AROI_JSON_REGEX" "$lf" 2>/dev/null || true
        done < <(find "$ARCHIVE_DIR" -maxdepth 1 -name 'aroi-*.list' -type f -print0 2>/dev/null)
        list_nonempty_validation_files "$PUBLIC_DIR"
    } | LC_ALL=C sort -u > "$WORK/local-expected.txt"
}

# List live JSONs (non-empty and 0-byte separately) + _backups/ from a remote bucket
scan_remote() {
    local name=$1 bucket=$2 live_ok=$3 live_zero=$4 backups_out=$5
    local raw_live raw_bk
    raw_live="$WORK/${name}-raw-live.txt"
    raw_bk="$WORK/${name}-raw-bk.txt"

    if ! "$RCLONE" lsf "$bucket" --max-depth 1 --files-only --format sp > "$raw_live" 2>"$WORK/${name}.err"; then
        echo "✗ $name: failed listing $bucket ($(head -n 1 "$WORK/${name}.err"))"
        return 1
    fi
    awk -F';' '$1+0 > 0 {print $2}' "$raw_live" | grep -E "$AROI_JSON_REGEX" | LC_ALL=C sort -u > "$live_ok" || true
    awk -F';' '$1+0 == 0 {print $2}' "$raw_live" | grep -E "$AROI_JSON_REGEX" | LC_ALL=C sort -u > "$live_zero" || true

    if ! "$RCLONE" lsf "$bucket/_backups/" --max-depth 1 --files-only --format sp > "$raw_bk" 2>"$WORK/${name}-bk.err"; then
        echo "✗ $name: failed listing $bucket/_backups/ ($(head -n 1 "$WORK/${name}-bk.err"))"
        return 1
    fi
    LC_ALL=C sort -u "$raw_bk" > "$backups_out"
}

# Materialize missing hourly JSONs from public/ or local-archive/*.tar.zst (or healthy bucket)
# into $WORK/stage-backfill/ and copy to target bucket.
backfill_remote_live() {
    local target_name=$1 target_bucket=$2 missing_file=$3 source_bucket=${4:-}
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
        # Group by YYYYMM and extract matching files from local-archive/aroi-YYYYMM.tar.zst
        local ym
        while IFS= read -r ym; do
            [[ -z "$ym" ]] && continue
            local zst="$ARCHIVE_DIR/aroi-${ym}.tar.zst"
            local want="$WORK/want-${target_name}-${ym}.txt"
            printf '%s\n' "${need_from_archive[@]}" | grep "^aroi_validation_${ym}" > "$want" || true
            if [[ -s "$zst" && -s "$want" ]]; then
                zstd -dc --long="$ZSTD_LONG" "$zst" | tar -C "$stage" -xf - -T "$want" 2>/dev/null || true
            fi
        done < <(printf '%s\n' "${need_from_archive[@]}" | sed -E 's/^aroi_validation_([0-9]{6}).*/\1/' | LC_ALL=C sort -u)

        for fn in "${need_from_archive[@]}"; do
            [[ -s "$stage/$fn" ]] || need_from_remote+=("$fn")
        done
        if (( ${#need_from_remote[@]} > 0 )) && [[ -n "$source_bucket" ]]; then
            local dl_list="$WORK/dl-${target_name}.txt"
            printf '%s\n' "${need_from_remote[@]}" > "$dl_list"
            "$RCLONE" copy "$source_bucket" "$stage" --files-from "$dl_list" --no-traverse || true
        fi
    fi

    local ready="$WORK/ready-${target_name}.txt"
    list_nonempty_validation_files "$stage" > "$ready"
    if [[ -s "$ready" ]]; then
        echo "  → Backfilling $(wc -l < "$ready" | tr -d '[:space:]') missing live file(s) to $target_name..."
        "$RCLONE" copy "$stage" "$target_bucket" --files-from "$ready" --no-traverse --ignore-existing
    else
        echo "  ✗ No local/source copies found to backfill $target_name"
        return 1
    fi
}

echo "=== AROI Validator Parity Audit ($(date)) ==="

# 1. Local 0-byte check
local_zero=$(
    cd "$PUBLIC_DIR"
    find . -maxdepth 1 -name 'aroi_validation_*.json' -type f -size 0c 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort -u || true
)
if [[ -n "$local_zero" ]]; then
    echo "✗ Local public/ contains 0-byte JSON(s):"
    printf '    %s\n' "$local_zero"
    ERRORS=$((ERRORS + 1))
fi

# 2. Local zstd integrity (optional --verify-zstd)
if $VERIFY_ZSTD; then
    while IFS= read -r -d '' zst; do
        base=$(basename "$zst")
        ym=${base#aroi-}
        ym=${ym%.tar.zst}
        lst="$ARCHIVE_DIR/aroi-${ym}.list"
        if ! zstd -t "$zst" >/dev/null 2>&1; then
            echo "✗ Corrupt zstd archive: $base"
            ERRORS=$((ERRORS + 1))
            continue
        fi
        if [[ ! -s "$lst" ]] || ! cmp -s "$lst" <(zstd -dc --long="$ZSTD_LONG" "$zst" | tar tf - 2>/dev/null | LC_ALL=C sort -u); then
            echo "✗ Manifest mismatch for $base vs aroi-${ym}.list"
            ERRORS=$((ERRORS + 1))
        fi
    done < <(find "$ARCHIVE_DIR" -maxdepth 1 -name 'aroi-*.tar.zst' -type f -print0 2>/dev/null)
fi

collect_local_expected
expected_count=$(wc -l < "$WORK/local-expected.txt" | tr -d '[:space:]')
echo "Local expected hourly JSONs: $expected_count"

# 3. Scan remote buckets
DO_BUCKET="aroi-spaces:${DO_SPACES_BUCKET:-}"
R2_BUCKET_URI="aroi-r2:${R2_BUCKET:-}"

if [[ "$DO_ENABLED" == "true" ]]; then
    scan_remote "do" "$DO_BUCKET" "$WORK/do-live.txt" "$WORK/do-zero.txt" "$WORK/do-backups.txt" || ERRORS=$((ERRORS + 1))
    echo "DO Spaces live JSONs: $(wc -l < "$WORK/do-live.txt" | tr -d '[:space:]')"
    if [[ -s "$WORK/do-zero.txt" ]]; then
        echo "✗ DO Spaces has 0-byte live JSON(s):"
        sed 's/^/    /' "$WORK/do-zero.txt"
        ERRORS=$((ERRORS + 1))
    fi
fi

if [[ "$R2_ENABLED" == "true" ]]; then
    scan_remote "r2" "$R2_BUCKET_URI" "$WORK/r2-live.txt" "$WORK/r2-zero.txt" "$WORK/r2-backups.txt" || ERRORS=$((ERRORS + 1))
    echo "R2 live JSONs:        $(wc -l < "$WORK/r2-live.txt" | tr -d '[:space:]')"
    if [[ -s "$WORK/r2-zero.txt" ]]; then
        echo "✗ R2 has 0-byte live JSON(s):"
        sed 's/^/    /' "$WORK/r2-zero.txt"
        ERRORS=$((ERRORS + 1))
    fi
fi

# 4. Compare live sets and backfill in --fix mode
check_provider_parity() {
    local name=$1 bucket=$2 live_file=$3 backups_file=$4 peer_bucket=${5:-}
    local missing="$WORK/missing-${name}.txt"
    comm -23 "$WORK/local-expected.txt" "$live_file" > "$missing"
    if [[ -s "$missing" ]]; then
        local mc
        mc=$(wc -l < "$missing" | tr -d '[:space:]')
        echo "⚠ $name missing $mc expected live JSON(s)"
        if $FIX_MODE; then
            backfill_remote_live "$name" "$bucket" "$missing" "$peer_bucket" || ERRORS=$((ERRORS + 1))
        else
            ERRORS=$((ERRORS + 1))
        fi
    fi

    # Check if remote has any valid live JSONs missing from local expected
    local extra="$WORK/extra-${name}.txt"
    comm -13 "$WORK/local-expected.txt" "$live_file" > "$extra"
    if [[ -s "$extra" ]]; then
        local ec
        ec=$(wc -l < "$extra" | tr -d '[:space:]')
        echo "⚠ $name has $ec live JSON(s) absent from local archive/public"
        if $FIX_MODE; then
            echo "  → Downloading $ec missing JSON(s) from $name to public/..."
            "$RCLONE" copy "$bucket" "$PUBLIC_DIR" --files-from "$extra" --no-traverse --ignore-existing || ERRORS=$((ERRORS + 1))
        else
            ERRORS=$((ERRORS + 1))
        fi
    fi

    # Verify zstd backup archives & .list manifests in $bucket/_backups/
    local backup_mismatch=false zst base sz remote_sz
    while IFS= read -r -d '' zst; do
        base=$(basename "$zst")
        sz=$(file_size_bytes "$zst")
        remote_sz=$(awk -F';' -v f="$base" '$2 == f {print $1}' "$backups_file")
        if [[ -z "$remote_sz" || "$remote_sz" != "$sz" ]]; then
            echo "⚠ $name _backups/$base size mismatch (local=$sz, remote=${remote_sz:-missing})"
            backup_mismatch=true
        fi
        local list_base="${base%.tar.zst}.list"
        if ! grep -qE "^[1-9][0-9]*;${list_base}$" "$backups_file"; then
            echo "⚠ $name _backups/$list_base missing or empty"
            backup_mismatch=true
        fi
    done < <(find "$ARCHIVE_DIR" -maxdepth 1 -name 'aroi-*.tar.zst' -type f -print0 2>/dev/null)

    if [[ "$backup_mismatch" == "true" ]]; then
        if $FIX_MODE; then
            local name_lower upload_script
            name_lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
            upload_script="$SCRIPT_DIR/upload-${name_lower}.sh"
            if [[ -x "$upload_script" ]]; then
                "$upload_script" --upload-backups || ERRORS=$((ERRORS + 1))
            else
                ERRORS=$((ERRORS + 1))
            fi
        else
            ERRORS=$((ERRORS + 1))
        fi
    fi
}

if [[ "$DO_ENABLED" == "true" && -f "$WORK/do-live.txt" ]]; then
    peer=""
    [[ "$R2_ENABLED" == "true" ]] && peer="$R2_BUCKET_URI"
    check_provider_parity "DO" "$DO_BUCKET" "$WORK/do-live.txt" "$WORK/do-backups.txt" "$peer"
fi
if [[ "$R2_ENABLED" == "true" && -f "$WORK/r2-live.txt" ]]; then
    peer=""
    [[ "$DO_ENABLED" == "true" ]] && peer="$DO_BUCKET"
    check_provider_parity "R2" "$R2_BUCKET_URI" "$WORK/r2-live.txt" "$WORK/r2-backups.txt" "$peer"
fi

# Recompute local expected set after any remote -> local downloads, then verify/rebuild files.json
if $FIX_MODE; then
    collect_local_expected
    expected_count=$(wc -l < "$WORK/local-expected.txt" | tr -d '[:space:]')
fi

if [[ -s "$PUBLIC_DIR/files.json" ]]; then
    jq -r '.[]' "$PUBLIC_DIR/files.json" 2>/dev/null | grep -E "$AROI_JSON_REGEX" | LC_ALL=C sort -u > "$WORK/files-json.txt" || true
else
    : > "$WORK/files-json.txt"
fi
if ! cmp -s "$WORK/local-expected.txt" "$WORK/files-json.txt"; then
    echo "⚠ public/files.json differs from local expected set (files.json=$(wc -l < "$WORK/files-json.txt" | tr -d '[:space:]'), expected=$expected_count)"
    if $FIX_MODE; then
        exec 7>>"$LOG_DIR/public.lock"
        if flock -w "$PUBLIC_LOCK_WAIT" 7; then
            note_lock_holder "$LOG_DIR/public.lock"
            build_files_manifest "$PUBLIC_DIR" "$ARCHIVE_DIR" "$STAGE_DIR"
            exec 7>&-
            echo "  ✓ Rebuilt public/files.json"
        else
            exec 7>&-
            ERRORS=$((ERRORS + 1))
        fi
    else
        ERRORS=$((ERRORS + 1))
    fi
fi

# Refresh ledgers + metadata in --fix mode after all backfills (non-empty live objects only)
if $FIX_MODE; then
    if [[ "$DO_ENABLED" == "true" ]]; then
        if raw_do=$("$RCLONE" lsf "$DO_BUCKET" --max-depth 1 --files-only --format sp 2>/dev/null); then
            printf '%s\n' "$raw_do" | awk -F';' '$1+0 > 0 {print $2}' | { grep -E "$AROI_JSON_REGEX" || true; } \
                | LC_ALL=C sort -u > "$LOG_DIR/uploaded-do.txt"
        else
            ERRORS=$((ERRORS + 1))
        fi
        "$SCRIPT_DIR/upload-do.sh" "$PUBLIC_DIR" || ERRORS=$((ERRORS + 1))
    fi
    if [[ "$R2_ENABLED" == "true" ]]; then
        if raw_r2=$("$RCLONE" lsf "$R2_BUCKET_URI" --max-depth 1 --files-only --format sp 2>/dev/null); then
            printf '%s\n' "$raw_r2" | awk -F';' '$1+0 > 0 {print $2}' | { grep -E "$AROI_JSON_REGEX" || true; } \
                | LC_ALL=C sort -u > "$LOG_DIR/uploaded-r2.txt"
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
