#!/usr/bin/env bash
# AROI Validator - Shared Functions
# Source this file in other scripts: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Prevent multiple sourcing
[[ -n "${_AROI_COMMON_LOADED:-}" ]] && return 0
_AROI_COMMON_LOADED=1

set -euo pipefail

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
    perms=$(stat -c '%a' "$config_file" 2>/dev/null || echo "644")
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
        source "$config_file"
        if $_cfg_nounset; then set -u; fi
        return 0
    fi
    return 1
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

# Remove files an interrupted publish or compress left in tmp/ (rsync --temp-dir
# "<name>.XXXXXX", staged latest.json/files.json/archives). Call with public.lock held.
# Regular files directly in tmp/ only: upload snapshots (tmp/upload-*.snap/) are directories.
clean_stage_dir() {
    local n
    n=$(find "$1" -maxdepth 1 -type f -print -delete 2>/dev/null | wc -l) || n=0
    [[ $n -eq 0 ]] || echo "Removed $((n)) leftover temp file(s) from ${1##*/}/ (interrupted publish)"
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
