#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
WORKER_DIR="$ROOT_DIR/workers/diagnostics"
BUCKET_NAME="toastty-diagnostics-prod"

require_env() {
  local name="$1"
  local value="${!name:-}"
  if [[ -z "$value" ]]; then
    echo "error: ${name} is required" >&2
    exit 78
  fi
}

put_secret() {
  local name="$1"
  local value="$2"
  local file="$SECRET_DIR/$name"

  printf '%s' "$value" >"$file"
  npx wrangler secret put "$name" --env="" <"$file"
  rm -f "$file"
}

require_env TOASTTY_CLOUDFLARE_API_TOKEN
require_env TOASTTY_DIAGNOSTICS_UPLOAD_KEY
require_env TOASTTY_DIAGNOSTICS_ADMIN_KEY

export CLOUDFLARE_API_TOKEN="$TOASTTY_CLOUDFLARE_API_TOKEN"
if [[ -n "${TOASTTY_CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
  export CLOUDFLARE_ACCOUNT_ID="$TOASTTY_CLOUDFLARE_ACCOUNT_ID"
fi

cd "$WORKER_DIR"

if ! npx wrangler r2 bucket create "$BUCKET_NAME"; then
  echo "warning: failed to create ${BUCKET_NAME}; verifying that the bucket is accessible" >&2
  npx wrangler r2 bucket info "$BUCKET_NAME" >/dev/null
fi

npm run check
# Wrangler v4 targets the top-level config when passed an empty environment.
# The local package-lock pins the Wrangler version used by npx here.
npx wrangler deploy --env=""

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
SECRET_DIR="$(mktemp -d "$TMP_BASE/toastty-diagnostics-secrets.XXXXXX")"
chmod 700 "$SECRET_DIR"
trap 'rm -rf "$SECRET_DIR"' EXIT

put_secret TOASTTY_DIAGNOSTICS_UPLOAD_KEY "$TOASTTY_DIAGNOSTICS_UPLOAD_KEY"
put_secret TOASTTY_DIAGNOSTICS_ADMIN_KEY "$TOASTTY_DIAGNOSTICS_ADMIN_KEY"
if [[ -n "${TOASTTY_DIAGNOSTICS_NOTIFY_WEBHOOK_URL:-}" ]]; then
  put_secret TOASTTY_DIAGNOSTICS_NOTIFY_WEBHOOK_URL "$TOASTTY_DIAGNOSTICS_NOTIFY_WEBHOOK_URL"
else
  echo "TOASTTY_DIAGNOSTICS_NOTIFY_WEBHOOK_URL is not set; skipping notification webhook secret"
fi
