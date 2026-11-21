#!/usr/bin/env bash
# AROI Validator - Shared Functions
# Source this file in other scripts: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Prevent multiple sourcing
[[ -n "${_AROI_COMMON_LOADED:-}" ]] && return 0
_AROI_COMMON_LOADED=1

set -euo pipefail

# Canonical filename regex for hourly validation JSON outputs
# shellcheck disable=SC2034  # used across sourcing scripts
AROI_JSON_REGEX='^aroi_validation_[0-9]{8}_[0-9]{6}\.json$'

# === Path Detection (call init_paths from sourcing script) ===
init_paths() {
    # Use BASH_SOURCE to get the calling script's directory
    # Default to index 1 (direct caller), but allow override for nested sourcing
    local caller_idx=${1:-1}
    local max_idx=$((${#BASH_SOURCE[@]} - 1))
    # Clamp to valid range
    [[ $caller_idx -gt $max_idx ]] && caller_idx=$max_idx
    [[ $caller_idx -lt 0 ]] && caller_idx=0

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[$caller_idx]}")" && pwd)"
    DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
    export SCRIPT_DIR DEPLOY_DIR
}

# === Config Validation & Loading ===
# Returns 0 if config is valid, 1 otherwise. Warns on insecure permissions.
validate_config() {
    local config_file="${1:-$DEPLOY_DIR/config.env}"
    [[ -f "$config_file" ]] || return 1

    local perms
    perms=$(stat -c '%a' "$config_file" 2>/dev/null || stat -f '%Lp' "$config_file" 2>/dev/null || echo "644")
    # Check world-readable/writable (last digit should be 0 or 4)
    if [[ "${perms: -1}" != "0" && "${perms: -1}" != "4" ]]; then
        echo "Warning: $config_file has insecure permissions ($perms). Run: chmod 600 $config_file" >&2
    fi
    return 0
}

# Load config with validation
load_config() {
    local config_file="${1:-$DEPLOY_DIR/config.env}"
    if [[ -f "$config_file" ]]; then
        validate_config "$config_file"
        # Source with nounset off: an unset reference in config.env would otherwise
        # abort the caller under set -u, even behind "load_config || true".
        local _cfg_nounset=false
        [[ $- == *u* ]] && _cfg_nounset=true
        set +u
        # shellcheck disable=SC1090
        source "$config_file"
        if $_cfg_nounset; then set -u; fi
        return 0
    fi
    return 1
}

# Validate an integer setting against [min, max]; returns validated integer or default.
validate_int_range() {
    local name=$1 raw=$2 min=$3 max=$4 def=$5
    if [[ ! "$raw" =~ ^[0-9]+$ ]]; then
        echo "Warning: invalid $name='$raw' (expected integer ${min}-${max}), using $def" >&2
        echo "$def"
        return 0
    fi
    local val=$((10#$raw))
    if (( val < min || val > max )); then
        echo "Warning: $name=$val out of range (${min}-${max}), using $def" >&2
        echo "$def"
        return 0
    fi
    echo "$val"
}

# Portable file size in bytes (GNU coreutils, macOS BSD stat, or wc fallback)
file_size_bytes() {
    local path=$1
    stat -c '%s' "$path" 2>/dev/null || stat -f '%z' "$path" 2>/dev/null || wc -c < "$path" | tr -d '[:space:]'
}

# Portable available free GiB on the filesystem containing path
available_gb() {
    local path=$1
    df -Pk "$path" | awk 'NR==2 {print int($4 / 1048576)}'
}

# === Locking ===
# Lock files are opened for append (exec N>>file) so a process that fails to get
# the lock does not wipe the holder's line, and are never deleted: deleting one
# lets a later process lock a new inode while an older holder still has the old one.
# Exit status of upload-*.sh when the provider's previous upload still holds its lock
# shellcheck disable=SC2034  # used by upload-common.sh and run-batch-validation.sh
UPLOAD_SKIPPED=75

# How long the publish step and upload snapshots wait for public.lock
# shellcheck disable=SC2034  # used by upload-common.sh and run-batch-validation.sh
PUBLIC_LOCK_WAIT=900

# Record "<pid> <start time>" in a lock file this process has just flock'ed
note_lock_holder() { printf '%s %s\n' "$$" "$(date '+%Y-%m-%d %H:%M:%S')" > "$1"; }

# Describe the recorded holder, e.g. "pid 123, since 2026-10-12 00:00:31"
lock_holder() {
    local pid="" since="" state="" try
    for try in 1 2; do
        pid="" since=""
        read -r pid since 2>/dev/null < "$1" || true
        [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && break
        [[ $try -eq 1 ]] && sleep 1  # a new holder may not have recorded itself yet
    done
    if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
        # Recorded pid gone: if the lock is still held, a child that inherited the fd
        # (e.g. rclone) holds it; otherwise the holder has finished since we checked
        if flock -n "$1" true 2>/dev/null; then state=" (exited)"
        else state=" (exited, a child still holds the lock)"; fi
    fi
    echo "pid ${pid:-?}${state}, since ${since:-?}"
}

# Without locking it, read a lock file's "<pid> <since>" into LOCK_PID/LOCK_SINCE and
# succeed if that process is still alive and started by <since> (not a reused pid)
lock_pid_alive() {
    local age since_s
    LOCK_PID="" LOCK_SINCE=""
    read -r LOCK_PID LOCK_SINCE 2>/dev/null < "$1" || true
    [[ "$LOCK_PID" =~ ^[0-9]+$ ]] && kill -0 "$LOCK_PID" 2>/dev/null || return 1
    age=$(ps -o etimes= -p "$LOCK_PID" 2>/dev/null) || age=""
    age=${age//[[:space:]]/}
    # No elapsed time: the process exited after kill -0, or ps has no etimes (then
    # trust kill -0). Ask kill -0 again, so an exit in between reads as not alive.
    [[ "$age" =~ ^[0-9]+$ ]] || { kill -0 "$LOCK_PID" 2>/dev/null; return; }
    # Recorded start time unreadable (e.g. no GNU date): trust ps
    since_s=$(date -d "$LOCK_SINCE" +%s 2>/dev/null) || return 0
    (( $(date +%s) - age <= since_s + 2 ))
}

# Remove files an interrupted publish or compress left in tmp/ (rsync/staged files).
# Call with public.lock held. Regular files directly in tmp/ only: snapshot
# directories (tmp/upload-*.snap/, tmp/archive-*.snap/) are managed by their owners.
clean_stage_dir() {
    local out line n=0 err=""
    out=$(find "$1" -maxdepth 1 -type f -print -delete 2>&1) || true
    # Count the listed files that are gone; any other output line is an error
    while IFS= read -r line; do
        if [[ "$line" == "$1/"* ]]; then
            [[ -e "$line" ]] || n=$((n + 1))
        elif [[ -n "$line" ]]; then
            err=${err:-$line}
        fi
    done <<< "$out"
    [[ $n -eq 0 ]] || echo "Removed $n leftover temp file(s) from ${1##*/}/ (interrupted publish)"
    [[ -z "$err" ]] || echo "WARNING: could not clean up ${1##*/}/: $err"
}

# List non-empty hourly validation JSON basenames in a directory (sorted ascending).
# Works portably across GNU and BSD find without ARG_MAX limits.
list_nonempty_validation_files() {
    local dir=$1
    [[ -d "$dir" ]] || return 0
    (
        cd "$dir"
        find . -maxdepth 1 -name 'aroi_validation_*.json' -type f -size +0c 2>/dev/null \
            | sed 's|^\./||' \
            | grep -E "$AROI_JSON_REGEX" \
            | LC_ALL=C sort -u || true
    )
}

# Build public/files.json atomically as a newest-first flat JSON array combining:
#   - all archived filenames listed in <archive_dir>/aroi-*.list
#   - all non-empty hourly JSONs currently in <public_dir>
# Call under public.lock.
build_files_manifest() {
    local public_dir=$1 archive_dir=$2 stage_dir=$3
    mkdir -p "$public_dir" "$stage_dir"

    local tmp_names tmp_manifest
    tmp_names=$(mktemp "$stage_dir/manifest-names.XXXXXX")
    tmp_manifest=$(mktemp "$stage_dir/files.json.XXXXXX")

    {
        if [[ -d "$archive_dir" ]]; then
            local list_file
            while IFS= read -r -d '' list_file; do
                grep -E "$AROI_JSON_REGEX" "$list_file" 2>/dev/null || true
            done < <(find "$archive_dir" -maxdepth 1 -name 'aroi-*.list' -type f -print0 2>/dev/null)
        fi
        list_nonempty_validation_files "$public_dir"
    } | LC_ALL=C sort -ru > "$tmp_names"

    if ! jq -Rs 'split("\n") | map(select(length > 0))' < "$tmp_names" > "$tmp_manifest"; then
        rm -f "$tmp_names" "$tmp_manifest"
        return 1
    fi
    rm -f "$tmp_names"

    chmod 644 "$tmp_manifest"
    mv -f "$tmp_manifest" "$public_dir/files.json"
}

# === Logging Functions ===
_log_ts() { date '+%H:%M:%S'; }

log()         { echo "[$(_log_ts)]${STORAGE_NAME:+ [$STORAGE_NAME]} $1"; }
log_error()   { echo "[$(_log_ts)] ❌ $1" >&2; }
log_success() { echo "[$(_log_ts)] ✅ $1"; }

# === Utility Functions ===
# Check if command exists
require_cmd() {
    command -v "$1" &>/dev/null || { log_error "$1 required but not found"; return 1; }
}

# Validate string matches pattern (for security checks)
validate_pattern() {
    local value="$1" pattern="$2" name="${3:-value}"
    [[ "$value" =~ $pattern ]] || { log_error "Invalid $name: $value"; return 1; }
}
