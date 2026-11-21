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

Static frontend on Pages, JSON data on DO Spaces and Cloudflare R2.

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
BATCH_QUIET=true           # Suppress per-relay progress lines in cron.log
ZSTD_LEVEL=12              # Monthly zstd backup compression level (1-19)
ZSTD_LONG=27               # Monthly zstd --long window exponent (10-27)
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

## Automation & Storage Model

Every hourly validation result (`aroi_validation_YYYYMMDD_HHMMSS.json`) is kept
available directly on the website from **both** DO Spaces and Cloudflare R2, and
backed up in highly compressed monthly `zstd --long=27` archives (`aroi-YYYYMM.tar.zst`
+ `aroi-YYYYMM.list`) across local disk (`local-archive/`) and remote `_backups/`:

| Location | Contents | Retention / Notes |
|----------|----------|-------------------|
| DO Spaces root | All uncompressed hourly JSONs + `latest.json` + `files.json` | Hourly JSONs: append-only `rclone copy --no-traverse --ignore-existing`; `latest.json` & `files.json`: copied separately without `--ignore-existing` |
| Cloudflare R2 root | Identical copy of all hourly JSONs + `latest.json` + `files.json` | Hourly JSONs: append-only `rclone copy --no-traverse --ignore-existing`; `latest.json` & `files.json`: copied separately without `--ignore-existing` |
| DO Spaces `_backups/` & R2 `_backups/` | `aroi-YYYYMM.tar.zst` + `aroi-YYYYMM.list` | Uploaded daily for current month, finalized on month rollover |
| Local `local-archive/` | `aroi-YYYYMM.tar.zst` + `aroi-YYYYMM.list` | Complete compressed local history (~3.5 MiB/month) |
| Local `public/` | `latest.json`, `files.json`, and current month's hourly JSONs | Completed months removed only after 3-copy verification |
| `~/aroivalidator/validation_results/` | `latest.json` only | Published JSONs are moved into `public/` atomically |

| Schedule | Task |
|----------|------|
| Hourly (`run-batch-validation.sh`) | Validate relays, move new JSONs to `public/`, rebuild full `files.json`, append-only copy to DO/R2, refresh daily zstd archive once/day |
| Monthly 1st 02:00 (`compress-old-data.sh`) | Archive/verify completed months, rotate `cron.log` (>50 MB) to `logs/archives/*.log.zst`, verify 3-copy parity before cleaning `public/` |

---

## Commands

```bash
# Manual validation + upload
./scripts/run-batch-validation.sh

# Append-only upload to cloud (or --full-copy / --upload-backups [YYYYMM])
./scripts/upload-do.sh
./scripts/upload-r2.sh

# Build/refresh zstd monthly archives and verify completed-month cleanup
./scripts/compress-old-data.sh

# Verify parity across local-archive, public, DO Spaces, and R2 (add --fix to backfill)
./scripts/verify-sync.sh
./scripts/verify-sync.sh --verify-zstd

# Clean legacy timestamped uncompressed backup directories (never touches aroi-*.tar.zst)
./scripts/prune-backups.sh --dry-run

# Deploy frontend
./scripts/pages-deploy.sh

# View logs
tail -f logs/cron.log
```

---

## Locks & Logs

The hourly run holds `logs/validation.lock` only for the code update, validation
and publishing to `public/` (about a minute). Uploads start after it is released,
each under its own provider lock using per-provider ledgers (`logs/uploaded-do.txt`
and `logs/uploaded-r2.txt`) and `--files-from --no-traverse`, so uploads complete in
seconds without traversing historical objects or `_backups/`.

| Lock (`logs/`) | Held by | When busy |
|----------------|---------|-----------|
| `validation.lock` | update + validation + publish | run exits `Already running (... pid N, since T)` |
| `public.lock` | publish step, `compress-old-data.sh` snapshot/cleanup, upload snapshot (< 1 s) | waits (publish and snapshot 15 min, compress 1 h) |
| `cron-log.lock` | `run-batch-validation.sh` (shared), `cron.log` rotation (exclusive) | waits up to 300 s (on timeout, batch warns and runs unlocked, so concurrent rotation could drop lines) |
| `compress.lock` | `compress-old-data.sh` | duplicate compress exits cleanly |
| `upload-do.lock`, `upload-r2.lock` | `upload-do.sh`, `upload-r2.sh` | live upload skipped; backup uploads wait up to 5 min |
| `prune.lock` | `prune-backups.sh` | prune skipped |

Lock files hold the holder's `pid start-time` and are never deleted.

Nothing in `public/` is written in place: publish steps stage `.aroi-tmp.*` files
directly on `public/`'s filesystem and atomically rename them into place.
Each live upload takes a hard-link snapshot of `public/` (`tmp/upload-do.snap/`,
`tmp/upload-r2.snap/`) under `public.lock`. The snapshot is removed when rclone
finishes; one left by a killed upload is removed by the next upload to the same
provider.

Temp files an interrupted publish leaves in `tmp/` are removed by the next
publish or compress once it holds `public.lock` (logged as `Removed N leftover
temp file(s) from tmp/`); snapshot directories are left alone.

Per run, `cron.log` shows:

```
HEAD is now at 6e070ff ...                     # code update succeeded
Code: 6e070ff <subject> (origin/main 6e070ff)  # code that ran; full SHA is passed to the validator as AROIVALIDATOR_COMMIT
Validation + publish done in 35s, validation lock released
=== Cloud Upload [batch 08:00:01] ===
✓ DO (2s) [batch 08:00:01]
✓ R2 (2s) [batch 08:00:01]
=== Complete Sat Nov 21 08:00:39 AM PST 2026 [batch 08:00:01] ===
```

Lines after the lock is released are tagged `[batch HH:MM:SS]` (the run's start
time), because a run waiting on a long upload can finish after the next run starts.

---

## Structure

```
~/aroivalidator/           # Code (validator)
~/aroivalidator-deploy/    # This repo
├── config.env             # Your settings (gitignored)
├── scripts/               # Automation, archival & parity verification
├── functions/             # Pages Function (data proxy)
├── local-archive/         # Monthly zstd --long=27 archives + .list manifests
├── public/                # Local current-month JSONs, latest.json, files.json
└── logs/                  # cron.log, upload ledgers, lock files, log archives
```

---

## Cache

| File | TTL |
|------|-----|
| `latest.json`, `files.json` | 60s |
| `aroi_validation_*.json` | 1 year (immutable) |

---

## License

Apache 2.0
