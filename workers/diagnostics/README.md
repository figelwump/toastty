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
Toastty-specific resources. The helper expects Toastty-specific `sv` keys and
maps them to Wrangler's generic Cloudflare environment names only for the child
process:

```bash
sv exec -- ./scripts/deploy/diagnostics-worker.sh
```

Required for deploy: `TOASTTY_CLOUDFLARE_API_TOKEN`,
`TOASTTY_DIAGNOSTICS_UPLOAD_KEY`, and `TOASTTY_DIAGNOSTICS_ADMIN_KEY`.
`TOASTTY_CLOUDFLARE_ACCOUNT_ID` is recommended to avoid account ambiguity.
`TOASTTY_DIAGNOSTICS_NOTIFY_WEBHOOK_URL` is optional; if a webhook secret was
previously uploaded and you later remove it from `sv`, delete the Worker secret
manually.

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
sv exec -- tuist generate
```

After the first deploy, set `TUIST_TOASTTY_DIAGNOSTICS_ENDPOINT` in `sv` to the
Worker URL printed by Wrangler, for example
`https://toastty-diagnostics.giantthings.workers.dev`.

The upload key is spam friction, not a strong secret once embedded in a shipped
CLI binary.
