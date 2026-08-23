---
name: toastty-send-diagnostics
description: Use this skill when a user asks to send Toastty diagnostics, submit a Toastty diagnostic report, report a Toastty problem to the developer team, or collect and review Toastty support data before sending it.
---

# Toastty Send Diagnostics

Collect a local redacted Toastty diagnostics bundle, review it with the user,
and upload only after the user explicitly approves the reviewed report.

## Environment Contract

This skill supports two entry paths:

- In a Toastty-managed agent session, use the executable at
  `TOASTTY_CLI_PATH`.
- Toastty's **Send Diagnostics…** dialog may provide this skill's absolute file
  path and an exact bundled CLI path. This direct handoff deliberately bypasses
  skill discovery. Use the provided CLI path literally; do not require
  `TOASTTY_SKILLS_ROOT`.

If neither an executable `TOASTTY_CLI_PATH` nor an exact CLI path from the
direct handoff is available, stop. Do not guess a repository checkout, app
installation, global skill directory, plugin cache, or Toastty instance. Report
that `toastty-send-diagnostics must run inside a Toastty-managed agent session
or from Toastty's direct diagnostics handoff`.

## Consent Boundary

The user's initial request to "send Toastty diagnostics" authorizes local
collection, not upload. Always collect and review first. After showing the
review, ask for a new explicit approval before running any command containing
`diagnostics submit --yes`.

- Do not infer post-review approval from the initial request, tool permissions,
  an auto-approval mode, or a previous diagnostics submission.
- Do not submit in the same uninterrupted step as collection and review.
- Include contact text only when the user explicitly provides the text for this
  submission. Never derive contact details from Git configuration, environment
  variables, account metadata, or files.
- Never use `--allow-secret-scan-warning` unless the user separately asks to
  override a reported finding after seeing the warning.

## Collect

1. Resolve `TC` to the exact CLI executable from the environment contract.
2. Choose a concise diagnostics note from the reported Toastty symptom. Do not
   include the conversation transcript, contact information, credentials, or
   unrelated private context. If no symptom was provided, use
   `User requested Toastty diagnostics; symptom not specified.`
3. In one shell invocation, create private per-run probe, doctor, and bundle
   files, then collect diagnostics. Substitute the resolved CLI path and safely
   shell-quote the diagnostics note before running this template:

```bash
TC=<TOASTTY_CLI_SHELL_LITERAL>
DIAGNOSTICS_NOTE=<DIAGNOSTICS_NOTE_SHELL_LITERAL>
TMPBASE="${TMPDIR:-/tmp}"
TMPBASE="${TMPBASE%/}"
umask 077
PROBE="$(mktemp "$TMPBASE/toastty-probe.XXXXXX")"
DOCTOR="$(mktemp "$TMPBASE/toastty-doctor.XXXXXX")"
DIAG="$(mktemp "$TMPBASE/toastty-diag.XXXXXX")"
DOCTOR_EXIT=0
COLLECT_EXIT=0

{
  echo "TOASTTY_CLI_PATH=${TOASTTY_CLI_PATH:-<unset>}"
  command -v toastty claude codex pi opencode mimo mimocode
  type -a claude codex pi opencode mimo mimocode
  ls -la ~/.toastty/bin 2>&1
  echo "PATH=$PATH"
} > "$PROBE" 2>&1

"$TC" --json doctor > "$DOCTOR" || DOCTOR_EXIT=$?

"$TC" diagnostics collect \
  --shell-probe "$PROBE" \
  --note "$DIAGNOSTICS_NOTE" \
  --out "$DIAG" || COLLECT_EXIT=$?

printf '\nTOASTTY_CLI_RESOLVED=%s\n' "$TC"
printf 'TOASTTY_DOCTOR_JSON=%s\n' "$DOCTOR"
printf 'TOASTTY_DOCTOR_EXIT=%s\n' "$DOCTOR_EXIT"
printf 'TOASTTY_DIAGNOSTICS_JSON=%s\n' "$DIAG"
printf 'TOASTTY_DIAGNOSTICS_EXIT=%s\n' "$COLLECT_EXIT"
```

Do not execute the angle-bracket placeholders literally. Replace each entire
placeholder with a shell-single-quoted literal for the resolved value. Preserve
the printed CLI and diagnostics paths
for the later submission; do not rely on shell variables persisting between
tool calls.

### Socket Permission Retry

Before review or any upload approval, inspect the collected bundle's structured
`socket.stat` and `socket.connect` fields. Treat the first result as
permission-limited when either:

- `socket.stat.errnoCode` is `1` (`EPERM`) or `13` (`EACCES`); or
- the target exists and is a Unix socket, and either `socket.state` is
  `permission-denied` or `socket.connect.errnoCode` is `1` or `13`.

In that case, request the narrowest permission the agent runtime supports to
connect to that exact Unix socket while running the exact doctor-and-collection
workflow above, then rerun that workflow once with the same CLI path and note.
This is the only collection retry allowed by this skill. Do not use `sudo`,
change socket permissions, disable sandboxing for the session, restart Toastty,
remove the socket, or select a different Toastty instance.

If the retry produces a complete bundle, use its doctor and diagnostics files
as authoritative, even when it reveals a different socket failure. If it shows
a healthy socket, explain in the review that the first result was limited by
the agent sandbox. If scoped access is unavailable, denied, or the retry is
still permission-limited, stop retrying and describe socket health as
inconclusive rather than stale; use the most recent complete bundle for review.

## Review

Before asking to upload, show the user a concise review containing:

- doctor status and warn/fail checks
- diagnostics path, size, collection exit code, and printed summary
- top-level diagnostics sections
- redaction rules version and redaction count
- log sizes, workspace layout profile summary, updater/layout lifecycle events,
  automation audit count, socket state, and obvious warnings
- a short privacy summary of what remains in cleartext

Base the privacy summary on the diagnostics structure, redaction metadata, and
printed summary. Do not paste the full diagnostics JSON when it is large.
Do not run broad heuristic grep or token scans over the raw JSON unless a
warning, failure, or secret-scan result indicates a problem. Do not recollect
merely to improve the note or for any reason outside the socket permission retry
above.

Then ask whether the user approves sending this exact reviewed file to the
Toastty developer team. Explain that anonymous submission is fine and that the
user may provide name/email if they want follow-up. Explain that supplied
contact text is added to the uploaded note in cleartext.

## Submit After Approval

Only after a new explicit approval, run exactly one submission command using
the literal CLI and diagnostics paths printed by collection:

```text
With user-provided contact:
"<TOASTTY_CLI_RESOLVED>" diagnostics submit --file "<TOASTTY_DIAGNOSTICS_JSON>" --yes --contact "<USER-PROVIDED CONTACT>"

Without contact:
"<TOASTTY_CLI_RESOLVED>" diagnostics submit --file "<TOASTTY_DIAGNOSTICS_JSON>" --yes
```

Shell-quote every substituted value as one argument. Omit `--contact` entirely
when the user did not provide contact text. Do not edit the diagnostics JSON,
re-run collection, or choose another diagnostics file before submitting.

Do not wrap the user-side submit command in `sv exec`, `sudo`, or repository
helpers. The installed Toastty CLI carries its upload configuration.

## Submission Failures

- If the endpoint or upload key is unavailable or unconfigured, show the exact
  error and stop without retrying.
- If submission fails before any request reaches the server specifically
  because hostname resolution failed or the runtime denied network access,
  retry the exact same command at most once with network access allowed only
  for that command. Do not use `sudo`, `sv exec`, disable the sandbox, or change
  the endpoint, file, contact, or other arguments.
- Do not retry HTTP, authentication, TLS, connection-timeout, or other failures
  that could occur after an upload began; the server may already have received
  the report.
- On success, report the returned Toastty diagnostics report ID. Do not paste
  the uploaded bundle into chat.
