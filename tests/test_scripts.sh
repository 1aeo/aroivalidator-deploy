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
cleanup() { rm -rf "$WORK"; }
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
        aroi-spaces:*)
            local rest=${p#aroi-spaces:}
            echo "${MOCK_RCLONE_ROOT:?}/do/$rest"
            ;;
        aroi-r2:*)
            local rest=${p#aroi-r2:}
            echo "${MOCK_RCLONE_ROOT:?}/r2/$rest"
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
            if [[ "$fmt" == "sp" ]]; then
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

# If R2 listing fails during verification, safety gate MUST keep local completed-month files
if MOCK_RCLONE_FAIL_PATTERN="lsf aroi-r2:test-bucket" "$DEPLOY/scripts/compress-old-data.sh" --daily >/dev/null 2>&1; then
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

echo ""
echo "Summary: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
