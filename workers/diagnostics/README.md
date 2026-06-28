# Toastty Diagnostics Worker

This package receives explicitly submitted Toastty diagnostics bundles and stores
them in Cloudflare R2. It intentionally lives inside the Toastty repo so Worker
code, CLI submit behavior, tests, and privacy docs evolve together.

## Local Setup

```bash
cd workers/diagnostics
npm install
npm run check
```

Local tests use the `test` Wrangler environment and dummy keys from
`wrangler.jsonc`. Production secrets are not committed.

## Cloudflare Setup

Use the same Cloudflare account you use for other projects, but create
Toastty-specific resources:

```bash
cd workers/diagnostics
npx wrangler login
npx wrangler r2 bucket create toastty-diagnostics-prod
npx wrangler secret put TOASTTY_DIAGNOSTICS_UPLOAD_KEY
npx wrangler secret put TOASTTY_DIAGNOSTICS_ADMIN_KEY
npx wrangler secret put TOASTTY_DIAGNOSTICS_NOTIFY_WEBHOOK_URL # optional
npx wrangler deploy
```

Add an R2 lifecycle deletion rule for the `reports/` prefix. Keep the retention
window aligned with `RETENTION_DAYS` in `wrangler.jsonc`; the JSON
`expiresAtMs` field is only metadata and does not delete objects by itself.

## CLI Configuration

For local development, run submit with environment values:

```bash
TOASTTY_DIAGNOSTICS_ENDPOINT=http://127.0.0.1:8787 \
TOASTTY_DIAGNOSTICS_UPLOAD_KEY=test-upload-key \
toastty diagnostics submit --file /path/to/toastty-diag.json --yes
```

For releases, inject the endpoint and upload key at `tuist generate` time:

```bash
TUIST_TOASTTY_DIAGNOSTICS_ENDPOINT=https://<worker-host> \
TUIST_TOASTTY_DIAGNOSTICS_UPLOAD_KEY=<upload-key> \
tuist generate
```

The upload key is spam friction, not a strong secret once embedded in a shipped
CLI binary.
