#!/bin/bash
# AROI Validator - Monthly Data Compression
# Compresses validation files 180+ days old and large logs

set -euo pipefail

# Security: Use safe umask for created files
umask 077

# Source shared functions and initialize paths
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
init_paths

PUBLIC_DIR="$DEPLOY_DIR/public"
LOG_DIR="$DEPLOY_DIR/logs"
STAGE_DIR="$DEPLOY_DIR/tmp"  # same filesystem as public/: files are renamed into place

echo "========================================="
echo "Data Compression - $(date)"
echo "========================================="

# Check available disk space (need at least 5GB free for safety)
AVAILABLE=$(df -BG "$DEPLOY_DIR" | tail -1 | awk '{print $4}' | tr -d 'G')
if [ "$AVAILABLE" -lt 5 ]; then
    echo "ERROR: Less than 5GB free disk space. Aborting."
    exit 1
fi

# Create archives directories
mkdir -p "$PUBLIC_DIR/archives" "$LOG_DIR/archives" "$STAGE_DIR"
chmod 755 "$PUBLIC_DIR/archives" "$LOG_DIR/archives"

# Serialize public/ changes with the hourly publish step, which waits on the same lock
COMPRESS_LOCK_WAIT=3600
exec 7>>"$LOG_DIR/public.lock"
if ! flock -w "$COMPRESS_LOCK_WAIT" 7; then
    echo "ERROR: public.lock still held after ${COMPRESS_LOCK_WAIT}s ($(lock_holder "$LOG_DIR/public.lock")). Aborting."
    exit 1
fi
note_lock_holder "$LOG_DIR/public.lock"
clean_stage_dir "$STAGE_DIR"

# === COMPRESS VALIDATION FILES (180+ days old) ===
echo "Checking for validation files 180+ days old..."

# Get list of months with old files
MONTHS_TO_COMPRESS=$(find "$PUBLIC_DIR" -maxdepth 1 -name "aroi_validation_*.json" -mtime +180 -type f 2>/dev/null | \
    sed 's/.*aroi_validation_\([0-9]\{6\}\).*/\1/' | sort -u)

if [ -n "$MONTHS_TO_COMPRESS" ]; then
    for MONTH in $MONTHS_TO_COMPRESS; do
        # Security: Validate MONTH format (should be 6 digits YYYYMM)
        if ! echo "$MONTH" | grep -qE '^[0-9]{6}$'; then
            echo "  ⚠ Skipping invalid month format: $MONTH"
            continue
        fi
        
        ARCHIVE_NAME="aroi-$MONTH.tar.gz"
        ARCHIVE_PATH="$PUBLIC_DIR/archives/$ARCHIVE_NAME"
        
        echo "Processing month: $MONTH"
        
        # Find all files for this month using null-delimited output for safety
        mapfile -d '' FILES_ARRAY < <(find "$PUBLIC_DIR" -maxdepth 1 -name "aroi_validation_${MONTH}*.json" -mtime +180 -type f -print0 2>/dev/null)
        
        if [ ${#FILES_ARRAY[@]} -gt 0 ]; then
            FILE_COUNT=${#FILES_ARRAY[@]}
            echo "  Found $FILE_COUNT files for $MONTH"
            
            # Security: Build basename list safely without command injection
            BASENAMES=()
            for f in "${FILES_ARRAY[@]}"; do
                BASENAMES+=("$(basename "$f")")
            done
            
            # Create archive with all files for this month, outside public/ so a
            # concurrent upload never reads a partial one and a failure keeps the old one
            TMP_ARCHIVE="$STAGE_DIR/$ARCHIVE_NAME"
            tar czf "$TMP_ARCHIVE" -C "$PUBLIC_DIR" "${BASENAMES[@]}" 2>/dev/null
            
            # Verify archive was created and contains files
            if [ -f "$TMP_ARCHIVE" ] && tar tzf "$TMP_ARCHIVE" >/dev/null 2>&1; then
                chmod 644 "$TMP_ARCHIVE"
                mv -f "$TMP_ARCHIVE" "$ARCHIVE_PATH"
                # Archive verified, safe to delete originals
                for f in "${FILES_ARRAY[@]}"; do
                    rm -f "$f"
                done
                echo "  ✓ Compressed $FILE_COUNT files → $ARCHIVE_NAME"
            else
                echo "  ✗ Archive verification failed, keeping originals"
                rm -f "$TMP_ARCHIVE"
            fi
        fi
    done
else
    echo "No files older than 180 days found"
fi

# === COMPRESS CRON LOG (if > 50 MB) ===
echo "Checking cron.log size..."

if [ -f "$LOG_DIR/cron.log" ]; then
    LOG_SIZE=$(stat -c%s "$LOG_DIR/cron.log" 2>/dev/null || echo 0)
    # Security: Validate LOG_SIZE is a number
    if ! [[ "$LOG_SIZE" =~ ^[0-9]+$ ]]; then
        LOG_SIZE=0
    fi
    LOG_SIZE_MB=$((LOG_SIZE / 1048576))
    
    if [ "$LOG_SIZE_MB" -gt 50 ]; then
        # Security: Use safe date format and validate
        DATE_PART=$(date +%Y-%m)
        if [[ "$DATE_PART" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
            ARCHIVE_NAME="cron-${DATE_PART}.log.gz"
        else
            echo "  ⚠ Invalid date format, skipping log compression"
            ARCHIVE_NAME=""
        fi
        
        if [ -n "$ARCHIVE_NAME" ]; then
            echo "cron.log is ${LOG_SIZE_MB}MB, compressing..."
            
            # Compress entire log
            gzip -9 -c "$LOG_DIR/cron.log" > "$LOG_DIR/archives/$ARCHIVE_NAME"
            
            # Verify compression
            if [ -f "$LOG_DIR/archives/$ARCHIVE_NAME" ] && gunzip -t "$LOG_DIR/archives/$ARCHIVE_NAME" 2>/dev/null; then
                # Keep only last 500 lines in current log. Truncate in place rather than
                # mv: a batch still appending to cron.log would keep writing to the old inode.
                TEMP_FILE=$(mktemp "$LOG_DIR/cron.log.XXXXXX")
                tail -500 "$LOG_DIR/cron.log" > "$TEMP_FILE"
                cat "$TEMP_FILE" > "$LOG_DIR/cron.log"
                rm -f "$TEMP_FILE"
                chmod 644 "$LOG_DIR/archives/$ARCHIVE_NAME"
                echo "  ✓ Compressed to $ARCHIVE_NAME"
            else
                echo "  ✗ Compression verification failed"
                rm -f "$LOG_DIR/archives/$ARCHIVE_NAME"
            fi
        fi
    else
        echo "cron.log is ${LOG_SIZE_MB}MB (under 50MB threshold)"
    fi
fi

# === UPDATE FILES MANIFEST ===
echo "Updating file manifest..."

# List current uncompressed files (sorted newest first); built outside public/, then renamed in
cd "$PUBLIC_DIR" || exit 1
MANIFEST="$STAGE_DIR/files.json"
ls -1 aroi_validation_*.json 2>/dev/null | sort -r | jq -R -s 'split("\n") | map(select(length > 0))' > "$MANIFEST" || echo '[]' > "$MANIFEST"

# Add archives to manifest
if [ -d archives ] && ls archives/*.tar.gz >/dev/null 2>&1; then
    # List archives and merge with main list
    (echo '{"files":'; cat "$MANIFEST"; echo ',"archives":'; ls -1 archives/*.tar.gz | jq -R -s 'split("\n") | map(select(length > 0))'; echo '}') | jq '{files: .files, archives: .archives}' > "$MANIFEST.new" 2>/dev/null && mv "$MANIFEST.new" "$MANIFEST" || echo '[]' > "$MANIFEST"
fi

chmod 644 "$MANIFEST" 2>/dev/null || true
mv -f "$MANIFEST" files.json

echo "Compression completed at $(date)"
echo ""

