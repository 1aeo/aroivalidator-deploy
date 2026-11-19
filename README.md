# AROI Validator - Deployment

Validates ~11,000 Tor relay operator IDs hourly. Supports **CIISS ContactInfo
specification versions 2** (RSA-fingerprint proofs) and **3** (ed25519
family-ID proofs).

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

**Optional:**
```bash
CIISS_VERSIONS=2,3         # CIISS spec versions to validate (default: 2,3)
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

## Locks & Logs

The hourly run holds `logs/validation.lock` only for the code update, validation
and publishing to `public/` (about a minute). Uploads start after it is released,
each under its own provider lock, so a slow upload (e.g. the daily backups in the
first upload of the day) no longer makes the next hour skip validation or the
code update.

| Lock (`logs/`) | Held by | When busy |
|----------------|---------|-----------|
| `validation.lock` | update + validation + publish | run exits `Already running (... pid N, since T)` |
| `public.lock` | publish step, `compress-old-data.sh`, upload snapshot (< 1 s) | waits (publish and snapshot 15 min, compress 1 h) |
| `upload-do.lock`, `upload-r2.lock` | `upload-do.sh`, `upload-r2.sh` incl. backups (also manual runs) | upload skipped; the next run syncs everything |
| `prune.lock` | `prune-backups.sh` | prune skipped |

Lock files hold the holder's `pid start-time` and are never deleted.

Nothing in `public/` is written in place: files reach it by rename from `tmp/`.
Each upload syncs a hard-link snapshot of `public/` (`tmp/upload-do.snap/`,
`tmp/upload-r2.snap/`) taken under `public.lock`, so it always uploads one
complete publish, and a publish during a long upload cannot change a file rclone
is reading (which made rclone fail it as `corrupted on transfer` and skip
deletions). Newer results go up with the next upload. The snapshot is removed
when rclone finishes; one left by a killed upload is removed by the next upload
to the same provider. If a snapshot cannot be removed, the upload logs a
`WARNING` and syncs `public/` directly until it is gone.

Temp files an interrupted publish leaves in `tmp/` are removed by the next
publish or compress once it holds `public.lock` (logged as `Removed N leftover
temp file(s) from tmp/`); snapshot directories are left alone.

Per run, `cron.log` shows:

```
HEAD is now at 6e070ff ...                     # code update succeeded
WARNING: code update failed at 'git fetch origin main' (exit 128): ... - running existing checkout
Code: 6e070ff <subject> (origin/main 6e070ff)  # code that ran; full SHA is passed to the validator as AROIVALIDATOR_COMMIT
Note: validating while DO upload (pid 889905, since 2026-10-12 00:00:31) is still running
Validation + publish done in 41s, validation lock released
↷ skipping DO upload: previous still running (pid 889905, since 2026-10-12 00:00:31) [batch 01:00:01]
✓ R2 (95s) [batch 01:00:01]
=== Complete Mon Oct 12 01:02:37 AM PDT 2026 [batch 01:00:01] ===
```

Lines after the lock is released are tagged `[batch HH:MM:SS]` (the run's start
time), because a run waiting on a long upload can finish after the next run starts.

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
