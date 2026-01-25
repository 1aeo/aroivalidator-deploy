#!/bin/bash
# Cron management - uses /etc/cron.d/ to prevent overwrites
# Usage: ./cron-manage.sh {install|verify|backup|show|migrate}
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${BLUE}[cron]${NC} $1"; }
ok() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
err() { echo -e "${RED}✗${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
CRON_USER="${SUDO_USER:-${USER:-$(stat -c '%U' "$DEPLOY_DIR")}}"
CRON_D_FILE="/etc/cron.d/aroivalidator"
BACKUP_DIR="$DEPLOY_DIR/backups/cron"
mkdir -p "$BACKUP_DIR"

gen_content() {
    export DEPLOY_DIR CRON_USER
    [[ -f "$DEPLOY_DIR/configs/aroivalidator.cron.d" ]] && \
        envsubst '${DEPLOY_DIR} ${CRON_USER}' < "$DEPLOY_DIR/configs/aroivalidator.cron.d" && return
    cat << EOF
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
MAILTO=""
5 * * * * ${CRON_USER} ${DEPLOY_DIR}/scripts/run-batch-validation.sh >> ${DEPLOY_DIR}/logs/cron.log 2>&1
0 2 1 * * ${CRON_USER} ${DEPLOY_DIR}/scripts/compress-old-data.sh >> ${DEPLOY_DIR}/logs/compression.log 2>&1
EOF
}

cmd_install() {
    log "Installing cron jobs to /etc/cron.d/..."
    if [[ $EUID -ne 0 ]]; then
        err "Requires sudo: sudo $0 install"; exit 1
    fi
    gen_content > "$CRON_D_FILE"
    chmod 644 "$CRON_D_FILE"; chown root:root "$CRON_D_FILE"
    ok "Installed: $CRON_D_FILE"; echo ""; cat "$CRON_D_FILE"
}

cmd_verify() {
    log "Verifying cron jobs..."; echo ""
    local found_crond=false found_user=false
    if [[ -f "$CRON_D_FILE" ]] && grep -q "run-batch-validation" "$CRON_D_FILE" 2>/dev/null; then
        ok "/etc/cron.d/aroivalidator: hourly validation ✓"
        grep -q "compress-old-data" "$CRON_D_FILE" && ok "/etc/cron.d/aroivalidator: monthly compression ✓"
        found_crond=true
    else
        warn "/etc/cron.d/aroivalidator: not found"
    fi
    local user_cron; user_cron=$(crontab -l 2>/dev/null || true)
    if echo "$user_cron" | grep -q "run-batch-validation"; then
        [[ "$found_crond" == "true" ]] && warn "User crontab: DUPLICATE (run migrate)" || ok "User crontab: hourly ✓"
        found_user=true
    fi
    echo ""
    if [[ "$found_crond" == "true" ]]; then
        ok "Status: Cron jobs in /etc/cron.d/ (protected)"
        [[ "$found_user" == "true" ]] && warn "Run '$0 migrate' to remove duplicates"
    elif [[ "$found_user" == "true" ]]; then
        warn "Status: User crontab only (vulnerable). Run 'sudo $0 install'"
    else
        err "NO CRON JOBS FOUND! Run 'sudo $0 install'"; return 1
    fi
}

cmd_backup() {
    local f="$BACKUP_DIR/crontab-$(date +%Y%m%d_%H%M%S).bak"
    crontab -l > "$f" 2>/dev/null && [[ -s "$f" ]] && ok "Backed up: $f" || { rm -f "$f"; warn "Nothing to backup"; }
}

cmd_show() {
    log "Current configuration:"; echo ""
    echo "=== /etc/cron.d/aroivalidator ===" 
    [[ -f "$CRON_D_FILE" ]] && cat "$CRON_D_FILE" || echo "(not found)"; echo ""
    echo "=== User crontab (aroivalidator) ==="
    crontab -l 2>/dev/null | grep -E "(run-batch-validation|compress-old-data)" || echo "(none)"; echo ""
    echo "=== Backups ===" 
    ls "$BACKUP_DIR"/*.bak 2>/dev/null || echo "(none)"
}

cmd_migrate() {
    log "Migrating to /etc/cron.d/..."; echo ""
    [[ -f "$CRON_D_FILE" ]] || { err "Run 'sudo $0 install' first"; exit 1; }
    local cur; cur=$(crontab -l 2>/dev/null || true)
    [[ -z "$cur" ]] && { ok "User crontab empty"; return 0; }
    local cnt; cnt=$(echo "$cur" | grep -cE "(run-batch-validation|compress-old-data)" || echo 0)
    [[ "$cnt" -eq 0 ]] && { ok "No entries to migrate"; return 0; }
    # Backup then remove
    local f="$BACKUP_DIR/crontab-$(date +%Y%m%d_%H%M%S).bak"
    echo "$cur" > "$f"; ok "Backed up: $f"
    local new; new=$(echo "$cur" | grep -vE "(run-batch-validation|compress-old-data)" || true)
    [[ -n "$new" ]] && echo "$new" | crontab - || crontab -r 2>/dev/null
    ok "Removed $cnt entries from user crontab"
}

case "${1:-}" in
    install) cmd_install ;; verify) cmd_verify ;; backup) cmd_backup ;;
    show) cmd_show ;; migrate) cmd_migrate ;;
    *) echo "Usage: $0 {install|verify|backup|show|migrate}"; exit 1 ;;
esac
