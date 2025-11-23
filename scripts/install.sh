#!/bin/bash
# AROI Validator - Simplified Installation
# Run with: sudo bash install.sh

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         AROI Validator - Installation                     ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Must run as root (use sudo)${NC}"
    exit 1
fi

# Auto-detect user and paths
ACTUAL_USER=${SUDO_USER:-$(logname 2>/dev/null || echo $USER)}
USER_HOME=$(eval echo ~$ACTUAL_USER)
DEPLOY_DIR="$USER_HOME/aroivalidator-deploy"
CODE_DIR="$USER_HOME/aroivalidator"

# Load configuration
if [ ! -f "$DEPLOY_DIR/config.env" ]; then
    echo -e "${RED}Error: config.env not found${NC}"
    echo "Please copy config.env.example to config.env and edit it"
    exit 1
fi

source "$DEPLOY_DIR/config.env"

# Validate configuration
echo -e "${BLUE}[1/7] Validating configuration...${NC}"
if [[ ! "$DEPLOY_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo -e "${RED}Error: Invalid DEPLOY_IP in config.env${NC}"
    exit 1
fi
if [ -z "$DEPLOY_DOMAIN" ] || [ "$DEPLOY_DOMAIN" = "your-subdomain.your-domain.com" ]; then
    echo -e "${RED}Error: Please set DEPLOY_DOMAIN in config.env${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Configuration valid${NC}"

# Install system packages
echo -e "${BLUE}[2/7] Installing system packages...${NC}"
apt-get update -qq
apt-get install -y -qq python3-venv debian-keyring apt-transport-https curl gettext-base > /dev/null 2>&1

# Install Caddy
if ! command -v caddy &> /dev/null; then
    echo -e "${BLUE}[3/7] Installing Caddy...${NC}"
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq caddy > /dev/null 2>&1
    echo -e "${GREEN}✓ Caddy installed${NC}"
else
    echo -e "${GREEN}✓ Caddy already installed${NC}"
fi

# Set up Python environment
echo -e "${BLUE}[4/7] Setting up Python environment...${NC}"
if [ -d "$CODE_DIR/venv" ] && [ ! -f "$CODE_DIR/venv/bin/pip" ]; then
    rm -rf "$CODE_DIR/venv"
fi
if [ ! -d "$CODE_DIR/venv" ]; then
    sudo -u $ACTUAL_USER python3 -m venv "$CODE_DIR/venv"
fi
sudo -u $ACTUAL_USER bash -c "source $CODE_DIR/venv/bin/activate && pip install -q --upgrade pip && pip install -q streamlit dnspython pandas requests urllib3"
echo -e "${GREEN}✓ Python environment ready${NC}"

# Process templates and install configs
echo -e "${BLUE}[5/7] Installing configurations...${NC}"

# Process Caddyfile template
export DEPLOY_IP DEPLOY_DOMAIN DEPLOY_EMAIL DEPLOY_DIR
envsubst < "$DEPLOY_DIR/configs/Caddyfile.template" > /etc/caddy/Caddyfile

# Process cron templates
CRON_HOURLY=$(envsubst < "$DEPLOY_DIR/configs/aroivalidator.cron.template")
CRON_MONTHLY=$(envsubst < "$DEPLOY_DIR/configs/monthly-compression.cron.template")

# Install cron jobs
(sudo -u $ACTUAL_USER crontab -l 2>/dev/null | grep -v "aroivalidator\|compress-old-data"; echo "$CRON_HOURLY"; echo "$CRON_MONTHLY") | sudo -u $ACTUAL_USER crontab -
echo -e "${GREEN}✓ Cron jobs configured${NC}"

# Set permissions
chown -R $ACTUAL_USER:$ACTUAL_USER "$DEPLOY_DIR" "$CODE_DIR"
chmod 755 "$DEPLOY_DIR"/scripts/*.sh
chmod 600 "$DEPLOY_DIR/config.env"
chmod 711 "$USER_HOME"
chmod 755 "$DEPLOY_DIR/public"

# Start Caddy
echo -e "${BLUE}[6/7] Starting Caddy...${NC}"
systemctl enable caddy > /dev/null 2>&1
systemctl restart caddy

if systemctl is-active --quiet caddy; then
    echo -e "${GREEN}✓ Caddy running on $DEPLOY_IP${NC}"
else
    echo -e "${RED}✗ Caddy failed - check: journalctl -u caddy${NC}"
    exit 1
fi

# Configure fail2ban
echo -e "${BLUE}[7/7] Configuring fail2ban...${NC}"
if systemctl is-active --quiet fail2ban; then
    cp "$DEPLOY_DIR/configs/fail2ban-caddy.filter" /etc/fail2ban/filter.d/caddy.conf
    cp "$DEPLOY_DIR/configs/fail2ban-caddy.conf" /etc/fail2ban/jail.d/caddy.local
    systemctl restart fail2ban
    echo -e "${GREEN}✓ fail2ban configured${NC}"
else
    echo -e "${GREEN}⚠ fail2ban not running (optional)${NC}"
fi

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              ✓ Installation Complete!                     ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Next validation: $(date -d 'next hour' +'%H'):05"
echo "Website: https://$DEPLOY_DOMAIN"
echo "Monitor: tail -f $DEPLOY_DIR/logs/cron.log"
echo ""

