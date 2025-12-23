#!/bin/bash
# AROI Validator Hourly Batch Execution Script
# Automatically pulls latest code and runs validation

set -euo pipefail

# Auto-detect paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
CODE_DIR="$HOME/aroivalidator"
VENV_DIR="$CODE_DIR/venv"
LOG_DIR="$DEPLOY_DIR/logs"
WEB_DIR="$DEPLOY_DIR/public"
LOCK_FILE="$LOG_DIR/validation.lock"

# Create directories if they don't exist
mkdir -p "$LOG_DIR" "$WEB_DIR"

# Prevent concurrent execution
if [ -f "$LOCK_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "Another validation is already running (PID: $LOCK_PID). Exiting."
        exit 0
    fi
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

echo "========================================="
echo "AROI Validator Batch Run - $(date)"
echo "========================================="

cd "$CODE_DIR" || exit 1

# Verify we're in a git repository
if [ ! -d ".git" ]; then
    echo "Error: Not a git repository"
    exit 1
fi

# Update code from git
echo "Pulling latest code from git..."
git fetch origin main 2>/dev/null || echo "Warning: Git fetch failed"
git reset --hard origin/main 2>/dev/null || echo "Warning: Git reset failed, using existing code"

# Verify virtual environment exists
if [ ! -f "$VENV_DIR/bin/activate" ]; then
    echo "Error: Virtual environment not found"
    exit 1
fi

source "$VENV_DIR/bin/activate"

# Run batch validation
echo "Starting batch validation..."
BATCH_LIMIT=0 PARALLEL=true MAX_WORKERS=10 python3 aroi_cli.py batch || {
    echo "Error: Validation failed"
    exit 1
}

SOURCE_RESULTS="$CODE_DIR/validation_results"

if [ -d "$SOURCE_RESULTS" ]; then
    echo "Publishing results to web directory..."
    
    # rsync -a copies only changed files AND sets permissions (no separate chmod needed)
    rsync -a --include='*.json' --exclude='*' "$SOURCE_RESULTS/" "$WEB_DIR/" 2>/dev/null || {
        find "$SOURCE_RESULTS" -maxdepth 1 -name "*.json" -type f -newer "$WEB_DIR/files.json" -exec cp -f {} "$WEB_DIR/" \; 2>/dev/null || true
    }
    
    # Get newest file using ls -t (optimized for time-sorting, faster than find|sort)
    # Subshell disables pipefail to avoid SIGPIPE from head closing the pipe early
    LATEST_RESULT=$(set +o pipefail; ls -t "$SOURCE_RESULTS"/aroi_validation_*.json 2>/dev/null | head -1)
    
    if [ -n "$LATEST_RESULT" ] && [ -f "$LATEST_RESULT" ]; then
        cp -f "$LATEST_RESULT" "$WEB_DIR/latest.json"
        echo "Latest result published: $(basename "$LATEST_RESULT")"
    fi
    
    # Create files.json manifest (single find operation for the web directory)
    echo "Creating file manifest..."
    find "$WEB_DIR" -maxdepth 1 -name "aroi_validation_*.json" -printf '%f\n' 2>/dev/null \
        | sort -r \
        | jq -R -s 'split("\n") | map(select(length > 0))' \
        > "$WEB_DIR/files.json.tmp" \
        && mv "$WEB_DIR/files.json.tmp" "$WEB_DIR/files.json" \
        || echo '[]' > "$WEB_DIR/files.json"
fi

echo "Batch validation completed at $(date)"
