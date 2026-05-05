# toastty codex computer use e2e

Date: 2026-04-20
Updated: 2026-05-05

This document captures the working context and decisions from the remote
validation thread that led into the `codex/computer-use-e2e` worktree. The
goal is to preserve the architecture discussion in-repo so the next
implementation pass does not depend on chat history.

Implementation note, 2026-04-20:

- `scripts/remote/computer-use-run.sh` now proves that a Codex `app-server`
  turn can be started on the Mini, observed remotely over an SSH tunnel, and
  harvested into a copied-back result bundle without a human at the keyboard.
- At that point, the blocker was Toastty-specific Computer Use approval on the
  Mini. Until that approval was handled, the default prompt exited
  `setup_error` with `failureReason.kind = "approval_denied"`.

Implementation note, 2026-05-05:

- `scripts/remote/codex-app-server-client.mjs` now enables MCP elicitations and
  narrowly auto-accepts known Computer Use app-access or tool-call approval
  prompts, so the original app-approval blocker is no longer expected for those
  prompt shapes.
- The copied-back summary records `mcpElicitationsAccepted` and
  `mcpElicitationsDeclined`; any declined or failed Computer Use approval is
  still reported through the run's normal failure fields.

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
5. Parallel Computer Use on one Mac mini login session is an explicit
   follow-up experiment, not a v1 architecture requirement. The first version
   should avoid accidental singleton assumptions such as shared artifact paths,
   fixed runtime homes, or global lockfiles, but it should still ship as a
   single-run prototype.
6. The first slice should first prove the supported Codex Computer Use
   execution path on the Mini, then prove one realistic end-to-end UI flow,
   then run a two-job experiment before any larger orchestration layer is
   considered.

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
- The user wants to test whether multiple Computer Use jobs can run in
  parallel on the Mini and does not want a single-job assumption baked into
  the design prematurely.

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

This remains the leading hypothesis for the first prototype, but it is not
locked in until a short spike proves it is usable on the Mini.

- Best fit if a manual or semi-manual prototype is acceptable.
- Matches the desire to use Codex Computer Use specifically on macOS.
- Avoids prematurely committing to undocumented or unstable automation hooks.

Limitations captured during planning:

- At the time of the thread, the working assumption was that Computer Use is
  primarily exposed through the Codex app workflow on macOS.
- Fully unattended triggering was not treated as proven for the Codex app path.
- The first implementation should not depend on this path until a short Mini
  spike confirms a run can be started, observed, and harvested with usable
  copied-back artifacts.

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

1. Run a short gating spike on the Mini that proves the supported Codex
   Computer Use execution path: start a run, observe progress remotely enough
   to know it is alive, and copy back a usable result bundle without a human
   babysitting the keyboard.
2. If that spike succeeds, reuse the existing remote transport/provisioning
   model from `scripts/remote/validate.sh`.
3. Add a Computer Use specific runner path without overloading the current
   smoke script contract too early.
4. Prove one named Toastty UI flow on the Mini with Codex Computer Use.
5. Write a stable result bundle with JSON summary, structured transcript,
   screenshots, raw logs, and machine-checkable assertion output.
6. Keep v1 single-run. Do not build a queue, scheduler, or session manager
   before there is evidence that they are needed.
7. After the first spec passes, run one explicit two-job experiment against the
   same Mini login session to establish whether parallel runs fight each other
   or can coexist with isolated runtime paths.

If the gating spike fails, stop and revisit the execution path before building
the runner or spec contract around the Codex app workflow.

Practical implication:

- The first implementation should be a small local runner on the Mini plus a
  test spec and artifact contract, not a dashboard, queue, or multi-run
  scheduler.
- The first implementation is allowed to add one narrow app-side verification
  probe if that is the cleanest way to make the chosen spec deterministic.

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
    transcript.jsonl
    assertions.json
    app.log
    build.log
```

The exact script names can change, but the design intent should stay:

- keep specs as plain text instructions with a small required header
- keep result bundles machine-readable
- keep copied-back artifacts easy to inspect locally

## first spec candidate

The first spec should be named up front so the slice stays reviewable. The
recommended first candidate is:

- `agent-get-started-keyboard-shortcuts`

Why this is the best v1 candidate:

- It exercises a real multi-step modal sheet inside Toastty rather than a
  shortcut-injection path that deterministic smoke automation already targets.
- It is grounded in an existing UI flow: the top-bar `Get Started…` path and
  the Agent onboarding sheet.
- It avoids real shell dotfile writes and avoids secrets if the flow stops on
  the `Keyboard Shortcuts` step instead of performing shell integration.

Proposed user journey:

1. Launch Toastty in an isolated runtime home on the Mini.
2. Click the top-bar `Get Started…` entry point.
3. Navigate to the `Keyboard Shortcuts` step in the onboarding sheet.
4. End with the sheet still open on that step.

Deterministic assertion for v1:

- The run should not self-grade based only on the model's summary.
- Add or reuse a narrow app-side probe that records whether the
  `sheet.agent.get-started` sheet is visible and whether the active step is
  `keyboardShortcuts`.
- Store that probe output in `remote/assertions.json` and use it to decide
  pass/fail.

This keeps the first spec focused on a UI path that is awkward for current
automation while still allowing a machine-checkable end state.

## spec contract

Specs can stay as plain-text files under `docs/computer-use-tests/<id>.md`, but
each spec should include a small required header so the runner does not have to
guess the contract:

```text
Test ID: agent-get-started-keyboard-shortcuts
Intent: Navigate the Agent onboarding sheet to the Keyboard Shortcuts step.
Launch Preconditions: Fresh isolated runtime home; no shell integration writes.
Prompt Instructions: <plain-language Computer Use prompt>
Expected End State: Agent Get Started sheet is visible on the Keyboard Shortcuts step.
Assertions:
- assertion ID + machine-check source
Timeout Seconds: 300
Token Budget: 20000
Automatic Retries On Agent Error: 1
Cleanup: Close the app or leave it running for artifact capture.
```

The important point is not YAML versus prose. The important point is that every
spec names:

- the expected end state
- the machine-checkable assertion source
- the timeout and token budget
- whether automatic retry is allowed
- whether the flow is allowed to mutate user state or secrets

## result contract

The thread consistently treated a stable result contract as important. The
result needs to separate product failures from agent failures instead of
collapsing both into a single `fail`.

A minimal Computer Use result shape should look like this:

```json
{
  "schemaVersion": 1,
  "status": "pass|fail|agent_error|timeout|setup_error",
  "mode": "computer_use",
  "executionPath": "codex_app",
  "testID": "agent-get-started-keyboard-shortcuts",
  "startedAt": "2026-04-20T10:00:00-07:00",
  "endedAt": "2026-04-20T10:02:30-07:00",
  "durationSeconds": 150,
  "retryCount": 0,
  "tokensUsed": {
    "input": 12000,
    "output": 1800,
    "total": 13800
  },
  "costUSD": 0.42,
  "summary": "One-line outcome",
  "failureReason": {
    "kind": "assertion_failed|agent_gave_up|budget_exceeded|launch_failed|verification_failed",
    "message": "Structured short reason"
  },
  "assertions": [
    {
      "id": "agent-get-started-step",
      "passed": true,
      "source": "remote/assertions.json",
      "expected": "sheet visible on keyboardShortcuts step",
      "actual": "sheet visible on keyboardShortcuts step"
    }
  ],
  "artifacts": {
    "screenshots": ["remote/screenshots/step-3.png"],
    "transcript": "remote/transcript.jsonl",
    "assertions": "remote/assertions.json",
    "appLog": "remote/app.log",
    "buildLog": "remote/build.log"
  }
}
```

The local orchestrator should consume this contract rather than needing to
understand the full remote session.

## transcript contract

`transcript.txt` is too vague for tooling. The transcript artifact should be
`transcript.jsonl`, one JSON object per event, for example:

```json
{"ts":"2026-04-20T10:00:05-07:00","type":"model_message","text":"Opening Toastty and looking for Get Started"}
{"ts":"2026-04-20T10:00:12-07:00","type":"computer_use_action","action":"click","target":"Get Started… button"}
{"ts":"2026-04-20T10:00:20-07:00","type":"computer_use_observation","text":"Agent Get Started sheet is visible"}
{"ts":"2026-04-20T10:02:18-07:00","type":"verification","assertionID":"agent-get-started-step","passed":true}
```

This keeps the artifact readable by humans while also making it consumable by
future tooling.

## timeouts, budgets, and flake triage

- Every spec must declare `Timeout Seconds` and a token budget.
- The runner should terminate the run when either budget is exceeded and record
  `timeout` or `agent_error` with a structured `failureReason`.
- The runner may automatically retry once for `agent_error` only. It should not
  auto-retry a real assertion failure and then hide a product regression.
- Before a spec is promoted to a real regression gate, run it multiple times on
  a known-good baseline commit to measure its noise level. The initial target is
  a simple repeated-run experiment, not a general flake service.

## secrets and side effects

- Specs must not contain literal secrets.
- The Mini-side runner should receive secrets out of band from the execution
  environment rather than from the spec text.
- The first spec should avoid secrets entirely.
- The first spec should also avoid user-dotfile mutation, which is another
  reason to stop the onboarding flow at the `Keyboard Shortcuts` step.

## non-goals for v1

- Do not build a multi-tenant queue.
- Do not design a queue, scheduler, or session-manager abstraction just to
  preserve a theoretical future parallelism story.
- Do not hard-code singleton assumptions such as shared run directories, fixed
  runtime homes, or one global mutable result path.
- Do not assume that parallel execution on one Mini login session works before
  running the explicit follow-up experiment.
- Do not replace the existing smoke automation entry points.
- Do not overfit the first version to `app-server` unless a real need appears.
- Do not invent a large test DSL before one or two narrow specs prove useful.

## open questions for this worktree

1. Can the Codex app path on the Mini actually support the gating spike:
   start, observe, and harvest artifacts without a human standing over it?
2. Should the first integration live alongside `scripts/remote/validate.sh` or
   start as a separate runner until the interface settles?
3. What is the cleanest way to hand prompts/specs to the Mini without relying
   on chat state?
4. Does the chosen first spec need a small app-side assertion probe, or can an
   existing artifact expose the UI step cleanly enough?
5. How should future secret-bearing specs receive credentials on the Mini
   without baking them into specs?
6. After the first spec passes, can two isolated runs coexist on one Mini
   login session, or do they fight over focus, cursor, or keyboard state?

## starting recommendation

Start by implementing the smallest real prototype:

- one execution-path spike
- one named Computer Use spec
- one Mini-side runner path
- one copied-back result bundle

Use the remote smoke work that is already on `main` as the transport and
artifact model, but do not force the first Computer Use version to look exactly
like smoke validation if that makes the execution model worse.
