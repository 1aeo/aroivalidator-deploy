#!/bin/bash
# AROI Validator Hourly Batch - Validation + Cloud Upload
# Uploads to DO Spaces (primary) and R2 (backup) in parallel
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
CODE_DIR="$HOME/aroivalidator"
LOG_DIR="$DEPLOY_DIR/logs"
WEB_DIR="$DEPLOY_DIR/public"
LOCK_FILE="$LOG_DIR/validation.lock"

# Security: Validate config before sourcing
if [[ -f "$DEPLOY_DIR/config.env" ]]; then
    CONFIG_PERMS=$(stat -c '%a' "$DEPLOY_DIR/config.env" 2>/dev/null || echo "644")
    if [[ "${CONFIG_PERMS: -1}" != "0" && "${CONFIG_PERMS: -1}" != "4" ]]; then
        echo "Warning: config.env has insecure permissions ($CONFIG_PERMS)"
    fi
    source "$DEPLOY_DIR/config.env"
fi
: "${CLOUD_UPLOAD:=true}" "${DO_ENABLED:=false}" "${R2_ENABLED:=false}"

mkdir -p "$LOG_DIR" "$WEB_DIR"

# Atomic lock file to prevent concurrent runs (race-condition safe)
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Already running (another instance holds the lock)"
    exit 0
fi
# Lock acquired, write PID for debugging
echo $$ >&9
trap 'rm -f "$LOCK_FILE"' EXIT

echo "=== AROI Batch $(date) ==="

cd "$CODE_DIR"
[[ -d ".git" ]] || { echo "Not a git repo"; exit 1; }

# Update code repository
# Security note: Only fetch/reset if CODE_DIR is a valid git repo we control
if [[ -d "$CODE_DIR/.git" ]]; then
    # Verify remote URL is from expected source before pulling
    REMOTE_URL=$(git -C "$CODE_DIR" config --get remote.origin.url 2>/dev/null || echo "")
    if [[ "$REMOTE_URL" == *"github.com/1aeo/AROIValidator"* || "$REMOTE_URL" == *"github.com:1aeo/AROIValidator"* ]]; then
        git -C "$CODE_DIR" fetch origin main 2>/dev/null && git -C "$CODE_DIR" reset --hard origin/main 2>/dev/null || true
    else
        echo "Warning: Skipping auto-update - unexpected remote URL"
    fi
fi
source "$CODE_DIR/venv/bin/activate"

echo "Running validation..."
BATCH_LIMIT=0 PARALLEL=true MAX_WORKERS=10 python3 aroi_cli.py batch || { echo "Validation failed"; exit 1; }

# Publish results
SRC="$CODE_DIR/validation_results"
if [[ -d "$SRC" ]]; then
    echo "Publishing..."
    rsync -a --include='*.json' --exclude='*' "$SRC/" "$WEB_DIR/" 2>/dev/null || \
        find "$SRC" -maxdepth 1 -name "*.json" -newer "$WEB_DIR/files.json" -exec cp {} "$WEB_DIR/" \; 2>/dev/null
    
    LATEST=$(ls -t "$SRC"/aroi_validation_*.json 2>/dev/null | head -1)
    [[ -n "$LATEST" ]] && cp -f "$LATEST" "$WEB_DIR/latest.json" && echo "Latest: $(basename "$LATEST")"
    
    # File manifest
    find "$WEB_DIR" -maxdepth 1 -name "aroi_validation_*.json" -printf '%f\n' 2>/dev/null \
        | sort -r | jq -Rs 'split("\n") | map(select(length > 0))' > "$WEB_DIR/files.json"
fi

# Cloud upload (parallel)
if [[ "$CLOUD_UPLOAD" == "true" ]]; then
    echo "=== Cloud Upload ==="
    PIDS=()
    
    [[ "$DO_ENABLED" == "true" ]] && {
        "$SCRIPT_DIR/upload-do.sh" "$WEB_DIR" >> "$LOG_DIR/upload-do.log" 2>&1 && echo "✓ DO" || echo "✗ DO" &
        PIDS+=($!)
    }
    [[ "$R2_ENABLED" == "true" ]] && {
        "$SCRIPT_DIR/upload-r2.sh" "$WEB_DIR" >> "$LOG_DIR/upload-r2.log" 2>&1 && echo "✓ R2" || echo "✗ R2" &
        PIDS+=($!)
    }
    
    # Wait for uploads
    FAILED=0
    for pid in "${PIDS[@]:-}"; do wait "$pid" || ((FAILED++)); done
    [[ $FAILED -gt 0 ]] && echo "⚠ $FAILED upload(s) failed" || echo "✓ All uploads done"
fi

echo "=== Complete $(date) ==="
