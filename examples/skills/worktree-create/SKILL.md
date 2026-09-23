---
name: worktree-create
description: Create a named Toastty task workspace and Git worktree for planning or implementation. Start a fresh task conversation or fork an existing Codex or Claude discussion into the worktree, and register it with the coordinator.
---

# Worktree Create

Create the task's worktree and workspace together. The normal starting point is
a persistent coordinator workspace: launch a fresh task session, do detailed
planning there, then implement in that same conversation when authorized.
If the task was already discussed at length, fork the current conversation into
the worktree. A generated summary must not replace the inherited conversation
or an existing settled plan.

Install this package together with `coordinator` and `worktree-done`. Resolve all
scripts relative to the loaded skill package, including inside a plugin snapshot.
Use `scripts/create-worktree.sh`, `scripts/open-toastty-worktree-session.sh`, and
the sibling `../coordinator/scripts/tasks.py`. Never edit the delivered snapshot.

Preserve the user's visible workspace, tab, and keyboard focus during discovery,
inspection, status reporting, and verification. Use explicit workspace/panel
queries. Do not select a workspace/tab or focus a panel to make evidence ready;
selection and focus actions are appropriate only for user-authorized navigation.
Include this constraint in the child handoff.

## Select the start

- **New task:** create a fresh conversation with `--mode plan` by default.
  The child investigates and designs, then waits for the user's implementation
  instruction. Registration does not authorize implementation.
- **Existing discussion:** use `--fork-from-session "$TOASTTY_SESSION_ID"` with
  the same provider. Pick plan or implement from the user's actual request.
  An explicit implementation request already authorizes `--mode implement`;
  do not introduce another approval step.
- Forks are independent conversations. Later parent messages do not transfer.
  The child owns this task after launch; the parent can continue coordination.
  Do not fork a broad coordinator history when starting an unrelated task.
- Provider changes cannot inherit a native conversation. If a required fork
  is unavailable, report the exact missing capability and retain the task;
  do not silently substitute a fresh session with a summary.

## Prepare

Read `toastty-capabilities` and require executable `TOASTTY_CLI_PATH`, current
`TOASTTY_PANEL_ID`, and managed `TOASTTY_SESSION_ID`. Use the injected socket
for the owning instance. Discover live actions and queries. Structured forks
require `agent.launch` support for `forkFromSessionID`; queue directory access
requires `additionalDirectories`. Check selected-provider support before
creating resources. Older running apps need an updated app; no raw-terminal
fallback bypasses missing launch support.

Before creating a worktree or workspace for a fork, also verify the installed
provider CLI supports the native fork arguments. Establish the actual executable
used by the selected profile in the owning Toastty instance from its configured
argv and resolved launch environment. Follow Toastty's existing `agents.toml`
configuration conventions: a configured profile's argv wins; when the built-in
profile has no override, its implicit command is `codex` or `claude`. Resolve
that command in the owning instance's launch environment. A profile ID alone
is not an executable path:
custom profiles can override it, and the current terminal's `PATH` may contain
Toastty shims or a different installation. Do not use a generic `command -v codex`
or `command -v claude` result as proof. The current action descriptor does not
expose the resolved executable; if it cannot be established reliably, stop
before resource creation and report this preflight as blocked.

Run only read-only help/version probes on that verified executable, without
launching or authenticating an agent:

- Codex: `"$PROVIDER_EXECUTABLE" fork --help` must succeed and advertise the
  session and prompt arguments, plus the `-C`/`--cd` option used by Toastty.
- Claude: `"$PROVIDER_EXECUTABLE" --version` must identify version 2.1.257 or
  newer; `"$PROVIDER_EXECUTABLE" --help` must advertise `--resume`,
  `--fork-session`, and `--system-prompt-snapshot` with its `off` value.

Missing or ambiguous evidence is a blocked fork, not permission to substitute a
fresh session. Record the verified executable and capability evidence in the
handoff. Run required setup separately; `--initial-command` cannot be combined
with `--fork-from-session`.

Read [model and base selection](references/model-and-base.md). Choose an available
provider/model/effort explicitly, preserving Codex versus Claude unless the user
requests otherwise. Identify the repository, intended remote/destination and
pinned base commit without modifying the parent checkout. Choose a short task
slug and semantic branch prefix (`feat`, `fix`, `debug`, `refactor`, `test`,
`docs`, or `chore`) matching repository conventions.

Find explicit fresh-worktree setup requirements in the target repository's
instructions. Run those commands from the new worktree before launch. Do not
infer setup from a package manager's presence, and do not add trust-changing
commands without authorization.

## Create and register

The examples use `SKILL_DIR` for this skill's loaded directory, `TASKS` for the
sibling helper, `REPO` for the canonical parent checkout and `TASK` for the slug.

```bash
"$SKILL_DIR/scripts/create-worktree.sh" \
  --slug "$TASK" --branch-prefix "$PREFIX" --base-ref "$BASE_SHA" --json
python3 "$TASKS" --repo "$REPO" paths
```

Parse the returned branch/worktree/handoff paths and queue directory. The queue
lives outside removable task worktrees under `~/.toastty/task-state/`, keyed by
the canonical shared Git directory. Carry an explicit `--state-root` consistently
for an isolated run. If access is denied, obtain narrow access to this repository's
state directory; do not report success or broaden access to the whole home.

Register the exact worktree before launch. Omit PR metadata until a PR exists:

```bash
python3 "$TASKS" --repo "$REPO" register --task "$TASK" \
  --worktree "$WORKTREE" --branch "$BRANCH" --base "$BASE_SHA" \
  --landing "$LANDING_BRANCH" --remote "$REMOTE" --socket "$TOASTTY_SOCKET_PATH"
```

Run the required setup. Keep any failure and the created resources visible; do
not launch an agent into a half-configured task or delete resources to hide an
error.

## Preserve context

Write `WORKTREE_HANDOFF.md` before launch with the task scope, selected mode,
model/effort rationale, exact base and destination, queue helper/state paths,
task ID, known dependencies, and parent/coordinator identities. Include the
[task workflow](references/task-workflow.md). Keep this private task artifact
out of product commits and public PRs.

For a new task, preserve the user's actual request and identify unresolved
design questions. Do not invent a finished plan. For an existing discussion,
reference existing plans unchanged and identify the exact source managed session.
The fork transfers conversation history; this file supplies current task and
directory information, not a newly summarized replacement for that history.
Retain settled artifacts without rewriting them. Forking does not recover context
already lost to provider compaction.

Look up the current session's Scratchpad using `panel.scratchpad.lookup`.
If linked, export it and record its exact path/title/revision in the handoff.
If unlinked, continue without scanning other panels. Surface lookup/export errors;
do not silently omit an artifact that is the task's design source.

## Launch

```bash
"$SKILL_DIR/scripts/open-toastty-worktree-session.sh" \
  --workspace-name "$TASK" --worktree-path "$WORKTREE" \
  --handoff-file "$HANDOFF" --mode "$MODE" \
  --model "$MODEL" --reasoning-effort "$EFFORT" \
  --additional-directory "$REPO_STATE_DIR" --json
```

Add `--fork-from-session "$TOASTTY_SESSION_ID"` for an existing discussion.
The source must have verified native session metadata and use the same provider.
The helper passes the worktree cwd explicitly, creates a background workspace,
opens the handoff, launches a managed session and applies workspace scope. It
does not set task or branch annotations.

The helper preserves an existing parent scope, scopes an unrestricted parent
to its current workspace, and includes the created workspace. The child receives
its own workspace and the parent workspace for task-related replies; this is
cooperative scope, not a security sandbox. Replies use the recorded panel plus
`expectedSessionID`. An unavailable or replaced parent is not a new destination.
Do not use `--no-scope-parent` unless intentionally disabling that return route.

Forks must establish a new native session identity and use the worktree's effective
cwd and permissions. Check launch/runtime evidence before claiming context was
transferred successfully. A composed command alone does not prove the provider
started. The child verifies its directory, branch, scope and task record before
writes; previous paths in inherited history are historical. Do not resume the
same live native session into a second writer.

After successful launch, attach the returned workspace/panel/session IDs:

```bash
python3 "$TASKS" --repo "$REPO" attach --task "$TASK" \
  --workspace "$WORKSPACE_ID" --panel "$PANEL_ID" --session "$SESSION_ID" \
  --socket "$TOASTTY_SOCKET_PATH"
```

Do not overwrite the
child's state or rewrite its handoff after launch. Registration is not acceptance.
If an assigned coordinator exists, verify its ownership and workspace scope before
control; it need not be the original parent. A separate coordinator can discover
the record on startup even if the parent exits.

## Handoff and checks

Report the task workspace, worktree/branch, selected mode/provider/model/effort,
whether conversation forking was verified, setup result, and queue registration.
Include exact resource IDs in the durable record; keep the user-facing summary
brief. The user continues planning, implementation and testing in that workspace,
then invokes `worktree-done`. Neither launcher nor child merges automatically.

Use the helper's JSON results and live metadata to verify child placement and
scope. Confirm no task or Git branch annotation was added.
For workflow changes, validate scripts and run `WorktreeCreateSkillScriptTests`
under the repository's verification guide. Custom `--startup-command` launches
are only for explicit smoke/custom shell use and cannot claim managed forks.
