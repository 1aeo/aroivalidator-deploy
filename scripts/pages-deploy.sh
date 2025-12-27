#!/usr/bin/env bash
# AROI Validator - Cloudflare Pages Deploy
# Generates wrangler.toml and deploys frontend with Pages Functions.
set -euo pipefail

# Source shared functions and initialize paths
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
init_paths

err() { echo "✗ $1" >&2; exit 1; }

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { echo "Usage: $0 [--dry-run]"; exit 0; }
DRY_RUN=$([[ "${1:-}" == "--dry-run" ]] && echo true || echo false)

# Load config
load_config || err "config.env not found"

# Check dependencies
command -v node &>/dev/null || err "Node.js required (apt install nodejs npm)"
command -v npm &>/dev/null || err "npm required"

# Validate required config
[[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" && "$CLOUDFLARE_ACCOUNT_ID" != "your_account_id_here" ]] || err "CLOUDFLARE_ACCOUNT_ID not set"
[[ -n "${CLOUDFLARE_API_TOKEN:-}" && "$CLOUDFLARE_API_TOKEN" != "your_api_token_here" ]] || {
    [[ -f "$HOME/.config/cloudflare/api_token" ]] && source "$HOME/.config/cloudflare/api_token"
}
[[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || err "CLOUDFLARE_API_TOKEN not set"

# Defaults
: "${PAGES_PROJECT_NAME:=aroivalidator}"
: "${STORAGE_ORDER:=do,r2}"
: "${WRANGLER_COMPATIBILITY_DATE:=2025-12-01}"
: "${CACHE_TTL_LATEST:=60}"
: "${CACHE_TTL_HISTORICAL:=86400}"
: "${DO_SPACES_REGION:=nyc3}"
: "${DO_SPACES_CDN:=false}"

# Build DO URL if not set
if [[ "${DO_ENABLED:-true}" == "true" && -z "${DO_SPACES_URL:-}" && -n "${DO_SPACES_BUCKET:-}" ]]; then
    CDN=$([[ "$DO_SPACES_CDN" == "true" ]] && echo ".cdn" || echo "")
    DO_SPACES_URL="https://${DO_SPACES_BUCKET}.${DO_SPACES_REGION}${CDN}.digitaloceanspaces.com"
fi

# Generate wrangler.toml
log "Generating wrangler.toml..."
{
    echo "name = \"${PAGES_PROJECT_NAME}\""
    echo "compatibility_date = \"${WRANGLER_COMPATIBILITY_DATE}\""
    echo 'pages_build_output_dir = "pages-static"'
    echo ""
    echo "[vars]"
    echo "STORAGE_ORDER = \"${STORAGE_ORDER}\""
    echo "CACHE_TTL_LATEST = \"${CACHE_TTL_LATEST}\""
    echo "CACHE_TTL_HISTORICAL = \"${CACHE_TTL_HISTORICAL}\""
    if [[ -n "${DO_SPACES_URL:-}" ]]; then
        echo "DO_SPACES_URL = \"${DO_SPACES_URL}\""
    fi
    echo ""
    if [[ "${R2_ENABLED:-true}" == "true" && -n "${R2_BUCKET:-}" ]]; then
        echo "[[r2_buckets]]"
        echo 'binding = "AROI_BUCKET"'
        echo "bucket_name = \"${R2_BUCKET}\""
    else
        echo "# R2 disabled"
    fi
} > "$DEPLOY_DIR/wrangler.toml"

# Prepare static directory
STATIC_DIR="$DEPLOY_DIR/pages-static"
mkdir -p "$STATIC_DIR"
cp -f "$DEPLOY_DIR/public/index.html" "$STATIC_DIR/"

log "Project: $PAGES_PROJECT_NAME | Storage: $STORAGE_ORDER"
log "DO: ${DO_SPACES_URL:-disabled} | R2: ${R2_BUCKET:-disabled}"
log "Static: $(du -sh "$STATIC_DIR" | cut -f1)"

[[ "$DRY_RUN" == "true" ]] && { log "Dry run - skipping deploy"; exit 0; }

# Deploy
export CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID
cd "$DEPLOY_DIR"

WRANGLER=$(command -v wrangler 2>/dev/null || echo "npx wrangler")
log "Deploying..."
$WRANGLER pages deploy "$STATIC_DIR" --project-name="$PAGES_PROJECT_NAME" --branch=production --commit-dirty=true

echo ""
log "✅ Deployed: https://${PAGES_PROJECT_NAME}.pages.dev"
[[ -n "${CUSTOM_DOMAIN:-}" ]] && log "   Custom: https://$CUSTOM_DOMAIN"
