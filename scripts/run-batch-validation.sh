#!/bin/bash
# AROI Validator Hourly Batch - Validation + Cloud Upload
# Uploads to DO Spaces (primary) and R2 (backup) in parallel
#
# Locks (in logs/, see README "Locks & Logs"):
#   validation.lock  code update + validation + publish only; released before uploads
#                    so a slow upload never costs the next hour its results
#   public.lock      writes to public/ (shared with compress-old-data.sh)
#   upload-do.lock / upload-r2.lock  taken by upload-do.sh / upload-r2.sh
set -euo pipefail

# Source shared functions and initialize paths
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
init_paths
load_config || true

CODE_DIR="$HOME/aroivalidator"
LOG_DIR="$DEPLOY_DIR/logs"
WEB_DIR="$DEPLOY_DIR/public"
STAGE_DIR="$DEPLOY_DIR/tmp"  # same filesystem as public/: files are renamed into place
LOCK_FILE="$LOG_DIR/validation.lock"
PUBLIC_LOCK="$LOG_DIR/public.lock"
GIT_TIMEOUT=300
# Tags lines printed after the validation lock is released (they can interleave with the next run)
RUN_TAG="batch $(date '+%H:%M:%S')"

: "${CLOUD_UPLOAD:=true}" "${DO_ENABLED:=false}" "${R2_ENABLED:=false}"

mkdir -p "$LOG_DIR" "$WEB_DIR" "$STAGE_DIR"

# Atomic lock file to prevent concurrent runs (race-condition safe)
exec 9>>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Already running (another instance holds the lock: $(lock_holder "$LOCK_FILE")) - skipped $(date '+%Y-%m-%d %H:%M:%S')"
    exit 0
fi
note_lock_holder "$LOCK_FILE"

echo "=== AROI Batch $(date) ==="

# Hide credentials embedded in a remote URL
redact() { sed -E 's#://[^/@[:space:]]+@#://***@#g' <<< "$1"; }

# First 3 non-empty lines of a command's output, joined with " | "
first_lines() {
    local line out="" n=0
    while IFS= read -r line && [[ $n -lt 3 ]]; do
        [[ -n "$line" ]] || continue
        out+="${out:+ | }$line"
        n=$((n + 1))
    done <<< "$1"
    echo "$out"
}

# One loud line per failed update step; the run continues on the existing checkout
update_warning() {
    local step=$1 rc=$2 detail
    detail=$(redact "$(first_lines "$3")")
    [[ $rc -eq 124 ]] && detail="timed out after ${GIT_TIMEOUT}s"
    echo "WARNING: code update failed at '$step' (exit $rc): ${detail:-no output} - running existing checkout"
}

# Validate CODE_DIR is a git repo and update if from trusted source
[[ -d "$CODE_DIR/.git" ]] || { echo "Not a git repo: $CODE_DIR"; exit 1; }

# Security: Only fetch/reset if remote URL is from expected source (case-insensitive)
REMOTE_URL=$(git -C "$CODE_DIR" config --get remote.origin.url 2>/dev/null || echo "")
REMOTE_URL_LOWER="${REMOTE_URL,,}"  # Convert to lowercase for comparison
if [[ "$REMOTE_URL_LOWER" == *"github.com/1aeo/aroivalidator"* || "$REMOTE_URL_LOWER" == *"github.com:1aeo/aroivalidator"* ]]; then
    rc=0
    out=$(GIT_TERMINAL_PROMPT=0 timeout "$GIT_TIMEOUT" git -C "$CODE_DIR" fetch origin main 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then
        update_warning "git fetch origin main" "$rc" "$out"
    else
        out=$(git -C "$CODE_DIR" reset --hard origin/main 2>&1) || rc=$?
        if [[ $rc -ne 0 ]]; then
            update_warning "git reset --hard origin/main" "$rc" "$out"
        else
            echo "$out"  # HEAD is now at <sha> <subject>
        fi
    fi
else
    echo "Warning: Skipping auto-update - unexpected remote URL: $(redact "$REMOTE_URL")"
fi

# Always record the code that will run; the validator stores it in the results metadata
CODE_HEAD=$(git -C "$CODE_DIR" log -1 --format='%h %s' 2>/dev/null) || CODE_HEAD="unknown"
CODE_ORIGIN=$(git -C "$CODE_DIR" rev-parse --short origin/main 2>/dev/null) || CODE_ORIGIN="?"
git -C "$CODE_DIR" diff --quiet HEAD -- 2>/dev/null || CODE_HEAD+=" +local changes"
echo "Code: $CODE_HEAD (origin/main $CODE_ORIGIN)"
if AROIVALIDATOR_COMMIT=$(git -C "$CODE_DIR" rev-parse --verify -q HEAD 2>/dev/null); then
    export AROIVALIDATOR_COMMIT
else
    unset AROIVALIDATOR_COMMIT
fi

cd "$CODE_DIR"
source venv/bin/activate

# CIISS ContactInfo spec versions to validate. Default 2,3 = every version this
# build of aroivalidator understands (v2 RSA-fingerprint + v3 ed25519 family-ID).
# Override via CIISS_VERSIONS in config.env (e.g. "3" to validate only v3 relays).
: "${CIISS_VERSIONS:=2,3}"

echo "Running validation (ciissversions: ${CIISS_VERSIONS})..."
BATCH_LIMIT=0 PARALLEL=true MAX_WORKERS=20 python3 aroi_cli.py batch \
    --ciiss-versions "$CIISS_VERSIONS" \
    || { echo "Validation failed"; exit 1; }

# Copy into public/ via STAGE_DIR + rename, so an upload still reading public/
# (e.g. a long DO sync from an earlier hour) never sees a partial file
publish_file() { cp "$1" "$STAGE_DIR/$2" && mv -f "$STAGE_DIR/$2" "$WEB_DIR/$2"; }

# Publish results
SRC="$CODE_DIR/validation_results"
if [[ -d "$SRC" ]]; then
    echo "Publishing..."
    # Waits for compress-old-data.sh, which also rewrites public/
    exec 7>>"$PUBLIC_LOCK"
    if flock -w "$PUBLIC_LOCK_WAIT" 7; then
        note_lock_holder "$PUBLIC_LOCK"
        rc=0
        out=$(rsync -a --temp-dir="$STAGE_DIR" --include='*.json' --exclude='*' "$SRC/" "$WEB_DIR/" 2>&1) || rc=$?
        if [[ $rc -ne 0 ]]; then
            out=$(first_lines "$out")
            echo "WARNING: publish rsync failed (exit $rc): ${out:-no output} - copying results newer than files.json instead"
            while IFS= read -r -d '' f; do
                publish_file "$f" "${f##*/}" || true
            done < <(find "$SRC" -maxdepth 1 -name "*.json" -newer "$WEB_DIR/files.json" -print0 2>/dev/null)
        fi

        # Subshell disables pipefail to avoid SIGPIPE from head closing the pipe early
        LATEST=$(set +o pipefail; ls -t "$SRC"/aroi_validation_*.json 2>/dev/null | head -1)
        [[ -n "$LATEST" ]] && publish_file "$LATEST" latest.json && echo "Latest: $(basename "$LATEST")"

        # File manifest (atomic write to prevent corruption)
        find "$WEB_DIR" -maxdepth 1 -name "aroi_validation_*.json" -printf '%f\n' 2>/dev/null \
            | sort -r | jq -Rs 'split("\n") | map(select(length > 0))' > "$STAGE_DIR/files.json" \
            && mv -f "$STAGE_DIR/files.json" "$WEB_DIR/files.json"
    else
        echo "WARNING: not publishing - public.lock still held after ${PUBLIC_LOCK_WAIT}s ($(lock_holder "$PUBLIC_LOCK")); the next run publishes this file"
    fi
    exec 7>&-
fi

# Release the validation lock: uploads below take their own per-provider locks
echo "Validation + publish done in ${SECONDS}s, validation lock released"
exec 9>&-

# Run one provider's upload; prints a single result line
run_upload() {
    local name=$1 id=$2 rc=0 t0=$SECONDS
    "$SCRIPT_DIR/upload-$id.sh" "$WEB_DIR" >> "$LOG_DIR/upload-$id.log" 2>&1 || rc=$?
    case $rc in
        0) echo "✓ $name ($((SECONDS - t0))s) [$RUN_TAG]" ;;
        "$UPLOAD_SKIPPED") echo "↷ skipping $name upload: previous still running ($(lock_holder "$LOG_DIR/upload-$id.lock")) [$RUN_TAG]" ;;
        *) echo "✗ $name (exit $rc after $((SECONDS - t0))s, see logs/upload-$id.log) [$RUN_TAG]" ;;
    esac
    return "$rc"
}

# Cloud upload (parallel)
if [[ "$CLOUD_UPLOAD" == "true" ]]; then
    echo "=== Cloud Upload [$RUN_TAG] ==="
    PIDS=()
    if [[ "$DO_ENABLED" == "true" ]]; then run_upload DO "do" & PIDS+=($!); fi
    if [[ "$R2_ENABLED" == "true" ]]; then run_upload R2 "r2" & PIDS+=($!); fi

    # Wait for uploads
    FAILED=0 SKIPPED=0
    for pid in "${PIDS[@]}"; do
        rc=0
        wait "$pid" || rc=$?
        if [[ $rc -eq $UPLOAD_SKIPPED ]]; then SKIPPED=$((SKIPPED + 1))
        elif [[ $rc -ne 0 ]]; then FAILED=$((FAILED + 1)); fi
    done
    if [[ $FAILED -gt 0 ]]; then echo "⚠ $FAILED upload(s) failed [$RUN_TAG]"
    elif [[ $SKIPPED -gt 0 ]]; then echo "✓ Uploads done, $SKIPPED skipped (previous still running) [$RUN_TAG]"
    else echo "✓ All uploads done [$RUN_TAG]"; fi
fi

# Prune old backups (non-fatal)
if [[ -x "$SCRIPT_DIR/prune-backups.sh" ]]; then
    "$SCRIPT_DIR/prune-backups.sh" >> "$LOG_DIR/prune.log" 2>&1 || true
fi

echo "=== Complete $(date) [$RUN_TAG] ==="
