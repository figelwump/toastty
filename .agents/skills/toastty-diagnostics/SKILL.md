---
name: toastty-diagnostics
description: Use this skill when listing recent Toastty diagnostics submissions, fetching, saving, or analyzing a submitted Toastty diagnostics report by report ID, or summarizing a local diagnostics JSON file. It retrieves reports through the Toastty diagnostics Worker admin API, summarizes logs, automation audit calls, redaction state, socket health, and avoids exposing admin secrets or dumping full log bodies.
---

# Toastty Diagnostics

## Overview

Use this workflow when a user asks for recent Toastty diagnostics submissions, gives you a report ID, asks what a submitted diagnostics report shows, or wants operator-side analysis of a downloaded diagnostics JSON file.

## Core Flow

1. Treat diagnostics reports as sensitive support data. Do not paste full embedded logs or environment dumps into chat.
2. If the user asks what is new or does not provide a report ID, list recent submissions through the Worker admin API:

```bash
sv exec -- .agents/skills/toastty-diagnostics/scripts/fetch-diagnostics-report.py
```

The list shows report IDs, submission times, expiration times, app/runtime/socket summary, and note/contact preview when provided.

3. If the user provides a report ID, fetch it through the Worker admin API with the bundled helper:

```bash
sv exec -- .agents/skills/toastty-diagnostics/scripts/fetch-diagnostics-report.py TT-YYYYMMDD-ABCDEFGHJKLMNPQR
```

4. If the user provides a local report envelope JSON file, summarize it without network access:

```bash
.agents/skills/toastty-diagnostics/scripts/fetch-diagnostics-report.py --file artifacts/diagnostics/TT-YYYYMMDD-ABCDEFGHJKLMNPQR.json
```

5. Use the helper's printed summary for the first read: app/runtime, socket state, redaction state, log sizes, warning/error-like log lines, and recent automation calls.
6. For deeper analysis, read the saved JSON file and inspect only the relevant sections. Prefer targeted excerpts over raw dumps.

## Access Rules

- The helper expects `TOASTTY_DIAGNOSTICS_ADMIN_KEY` in the environment. Run through `sv exec --` when listing or fetching reports by ID.
- Do not ask the user to paste the admin key.
- The endpoint defaults to `https://toastty-diagnostics.giantthings.workers.dev`. Override with `--endpoint` or `TOASTTY_DIAGNOSTICS_ENDPOINT` for test or staging Workers.
- The helper saves fetched reports under `artifacts/diagnostics/<reportID>.json` by default.
- Treat list note/contact previews as server-curated diagnostics fields: bounded and redacted by the submit/Worker path, but still support data.
- Fetch through the Worker admin endpoint rather than direct R2 credentials unless the Worker is unavailable and the user explicitly asks for lower-level Cloudflare/R2 recovery.

## Analysis Priorities

Start with the report summary, then inspect likely root-cause areas:

- `summary` and `bundle.socket` for app/runtime and automation socket health.
- `bundle.automation.recentRequests` for recent app-control calls, focus-changing actions, caller agent, selector IDs, flags, outcome, and duration.
- `bundle.logs.current.content` for focused warning/error lines near the reported symptom.
- `bundle.redaction` and `summary.secretScanFindings` for privacy state before quoting any content.
- `bundle.probe`, `bundle.shell`, and `bundle.system` only when the issue plausibly depends on shell setup, CLI shims, PATH, or host environment.

## Reporting

In the handoff, include:

- Report ID and saved file path.
- Whether the fetch used the Worker admin API or a local file.
- Key findings and their supporting sections.
- Any missing data that blocks diagnosis.
- A privacy note when quoting report content, especially logs or environment-derived paths.
