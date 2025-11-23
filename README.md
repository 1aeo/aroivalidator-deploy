# AROI Validator - Deployment Template

Automated Tor relay validation with web interface. Validates ~11,000 relays hourly.

**Code repo:** https://github.com/1aeo/AROIValidator

---

## Quick Start

```bash
# 1. Clone code repo
git clone https://github.com/1aeo/AROIValidator.git ~/aroivalidator

# 2. Clone deployment
git clone <this-repo> ~/aroivalidator-deploy
cd ~/aroivalidator-deploy

# 3. Configure
cp config.env.example config.env
nano config.env  # Edit 3 values (see below)

# 4. Install
sudo ./scripts/install.sh

# Done! Visit https://your-domain.com
```

---

## Configuration (config.env)

Edit these 3 values:

```bash
DEPLOY_IP=1.2.3.4                        # Your server IP
DEPLOY_DOMAIN=validator.example.com      # Your domain
DEPLOY_EMAIL=admin@example.com           # Let's Encrypt email
```

Optional:
```bash
CLOUDFLARE_MODE=flexible  # or 'full-strict'
```

**Cloudflare DNS:** Add A record: `your-subdomain` → `your-ip` (gray cloud initially)

---

## What It Does

**Hourly (at :05):**
- Validates ~11,000 Tor relay operator IDs (AROIs)
- Publishes JSON results to website
- Auto-updates code from GitHub

**Monthly (1st at 2 AM):**
- Compresses files 180+ days old (saves 90% space)
- Rotates logs when > 50 MB

**Website:**
- Green theme (1aeo.com style)
- View/Download buttons for all results
- Pagination for 1000s of files
- Historical archive with monthly compression

---

## Commands

```bash
# View logs
tail -f ~/aroivalidator-deploy/logs/cron.log

# Run validation manually  
~/aroivalidator-deploy/scripts/run-batch-validation.sh

# Update code
cd ~/aroivalidator && git pull

# Check status
sudo systemctl status caddy
crontab -l
```

---

## Structure

```
aroivalidator/         Code (git repo)
aroivalidator-deploy/  Deployment (this template)
├── config.env         Your settings (gitignored)
├── configs/           Caddyfile, cron templates
├── scripts/           Automation scripts
├── public/            Web files + JSON results
└── logs/              cron.log
```

---

## Features

✅ Auto-detection (username, paths)  
✅ Cloudflare integration (Flexible or Full Strict SSL)  
✅ fail2ban rate limiting  
✅ Monthly data compression (180 day retention)  
✅ Security headers  
✅ 10 parallel workers  

---

## Troubleshooting

**Website not working?**
```bash
sudo systemctl status caddy
curl -I http://YOUR_IP -H "Host: your-domain.com"
```

**Validation not running?**
```bash
crontab -l | grep aroi
tail ~/aroivalidator-deploy/logs/cron.log
```

**Permission errors?**
```bash
chmod 711 $HOME
chmod 755 ~/aroivalidator-deploy/public
```

---

## Requirements

- Debian/Ubuntu Linux
- Python 3.11+
- Cloudflare account
- DNS configured

---

## Credits

- **AROI Framework:** https://nusenu.github.io/tor-relay-operator-ids-trust-information/
- **1AEO:** https://1aeo.com
- **Tor Project:** https://www.torproject.org

---

## License

Apache 2.0

