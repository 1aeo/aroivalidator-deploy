# AROI Validator - Deployment

Validates ~11,000 Tor relay operator IDs hourly.

**Live:** https://aroivalidator.pages.dev  
**Code:** https://github.com/1aeo/AROIValidator

---

## Quick Start

```bash
# Clone repos
git clone https://github.com/1aeo/AROIValidator.git ~/aroivalidator
git clone <this-repo> ~/aroivalidator-deploy
cd ~/aroivalidator-deploy

# Configure
cp config.env.example config.env
nano config.env

# Install
./scripts/install.sh
```

---

## Hosting Options

### Option 1: Cloudflare Pages (Default)

Static frontend on Pages, JSON data on DO Spaces/R2.

**Required in config.env:**
```bash
CLOUDFLARE_ACCOUNT_ID=xxx
CLOUDFLARE_API_TOKEN=xxx
DO_SPACES_KEY=xxx          # Primary storage
DO_SPACES_SECRET=xxx
R2_ACCESS_KEY_ID=xxx       # Backup storage
R2_SECRET_ACCESS_KEY=xxx
```

**Deploy:**
```bash
./scripts/pages-deploy.sh
```

### Option 2: Caddy (Self-hosted Fallback)

```bash
# config.env
DEPLOY_IP=1.2.3.4
DEPLOY_DOMAIN=validator.example.com
DEPLOY_EMAIL=admin@example.com

# Install
sudo ./scripts/install.sh --caddy
```

---

## Automation

| Schedule | Task |
|----------|------|
| Hourly :05 | Validate relays, upload to cloud |
| Monthly 1st | Compress data >180 days old |

---

## Commands

```bash
# Manual validation
./scripts/run-batch-validation.sh

# Upload to cloud
./scripts/upload-do.sh
./scripts/upload-r2.sh

# Deploy frontend
./scripts/pages-deploy.sh

# View logs
tail -f logs/cron.log
```

---

## Structure

```
~/aroivalidator/           # Code (validator)
~/aroivalidator-deploy/    # This repo
├── config.env             # Your settings (gitignored)
├── scripts/               # Automation
├── functions/             # Pages Function (data proxy)
├── public/                # Local JSON results
└── logs/                  # cron.log
```

---

## Cache

| File | TTL |
|------|-----|
| `latest.json` | 60s |
| `aroi_validation_*.json` | 1 year (immutable) |

---

## License

Apache 2.0
