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

[[ -f "$DEPLOY_DIR/config.env" ]] && source "$DEPLOY_DIR/config.env"
: "${CLOUD_UPLOAD:=true}" "${DO_ENABLED:=false}" "${R2_ENABLED:=false}"

mkdir -p "$LOG_DIR" "$WEB_DIR"

# Lock to prevent concurrent runs
if [[ -f "$LOCK_FILE" ]]; then
    PID=$(cat "$LOCK_FILE" 2>/dev/null)
    [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null && { echo "Already running (PID $PID)"; exit 0; }
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

echo "=== AROI Batch $(date) ==="

cd "$CODE_DIR"
[[ -d ".git" ]] || { echo "Not a git repo"; exit 1; }

# Update and run
git fetch origin main 2>/dev/null && git reset --hard origin/main 2>/dev/null || true
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
