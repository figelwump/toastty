---
name: toastty-debug
description: Use this skill when debugging Toastty bugs, crashes, regressions, logs, runtime state, ambiguous running instances, production-vs-worktree target selection, or focused repro plans. It guides log discovery, instance.json targeting, hypothesis-driven debugging, instrumentation, remote/local GUI repro routing, and cleanup.
---

# Toastty Debug

## Overview

Use this workflow to identify the exact Toastty target, gather the right logs/runtime state, and choose a focused repro path before changing code. Keep deterministic validation in `.agents/skills/toastty-verify/SKILL.md`; use this skill for investigation and diagnosis.

## Core Workflow

1. Answer the user's diagnostic question first when they ask what happened or report expected behavior. Do not change code until they ask you to proceed.
2. Identify the target being debugged: production/installed app, current worktree run, named worktree run, Xcode run, smoke/dev run, or an unknown running instance.
3. Resolve the target's log path and runtime state before reading broad process lists.
4. Form 2-3 plausible hypotheses for non-obvious bugs and collect discriminating evidence before choosing a fix direction.
5. Prefer scoped instrumentation when logs are insufficient; remove or downgrade noisy diagnostics after they serve their purpose.
6. After a fix, use `.agents/skills/toastty-verify/SKILL.md` to choose validation, then explain root cause and resolution.

## Target And Log Decision Tree

### Production Or Installed Toastty

Use the production log only when the user clearly means the installed app, or when worktree/runtime-isolated targets have been ruled out:

```text
~/Library/Logs/Toastty/toastty.log
```

Production logs rotate under `~/Library/Logs/Toastty/`.

### Named Worktree, Xcode, Dev, Or Smoke Run

Worktree/Xcode/dev/smoke runs use runtime isolation. Resolve `instance.json` in that worktree and read `logFilePath`.

If the user names a worktree, start from:

```text
<worktree>/artifacts/dev-runs/worktree-*/runtime-home/instance.json
```

For Xcode-launched Toastty runs, assume runtime isolation is active unless there is evidence otherwise. Xcode `Release` configuration is still a worktree run when launched from the generated scheme; do not treat it as production logging.

`instance.json` is authoritative for `pid`, `bundlePath`, `runtimeHomePath`, `logFilePath`, `socketPath`, `derivedPath`, and `worktreeRootPath`. Validate the PID is alive before using the instance for GUI or socket work.

When `logFilePath` is present, derive the rotated log sibling from that path by replacing its extension with `.previous.log`; do not assume the default runtime-home log directory if `TOASTTY_LOG_FILE` was overridden. For example:

```text
<logFilePath without extension>.previous.log
```

### Ambiguous Target

Default to the current worktree's runtime-isolated instance. Look under:

```text
artifacts/dev-runs/worktree-*/runtime-home/instance.json
```

If the instance is stale or still ambiguous, inspect running Toastty processes:

```bash
pgrep -af Toastty
```

Use `lsof -p <pid>` only after narrowing to a likely PID, then find open `toastty.log` paths. Avoid app-name-only targeting when multiple Toastty instances may be running.

## Repro And Evidence Routing

Use the smallest repro path that can distinguish the hypotheses.

- For live app instance setup, runtime isolation, PID targeting, local Peekaboo, or foreground-capable remote validation, use `.agents/skills/toastty-dev-run/SKILL.md`.
- For supported smoke checks, shortcut traces, remote xcodebuild tests, and validation reporting, use `.agents/skills/toastty-verify/SKILL.md` and `docs/agents/automation.md`.
- For human-like remote GUI interaction beyond smoke coverage, use `.agents/skills/toastty-computer-use/SKILL.md`.
- For menu rebuilds, hidden system menu items, workspace shortcuts, or `Cmd+W` behavior, read `docs/agents/menu-performance.md` before choosing experiments or fixes.
- For local Peekaboo or GUI scripting permission preflight and caveats, follow `.agents/skills/toastty-dev-run/SKILL.md` and `docs/agents/manual-interaction.md` instead of inventing a local workaround.

## Useful Logging Controls

- `TOASTTY_LOG_LEVEL`: adjust verbosity for a scoped run.
- `TOASTTY_LOG_FILE`: override the log path; `none` disables file logging.
- `TOASTTY_LOG_STDERR=1`: mirror logs to stderr for foreground launches.
- `TOASTTY_LOG_DISABLE=1`: disable logging.

Prefer per-run log paths for trace-style runs instead of shared files. Keep temporary verbosity scoped to the suspect path and remove it before handoff unless it is intentionally retained.

## Debug Handoff

Report:

- Target type and how it was resolved.
- `instance.json` path or production log path used.
- Whether the PID was alive when inspected.
- Key log lines or state evidence, summarized without dumping large logs.
- Hypotheses considered and the evidence that selected or rejected them.
- Repro path used, including local/remote target and artifact paths.
- Any temporary instrumentation added, removed, or intentionally retained.
