#!/usr/bin/env bash
# Isolated test suite for aroivalidator-deploy scripts (uses temp dirs & mock rclone).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

assert_eq() {
    local actual=$1 expected=$2 msg=$3
    if [[ "$actual" == "$expected" ]]; then
        pass "$msg"
    else
        fail "$msg (expected='$expected', actual='$actual')"
    fi
}

assert_file_exists() {
    if [[ -e "$1" ]]; then pass "$2"; else fail "$2 (missing: $1)"; fi
}

assert_file_missing() {
    if [[ ! -e "$1" ]]; then pass "$2"; else fail "$2 (unexpectedly exists: $1)"; fi
}

# Set up temporary workspace with copied deploy scripts + mock rclone
WORK=$(mktemp -d)
cleanup() {
    [[ -z "${DEPLOY:-}" ]] || chmod 755 "$DEPLOY/local-archive" 2>/dev/null || true
    if [[ -n "${WORK:-}" ]]; then
        chmod 755 "$WORK/unreadable-archive" "$WORK/unreadable-manifests" "$WORK/unreadable-backups" 2>/dev/null || true
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

MOCK_BIN="$WORK/mock-bin"
MOCK_ROOT="$WORK/mock-cloud"
MOCK_LOG="$WORK/rclone.log"
mkdir -p "$MOCK_BIN" "$MOCK_ROOT/do/test-bucket/_backups" "$MOCK_ROOT/r2/test-bucket/_backups"
: > "$MOCK_LOG"

cat > "$MOCK_BIN/rclone" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "$*" >> "${MOCK_RCLONE_LOG:?}"

map_path() {
    local p=$1
    case "$p" in
        *:*)
            local remote=${p%%:*}
            local rest=${p#*:}
            case "$remote" in
                *spaces*|*do*) echo "${MOCK_RCLONE_ROOT:?}/do/$rest" ;;
                *r2*)          echo "${MOCK_RCLONE_ROOT:?}/r2/$rest" ;;
                *)             echo "$p" ;;
            esac
            ;;
        *)
            echo "$p"
            ;;
    esac
}

cmd=${1:-}
shift || true

if [[ -n "${MOCK_RCLONE_FAIL_PATTERN:-}" && "$cmd $*" == *"$MOCK_RCLONE_FAIL_PATTERN"* ]]; then
    echo "mock rclone error for: $cmd $*" >&2
    exit 1
fi

case "$cmd" in
    listremotes)
        printf 'aroi-spaces:\naroi-r2:\n'
        ;;
    config)
        exit 0
        ;;
    copy)
        src=$(map_path "$1"); dst=$(map_path "$2"); shift 2
        files_from=""
        ignore_existing=false
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --files-from) files_from="$2"; shift 2 ;;
                --files-from=*) files_from="${1#*=}"; shift ;;
                --ignore-existing) ignore_existing=true; shift ;;
                *) shift ;;
            esac
        done
        mkdir -p "$dst"
        if [[ -n "$files_from" ]]; then
            while IFS= read -r rel; do
                [[ -z "$rel" ]] && continue
                [[ -f "$src/$rel" ]] || { echo "missing source: $src/$rel" >&2; exit 1; }
                if $ignore_existing && [[ -e "$dst/$rel" ]]; then
                    continue
                fi
                mkdir -p "$(dirname "$dst/$rel")"
                cp -f "$src/$rel" "$dst/$rel"
            done < "$files_from"
        else
            cp -Rf "$src/." "$dst/"
        fi
        ;;
    lsf)
        target=$(map_path "$1"); shift
        files_only=false
        dirs_only=false
        fmt="p"
        inc=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --files-only) files_only=true; shift ;;
                --dirs-only) dirs_only=true; shift ;;
                --format) fmt="$2"; shift 2 ;;
                --format=*) fmt="${1#*=}"; shift ;;
                --include) inc="$2"; shift 2 ;;
                --include=*) inc="${1#*=}"; shift ;;
                *) shift ;;
            esac
        done
        [[ -d "$target" ]] || exit 0
        for entry in "$target"/*; do
            [[ -e "$entry" ]] || continue
            name=$(basename "$entry")
            if $files_only && [[ ! -f "$entry" ]]; then continue; fi
            if $dirs_only && [[ ! -d "$entry" ]]; then continue; fi
            if [[ -n "$inc" ]]; then
                # shellcheck disable=SC2053
                [[ "$name" == $inc ]] || continue
            fi
            if [[ -d "$entry" ]]; then
                out_name="${name}/"
            else
                out_name="$name"
            fi
            if [[ "$fmt" == "shp" ]]; then
                sz=$(stat -c '%s' "$entry" 2>/dev/null || stat -f '%z' "$entry" 2>/dev/null || wc -c < "$entry" | tr -d '[:space:]')
                if [[ "${MOCK_RCLONE_OMIT_HASH:-false}" == "true" ]]; then
                    h=""
                elif command -v md5sum >/dev/null 2>&1; then
                    h=$(md5sum "$entry" | awk '{print $1}')
                else
                    h=$(md5 -q "$entry")
                fi
                printf '%s;%s;%s\n' "$sz" "$h" "$out_name"
            elif [[ "$fmt" == "sp" ]]; then
                sz=$(stat -c '%s' "$entry" 2>/dev/null || stat -f '%z' "$entry" 2>/dev/null || wc -c < "$entry" | tr -d '[:space:]')
                printf '%s;%s\n' "$sz" "$out_name"
            else
                printf '%s\n' "$out_name"
            fi
        done
        ;;
    purge)
        target=$(map_path "$1")
        rm -rf "$target"
        ;;
    *)
        echo "unsupported mock rclone cmd: $cmd" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$MOCK_BIN/rclone"

export MOCK_RCLONE_ROOT="$MOCK_ROOT"
export MOCK_RCLONE_LOG="$MOCK_LOG"
export PATH="$MOCK_BIN:$PATH"

# Create an isolated deploy tree + fake validator repo
DEPLOY="$WORK/deploy"
CODE="$WORK/aroivalidator"
mkdir -p "$DEPLOY" "$CODE/.git" "$CODE/validation_results"
cp -R "$REPO_ROOT/scripts" "$DEPLOY/scripts"
chmod +x "$DEPLOY"/scripts/*.sh

cat > "$DEPLOY/config.env" <<EOF
STORAGE_ORDER=do,r2
CLOUD_UPLOAD=true
DO_ENABLED=true
DO_SPACES_BUCKET=test-bucket
DO_SPACES_REGION=nyc3
DO_SPACES_KEY=mock
DO_SPACES_SECRET=mock
R2_ENABLED=true
R2_BUCKET=test-bucket
CLOUDFLARE_ACCOUNT_ID=mockacct
R2_ACCESS_KEY_ID=mock
R2_SECRET_ACCESS_KEY=mock
RCLONE_PATH=$MOCK_BIN/rclone
OUTPUT_DIR=$DEPLOY/public
ARCHIVE_DIR=$DEPLOY/local-archive
BACKUP_DIR=$DEPLOY/backups
ZSTD_LEVEL=3
ZSTD_LONG=20
MIN_FREE_GB=1
BATCH_QUIET=true
EOF
chmod 600 "$DEPLOY/config.env"

echo "=== 1. Syntax & Lint ==="
for f in "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/tests/*.sh; do
    if bash -n "$f"; then
        pass "bash -n $(basename "$f")"
    else
        fail "bash -n $(basename "$f")"
    fi
done

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x -P "$REPO_ROOT/scripts" \
        "$REPO_ROOT/scripts/common.sh" \
        "$REPO_ROOT/scripts/compress-old-data.sh" \
        "$REPO_ROOT/scripts/prune-backups.sh" \
        "$REPO_ROOT/scripts/run-batch-validation.sh" \
        "$REPO_ROOT/scripts/upload-common.sh" \
        "$REPO_ROOT/scripts/upload-do.sh" \
        "$REPO_ROOT/scripts/upload-r2.sh" \
        "$REPO_ROOT/scripts/verify-sync.sh" \
        "$REPO_ROOT/tests/test_scripts.sh"; then
        pass "shellcheck clean across touched scripts and tests"
    else
        fail "shellcheck reported warnings/errors"
    fi
fi

echo "=== 2. Manifest builder (build_files_manifest) ==="
mkdir -p "$DEPLOY/public" "$DEPLOY/local-archive" "$DEPLOY/tmp" "$DEPLOY/logs"
echo "aroi_validation_20251101_000001.json" > "$DEPLOY/local-archive/aroi-202511.list"
echo '{"ok":1}' > "$DEPLOY/public/aroi_validation_20261101_010000.json"
: > "$DEPLOY/public/aroi_validation_20261101_020000.json"  # 0-byte must be excluded
(
    source "$DEPLOY/scripts/common.sh"
    build_files_manifest "$DEPLOY/public" "$DEPLOY/local-archive" "$DEPLOY/tmp"
)
manifest_count=$(jq 'length' "$DEPLOY/public/files.json")
assert_eq "$manifest_count" "2" "build_files_manifest merges archive lists + non-empty public JSONs and ignores 0-byte"
assert_eq "$(jq -r '.[0]' "$DEPLOY/public/files.json")" "aroi_validation_20261101_010000.json" "manifest sorted newest first"
assert_eq "$(jq -r '.[1]' "$DEPLOY/public/files.json")" "aroi_validation_20251101_000001.json" "manifest retains historical archive entries"
rm -f "$DEPLOY/local-archive/aroi-202511.list"
(
    source "$DEPLOY/scripts/common.sh"
    build_files_manifest "$DEPLOY/public" "$DEPLOY/local-archive" "$DEPLOY/tmp"
)

echo "=== 3. Append-only upload & ledger recovery ==="
echo '{"ok":2}' > "$DEPLOY/public/latest.json"
"$DEPLOY/scripts/upload-do.sh" "$DEPLOY/public" >/dev/null
"$DEPLOY/scripts/upload-r2.sh" "$DEPLOY/public" >/dev/null
assert_file_exists "$MOCK_ROOT/do/test-bucket/aroi_validation_20261101_010000.json" "DO received live JSON"
assert_file_exists "$MOCK_ROOT/r2/test-bucket/aroi_validation_20261101_010000.json" "R2 received live JSON"
assert_file_exists "$MOCK_ROOT/do/test-bucket/files.json" "DO received files.json"
assert_file_missing "$MOCK_ROOT/do/test-bucket/aroi_validation_20261101_020000.json" "0-byte file never uploaded"

if grep -q " sync " "$MOCK_LOG"; then
    fail "rclone sync was invoked (must be append-only copy)"
else
    pass "upload scripts never invoked rclone sync"
fi
if grep -q -- "--no-traverse" "$MOCK_LOG" && grep -q -- "--files-from" "$MOCK_LOG"; then
    pass "upload scripts used --no-traverse and --files-from"
else
    fail "upload scripts missing --no-traverse or --files-from"
fi

# Simulated failed copy must NOT advance ledger, and next run must catch up
echo '{"ok":3}' > "$DEPLOY/public/aroi_validation_20261101_030000.json"
if MOCK_RCLONE_FAIL_PATTERN="aroi-r2:test-bucket" "$DEPLOY/scripts/upload-r2.sh" "$DEPLOY/public" >/dev/null 2>&1; then
    fail "upload-r2.sh should fail when rclone fails"
else
    pass "upload-r2.sh propagated failure"
fi
if grep -q "aroi_validation_20261101_030000.json" "$DEPLOY/logs/uploaded-r2.txt"; then
    fail "failed upload incorrectly advanced uploaded-r2.txt"
else
    pass "failed upload did not advance uploaded-r2.txt"
fi
"$DEPLOY/scripts/upload-r2.sh" "$DEPLOY/public" >/dev/null
assert_file_exists "$MOCK_ROOT/r2/test-bucket/aroi_validation_20261101_030000.json" "next upload caught up missed file"

echo "=== 4. Archival & 3-copy safety gate (compress-old-data.sh) ==="
CUR_YM=$(date '+%Y%m')
OLD_YM="202609"
echo '{"old":1}' > "$DEPLOY/public/aroi_validation_${OLD_YM}01_000000.json"
echo '{"cur":1}' > "$DEPLOY/public/aroi_validation_${CUR_YM}01_000000.json"
# Upload OLD_YM to DO only (NOT R2) first -> compress-old-data.sh auto-backfills R2 from public/ then removes OLD_YM!
"$DEPLOY/scripts/upload-do.sh" "$DEPLOY/public" >/dev/null

# If R2 live listing fails during verification, safety gate MUST keep local completed-month files
if MOCK_RCLONE_FAIL_PATTERN="lsf aroi-r2:test-bucket --max-depth 1 --files-only --format sp" "$DEPLOY/scripts/compress-old-data.sh" --daily >/dev/null 2>&1; then
    fail "compress-old-data.sh should report failure when R2 verification fails"
else
    pass "compress-old-data.sh blocked completed-month deletion when R2 verification failed"
fi
assert_file_exists "$DEPLOY/local-archive/aroi-${OLD_YM}.tar.zst" "zstd archive created for $OLD_YM"
assert_file_exists "$DEPLOY/local-archive/aroi-${CUR_YM}.tar.zst" "zstd archive created for current month $CUR_YM"
assert_file_exists "$DEPLOY/public/aroi_validation_${OLD_YM}01_000000.json" "completed month retained locally when R2 verification failed"
assert_file_exists "$MOCK_ROOT/do/test-bucket/_backups/aroi-${OLD_YM}.tar.zst" "DO _backups received zstd archive"
assert_file_exists "$MOCK_ROOT/r2/test-bucket/_backups/aroi-${OLD_YM}.tar.zst" "R2 _backups received zstd archive"
assert_file_exists "$DEPLOY/public/aroi_validation_${CUR_YM}01_000000.json" "current month files remain in public/"

# Now run normally without mocked failure -> auto-backfills OLD_YM to R2, verifies 3 copies, removes OLD_YM from public/
"$DEPLOY/scripts/compress-old-data.sh" --daily >/dev/null
assert_file_exists "$MOCK_ROOT/r2/test-bucket/aroi_validation_${OLD_YM}01_000000.json" "compress-old-data.sh auto-backfilled missing completed-month live file to R2"
assert_file_missing "$DEPLOY/public/aroi_validation_${OLD_YM}01_000000.json" "completed month removed from public/ after 3-copy verification"
assert_file_exists "$DEPLOY/public/aroi_validation_${CUR_YM}01_000000.json" "current month still retained in public/ after --daily"

echo "=== 5. Explicit safety gate test when remote archive is corrupted/missing ==="
OLD2="202608"
echo '{"old2":1}' > "$DEPLOY/public/aroi_validation_${OLD2}01_000000.json"
"$DEPLOY/scripts/upload-do.sh" "$DEPLOY/public" >/dev/null
"$DEPLOY/scripts/upload-r2.sh" "$DEPLOY/public" >/dev/null
if MOCK_RCLONE_FAIL_PATTERN="aroi-r2:test-bucket/_backups" "$DEPLOY/scripts/compress-old-data.sh" --month "$OLD2" >/dev/null 2>&1; then
    fail "compress-old-data.sh should fail when R2 backup upload fails"
else
    pass "compress-old-data.sh failed cleanly when remote backup upload failed"
fi
assert_file_exists "$DEPLOY/public/aroi_validation_${OLD2}01_000000.json" "safety gate preserved local JSON when R2 backup upload failed"

# Now run normally -> uploads both + verifies 3 copies + removes OLD2 from public/ while preserving in files.json
"$DEPLOY/scripts/compress-old-data.sh" --month "$OLD2" >/dev/null
assert_file_missing "$DEPLOY/public/aroi_validation_${OLD2}01_000000.json" "verified completed month removed from public/"
if grep -q "aroi_validation_${OLD2}01_000000.json" "$DEPLOY/public/files.json"; then
    pass "completed month remains listed in files.json after local cleanup"
else
    fail "completed month disappeared from files.json"
fi

# Verify zstd archive can actually decompress and round-trip exact content
extracted=$(zstd -dc --long=20 "$DEPLOY/local-archive/aroi-${OLD2}.tar.zst" | tar -xOf - "aroi_validation_${OLD2}01_000000.json")
assert_eq "$extracted" '{"old2":1}' "zstd archive round-trips exact JSON bytes"

echo "=== 6. Legacy backup pruner (prune-backups.sh) ==="
mkdir -p "$DEPLOY/backups/backup-2026-11-18_000035" "$DEPLOY/backups/backup-2026-11-19_000036" "$DEPLOY/backups/cron"
touch "$DEPLOY/backups/cron/crontab.bak"
mkdir -p "$MOCK_ROOT/do/test-bucket/_backups/2026-11-18_000035" "$MOCK_ROOT/r2/test-bucket/_backups/2026-11-18_000035"

# Failure in rclone purge must exit non-zero and not silently succeed
if MOCK_RCLONE_FAIL_PATTERN="purge aroi-spaces:test-bucket/_backups/2026-11-18_000035/" "$DEPLOY/scripts/prune-backups.sh" --provider "do" >/dev/null 2>&1; then
    fail "prune-backups.sh should fail when rclone purge fails"
else
    pass "prune-backups.sh reported rclone purge failure"
fi

"$DEPLOY/scripts/prune-backups.sh" --provider all --tpslimit 60 >/dev/null
assert_file_missing "$DEPLOY/backups/backup-2026-11-18_000035" "legacy local backup pruned"
assert_file_exists "$DEPLOY/backups/cron/crontab.bak" "backups/cron/ preserved"
assert_file_missing "$MOCK_ROOT/do/test-bucket/_backups/2026-11-18_000035" "legacy DO _backups timestamp dir pruned"
assert_file_missing "$MOCK_ROOT/r2/test-bucket/_backups/2026-11-18_000035" "legacy R2 _backups timestamp dir pruned"
assert_file_exists "$MOCK_ROOT/do/test-bucket/_backups/aroi-${OLD2}.tar.zst" "DO zstd archive untouched by prune-backups.sh"
assert_file_exists "$MOCK_ROOT/r2/test-bucket/_backups/aroi-${OLD2}.tar.zst" "R2 zstd archive untouched by prune-backups.sh"

echo "=== 7. Parity verifier (verify-sync.sh) ==="
# 0-byte test file from section 2 should be caught by verify-sync.sh, then clean it before --fix parity check
if "$DEPLOY/scripts/verify-sync.sh" --verify-zstd >/dev/null 2>&1; then
    fail "verify-sync.sh should flag 0-byte file in public/"
else
    pass "verify-sync.sh flagged 0-byte file in public/"
fi
rm -f "$DEPLOY/public/aroi_validation_20261101_020000.json"

# Ensure archive/public state is consistent before checking parity
"$DEPLOY/scripts/compress-old-data.sh" --daily >/dev/null
# Delete one live file from R2 and verify verify-sync.sh detects then --fix restores from zstd archive!
rm -f "$MOCK_ROOT/r2/test-bucket/aroi_validation_${OLD2}01_000000.json"
if "$DEPLOY/scripts/verify-sync.sh" --verify-zstd >/dev/null 2>&1; then
    fail "verify-sync.sh should detect missing live file in R2"
else
    pass "verify-sync.sh detected missing live file in R2"
fi
"$DEPLOY/scripts/verify-sync.sh" --fix --verify-zstd >/dev/null
assert_file_exists "$MOCK_ROOT/r2/test-bucket/aroi_validation_${OLD2}01_000000.json" "verify-sync.sh --fix restored missing live file from zstd archive"
if "$DEPLOY/scripts/verify-sync.sh" --verify-zstd >/dev/null; then
    pass "verify-sync.sh passed with 0 issues after --fix"
else
    fail "verify-sync.sh still failed after --fix"
fi

echo "=== 8. Batch publish & cleanup of validation_results/ ==="
cat > "$CODE/aroi_cli.py" <<'EOF'
#!/usr/bin/env python3
import os, pathlib
assert os.environ.get("BATCH_QUIET") == "true", os.environ.get("BATCH_QUIET")
out_dir = pathlib.Path("validation_results")
out_dir.mkdir(exist_ok=True)
ym_file = out_dir / "aroi_validation_20261121_090500.json"
ym_file.write_text('{"batch":true}')
(out_dir / "latest.json").write_text('{"batch":true}')
EOF
chmod +x "$CODE/aroi_cli.py"

: > "$CODE/validation_results/aroi_validation_20261121_080500.json"  # 0-byte must NOT be published

CODE_DIR="$CODE" "$DEPLOY/scripts/run-batch-validation.sh" >/dev/null
assert_file_exists "$DEPLOY/public/aroi_validation_20261121_090500.json" "batch published new JSON to public/"
assert_file_missing "$CODE/validation_results/aroi_validation_20261121_090500.json" "published JSON removed from validation_results/"
assert_file_exists "$CODE/validation_results/latest.json" "validation_results/latest.json preserved"
assert_file_missing "$DEPLOY/public/aroi_validation_20261121_080500.json" "0-byte source file not published"
assert_file_exists "$MOCK_ROOT/do/test-bucket/aroi_validation_20261121_090500.json" "batch uploaded new JSON to DO"
assert_file_exists "$MOCK_ROOT/r2/test-bucket/aroi_validation_20261121_090500.json" "batch uploaded new JSON to R2"

echo "=== 9. Scoped upload ledger & private upload_zstd_backups temp dir ==="
mkdir -p "$MOCK_ROOT/do/test-bucket-2/_backups"
sed 's/^DO_SPACES_BUCKET=.*/DO_SPACES_BUCKET=test-bucket-2/' "$DEPLOY/config.env" > "$DEPLOY/config.env.new"
mv -f "$DEPLOY/config.env.new" "$DEPLOY/config.env" && chmod 600 "$DEPLOY/config.env"
"$DEPLOY/scripts/upload-do.sh" "$DEPLOY/public" >/dev/null
assert_file_exists "$MOCK_ROOT/do/test-bucket-2/aroi_validation_20261121_090500.json" "bucket change invalidated old ledger and uploaded to new bucket"
assert_eq "$(head -n 1 "$DEPLOY/logs/uploaded-do.txt")" "# bucket=aroi-spaces:test-bucket-2" "ledger header bound to new destination bucket"
sed 's/^DO_SPACES_BUCKET=.*/DO_SPACES_BUCKET=test-bucket/' "$DEPLOY/config.env" > "$DEPLOY/config.env.new"
mv -f "$DEPLOY/config.env.new" "$DEPLOY/config.env" && chmod 600 "$DEPLOY/config.env"
"$DEPLOY/scripts/upload-do.sh" "$DEPLOY/public" >/dev/null
"$DEPLOY/scripts/upload-do.sh" --upload-backups >/dev/null
top_tmp_count=$(find "$DEPLOY/tmp" -maxdepth 1 \( -type f -o -name 'backup-files.*' \) 2>/dev/null | wc -l | tr -d '[:space:]')
assert_eq "$top_tmp_count" "0" "upload_zstd_backups left no top-level files or backup-files.* dirs in tmp/"

echo "=== 10. Marker discipline (--no-upload, --month, failed --daily attempt limit) ==="
rm -f "$DEPLOY/logs/last-archive-date" "$DEPLOY/logs/last-archive-attempt-date"
"$DEPLOY/scripts/compress-old-data.sh" --no-upload >/dev/null
assert_file_missing "$DEPLOY/logs/last-archive-date" "--no-upload did not advance last-archive-date"
"$DEPLOY/scripts/compress-old-data.sh" --month "$CUR_YM" >/dev/null
assert_file_missing "$DEPLOY/logs/last-archive-date" "--month did not advance last-archive-date"
"$DEPLOY/scripts/compress-old-data.sh" >/dev/null
assert_file_exists "$DEPLOY/logs/last-archive-date" "full run wrote last-archive-date"

# Simulate failed --daily in run-batch-validation.sh: sets attempt marker and avoids hourly retry
rm -f "$DEPLOY/logs/last-archive-date" "$DEPLOY/logs/last-archive-attempt-date" "$DEPLOY/logs/compression.log"
: > "$DEPLOY/logs/compression.log"
MOCK_RCLONE_FAIL_PATTERN="_backups" CODE_DIR="$CODE" "$DEPLOY/scripts/run-batch-validation.sh" >/dev/null || true
assert_file_exists "$DEPLOY/logs/last-archive-attempt-date" "failed --daily recorded attempt date marker"
assert_file_missing "$DEPLOY/logs/last-archive-date" "failed --daily did not set completion marker"
: > "$DEPLOY/logs/compression.log"
CODE_DIR="$CODE" "$DEPLOY/scripts/run-batch-validation.sh" >/dev/null
assert_eq "$(wc -c < "$DEPLOY/logs/compression.log" | tr -d '[:space:]')" "0" "hourly run skipped retrying failed --daily archive same day"
rm -f "$DEPLOY/logs/last-archive-attempt-date"
"$DEPLOY/scripts/compress-old-data.sh" >/dev/null

echo "=== 11. Lowering ZSTD_LONG still reads archives built with --long=27 ==="
OLD3="202607"
echo '{"m7a":1}' > "$DEPLOY/public/aroi_validation_${OLD3}01_000000.json"
"$DEPLOY/scripts/upload-do.sh" "$DEPLOY/public" >/dev/null
"$DEPLOY/scripts/upload-r2.sh" "$DEPLOY/public" >/dev/null
sed 's/^ZSTD_LONG=.*/ZSTD_LONG=27/' "$DEPLOY/config.env" > "$DEPLOY/config.env.new"
mv -f "$DEPLOY/config.env.new" "$DEPLOY/config.env" && chmod 600 "$DEPLOY/config.env"
"$DEPLOY/scripts/compress-old-data.sh" --month "$OLD3" >/dev/null
assert_file_missing "$DEPLOY/public/aroi_validation_${OLD3}01_000000.json" "$OLD3 initial file archived & pruned at --long=27"

# Lower ZSTD_LONG=10, add second file for 202607, re-run compress-old-data.sh --month 202607
echo '{"m7b":2}' > "$DEPLOY/public/aroi_validation_${OLD3}02_000000.json"
"$DEPLOY/scripts/upload-do.sh" "$DEPLOY/public" >/dev/null
"$DEPLOY/scripts/upload-r2.sh" "$DEPLOY/public" >/dev/null
sed 's/^ZSTD_LONG=.*/ZSTD_LONG=10/' "$DEPLOY/config.env" > "$DEPLOY/config.env.new"
mv -f "$DEPLOY/config.env.new" "$DEPLOY/config.env" && chmod 600 "$DEPLOY/config.env"
"$DEPLOY/scripts/compress-old-data.sh" --month "$OLD3" >/dev/null
assert_eq "$(wc -l < "$DEPLOY/local-archive/aroi-${OLD3}.list" | tr -d '[:space:]')" "2" "lowering ZSTD_LONG preserved pruned member alongside late addition"
"$DEPLOY/scripts/verify-sync.sh" --verify-zstd >/dev/null
pass "verify-sync --verify-zstd passed with lowered ZSTD_LONG=10"
sed 's/^ZSTD_LONG=.*/ZSTD_LONG=20/' "$DEPLOY/config.env" > "$DEPLOY/config.env.new"
mv -f "$DEPLOY/config.env.new" "$DEPLOY/config.env" && chmod 600 "$DEPLOY/config.env"

echo "=== 12. Corrupt local archive recovery & partial-rebuild protection ==="
OLD4="202606"
echo '{"m6a":1}' > "$DEPLOY/public/aroi_validation_${OLD4}01_000000.json"
echo '{"m6b":2}' > "$DEPLOY/public/aroi_validation_${OLD4}02_000000.json"
"$DEPLOY/scripts/upload-do.sh" "$DEPLOY/public" >/dev/null
"$DEPLOY/scripts/upload-r2.sh" "$DEPLOY/public" >/dev/null
"$DEPLOY/scripts/compress-old-data.sh" --month "$OLD4" >/dev/null

# Save healthy remote backup, then remove both remote backups and corrupt local archive
cp "$MOCK_ROOT/r2/test-bucket/_backups/aroi-${OLD4}.tar.zst" "$WORK/healthy-${OLD4}.tar.zst"
rm -f "$MOCK_ROOT/do/test-bucket/_backups/aroi-${OLD4}.tar.zst" "$MOCK_ROOT/r2/test-bucket/_backups/aroi-${OLD4}.tar.zst"
printf 'corrupt-zst' > "$DEPLOY/local-archive/aroi-${OLD4}.tar.zst"
echo '{"m6c":3}' > "$DEPLOY/public/aroi_validation_${OLD4}03_000000.json"
"$DEPLOY/scripts/upload-do.sh" "$DEPLOY/public" >/dev/null
"$DEPLOY/scripts/upload-r2.sh" "$DEPLOY/public" >/dev/null

if "$DEPLOY/scripts/compress-old-data.sh" --month "$OLD4" >/dev/null 2>&1; then
    fail "compress-old-data.sh must fail when local archive corrupt and remote backups unavailable"
else
    pass "compress-old-data.sh refused partial rebuild when previously archived members missing"
fi
assert_file_missing "$MOCK_ROOT/do/test-bucket/_backups/aroi-${OLD4}.tar.zst" "did not overwrite DO backup with partial rebuild"

# Restore healthy remote backup on R2 -> recovery should restore m6a+m6b and include m6c
cp "$WORK/healthy-${OLD4}.tar.zst" "$MOCK_ROOT/r2/test-bucket/_backups/aroi-${OLD4}.tar.zst"
"$DEPLOY/scripts/compress-old-data.sh" --month "$OLD4" >/dev/null
assert_eq "$(wc -l < "$DEPLOY/local-archive/aroi-${OLD4}.list" | tr -d '[:space:]')" "3" "recovered pruned members from R2 backup and merged late public file"
assert_file_missing "$DEPLOY/public/aroi_validation_${OLD4}03_000000.json" "$OLD4 repaired and pruned cleanly"

echo "=== 13. Strict reuse check rebuilds archive missing manifest member ==="
# Put m6c back in public/ temporarily while building an incomplete .tar.zst containing only 2 of 3 files
echo '{"m6c":3}' > "$DEPLOY/public/aroi_validation_${OLD4}03_000000.json"
mkdir -p "$WORK/partial-tar"
printf 'aroi_validation_%s01_000000.json\naroi_validation_%s02_000000.json\n' "$OLD4" "$OLD4" > "$WORK/partial-list.txt"
zstd -dc --long=20 "$DEPLOY/local-archive/aroi-${OLD4}.tar.zst" | tar -C "$WORK/partial-tar" -xf - -T "$WORK/partial-list.txt"
tar cf - -C "$WORK/partial-tar" -T "$WORK/partial-list.txt" | zstd -3 --long=20 -q -f -o "$DEPLOY/local-archive/aroi-${OLD4}.tar.zst"
"$DEPLOY/scripts/compress-old-data.sh" --month "$OLD4" >/dev/null
rebuilt_members=$(zstd -dc --long=20 "$DEPLOY/local-archive/aroi-${OLD4}.tar.zst" | tar tf - | wc -l | tr -d '[:space:]')
assert_eq "$rebuilt_members" "3" "archive missing manifest member was rebuilt rather than reused"
assert_file_missing "$DEPLOY/public/aroi_validation_${OLD4}03_000000.json" "public file cleaned only after full archive rebuild"

echo "=== 14. Same-size / different-content remote backup verification & cmp fallback ==="
orig_list="$MOCK_ROOT/r2/test-bucket/_backups/aroi-${OLD4}.list"
# Flip one digit in the timestamp of first line -> identical byte count, different content
sed '1s/_000000\.json$/_000001.json/' "$orig_list" > "$WORK/tampered.list"
assert_eq "$(wc -c < "$orig_list" | tr -d '[:space:]')" "$(wc -c < "$WORK/tampered.list" | tr -d '[:space:]')" "tampered .list has identical byte count"
cp "$WORK/tampered.list" "$orig_list"
if "$DEPLOY/scripts/verify-sync.sh" >/dev/null 2>&1; then
    fail "verify-sync.sh must detect same-size content mismatch via MD5"
else
    pass "verify-sync.sh caught same-size content mismatch via MD5"
fi
if MOCK_RCLONE_OMIT_HASH=true "$DEPLOY/scripts/verify-sync.sh" >/dev/null 2>&1; then
    fail "verify-sync.sh must detect same-size mismatch even when MD5 hash omitted"
else
    pass "verify-sync.sh caught same-size mismatch via download+cmp fallback"
fi
MOCK_RCLONE_OMIT_HASH=true "$DEPLOY/scripts/verify-sync.sh" --fix >/dev/null
"$DEPLOY/scripts/verify-sync.sh" --verify-zstd >/dev/null
pass "verify-sync.sh --fix repaired same-size corrupted remote backup"

echo "=== 15. Zero-byte remote & local repair without clobbering healthy files ==="
# Compress + clean gate replaces confirmed 0-byte remote object from public/
OLD5="202605"
echo '{"m5":1}' > "$DEPLOY/public/aroi_validation_${OLD5}01_000000.json"
: > "$MOCK_ROOT/do/test-bucket/aroi_validation_${OLD5}01_000000.json"  # pre-existing 0-byte in DO
"$DEPLOY/scripts/upload-r2.sh" "$DEPLOY/public" >/dev/null
"$DEPLOY/scripts/compress-old-data.sh" --month "$OLD5" >/dev/null
do_m5_size=$(wc -c < "$MOCK_ROOT/do/test-bucket/aroi_validation_${OLD5}01_000000.json" | tr -d '[:space:]')
assert_eq "$do_m5_size" "9" "compress-old-data.sh replaced 0-byte DO object before pruning public/"

# Now truncate R2 live copy to 0 bytes (with file already pruned locally) -> verify-sync --fix repairs from archive
: > "$MOCK_ROOT/r2/test-bucket/aroi_validation_${OLD5}01_000000.json"
if "$DEPLOY/scripts/verify-sync.sh" >/dev/null 2>&1; then
    fail "verify-sync.sh must detect 0-byte object in R2"
else
    pass "verify-sync.sh detected 0-byte object in R2"
fi
"$DEPLOY/scripts/verify-sync.sh" --fix >/dev/null
r2_m5_size=$(wc -c < "$MOCK_ROOT/r2/test-bucket/aroi_validation_${OLD5}01_000000.json" | tr -d '[:space:]')
assert_eq "$r2_m5_size" "9" "verify-sync.sh --fix replaced 0-byte R2 object from zstd archive"

# Truncate a local current-month file to 0 bytes -> verify-sync --fix recovers non-empty copy while leaving healthy file untouched
healthy_before=$(cat "$DEPLOY/public/aroi_validation_20261121_090500.json")
: > "$DEPLOY/public/aroi_validation_${CUR_YM}01_000000.json"
"$DEPLOY/scripts/verify-sync.sh" --fix >/dev/null
local_cur_sz=$(wc -c < "$DEPLOY/public/aroi_validation_${CUR_YM}01_000000.json" | tr -d '[:space:]')
assert_eq "$local_cur_sz" "10" "verify-sync.sh --fix repaired 0-byte local file from remote"
assert_eq "$(cat "$DEPLOY/public/aroi_validation_20261121_090500.json")" "$healthy_before" "healthy local file left untouched"

echo "=== 16. Object-shaped files.json rejected & rebuilt by verify-sync.sh --fix ==="
printf '{"unexpected":"aroi_validation_20261121_090500.json"}\n' > "$DEPLOY/public/files.json"
if "$DEPLOY/scripts/verify-sync.sh" >/dev/null 2>&1; then
    fail "verify-sync.sh must reject non-array object-shaped files.json"
else
    pass "verify-sync.sh rejected object-shaped files.json"
fi
"$DEPLOY/scripts/verify-sync.sh" --fix >/dev/null
if jq -e 'type == "array"' "$DEPLOY/public/files.json" >/dev/null 2>&1; then
    pass "verify-sync.sh --fix rebuilt files.json as valid JSON array"
else
    fail "files.json still invalid after verify-sync.sh --fix"
fi

echo "=== 17. verify-sync.sh handles single-provider _backups/ scan failure cleanly ==="
partial_out=""
partial_rc=0
partial_out=$(MOCK_RCLONE_FAIL_PATTERN="lsf aroi-spaces:test-bucket/_backups/" "$DEPLOY/scripts/verify-sync.sh" 2>&1) || partial_rc=$?
if [[ $partial_rc -ne 0 ]] && grep -q "R2 live JSONs:" <<< "$partial_out"; then
    pass "verify-sync.sh retained DO error, continued auditing R2 cleanly, and exited non-zero"
else
    fail "verify-sync.sh aborted prematurely on DO _backups/ scan failure"
fi

echo "=== 18. verify-sync.sh --fix reports unrecoverable missing files after partial backfill ==="
cp "$DEPLOY/local-archive/aroi-${OLD5}.list" "$WORK/saved-old5.list"
printf 'aroi_validation_%s28_235959.json\n' "$OLD5" >> "$DEPLOY/local-archive/aroi-${OLD5}.list"
rm -f "$MOCK_ROOT/r2/test-bucket/aroi_validation_${OLD5}01_000000.json"
if "$DEPLOY/scripts/verify-sync.sh" --fix >/dev/null 2>&1; then
    fail "verify-sync.sh --fix must fail when unrecoverable file remains missing"
else
    pass "verify-sync.sh --fix reported unrecoverable file after backfilling recoverable sibling"
fi
assert_file_exists "$MOCK_ROOT/r2/test-bucket/aroi_validation_${OLD5}01_000000.json" "recoverable sibling was still backfilled during partial repair"
mv -f "$WORK/saved-old5.list" "$DEPLOY/local-archive/aroi-${OLD5}.list"
"$DEPLOY/scripts/verify-sync.sh" --fix --verify-zstd >/dev/null

echo "=== 19. Custom AROI_DO_REMOTE honored across verify-sync.sh and prune-backups.sh ==="
: > "$MOCK_LOG"
AROI_DO_REMOTE="custom-spaces" "$DEPLOY/scripts/verify-sync.sh" >/dev/null
if grep -q "custom-spaces:test-bucket" "$MOCK_LOG"; then
    pass "verify-sync.sh honored custom AROI_DO_REMOTE"
else
    fail "verify-sync.sh ignored custom AROI_DO_REMOTE"
fi
: > "$MOCK_LOG"
AROI_DO_REMOTE="custom-spaces" "$DEPLOY/scripts/prune-backups.sh" --dry-run --provider "do" >/dev/null
if grep -q "custom-spaces:test-bucket/_backups/" "$MOCK_LOG"; then
    pass "prune-backups.sh honored custom AROI_DO_REMOTE"
else
    fail "prune-backups.sh ignored custom AROI_DO_REMOTE"
fi

echo "=== 20. prune-backups.sh overflow bounds, dry-run without archive, unreadable dir ==="
if "$DEPLOY/scripts/prune-backups.sh" --keep 18446744073709551616 >/dev/null 2>&1; then
    fail "prune-backups.sh must reject 64-bit overflowing --keep"
else
    pass "prune-backups.sh rejected overflowing --keep before arithmetic"
fi
if KEEP_LEGACY_BACKUPS=18446744073709551616 "$DEPLOY/scripts/prune-backups.sh" >/dev/null 2>&1; then
    fail "prune-backups.sh must reject overflowing KEEP_LEGACY_BACKUPS env var"
else
    pass "prune-backups.sh rejected overflowing KEEP_LEGACY_BACKUPS env var"
fi

# Dry-run on DO bucket that has ONLY legacy dir and NO .tar.zst archive
mkdir -p "$MOCK_ROOT/do/dry-bucket/_backups/2026-01-01_000000"
sed 's/^DO_SPACES_BUCKET=.*/DO_SPACES_BUCKET=dry-bucket/' "$DEPLOY/config.env" > "$DEPLOY/config.env.new"
mv -f "$DEPLOY/config.env.new" "$DEPLOY/config.env" && chmod 600 "$DEPLOY/config.env"
dry_out=$("$DEPLOY/scripts/prune-backups.sh" --dry-run --provider "do" 2>&1)
sed 's/^DO_SPACES_BUCKET=.*/DO_SPACES_BUCKET=test-bucket/' "$DEPLOY/config.env" > "$DEPLOY/config.env.new"
mv -f "$DEPLOY/config.env.new" "$DEPLOY/config.env" && chmod 600 "$DEPLOY/config.env"
if grep -q "Would purge: DO/_backups/2026-01-01_000000/" <<< "$dry_out"; then
    pass "prune-backups.sh --dry-run previewed deletions without remote .tar.zst"
else
    fail "prune-backups.sh --dry-run failed without remote .tar.zst"
fi

if [[ $(id -u) -ne 0 ]]; then
    mkdir -p "$WORK/unreadable-backups/backup-2026-01-01_000000"
    chmod 111 "$WORK/unreadable-backups"
    sed "s|^BACKUP_DIR=.*|BACKUP_DIR=$WORK/unreadable-backups|" "$DEPLOY/config.env" > "$DEPLOY/config.env.new"
    mv -f "$DEPLOY/config.env.new" "$DEPLOY/config.env" && chmod 600 "$DEPLOY/config.env"
    if "$DEPLOY/scripts/prune-backups.sh" --provider local >/dev/null 2>&1; then
        chmod 755 "$WORK/unreadable-backups"
        fail "prune-backups.sh must fail when BACKUP_DIR cannot be listed"
    else
        chmod 755 "$WORK/unreadable-backups"
        pass "prune-backups.sh reported error when BACKUP_DIR could not be scanned"
    fi
    sed "s|^BACKUP_DIR=.*|BACKUP_DIR=$DEPLOY/backups|" "$DEPLOY/config.env" > "$DEPLOY/config.env.new"
    mv -f "$DEPLOY/config.env.new" "$DEPLOY/config.env" && chmod 600 "$DEPLOY/config.env"
fi

echo "=== 21. cron.log zstd rotation under cron-log.lock ==="
awk 'BEGIN { for (i = 0; i < 900000; i++) print "0000000000000000000000000000000000000000000000000000000000000000" }' > "$DEPLOY/logs/cron.log"
printf 'retained-tail-marker\n' >> "$DEPLOY/logs/cron.log"
"$DEPLOY/scripts/compress-old-data.sh" >/dev/null
rotated_zst=$(find "$DEPLOY/logs/archives" -maxdepth 1 -name 'cron-*.log.zst' -type f | head -n 1 || true)
assert_file_exists "$rotated_zst" "cron.log rotated to logs/archives/cron-*.log.zst"
if zstd -t "$rotated_zst" >/dev/null 2>&1; then
    pass "rotated cron log zstd archive passes zstd -t"
else
    fail "rotated cron log zstd archive failed zstd -t"
fi
if grep -q "retained-tail-marker" "$DEPLOY/logs/cron.log"; then
    pass "truncated cron.log preserved trailing lines"
else
    fail "truncated cron.log lost trailing lines"
fi
cron_after_sz=$(wc -c < "$DEPLOY/logs/cron.log" | tr -d '[:space:]')
if (( cron_after_sz < 1048576 )); then
    pass "cron.log truncated cleanly after rotation (${cron_after_sz} bytes)"
else
    fail "cron.log was not truncated after rotation (${cron_after_sz} bytes)"
fi

echo "=== 22. Rejected prune-backups bounds preserve actual input in error message ==="
keep_err=""
keep_rc=0
keep_err=$("$DEPLOY/scripts/prune-backups.sh" --keep 18446744073709551616 2>&1) || keep_rc=$?
if [[ $keep_rc -eq 2 ]] && grep -q "18446744073709551616" <<< "$keep_err"; then
    pass "prune-backups.sh error included rejected --keep value"
else
    fail "prune-backups.sh error omitted rejected --keep value: $keep_err"
fi
env_keep_err=""
env_keep_rc=0
env_keep_err=$(KEEP_LEGACY_BACKUPS=18446744073709551616 "$DEPLOY/scripts/prune-backups.sh" 2>&1) || env_keep_rc=$?
if [[ $env_keep_rc -eq 2 ]] && grep -q "18446744073709551616" <<< "$env_keep_err"; then
    pass "prune-backups.sh error included rejected KEEP_LEGACY_BACKUPS env value"
else
    fail "prune-backups.sh error omitted rejected KEEP_LEGACY_BACKUPS value: $env_keep_err"
fi

echo "=== 23. Missing local archive+list checks remote history before first-time build ==="
OLD6="202604"
echo '{"m4a":1}' > "$DEPLOY/public/aroi_validation_${OLD6}01_000000.json"
"$DEPLOY/scripts/upload-do.sh" "$DEPLOY/public" >/dev/null
"$DEPLOY/scripts/upload-r2.sh" "$DEPLOY/public" >/dev/null
"$DEPLOY/scripts/compress-old-data.sh" --month "$OLD6" >/dev/null

# Wipe local archive+list while remote _backups/ still holds m4a, then add late m4b
rm -f "$DEPLOY/local-archive/aroi-${OLD6}.tar.zst" "$DEPLOY/local-archive/aroi-${OLD6}.list"
echo '{"m4b":2}' > "$DEPLOY/public/aroi_validation_${OLD6}02_000000.json"
"$DEPLOY/scripts/upload-do.sh" "$DEPLOY/public" >/dev/null
"$DEPLOY/scripts/upload-r2.sh" "$DEPLOY/public" >/dev/null

# If remote _backups/ cannot be listed when local files are missing, compress-old-data must abort before overwriting
if MOCK_RCLONE_FAIL_PATTERN="lsf aroi-r2:test-bucket/_backups/" "$DEPLOY/scripts/compress-old-data.sh" --month "$OLD6" >/dev/null 2>&1; then
    fail "compress-old-data.sh must fail when local history absent and R2 _backups/ unreachable"
else
    pass "compress-old-data.sh refused build when local history absent and remote unreachable"
fi
assert_file_missing "$DEPLOY/local-archive/aroi-${OLD6}.tar.zst" "did not build partial local archive on unreachable remote check"

# When remote _backups/ is reachable, recovers m4a + merges m4b without losing m4a
"$DEPLOY/scripts/compress-old-data.sh" --month "$OLD6" >/dev/null
assert_eq "$(wc -l < "$DEPLOY/local-archive/aroi-${OLD6}.list" | tr -d '[:space:]')" "2" "recovered pruned m4a from remote backup when both local artifacts were absent"
assert_file_missing "$DEPLOY/public/aroi_validation_${OLD6}02_000000.json" "$OLD6 repaired and pruned cleanly"

echo "=== 24. Content conflict on overlapping filename retains public file ==="
# Put modified payload under already-archived m4a filename in public/
echo '{"m4a":"mutated-v2"}' > "$DEPLOY/public/aroi_validation_${OLD6}01_000000.json"
if "$DEPLOY/scripts/compress-old-data.sh" --month "$OLD6" >/dev/null 2>&1; then
    fail "compress-old-data.sh must reject conflicting payload under archived filename"
else
    pass "compress-old-data.sh rejected conflicting payload on archive reuse/merge"
fi
assert_eq "$(cat "$DEPLOY/public/aroi_validation_${OLD6}01_000000.json")" '{"m4a":"mutated-v2"}' "conflicting public file preserved unpruned"
rm -f "$DEPLOY/public/aroi_validation_${OLD6}01_000000.json"
"$DEPLOY/scripts/verify-sync.sh" --fix --verify-zstd >/dev/null

echo "=== 25. Concurrent replacement between snapshot and cleanup retains newer public generation ==="
OLD7="202603"
echo '{"gen":1}' > "$DEPLOY/public/aroi_validation_${OLD7}01_000000.json"
"$DEPLOY/scripts/upload-do.sh" "$DEPLOY/public" >/dev/null
"$DEPLOY/scripts/upload-r2.sh" "$DEPLOY/public" >/dev/null
HOOK_BIN="$WORK/hook-bin"
mkdir -p "$HOOK_BIN"
cat > "$HOOK_BIN/rclone" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"_backups"* && ! -f "$WORK/hook-ran" ]]; then
    touch "$WORK/hook-ran"
    printf '{"gen":2}\n' > "$DEPLOY/public/.aroi-tmp.hook"
    mv -f "$DEPLOY/public/.aroi-tmp.hook" "$DEPLOY/public/aroi_validation_${OLD7}01_000000.json"
fi
exec "$MOCK_BIN/rclone" "\$@"
EOF
chmod +x "$HOOK_BIN/rclone"
sed "s|^RCLONE_PATH=.*|RCLONE_PATH=$HOOK_BIN/rclone|" "$DEPLOY/config.env" > "$DEPLOY/config.env.new"
mv -f "$DEPLOY/config.env.new" "$DEPLOY/config.env" && chmod 600 "$DEPLOY/config.env"
if "$DEPLOY/scripts/compress-old-data.sh" --month "$OLD7" >/dev/null 2>&1; then
    sed "s|^RCLONE_PATH=.*|RCLONE_PATH=$MOCK_BIN/rclone|" "$DEPLOY/config.env" > "$DEPLOY/config.env.new"
    mv -f "$DEPLOY/config.env.new" "$DEPLOY/config.env" && chmod 600 "$DEPLOY/config.env"
    fail "compress-old-data.sh must retain file replaced after snapshot and fail cleanup"
else
    sed "s|^RCLONE_PATH=.*|RCLONE_PATH=$MOCK_BIN/rclone|" "$DEPLOY/config.env" > "$DEPLOY/config.env.new"
    mv -f "$DEPLOY/config.env.new" "$DEPLOY/config.env" && chmod 600 "$DEPLOY/config.env"
    pass "compress-old-data.sh detected generation change after snapshot"
fi
assert_eq "$(cat "$DEPLOY/public/aroi_validation_${OLD7}01_000000.json")" '{"gen":2}' "newer file generation preserved in public/"
# Align archives/buckets by cleaning test gen2 conflict cleanly back to valid state
rm -f "$DEPLOY/public/aroi_validation_${OLD7}01_000000.json"
"$DEPLOY/scripts/verify-sync.sh" --fix --verify-zstd >/dev/null

echo "=== 26. Zero-byte local file already listed in .list repaired from remote when tarball corrupt/absent ==="
: > "$DEPLOY/public/aroi_validation_${OLD7}01_000000.json"
mv "$DEPLOY/local-archive/aroi-${OLD7}.tar.zst" "$WORK/saved-old7.tar.zst"
"$DEPLOY/scripts/verify-sync.sh" --fix >/dev/null || true  # archive missing error expected, but local 0-byte must be repaired!
local_old7_sz=$(wc -c < "$DEPLOY/public/aroi_validation_${OLD7}01_000000.json" | tr -d '[:space:]')
assert_eq "$local_old7_sz" "10" "verify-sync.sh --fix repaired 0-byte local file listed in .list via remote bucket"
mv "$WORK/saved-old7.tar.zst" "$DEPLOY/local-archive/aroi-${OLD7}.tar.zst"
rm -f "$DEPLOY/public/aroi_validation_${OLD7}01_000000.json"

echo "=== 27. Manifest-only month flagged & corrupt local tarball never overwrites remote backup ==="
printf 'aroi_validation_20250201_000000.json\n' > "$DEPLOY/local-archive/aroi-202502.list"
if "$DEPLOY/scripts/verify-sync.sh" --verify-zstd >/dev/null 2>&1; then
    fail "verify-sync.sh --verify-zstd must flag manifest-only month without .tar.zst"
else
    pass "verify-sync.sh --verify-zstd detected manifest-only month without .tar.zst"
fi
rm -f "$DEPLOY/local-archive/aroi-202502.list"

# Corrupt local tarball for OLD7 while mocking healthy remote tarballs -> --fix must NOT overwrite either remote backup!
cp "$DEPLOY/local-archive/aroi-${OLD7}.tar.zst" "$WORK/good-old7.tar.zst"
cp "$MOCK_ROOT/do/test-bucket/_backups/aroi-${OLD7}.tar.zst" "$WORK/healthy-do.tar.zst"
cp "$MOCK_ROOT/r2/test-bucket/_backups/aroi-${OLD7}.tar.zst" "$WORK/healthy-r2.tar.zst"
printf 'bad-zst' > "$DEPLOY/local-archive/aroi-${OLD7}.tar.zst"
if "$DEPLOY/scripts/verify-sync.sh" --fix >/dev/null 2>&1; then
    fail "verify-sync.sh --fix must fail on corrupt local tarball"
else
    pass "verify-sync.sh --fix failed on corrupt local tarball without --verify-zstd"
fi
if cmp -s "$MOCK_ROOT/do/test-bucket/_backups/aroi-${OLD7}.tar.zst" "$WORK/healthy-do.tar.zst"; then
    pass "corrupt local tarball did not overwrite healthy DO remote backup"
else
    fail "corrupt local tarball overwrote healthy DO remote backup"
fi
if cmp -s "$MOCK_ROOT/r2/test-bucket/_backups/aroi-${OLD7}.tar.zst" "$WORK/healthy-r2.tar.zst"; then
    pass "corrupt local tarball did not overwrite healthy R2 remote backup"
else
    fail "corrupt local tarball overwrote healthy R2 remote backup"
fi
mv "$WORK/good-old7.tar.zst" "$DEPLOY/local-archive/aroi-${OLD7}.tar.zst"

# Repair valid same-size/content-mismatched backup uses --ignore-times via --repair-backups
sed '1s/_000000\.json$/_000001.json/' "$MOCK_ROOT/r2/test-bucket/_backups/aroi-${OLD7}.list" > "$WORK/tamper-old7.list"
cp "$WORK/tamper-old7.list" "$MOCK_ROOT/r2/test-bucket/_backups/aroi-${OLD7}.list"
: > "$MOCK_LOG"
"$DEPLOY/scripts/verify-sync.sh" --fix --verify-zstd >/dev/null
if grep -q -- "--ignore-times" "$MOCK_LOG"; then
    pass "verify-sync.sh --fix invoked --ignore-times repair path for mismatched backup"
else
    fail "verify-sync.sh --fix did not pass --ignore-times for mismatched backup"
fi

echo "=== 28. Multi-document files.json rejected & rebuilt cleanly by verify-sync.sh --fix ==="
printf '["aroi_validation_20261101_010000.json"] ["aroi_validation_20261121_090500.json"]\n' > "$DEPLOY/public/files.json"
if "$DEPLOY/scripts/verify-sync.sh" >/dev/null 2>&1; then
    fail "verify-sync.sh must reject multi-document files.json"
else
    pass "verify-sync.sh rejected multi-document files.json"
fi
"$DEPLOY/scripts/verify-sync.sh" --fix --verify-zstd >/dev/null
if jq -se 'length == 1 and (.[0] | type == "array")' "$DEPLOY/public/files.json" >/dev/null 2>&1; then
    pass "verify-sync.sh --fix rebuilt multi-document files.json as single array"
else
    fail "files.json still malformed after verify-sync.sh --fix"
fi

echo "=== 29. Unreadable ARCHIVE_DIR fails build_files_manifest & verify-sync without truncating ==="
if [[ "$(id -u)" -ne 0 ]]; then
    cp "$DEPLOY/public/files.json" "$WORK/prev-files.json"
    chmod 111 "$DEPLOY/local-archive"
    if (
        # shellcheck source=common.sh
        source "$DEPLOY/scripts/common.sh"
        build_files_manifest "$DEPLOY/public" "$DEPLOY/local-archive"
    ) >/dev/null 2>&1; then
        chmod 755 "$DEPLOY/local-archive"
        fail "build_files_manifest must fail when ARCHIVE_DIR is unreadable"
    else
        pass "build_files_manifest failed cleanly on unreadable ARCHIVE_DIR"
    fi
    if cmp -s "$DEPLOY/public/files.json" "$WORK/prev-files.json"; then
        pass "previous files.json preserved intact when ARCHIVE_DIR unreadable"
    else
        chmod 755 "$DEPLOY/local-archive"
        fail "files.json modified despite ARCHIVE_DIR scan error"
    fi
    if "$DEPLOY/scripts/verify-sync.sh" --verify-zstd >/dev/null 2>&1; then
        chmod 755 "$DEPLOY/local-archive"
        fail "verify-sync.sh --verify-zstd must fail when ARCHIVE_DIR is unreadable"
    else
        pass "verify-sync.sh --verify-zstd failed cleanly on unreadable ARCHIVE_DIR"
    fi
    chmod 755 "$DEPLOY/local-archive"
else
    pass "skipping chmod 111 unreadable ARCHIVE_DIR check under uid 0"
fi

echo "=== 30. Surviving remote .list without .tar.zst & public/ vs remote .tar.zst conflict ==="
mkdir -p "$WORK/sec30-bk/local" "$WORK/sec30-bk/do" "$WORK/sec30-bk/r2"
cp "$DEPLOY/local-archive/aroi-${OLD6}.tar.zst" "$DEPLOY/local-archive/aroi-${OLD6}.list" "$WORK/sec30-bk/local/"
cp "$MOCK_ROOT/do/test-bucket/_backups/aroi-${OLD6}.tar.zst" "$MOCK_ROOT/do/test-bucket/_backups/aroi-${OLD6}.list" "$WORK/sec30-bk/do/"
cp "$MOCK_ROOT/r2/test-bucket/_backups/aroi-${OLD6}.tar.zst" "$MOCK_ROOT/r2/test-bucket/_backups/aroi-${OLD6}.list" "$WORK/sec30-bk/r2/"

# 30a: Surviving DO .list without any .tar.zst when both local archive files are absent
rm -f "$DEPLOY/local-archive/aroi-${OLD6}.tar.zst" "$DEPLOY/local-archive/aroi-${OLD6}.list" \
    "$MOCK_ROOT/do/test-bucket/_backups/aroi-${OLD6}.tar.zst" \
    "$MOCK_ROOT/r2/test-bucket/_backups/aroi-${OLD6}.tar.zst" \
    "$MOCK_ROOT/r2/test-bucket/_backups/aroi-${OLD6}.list"
echo '{"m4b":2}' > "$DEPLOY/public/aroi_validation_${OLD6}02_000000.json"
if "$DEPLOY/scripts/compress-old-data.sh" --month "$OLD6" >/dev/null 2>&1; then
    fail "compress-old-data.sh must fail when surviving remote .list names unrecoverable member"
else
    pass "compress-old-data.sh refused partial overwrite when surviving remote .list present without .tar.zst"
fi
assert_file_missing "$DEPLOY/local-archive/aroi-${OLD6}.tar.zst" "did not build partial local tarball against surviving remote .list"

# 30b: Remote .tar.zst exists while local archive absent and public/ has conflicting m4a payload
cp "$WORK/sec30-bk/do/"* "$MOCK_ROOT/do/test-bucket/_backups/"
cp "$WORK/sec30-bk/r2/"* "$MOCK_ROOT/r2/test-bucket/_backups/"
rm -f "$DEPLOY/public/aroi_validation_${OLD6}02_000000.json"
echo '{"m4a":"conflict-v2"}' > "$DEPLOY/public/aroi_validation_${OLD6}01_000000.json"
if "$DEPLOY/scripts/compress-old-data.sh" --month "$OLD6" >/dev/null 2>&1; then
    fail "compress-old-data.sh must fail on content conflict between public/ and remote .tar.zst"
else
    pass "compress-old-data.sh detected content conflict against remote .tar.zst"
fi
assert_eq "$(cat "$DEPLOY/public/aroi_validation_${OLD6}01_000000.json")" '{"m4a":"conflict-v2"}' "conflicting public file retained when remote .tar.zst differs"

rm -f "$DEPLOY/public/aroi_validation_${OLD6}01_000000.json"
cp "$WORK/sec30-bk/local/"* "$DEPLOY/local-archive/"
"$DEPLOY/scripts/verify-sync.sh" --fix --verify-zstd >/dev/null
"$DEPLOY/scripts/verify-sync.sh" --verify-zstd >/dev/null

echo "=== 31. Direct --repair-backups refuses corrupt local tarball ==="
cp "$DEPLOY/local-archive/aroi-${OLD7}.tar.zst" "$WORK/sec31-local-old7.tar.zst"
cp "$MOCK_ROOT/do/test-bucket/_backups/aroi-${OLD7}.tar.zst" "$WORK/sec31-do-old7.tar.zst"
printf 'bad-zst' > "$DEPLOY/local-archive/aroi-${OLD7}.tar.zst"
: > "$MOCK_LOG"
if "$DEPLOY/scripts/upload-do.sh" --repair-backups "$OLD7" >/dev/null 2>&1; then
    fail "upload-do.sh --repair-backups must refuse corrupt local tarball"
else
    pass "upload-do.sh --repair-backups refused corrupt local tarball"
fi
if grep -q -- "--ignore-times" "$MOCK_LOG"; then
    fail "upload-do.sh --repair-backups invoked --ignore-times on corrupt tarball"
else
    pass "upload-do.sh --repair-backups did not invoke --ignore-times on corrupt tarball"
fi
if cmp -s "$MOCK_ROOT/do/test-bucket/_backups/aroi-${OLD7}.tar.zst" "$WORK/sec31-do-old7.tar.zst"; then
    pass "DO healthy backup untouched after refused direct --repair-backups"
else
    fail "DO healthy backup modified despite refused --repair-backups"
fi
mv "$WORK/sec31-local-old7.tar.zst" "$DEPLOY/local-archive/aroi-${OLD7}.tar.zst"

echo "=== 32. Stale repair generation refused & recovery mv failure propagated ==="
mkdir -p "$WORK/sec32-stale"
cp "$DEPLOY/local-archive/aroi-${OLD7}.tar.zst" "$DEPLOY/local-archive/aroi-${OLD7}.list" "$WORK/sec32-stale/"
echo '{"newgen":1}' > "$DEPLOY/public/aroi_validation_${OLD7}02_000000.json"
"$DEPLOY/scripts/upload-do.sh" "$DEPLOY/public" >/dev/null
"$DEPLOY/scripts/upload-r2.sh" "$DEPLOY/public" >/dev/null
"$DEPLOY/scripts/compress-old-data.sh" --month "$OLD7" >/dev/null
cp "$MOCK_ROOT/do/test-bucket/_backups/aroi-${OLD7}.tar.zst" "$WORK/sec32-new-do.tar.zst"

# 32a: Repair upload using older captured pair must refuse before --ignore-times
: > "$MOCK_LOG"
if "$DEPLOY/scripts/upload-do.sh" --repair-backups "$OLD7" "$WORK/sec32-stale" >/dev/null 2>&1; then
    fail "upload-do.sh --repair-backups must refuse stale captured generation"
else
    pass "upload-do.sh --repair-backups refused stale captured generation"
fi
if grep -q -- "--ignore-times" "$MOCK_LOG"; then
    fail "upload-do.sh --repair-backups invoked --ignore-times for stale generation"
else
    pass "upload-do.sh --repair-backups did not invoke --ignore-times for stale generation"
fi
if cmp -s "$MOCK_ROOT/do/test-bucket/_backups/aroi-${OLD7}.tar.zst" "$WORK/sec32-new-do.tar.zst"; then
    pass "DO newer archive untouched after refused stale repair"
else
    fail "DO newer archive overwritten by stale repair"
fi

# 32b: Failed mv while recovering remote .tar.zst (even without remote .list) must fail cleanly
rm -f "$DEPLOY/local-archive/aroi-${OLD7}.tar.zst" "$DEPLOY/local-archive/aroi-${OLD7}.list" \
    "$MOCK_ROOT/do/test-bucket/_backups/aroi-${OLD7}.list" \
    "$MOCK_ROOT/r2/test-bucket/_backups/aroi-${OLD7}.tar.zst" \
    "$MOCK_ROOT/r2/test-bucket/_backups/aroi-${OLD7}.list"
echo '{"late03":3}' > "$DEPLOY/public/aroi_validation_${OLD7}03_000000.json"
mkdir -p "$WORK/mv-fail-bin"
REAL_MV=$(command -v mv)
cat > "$WORK/mv-fail-bin/mv" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"/ext/"* && "\$*" == *"/snap/"* ]]; then
    echo "simulated mv failure" >&2
    exit 1
fi
exec "$REAL_MV" "\$@"
EOF
chmod +x "$WORK/mv-fail-bin/mv"
if PATH="$WORK/mv-fail-bin:$PATH" "$DEPLOY/scripts/compress-old-data.sh" --month "$OLD7" >/dev/null 2>&1; then
    fail "compress-old-data.sh must fail when recovery mv into snapshot fails"
else
    pass "compress-old-data.sh propagated recovery mv failure cleanly"
fi
assert_file_missing "$DEPLOY/local-archive/aroi-${OLD7}.tar.zst" "did not build partial local tarball after recovery mv failure"
if cmp -s "$MOCK_ROOT/do/test-bucket/_backups/aroi-${OLD7}.tar.zst" "$WORK/sec32-new-do.tar.zst"; then
    pass "DO archive untouched after recovery mv failure"
else
    fail "DO archive overwritten after recovery mv failure"
fi

rm -f "$DEPLOY/public/aroi_validation_${OLD7}03_000000.json"
"$DEPLOY/scripts/compress-old-data.sh" --month "$OLD7" >/dev/null
"$DEPLOY/scripts/verify-sync.sh" --fix --verify-zstd >/dev/null
"$DEPLOY/scripts/verify-sync.sh" --verify-zstd >/dev/null

echo ""
echo "Summary: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
