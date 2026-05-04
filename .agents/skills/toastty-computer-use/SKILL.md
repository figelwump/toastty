---
name: toastty-computer-use
description: Use this skill when a Toastty GUI bug, fix, or uncertainty needs human-like remote Computer Use interaction beyond the supported smoke tests, such as modal navigation, visual/focus checks, menu flows, onboarding, or reproducing ambiguous user reports with scripts/remote/computer-use-run.sh.
---

# Toastty Computer Use

Use this workflow for opportunistic GUI debugging and verification on the remote Mac when socket automation and smoke tests do not cover the interaction well.

This is not a CI-style assertion framework. A `pass` result means the Codex turn completed; only claim product verification when the transcript or final report contains the evidence you requested.

## When to use this

- A GUI issue needs human-like navigation, judgment, or visual inspection.
- The flow involves modal sheets, onboarding, menus, focus, selection, drag-like interaction, or ambiguous reproduction steps.
- The existing smoke tests are too narrow or brittle for the behavior, and local foreground inspection would be disruptive.

Prefer `scripts/remote/validate.sh --smoke-test ...` when a supported smoke test covers the path. Use `.agents/skills/toastty-dev-run/SKILL.md` for ordinary live app launches, local Peekaboo checks, and deterministic remote smoke validation.

## Before running

1. Inspect the relevant diff or files and write down the exact behavior you need evidence for.
2. Run `git status --short` and choose the validation scope deliberately:
   - `working-tree`: current uncommitted local changes. Use this for validating a fix before commit.
   - `head`: the current commit only. Prefer this for baseline checks.
   - `ref --ref <rev>`: an explicit branch, tag, or commit.
3. Pick a short run label: `<task-id-or-area>-<short-description>`.
4. Create a prompt under `artifacts/manual/computer-use/<run-label>.md`.

Use `sv exec --` for the runner so the remote GUI environment and any required service-managed configuration are injected. Do not probe `TOASTTY_REMOTE_GUI_HOST` outside `sv exec`.

## Prompt templates

Start from one of these templates:

- `assets/ad-hoc-gui-check.md`: repro, verify-fix, or exploratory GUI checks.
- `assets/visual-inspection.md`: visual, layout, focus, and text/label inspection.

Keep the prompt focused on 1-3 high-signal scenarios. The boundaries in the templates apply to the remote Computer Use turn, not to your local agent work.

## Run

From the repo root:

```bash
mkdir -p artifacts/manual/computer-use

sv exec -- scripts/remote/computer-use-run.sh \
  --scope working-tree \
  --run-label "<task-id-or-area>-<short-description>" \
  --timeout-seconds 600 \
  --prompt-file artifacts/manual/computer-use/<task-id-or-area>-<short-description>.md
```

Use `--scope head` or `--scope ref --ref <rev>` when that better matches the question.

Typical timeout guidance:

- `300`: one short inspection or simple repro.
- `600`: multi-step modal/menu verification.
- `900`: longer exploratory debugging. Prefer tightening the prompt before going higher.

## Inspect results

Artifacts are copied back to `artifacts/remote-gui/<run-label>/`.

Decision tree:

1. Read `result.json` first.
2. If `status` is `setup_error`, inspect `client-summary.json`, `remote/build.log`, `remote/app-server.log`, and `remote/app-server-session.log`.
3. If `status` is `timeout`, treat artifacts as partial. Inspect `remote/launch.json`, `remote/transcript.jsonl`, and `remote/app.log`.
4. If `status` is `agent_error`, inspect `client-summary.json.failureReason` and `remote/transcript.jsonl`.
5. If `status` is `pass`, confirm `client-summary.json.finalText` or `remote/transcript.jsonl` contains the requested evidence. If the evidence is missing, report the run as inconclusive.

Useful files:

- `result.json`: top-level status, model info, timing, and artifact index.
- `client-summary.json`: Codex app-server turn summary and failure reason.
- `remote/transcript.jsonl`: JSON-RPC transcript and Computer Use tool events.
- `remote/app.log`: Toastty runtime log for the isolated app instance.
- `remote/build.log`: remote build log.
- `remote/launch.json`: PID, runtime home, socket path, and app-server details.

## Handoff

Report:

- Scope and run label.
- Result status.
- Whether the behavior was reproduced, verified, not reproduced, or inconclusive.
- Exact visible UI evidence and any uncertainty.
- Artifact path, for example `artifacts/remote-gui/<run-label>/result.json`.

Do not turn an inconclusive Computer Use run into a claimed verification. If more confidence is needed, tighten the prompt, add an app-side assertion, or fall back to a deterministic smoke/test path.
