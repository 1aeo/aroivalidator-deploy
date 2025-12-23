#!/bin/bash
# AROI Validator - Installation Script
# Default: Cloudflare Pages + DO Spaces/R2
# Fallback: Caddy (self-hosted)

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
ok() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
err() { echo -e "${RED}✗${NC} $1"; exit 1; }

echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           AROI Validator - Installation                       ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Detect user and paths
if [[ $EUID -eq 0 ]]; then
    ACTUAL_USER=${SUDO_USER:-$(logname 2>/dev/null || echo $USER)}
else
    ACTUAL_USER=$USER
fi
USER_HOME=$(eval echo ~$ACTUAL_USER)
DEPLOY_DIR="$USER_HOME/aroivalidator-deploy"
CODE_DIR="$USER_HOME/aroivalidator"

# Load config
[[ -f "$DEPLOY_DIR/config.env" ]] || err "config.env not found. Copy config.env.example first."
source "$DEPLOY_DIR/config.env"

# Determine mode
USE_PAGES=false
USE_CADDY=false

if [[ "${1:-}" == "--caddy" ]]; then
    USE_CADDY=true
    log "Mode: Caddy (self-hosted)"
elif [[ -n "${CLOUDFLARE_API_TOKEN:-}" && "${CLOUDFLARE_API_TOKEN}" != "your_api_token" ]]; then
    USE_PAGES=true
    log "Mode: Cloudflare Pages + DO Spaces/R2"
elif [[ -n "${DEPLOY_IP:-}" && "${DEPLOY_IP}" != "YOUR_IP_ADDRESS" ]]; then
    USE_CADDY=true
    log "Mode: Caddy (fallback - no Cloudflare token)"
else
    err "Configure either CLOUDFLARE_API_TOKEN (Pages) or DEPLOY_IP (Caddy) in config.env"
fi

# === Common Setup ===
log "Installing dependencies..."
if [[ $EUID -eq 0 ]]; then
    apt-get update -qq
    apt-get install -y -qq python3-venv curl jq gettext-base > /dev/null 2>&1
    ok "System packages"
else
    command -v python3 &>/dev/null || err "python3 required"
    command -v curl &>/dev/null || err "curl required"
    command -v jq &>/dev/null || err "jq required"
    ok "Dependencies found"
fi

# Python environment
log "Setting up Python..."
[[ -d "$CODE_DIR" ]] || err "Code directory not found: $CODE_DIR"
[[ -d "$CODE_DIR/venv" && ! -f "$CODE_DIR/venv/bin/pip" ]] && rm -rf "$CODE_DIR/venv"
[[ -d "$CODE_DIR/venv" ]] || python3 -m venv "$CODE_DIR/venv"
source "$CODE_DIR/venv/bin/activate"
pip install -q --upgrade pip
pip install -q streamlit dnspython pandas requests urllib3
ok "Python environment"

# Create directories
mkdir -p "$DEPLOY_DIR"/{logs,public,backups,pages-static}
[[ -f "$DEPLOY_DIR/public/index.html" ]] && cp -f "$DEPLOY_DIR/public/index.html" "$DEPLOY_DIR/pages-static/"
ok "Directories"

# === Mode-specific Setup ===

if [[ "$USE_PAGES" == "true" ]]; then
    # Cloudflare Pages mode
    log "Setting up Cloudflare Pages..."
    
    # Check rclone
    RCLONE="${RCLONE_PATH:-$(command -v rclone 2>/dev/null || echo "$USER_HOME/bin/rclone")}"
    [[ -x "$RCLONE" ]] || {
        warn "rclone not found - install from https://rclone.org/install/"
        warn "Cloud uploads will fail until rclone is installed"
    }
    
    # Check node/npm for wrangler
    if ! command -v node &>/dev/null; then
        if [[ $EUID -eq 0 ]]; then
            log "Installing Node.js..."
            apt-get install -y -qq nodejs npm > /dev/null 2>&1
            ok "Node.js installed"
        else
            warn "Node.js not found - install for Pages deployment"
        fi
    fi
    
    # Validate storage config
    STORAGE_OK=false
    [[ "${DO_ENABLED:-}" == "true" && -n "${DO_SPACES_KEY:-}" ]] && STORAGE_OK=true
    [[ "${R2_ENABLED:-}" == "true" && -n "${R2_ACCESS_KEY_ID:-}" ]] && STORAGE_OK=true
    [[ "$STORAGE_OK" == "true" ]] || warn "No storage configured (DO_ENABLED or R2_ENABLED)"
    
    ok "Cloudflare Pages configured"
    
elif [[ "$USE_CADDY" == "true" ]]; then
    # Caddy mode (requires root)
    [[ $EUID -eq 0 ]] || err "Caddy install requires sudo"
    
    # Validate Caddy config
    [[ "$DEPLOY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "Invalid DEPLOY_IP"
    [[ -n "$DEPLOY_DOMAIN" && "$DEPLOY_DOMAIN" != *"example"* ]] || err "Set DEPLOY_DOMAIN in config.env"
    
    # Install Caddy
    if ! command -v caddy &>/dev/null; then
        log "Installing Caddy..."
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
        apt-get update -qq && apt-get install -y -qq caddy > /dev/null 2>&1
    fi
    ok "Caddy installed"
    
    # Configure Caddy
    export DEPLOY_IP DEPLOY_DOMAIN DEPLOY_EMAIL DEPLOY_DIR
    envsubst < "$DEPLOY_DIR/configs/Caddyfile.template" > /etc/caddy/Caddyfile
    systemctl enable caddy > /dev/null 2>&1
    systemctl restart caddy
    systemctl is-active --quiet caddy && ok "Caddy running" || err "Caddy failed"
    
    # fail2ban (optional)
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        cp "$DEPLOY_DIR/configs/fail2ban-caddy.filter" /etc/fail2ban/filter.d/caddy.conf 2>/dev/null || true
        cp "$DEPLOY_DIR/configs/fail2ban-caddy.conf" /etc/fail2ban/jail.d/caddy.local 2>/dev/null || true
        systemctl restart fail2ban 2>/dev/null || true
        ok "fail2ban configured"
    fi
fi

# === Cron Jobs ===
log "Setting up cron..."
export DEPLOY_DIR USER_HOME
CRON_HOURLY=$(envsubst < "$DEPLOY_DIR/configs/aroivalidator.cron.template" 2>/dev/null || echo "5 * * * * $DEPLOY_DIR/scripts/run-batch-validation.sh >> $DEPLOY_DIR/logs/cron.log 2>&1")
CRON_MONTHLY=$(envsubst < "$DEPLOY_DIR/configs/monthly-compression.cron.template" 2>/dev/null || echo "0 2 1 * * $DEPLOY_DIR/scripts/compress-old-data.sh >> $DEPLOY_DIR/logs/compression.log 2>&1")

CURRENT_CRON=$(crontab -l 2>/dev/null || echo "")
UPDATED=false

if ! echo "$CURRENT_CRON" | grep -q "run-batch-validation"; then
    CURRENT_CRON="$CURRENT_CRON"$'\n'"$CRON_HOURLY"
    UPDATED=true
fi
if ! echo "$CURRENT_CRON" | grep -q "compress-old-data"; then
    CURRENT_CRON="$CURRENT_CRON"$'\n'"$CRON_MONTHLY"
    UPDATED=true
fi

[[ "$UPDATED" == "true" ]] && echo "$CURRENT_CRON" | grep -v '^$' | crontab -
ok "Cron jobs"

# === Permissions ===
chmod 755 "$DEPLOY_DIR"/scripts/*.sh 2>/dev/null || true
chmod 600 "$DEPLOY_DIR/config.env" 2>/dev/null || true
chmod 755 "$DEPLOY_DIR/public" 2>/dev/null || true
ok "Permissions"

# === Summary ===
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    ✓ Installation Complete                    ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ "$USE_PAGES" == "true" ]]; then
    echo "Mode:     Cloudflare Pages + Cloud Storage"
    echo "Deploy:   $DEPLOY_DIR/scripts/pages-deploy.sh"
    echo "Upload:   Automatic at :05 each hour"
    [[ -n "${PAGES_PROJECT_NAME:-}" ]] && echo "Site:     https://${PAGES_PROJECT_NAME}.pages.dev"
else
    echo "Mode:     Caddy (self-hosted)"
    echo "Site:     https://$DEPLOY_DOMAIN"
fi
echo ""
echo "Validate: $DEPLOY_DIR/scripts/run-batch-validation.sh"
echo "Logs:     tail -f $DEPLOY_DIR/logs/cron.log"
echo "Next run: $(date -d 'next hour' +'%H'):05"
echo ""
