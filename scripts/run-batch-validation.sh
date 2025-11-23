#!/bin/bash
# AROI Validator Hourly Batch Execution Script
# Automatically pulls latest code and runs validation

set -euo pipefail

# Auto-detect paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
DEPLOY_USER=$(whoami)
CODE_DIR="$HOME/aroivalidator"
VENV_DIR="$CODE_DIR/venv"
LOG_DIR="$DEPLOY_DIR/logs"
WEB_DIR="$DEPLOY_DIR/public"

# Create directories if they don't exist
mkdir -p "$LOG_DIR" "$WEB_DIR"

echo "========================================="
echo "AROI Validator Batch Run - $(date)"
echo "========================================="

# Navigate to code directory
cd "$CODE_DIR" || exit 1

# Verify we're in a git repository
if [ ! -d ".git" ]; then
    echo "Error: Not a git repository"
    exit 1
fi

# Update code from git (only from origin/main)
echo "Pulling latest code from git..."
git fetch origin main 2>/dev/null || echo "Warning: Git fetch failed"
git reset --hard origin/main 2>/dev/null || echo "Warning: Git reset failed, using existing code"

# Verify virtual environment exists
if [ ! -f "$VENV_DIR/bin/activate" ]; then
    echo "Error: Virtual environment not found"
    exit 1
fi

# Activate virtual environment
source "$VENV_DIR/bin/activate"

# Run batch validation with default settings (10 parallel workers)
echo "Starting batch validation..."
BATCH_LIMIT=0 PARALLEL=true MAX_WORKERS=10 python3 aroi_cli.py batch || {
    echo "Error: Validation failed"
    exit 1
}

# Results are saved in CODE_DIR/validation_results/ by aroi_validator.py
SOURCE_RESULTS="$CODE_DIR/validation_results"

if [ -d "$SOURCE_RESULTS" ]; then
    echo "Publishing results to web directory..."
    
    # Copy only JSON files to public web directory
    find "$SOURCE_RESULTS" -maxdepth 1 -name "*.json" -type f -exec cp -f {} "$WEB_DIR/" \; 2>/dev/null || true
    
    # Get most recent file for latest.json
    LATEST_RESULT=$(find "$SOURCE_RESULTS" -maxdepth 1 -name "*.json" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    
    if [ -n "$LATEST_RESULT" ] && [ -f "$LATEST_RESULT" ]; then
        cp -f "$LATEST_RESULT" "$WEB_DIR/latest.json"
        echo "Latest result published: latest.json"
    fi
    
    # Create files.json manifest sorted newest first
    echo "Creating file manifest..."
    (cd "$WEB_DIR" && ls -1 aroi_validation_*.json 2>/dev/null | sort -r | jq -R -s 'split("\n") | map(select(length > 0))') > "$WEB_DIR/files.json" 2>/dev/null || echo '[]' > "$WEB_DIR/files.json"
    
    # Set proper permissions (owner rw, group/world read only)
    chmod 644 "$WEB_DIR"/*.json 2>/dev/null || true
fi

echo "Batch validation completed at $(date)"
echo ""

