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

# Overflow-safe non-negative integer parsing against [min, max].
# Strips leading zeros and checks digit count before Bash arithmetic.
parse_int_in_range() {
    local raw=$1 min=$2 max=$3
    [[ "$raw" =~ ^[0-9]+$ ]] || return 1
    local norm
    norm=$(printf '%s' "$raw" | sed 's/^0*//')
    [[ -n "$norm" ]] || norm="0"
    if (( ${#norm} > ${#max} )); then
        return 1
    fi
    local val=$((10#$norm))
    if (( val < min || val > max )); then
        return 1
    fi
    echo "$val"
}

# Validate an integer setting against [min, max]; returns validated integer or default.
validate_int_range() {
    local name=$1 raw=$2 min=$3 max=$4 def=$5
    local val
    if val=$(parse_int_in_range "$raw" "$min" "$max"); then
        echo "$val"
        return 0
    fi
    echo "Warning: invalid $name='$raw' (expected integer ${min}-${max}), using $def" >&2
    echo "$def"
}

# Portable lowercase 32-hex MD5 checksum of a regular file.
file_md5() {
    local path=$1 sum=""
    if command -v md5sum >/dev/null 2>&1; then
        sum=$(md5sum "$path" 2>/dev/null | awk '{print $1}')
    elif command -v md5 >/dev/null 2>&1; then
        sum=$(md5 -q "$path" 2>/dev/null)
    else
        return 1
    fi
    sum=$(printf '%s' "$sum" | tr '[:upper:]' '[:lower:]')
    [[ "$sum" =~ ^[0-9a-f]{32}$ ]] || return 1
    echo "$sum"
}

# Portable file size in bytes (GNU coreutils, macOS BSD stat, or wc fallback)
file_size_bytes() {
    local path=$1
    stat -c '%s' "$path" 2>/dev/null || stat -f '%z' "$path" 2>/dev/null || wc -c < "$path" | tr -d '[:space:]'
}

# Return 0 iff both paths exist and reside on the same filesystem device.
same_filesystem() {
    local d1 d2
    d1=$(stat -c '%d' "$1" 2>/dev/null || stat -f '%d' "$1" 2>/dev/null || echo "")
    d2=$(stat -c '%d' "$2" 2>/dev/null || stat -f '%d' "$2" 2>/dev/null || echo "")
    [[ -n "$d1" && -n "$d2" && "$d1" == "$d2" ]]
}

# Atomically install src_file to dest_path on dest_path's own filesystem.
atomic_install_file() {
    local src_file=$1 dest_path=$2 mode=${3:-644}
    local dest_dir tmp
    dest_dir=$(dirname "$dest_path")
    mkdir -p "$dest_dir"
    if same_filesystem "$(dirname "$src_file")" "$dest_dir"; then
        chmod "$mode" "$src_file" && mv -f "$src_file" "$dest_path"
        return $?
    fi
    tmp=$(mktemp "$dest_dir/.aroi-tmp.XXXXXX") || return 1
    if cp "$src_file" "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$dest_path"; then
        rm -f "$src_file"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Resolve configured rclone destination bucket URIs.
resolve_do_bucket() {
    if [[ -z "${DO_SPACES_BUCKET:-}" ]]; then
        echo "ERROR: DO_SPACES_BUCKET is not set" >&2
        return 1
    fi
    printf '%s:%s\n' "${AROI_DO_REMOTE:-aroi-spaces}" "$DO_SPACES_BUCKET"
}

resolve_r2_bucket() {
    if [[ -z "${R2_BUCKET:-}" ]]; then
        echo "ERROR: R2_BUCKET is not set" >&2
        return 1
    fi
    printf '%s:%s\n' "${AROI_R2_REMOTE:-aroi-r2}" "$R2_BUCKET"
}

# Decompression window log: never cap below 27 so lowering ZSTD_LONG cannot
# break reading/verifying archives created with --long=27.
zstd_decode_long() {
    local cfg=${1:-${ZSTD_LONG:-27}}
    local val
    if val=$(parse_int_in_range "$cfg" 10 31); then
        if (( val > 27 )); then
            echo "$val"
        else
            echo "27"
        fi
    else
        echo "27"
    fi
}

# List sorted unique member names of a .tar.zst archive without masking pipeline errors.
list_archive_members() {
    local archive_path=$1 out_file=$2
    local dec_long raw_list rc=0
    dec_long=$(zstd_decode_long "${ZSTD_LONG:-27}")
    raw_list=$(mktemp "$(dirname "$out_file")/.aroi-tmp.members.XXXXXX") || return 1
    zstd -dc --long="$dec_long" "$archive_path" 2>/dev/null | tar tf - > "$raw_list" 2>/dev/null || rc=$?
    if [[ $rc -ne 0 ]]; then
        rm -f "$raw_list"
        return 1
    fi
    LC_ALL=C sort -u "$raw_list" > "$out_file"
    rm -f "$raw_list"
}

# Read a destination-scoped upload ledger into out_file (sorted canonical filenames).
# Returns 0 only if line 1 header matches "# bucket=<bucket>"; returns 1 and clears out_file otherwise.
read_upload_ledger() {
    local ledger_file=$1 bucket=$2 out_file=$3
    : > "$out_file"
    [[ -s "$ledger_file" ]] || return 1
    local first_line=""
    IFS= read -r first_line < "$ledger_file" || return 1
    [[ "$first_line" == "# bucket=${bucket}" ]] || return 1
    grep -E "$AROI_JSON_REGEX" "$ledger_file" 2>/dev/null | LC_ALL=C sort -u > "$out_file" || true
    return 0
}

# Atomically write a destination-scoped upload ledger on ledger_file's own filesystem.
write_upload_ledger() {
    local ledger_file=$1 bucket=$2 entries_file=$3
    local dir tmp
    dir=$(dirname "$ledger_file")
    mkdir -p "$dir"
    tmp=$(mktemp "$dir/.aroi-tmp.ledger.XXXXXX") || return 1
    if ! {
        printf '# bucket=%s\n' "$bucket"
        if [[ -s "$entries_file" ]]; then
            grep -E "$AROI_JSON_REGEX" "$entries_file" 2>/dev/null | LC_ALL=C sort -u || true
        fi
    } > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 644 "$tmp" && mv -f "$tmp" "$ledger_file"
}

# Verify both aroi-YYYYMM.tar.zst and aroi-YYYYMM.list on a remote bucket match the local files
# in size AND content (via MD5 from rclone lsf --format shp, or download+cmp when hash unavailable).
verify_remote_backup_pair() {
    local rclone_bin=$1 provider_label=$2 bucket=$3 month=$4 archive_dir=$5 remote_backups_shp=$6 work_dir=$7
    local artifact_name local_path local_sz row remote_sz remote_md5 local_md5 dl_dir rc

    for artifact_name in "aroi-${month}.tar.zst" "aroi-${month}.list"; do
        local_path="$archive_dir/$artifact_name"
        if [[ ! -s "$local_path" ]]; then
            echo "  ✗ Local backup artifact missing or empty: $local_path"
            return 1
        fi
        local_sz=$(file_size_bytes "$local_path")
        row=$(awk -F';' -v name="$artifact_name" '$3 == name {print $1 ";" $2; exit}' "$remote_backups_shp")
        if [[ -z "$row" ]]; then
            echo "  ✗ $provider_label _backups/$artifact_name missing"
            return 1
        fi
        IFS=';' read -r remote_sz remote_md5 <<< "$row"
        if [[ -z "$remote_sz" || "$remote_sz" != "$local_sz" ]]; then
            echo "  ✗ $provider_label _backups/$artifact_name size mismatch (local=$local_sz, remote=${remote_sz:-missing})"
            return 1
        fi
        remote_md5=$(printf '%s' "$remote_md5" | tr '[:upper:]' '[:lower:]')
        if [[ "$remote_md5" =~ ^[0-9a-f]{32}$ ]]; then
            if ! local_md5=$(file_md5 "$local_path"); then
                echo "  ✗ Failed computing local MD5 for $artifact_name"
                return 1
            fi
            if [[ "$remote_md5" != "$local_md5" ]]; then
                echo "  ✗ $provider_label _backups/$artifact_name content checksum mismatch (local=$local_md5, remote=$remote_md5)"
                return 1
            fi
        else
            dl_dir=$(mktemp -d "$work_dir/cmp-${provider_label}-${month}.XXXXXX")
            printf '%s\n' "$artifact_name" > "$dl_dir/want.txt"
            rc=0
            "$rclone_bin" copy "$bucket/_backups" "$dl_dir" --files-from "$dl_dir/want.txt" --no-traverse >/dev/null 2>&1 || rc=$?
            if [[ $rc -ne 0 ]] || [[ ! -s "$dl_dir/$artifact_name" ]] || ! cmp -s "$local_path" "$dl_dir/$artifact_name"; then
                echo "  ✗ $provider_label _backups/$artifact_name content verification failed"
                rm -rf "$dl_dir"
                return 1
            fi
            rm -rf "$dl_dir"
        fi
    done
    return 0
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

# Remove interrupted same-filesystem staging temps (.aroi-tmp.*) directly in a target directory.
# Call with public.lock held.
clean_publish_temps() {
    local dir=$1
    [[ -d "$dir" ]] || return 0
    find "$dir" -maxdepth 1 -type f -name '.aroi-tmp.*' -delete 2>/dev/null || true
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

# Build public/files.json atomically on public_dir's own filesystem as a newest-first
# flat JSON array combining:
#   - all archived filenames listed in <archive_dir>/aroi-*.list
#   - all non-empty hourly JSONs currently in <public_dir>
# Call under public.lock.
build_files_manifest() {
    local public_dir=$1 archive_dir=$2 _stage_dir=${3:-}
    mkdir -p "$public_dir"

    local tmp_names tmp_manifest
    tmp_names=$(mktemp "$public_dir/.aroi-tmp.names.XXXXXX") || return 1
    tmp_manifest=$(mktemp "$public_dir/.aroi-tmp.files.XXXXXX") || { rm -f "$tmp_names"; return 1; }

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

    if ! { chmod 644 "$tmp_manifest" && mv -f "$tmp_manifest" "$public_dir/files.json"; }; then
        rm -f "$tmp_manifest"
        return 1
    fi
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
