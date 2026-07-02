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
manually. `TOASTTY_DIAGNOSTICS_ADMIN_BASE_URL` is a non-secret Worker variable
used to build notification admin URLs; keep it pinned to the trusted Worker
origin rather than deriving links from request host headers.

Add an R2 lifecycle deletion rule for the `reports/` prefix. Keep the retention
window aligned with `RETENTION_DAYS` in `wrangler.jsonc`; the JSON
`expiresAtMs` field is only metadata and does not delete objects by itself.

## Accessing Reports

Submitted reports are private R2 objects. Fetch them through the Worker admin
endpoint with `TOASTTY_DIAGNOSTICS_ADMIN_KEY`; do not expose direct R2
credentials to agent sessions.

List recent submissions:

```bash
ENDPOINT="https://toastty-diagnostics.giantthings.workers.dev"

sv exec -- sh -c '
  curl -fsS \
    -H "x-toastty-admin-key: $TOASTTY_DIAGNOSTICS_ADMIN_KEY" \
    "$0/v1/diagnostics?limit=25"
' "$ENDPOINT"
```

The list response is summary-only. It includes report IDs, submission and
expiration times, optional admin URLs, app/runtime/socket summary fields, and
the diagnostics note preview when present. It does not include the full
diagnostics bundle, raw logs, environment values, or secret-scan finding
details. If the response has `incomplete: true`, the Worker hit its internal R2
scan cap and the list may omit older reports.

Fetch a full report by ID:

```bash
REPORT_ID="TT-20260701-ABCDEFGHJKLMNPQR"
ENDPOINT="https://toastty-diagnostics.giantthings.workers.dev"

sv exec -- sh -c '
  curl -fsS \
    -H "x-toastty-admin-key: $TOASTTY_DIAGNOSTICS_ADMIN_KEY" \
    "$0/v1/diagnostics/$1" \
    -o "artifacts/diagnostics/$1.json"
' "$ENDPOINT" "$REPORT_ID"
```

Inside Toastty agent sessions, prefer the repo-local operator skill:

```bash
sv exec -- .agents/skills/toastty-diagnostics/scripts/fetch-diagnostics-report.py
sv exec -- .agents/skills/toastty-diagnostics/scripts/fetch-diagnostics-report.py "$REPORT_ID"
```

The no-argument form lists recent submissions. The report-ID form fetches and
saves the admin response JSON envelope containing `reportID`, `summary`, and the
full submitted `bundle`.

## Notifications

If `TOASTTY_DIAGNOSTICS_NOTIFY_WEBHOOK_URL` is configured, the Worker posts a
summary-only notification after storing a report:

```json
{
  "type": "toastty.diagnostics.submitted",
  "reportID": "TT-20260701-ABCDEFGHJKLMNPQR",
  "adminURL": "https://toastty-diagnostics.giantthings.workers.dev/v1/diagnostics/TT-20260701-ABCDEFGHJKLMNPQR",
  "skillPrompt": "Use $toastty-diagnostics to fetch and summarize TT-20260701-ABCDEFGHJKLMNPQR.",
  "summary": {
    "appVersion": "0.1.0",
    "build": "1",
    "runtimeLabel": "toastty-prod",
    "socketState": "healthy",
    "redactionRulesVersion": 1,
    "redactedKeyCount": 12,
    "secretScanOverride": false,
    "secretScanFindingCount": 0
  }
}
```

The notification omits freeform user notes, raw logs, environment values, and
secret-scan finding details. Route this webhook to Slack, email, or another
operator inbox as needed; the `adminURL` still requires `x-toastty-admin-key`.
If `TOASTTY_DIAGNOSTICS_ADMIN_BASE_URL` is not configured, the notification is
still sent with `reportID`, `skillPrompt`, and `summary`, but without
`adminURL`.

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
