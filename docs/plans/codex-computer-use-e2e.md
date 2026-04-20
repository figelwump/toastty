# toastty codex computer use e2e

Date: 2026-04-20
Updated: 2026-04-20

This document captures the working context and decisions from the remote
validation thread that led into the `codex/computer-use-e2e` worktree. The
goal is to preserve the architecture discussion in-repo so the next
implementation pass does not depend on chat history.

## summary

1. The goal of this project is to replace Peekaboo-driven GUI validation for
   hard-to-automate UI paths with Codex Computer Use running on the Mac mini.
2. The Mac mini should remain the dedicated GUI worker so validation stops
   stealing focus, keyboard, mouse, and CPU from the main development machine.
3. Remote smoke validation is already shipped separately and should remain a
   companion system. It solves deterministic automation; Computer Use should
   target the UI paths that are awkward or unreliable there.
4. The existing remote transport and provisioning layer should be reused:
   disposable remote worktree, remote build/launch, artifact copy-back, and a
   stable result bundle contract.
5. Assume one active GUI Computer Use job per logged-in Mac mini session until
   proven otherwise. Do not design v1 around concurrent GUI runs on the same
   desktop.
6. The first slice should prove one realistic end-to-end Computer Use flow on
   the Mac mini before building a large orchestration layer.

## current baseline on main

The following work is already landed on `main` and available in this worktree:

- `scripts/remote/validate.sh` is the primary remote validation wrapper.
- Remote smoke tests currently supported:
  - `smoke-ui`
  - `workspace-tabs`
  - `shortcut-hints`
  - `shortcut-trace`
- Remote smoke runs create disposable remote worktrees, run on the Mac mini,
  and copy artifacts back under `artifacts/remote-gui/<run-label>/`.
- Remote validation defaults to the `toastty-mini` SSH alias and the Mini repo
  root configured through env:
  - `TOASTTY_REMOTE_GUI_HOST=toastty-mini`
  - `TOASTTY_REMOTE_GUI_REPO_ROOT=/Users/agents/GiantThings/repos/toastty`
- The current merged baseline commit for this worktree is `ff96884`.

Known Mini-specific issue at handoff time:

- `shortcut-trace` is still flaky on the Mini because `System Events` can fail
  with `-25200` while injecting shortcuts over SSH.
- `smoke-ui`, `workspace-tabs`, and `shortcut-hints` passed on the merged
  branch.
- This is relevant to Computer Use because it confirms the Mini GUI session is
  still the main source of nondeterminism, not the remote worktree transport.

## user constraints and decisions from the thread

- The user explicitly wants to move away from Peekaboo because it has been
  unreliable.
- The user wants GUI validation to run on the Mac mini rather than the main
  workstation.
- The user is open to running smoke validation on the Mini as well, and that
  work has already been completed.
- The user is not using PRs for this project; merges happen locally.
- The user wants the ability to validate changes, validate release candidates,
  and run requested checks on demand.
- The user is interested in parallelism overall, but the current working
  assumption is still one active Computer Use job per Mini session.

## working architecture

The architecture agreed in the thread was:

```text
local agent / orchestrator
  -> SSH to Mac mini
    -> disposable remote worktree
      -> build + launch Toastty
      -> start Computer Use driven test
      -> collect JSON result + screenshots + logs
      -> copy artifacts back
```

Important boundaries:

- The Mac mini should own the app process, GUI session, build tools, and any
  Computer Use interaction with the desktop.
- The local machine should own orchestration, diff selection, and result
  inspection.
- The remote wrapper should stay dumb and reliable. The result bundle contract
  matters more than rich live control in v1.

## execution options considered

### option a: codex app computer use on the mac mini

This was the most realistic first path discussed in the thread.

- Best fit if a manual or semi-manual prototype is acceptable.
- Matches the desire to use Codex Computer Use specifically on macOS.
- Avoids prematurely committing to undocumented or unstable automation hooks.

Limitations captured during planning:

- At the time of the thread, the working assumption was that Computer Use is
  primarily exposed through the Codex app workflow on macOS.
- Fully unattended triggering was not treated as proven for the Codex app path.

### option b: codex app-server or codex exec first

This was intentionally not the chosen first slice.

- `codex exec` is attractive for scripting, but the thread did not lock in a
  documented Computer Use flow through it.
- `app-server` adds protocol and lifecycle complexity too early.
- If these paths become clearly supported for Computer Use, they can replace
  parts of the local-runner design later.

### option c: custom computer use harness

This remains the fallback if full unattended execution becomes a hard
requirement and the Codex app path is not a clean fit.

- More flexible.
- More engineering work.
- Should only be chosen after confirming the Codex app path is insufficient.

## recommended first implementation slice

The recommended v1 slice from the thread was:

1. Reuse the existing remote transport/provisioning model from
   `scripts/remote/validate.sh`.
2. Add a Computer Use specific runner path without overloading the current
   smoke script contract too early.
3. Prove one narrow Toastty UI flow on the Mini with Codex Computer Use.
4. Write a stable result bundle with JSON summary, screenshots, and raw logs.
5. Only after that prototype works, decide whether to invest in unattended
   execution, session management, or richer orchestration.

Practical implication:

- The first implementation should probably be a small local runner on the Mini
  plus a test spec and artifact contract, not a dashboard, queue, or multi-run
  scheduler.

## suggested file layout for this project

This layout was discussed as a practical direction:

```text
scripts/remote/
  computer-use-run.sh
docs/computer-use-tests/
  <test-id>.md
artifacts/remote-gui/<run-label>/
  result.json
  remote/
    screenshots/
    transcript.txt
    app.log
    build.log
```

The exact script names can change, but the design intent should stay:

- keep specs as plain text instructions
- keep result bundles machine-readable
- keep copied-back artifacts easy to inspect locally

## result contract

The thread consistently treated a stable result contract as important. A
minimal Computer Use result shape should look like this:

```json
{
  "schemaVersion": 1,
  "status": "pass|fail|timeout|setup_error",
  "mode": "computer_use",
  "testID": "workspace-menu",
  "startedAt": "2026-04-20T10:00:00-07:00",
  "endedAt": "2026-04-20T10:02:30-07:00",
  "summary": "One-line outcome",
  "artifacts": {
    "screenshots": ["remote/screenshots/step-3.png"],
    "transcript": "remote/transcript.txt",
    "appLog": "remote/app.log",
    "buildLog": "remote/build.log"
  }
}
```

The local orchestrator should consume this contract rather than needing to
understand the full remote session.

## non-goals for v1

- Do not build a multi-tenant queue.
- Do not assume parallel Computer Use runs on one Mini session.
- Do not replace the existing smoke automation entry points.
- Do not overfit the first version to `app-server` unless a real need appears.
- Do not invent a large test DSL before one or two narrow specs prove useful.

## open questions for this worktree

1. What is the exact supported execution path for Codex Computer Use on the
   Mini: manual Codex app, semi-manual local runner, or something fully
   scriptable?
2. What should the first Toastty Computer Use spec be?
3. Should the first integration live alongside `scripts/remote/validate.sh` or
   start as a separate runner until the interface settles?
4. What is the cleanest way to hand prompts/specs to the Mini without relying
   on chat state?
5. How should test credentials or other secrets be supplied to Computer Use
   flows without baking them into specs?

## starting recommendation

Start by implementing the smallest real prototype:

- one Computer Use spec
- one Mini-side runner path
- one copied-back result bundle

Use the remote smoke work that is already on `main` as the transport and
artifact model, but do not force the first Computer Use version to look exactly
like smoke validation if that makes the execution model worse.
