#!/usr/bin/env bash
# Exercise the real upload and backup helpers using only temporary local storage.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RCLONE_PATH="${RCLONE_PATH:-$(command -v rclone 2>/dev/null || true)}"
[[ -x "$RCLONE_PATH" ]] || { echo "Set RCLONE_PATH to an installed rclone binary" >&2; exit 1; }
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

source "$REPO_DIR/scripts/upload-common.sh"
# Never load a deployment's settings or create its normal runtime directories.
# shellcheck disable=SC2034 # Consumed by the sourced upload helper.
init_paths() { DEPLOY_DIR="$TEST_ROOT"; }
load_config() { return 0; }

SOURCE_DIR="$TEST_ROOT/source"
BACKUP_DIR="$TEST_ROOT/backups"
mkdir -p "$SOURCE_DIR/onionsurge/deep" "$SOURCE_DIR/nested/onionsurge"
printf 'current dataset replacement\n' > "$SOURCE_DIR/latest.json"
printf 'must never overwrite the reserved data\n' > "$SOURCE_DIR/onionsurge/deep/retained.json"
printf 'must never upload\n' > "$SOURCE_DIR/onionsurge/new.json"
printf 'ordinary nested content\n' > "$SOURCE_DIR/nested/onionsurge/normal.json"
init_upload "$SOURCE_DIR"
# The test has no configured remotes and cannot select a cloud destination.
RCLONE_OPTS_ARRAY+=(--config=/dev/null --stats=0)

for provider in 'do' 'r2'; do
    bucket="$TEST_ROOT/$provider-bucket"
    mkdir -p "$bucket/onionsurge/deep" "$bucket/nested/onionsurge"
    printf 'owned by another publisher\n' > "$bucket/onionsurge/deep/retained.json"
    printf 'old\n' > "$bucket/latest.json"
    printf 'obsolete\n' > "$bucket/obsolete.json"
    printf 'lookalike is ordinary AROI content\n' > "$bucket/onionsurge-old.json"
    printf 'nested obsolete\n' > "$bucket/nested/onionsurge/obsolete.json"
    cp "$bucket/onionsurge/deep/retained.json" "$TEST_ROOT/expected-reserved"

    # shellcheck disable=SC2034 # Consumed by the sourced upload helper.
    UPLOAD_SNAP="$STAGE_DIR/upload-$provider.snap"
    do_upload "$bucket"
    cmp "$TEST_ROOT/expected-reserved" "$bucket/onionsurge/deep/retained.json"
    [[ ! -e "$bucket/onionsurge/new.json" ]]
    cmp "$SOURCE_DIR/latest.json" "$bucket/latest.json"
    cmp "$SOURCE_DIR/nested/onionsurge/normal.json" "$bucket/nested/onionsurge/normal.json"
    [[ ! -e "$bucket/obsolete.json" && ! -e "$bucket/onionsurge-old.json" ]]
    [[ ! -e "$bucket/nested/onionsurge/obsolete.json" ]]

    maybe_backup "$bucket" "$TEST_ROOT/$provider-local.marker" local true
    local_backup="$BACKUP_DIR/backup-$TIMESTAMP"
    cmp "$bucket/latest.json" "$local_backup/latest.json"
    [[ ! -e "$local_backup/onionsurge" ]]

    maybe_backup "$bucket" "$TEST_ROOT/$provider-remote.marker" remote true
    remote_backup="$bucket/_backups/$TIMESTAMP"
    cmp "$bucket/latest.json" "$remote_backup/latest.json"
    [[ ! -e "$remote_backup/onionsurge" && ! -e "$remote_backup/_backups" ]]
    cmp "$TEST_ROOT/expected-reserved" "$bucket/onionsurge/deep/retained.json"
done

echo "PASS: reserved root prefix survives uploads; normal sync/delete and both backup paths work"
