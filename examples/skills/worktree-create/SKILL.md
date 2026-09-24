---
name: worktree-create
description: Create a named Toastty task workspace and Git worktree for planning or implementation. Start a fresh task conversation or fork an existing Codex or Claude discussion into the worktree.
---

# Worktree Create

Create the task's worktree and workspace together. Launch a fresh task session,
or fork the current conversation when the task has already been discussed.
A generated summary must not replace inherited conversation or a settled plan.
The user continues directly in the new workspace; this workflow does not register
a task queue, assign a coordinator, or request reports to the launching session.

Resolve scripts relative to the loaded package, including inside plugin snapshots.
Use `scripts/create-worktree.sh` and `scripts/open-toastty-worktree-session.sh`.
Never edit the delivered snapshot.

## Select the start

- **Default: execute the established task.** The user's worktree-create request
  starts work on the task discussed in the conversation. Use `--mode implement`
  unless the user explicitly limited this task to planning, investigation, or
  another read-only outcome. Do not add an approval checkpoint merely because
  the task is moving into a worktree or needs some design before implementation.
- **Publication scope:** user-authorized implementation handoffs include task-branch
  push and PR publication under [the task workflow](references/task-workflow.md).
  The launch prompt carries this scope. Include any user publication limits
  verbatim in the handoff. Merging, deployment, and production activation require
  separate authorization; repository publication rules and runtime approvals
  still apply.
- **Existing discussion:** fork with `--fork-from-session "$TOASTTY_SESSION_ID"`
  using the same provider. Continue from inherited decisions and the next
  unfinished step; do not restart discovery or produce a replacement plan.
- **New task:** use a fresh conversation with the user's actual task request.
  Use `--mode implement` for an actionable task. If none can be identified, ask
  what to work on instead of inventing scope. Use `--mode plan` only for an
  explicitly limited request.
- Resolve ordinary implementation choices autonomously. Preserve explicit user
  approval requirements and ask about material unresolved scope changes; keep
  independent authorized work moving while awaiting an answer.
- Forks are independent conversations. Later parent messages do not transfer.
  The child owns this task after launch and reports directly to the user there.
  Do not fork unrelated conversation history when starting a new task.
- Provider changes cannot inherit a native conversation. If a required fork
  is unavailable, report the exact missing capability and retain the task;
  do not silently substitute a fresh session with a summary.

## Prepare

Read `toastty-capabilities` and require executable `TOASTTY_CLI_PATH`, current
`TOASTTY_PANEL_ID`, and managed `TOASTTY_SESSION_ID`. Use the injected socket
for the owning instance. Discover live actions and queries. Structured forks
require `agent.launch` support for `forkFromSessionID`. Check selected-provider support before
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

## Create

The examples use `SKILL_DIR` for the loaded skill directory and `TASK` for the slug.

```bash
"$SKILL_DIR/scripts/create-worktree.sh" \
  --slug "$TASK" --branch-prefix "$PREFIX" --base-ref "$BASE_SHA" --json
```

Parse the returned branch, worktree, and handoff paths. Do not create queue records
or grant access to coordinator state directories as part of this workflow.

Run the required setup. Keep any failure and the created resources visible; do
not launch an agent into a half-configured task or delete resources to hide an
error.

## Preserve context

Keep `WORKTREE_HANDOFF.md` to current worktree/branch, pinned base/destination,
mode and launch selections, publication scope and user limits, source session
identity, setup result, and artifact paths/URLs to open. Link the existing task workflow at
`$SKILL_DIR/references/task-workflow.md` using the resolved absolute path and verify
that it exists. Explicitly instruct the child to read and follow that linked file;
do not paste its contents. Keep the private handoff out of commits.

For forks, use inherited history for the request, decisions, authorization,
progress, and next steps. Add a brief task pointer only when the history contains
multiple tasks. Reference settled plans unchanged; do not summarize the discussion
or introduce another approval gate. If essential context was lost to compaction,
consult the referenced artifacts or ask a focused question. Fresh sessions also
need the actual request and constraints; do not invent scope or a finished plan.

Look up the current session's Scratchpad using `panel.scratchpad.lookup`.
If linked, export it and record its exact path/title/revision in the handoff.
If unlinked, continue without scanning other panels. Surface lookup/export errors;
do not silently omit an artifact that is the task's design source.

## Launch

```bash
"$SKILL_DIR/scripts/open-toastty-worktree-session.sh" \
  --workspace-name "$TASK" --worktree-path "$WORKTREE" \
  --handoff-file "$HANDOFF" --mode "$MODE" \
  --model "$MODEL" --reasoning-effort "$EFFORT" --json
```

Add `--fork-from-session "$TOASTTY_SESSION_ID"` for an existing discussion.
The source must have verified native session metadata and use the same provider.
The helper passes the worktree cwd explicitly, creates a background workspace,
opens the handoff, launches a
managed session and applies workspace scope. It does not set a branch annotation.

The helper preserves an existing parent scope, scopes an unrestricted parent
to its current workspace, and includes the new workspace so the launcher can
finish setup. The child receives only its own workspace. Scope is cooperative
guidance, not a security sandbox. No parent reply is requested or authorized by
this workflow. Do not add a return route to the handoff or launch prompt.

Forks must establish a new native session identity and use the worktree's effective
cwd and permissions. Check launch/runtime evidence before claiming context was
transferred successfully. A composed command alone does not prove the provider
started. The child verifies its directory, branch, scope and handoff before
writes; previous paths in inherited history are historical. Do not resume the
same live native session into a second writer.

After launch, record returned workspace/panel/session IDs in the launcher's
completion notes. Do not rewrite the child's handoff or task state after launch.

## Open referenced artifacts

After the helper returns the new workspace and session IDs, the launcher opens
the task artifacts explicitly referenced by the handoff in the new workspace's right panel. Do this as part of creation, not as a later offer.
Use the references assembled while writing the handoff; do not build a Markdown
link parser or scan unrelated files or panels. Deduplicate identical artifacts.
Include the associated plans, design documents, mocks, and linked Scratchpad,
not instruction files, executable paths, logs, or every source-code citation.
Record the artifact paths/URLs and titles in the handoff before launch.

- For repository documents, use the corresponding file in the new worktree when
  it contains the referenced version. Copy task-owned untracked documents and
  local mock assets when necessary, preserving their relative asset paths; do not
  silently substitute a different version. Keep exported/private artifacts out
  of product commits. Report missing files or inaccessible URLs explicitly.
- Open documents with `panel.create.local-document` using their absolute
  `filePath`, the returned destination `workspaceID`, and `placement=rightPanel`.
  Open mock sites with `panel.create.browser`, their exact URL, and the same
  workspace and placement. For local HTML mocks use the Scratchpad flow rather
  than starting an external browser. Use the applicable Toastty document or
  Scratchpad skill when preparing the artifact.
- For the source session's linked Scratchpad, use its exported HTML to create a
  Scratchpad for the returned child `sessionID` with `panel.scratchpad.set-content`
  and its original title, using `createPolicy=new` to avoid overwriting a Scratchpad
  the child has already created. Use separate new panels for distinct HTML mocks;
  never overwrite one artifact with another. This is an independent copy for the fork; retain the
  source panel and record the original document/revision as provenance. Do not
  rebind or close the source Scratchpad. Preserve supporting assets required to
  render it; report anything that cannot be preserved.
- Check every response for success. Verify document paths and right-panel
  placement with the destination workspace snapshot; verify Scratchpad linkage,
  content, and title with its supported queries. Use browser state queries for
  loading results without selecting or focusing the new workspace. Report
  partial failures with exact artifact and workspace identities; do not claim
  that referenced artifacts opened merely because the handoff opened.

The launcher owns this initial opening step; the child should not duplicate it.
Artifact failure does not justify launching another child or deleting the
created workspace. Continue opening the remaining independent artifacts, retain successful setup,
and report what remains.

## Handoff and checks

Report the task workspace, worktree/branch, selected mode/provider/model/effort,
whether conversation forking was verified, setup result, and artifact-opening results.
Include exact resource IDs in the durable record; keep the user-facing summary
brief. The user continues planning, implementation and testing in that workspace,
with no required coordinator or completion skill. Neither session merges automatically.

Use the helper's JSON results and live metadata to verify child placement and
scope. Confirm no task or Git branch annotation was added.
For workflow changes, validate scripts and exercise the changed launch behavior
with a disposable CLI fixture. For repository copies, also follow that repository's verification guide. Custom `--startup-command` launches
are only for explicit smoke/custom shell use and cannot claim managed forks.
