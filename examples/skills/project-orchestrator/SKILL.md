---
name: project-orchestrator
description: Coordinate a project's work in Toastty while the user is working. Watch PRs and assigned local tasks, maintain a Scratchpad progress dashboard, assess interactions, and reconcile integration and deployment through the repository's workflows when authorized.
---

# Project Orchestrator

Run one coordinator session for the project. Worktree agents own implementation
and fixes; the coordinator keeps the project view, reviews how changes fit
together, and handles authorized integration and release work. PRs carry the
shared task record. Scratchpad presents the current project state.

## Start or resume

- Require an executable `TOASTTY_CLI_PATH` and `TOASTTY_SESSION_ID`. Otherwise
  report that `project-orchestrator` must run inside a Toastty-managed agent
  session. Use `toastty-capabilities` to discover the live app surface and
  `toastty-scratchpad` to create and update this session's dashboard.
- Resolve the repository, remote, destination branch, and assigned work. Read
  its instructions and verification/release guides. Do not assume `main`, a Git
  host, deployment provider, or Toastty's own build commands.
- Record standing authority for observation/review, messages to agents or PRs,
  integration/pushing, cleanup, and release. A watch request authorizes observation
  and its local dashboard. Carry other prior authorization forward within scope;
  do not ask at each routine step. Prepare concrete results before requesting
  missing final-action approval.
- Start scoped to this workspace. Add only user-assigned workspaces or those
  created under this workflow's task-management authority. A matching PR/title
  does not assign a workspace. Verify recorded workspace/panel/session IDs and
  respect `scope_denied`. Use the managed instance's injected targeting.
- Keep one local coordination note in an ignored artifact location or outside
  Git, separate from removable task worktrees. Record coordinator identity,
  assigned task/branch/checkout/session mappings, PRs, reviewed heads, pending
  decisions, authority, release plans, and last check. Keep machine paths and
  private session metadata out of public PRs.
- On resume, reobserve Git, PR, and release state. Resolve ownership if another
  coordinator is active before acting. The note is a handoff record, not a lock;
  use repository concurrency protections.

## Watch and assess

- Use the runtime's supported persistence and interruptible wait/resume mechanism
  for this user-requested watch; report any limit. Monitoring ends with the
  session. Do not install a scheduler, daemon, or supervisor.
  If a continuing watch is unsupported, perform one check and report that
  further checks require resuming the session; do not claim active monitoring.
- Poll at an interval appropriate to activity and host limits; roughly a minute
  is a starting point. Check metadata first, review new/changed heads, and back
  off on errors. Remain responsive to input. Notify meaningful transitions or
  blockers, not each poll; identify stale sources and last successful checks.
  If app access or dashboard publishing fails, report it in the session and
  keep the displayed last-checked time unchanged until publication succeeds.
- Inspect open PRs, relevant assigned local branches/worktrees, and merged work
  not yet included in required deployments. Include remote work even when its
  author has no local session. Establish the initial deployment baseline from
  release evidence; an unavailable baseline means unknown backlog, not empty.
- Draft PRs provide early visibility. Require an explicit handoff for assessment:
  current head, intent/decisions, validation, remaining human/reviewer gates,
  dependencies, and deployment implications. PR existence, draft status, and CI
  alone do not establish readiness. Local-only work uses a durable task note;
  blocked publication must remain explicit.
  Resolve the live head independently of handoff prose and label any mismatch;
  useful review can proceed on an identified head without claiming readiness.
- Assess a handed-off change against codebase patterns, scope and maintenance
  cost, contracts, safety, tests, and documentation. Inspect relevant in-flight
  work for duplication, shared assumptions, conflicts, and ordering. Record the
  task head, target head, and relevant peer heads examined. Git mergeability
  does not prove semantic compatibility. State discovery/coverage limits.
- Use `worktree-done` for detailed assessment and authorized landing/cleanup.
  If absent, continue observation and repository-supported operations; report
  the missing cleanup workflow. The original parent need not be present.
- Return actionable findings when communication/fixes are authorized; otherwise
  report them. Keep fixes with the task owner, arranging an authorized replacement
  from the PR/task record if needed. Separate blockers from optional suggestions.
- A new task head invalidates its prior readiness. Changed target or peer heads
  require reassessing affected interactions, not every unrelated task. Use a
  disposable integration check only for a specific risk and candidate order.
  Refresh evidence before authorized integration. Required independent review
  and human testing remain separate gates.

## Maintain the project dashboard

Update the same session-linked Scratchpad at meaningful state changes. Use the
Scratchpad skill's supported HTML publishing/patching; the agent fetches data and
publishes snapshots. The page itself is not a background network poller.

- Present work moving through Working, Validating, Ready to merge, Merged awaiting
  deployment, and Complete. Adapt the labels to the project, keeping blockers
  and remaining human checks visible. Readiness requires the repository's merge
  gates; a child handoff can be ready for assessment while still Validating.
- Show each task's PR/local record, activity, validation/head, blockers, and next
  action, linking detailed evidence. Show unpublished/ahead/behind/diverged state
  separately; these labels alone do not prove unique pending work.
- Merged work stays visible until its required release targets are verified.
  Show partial results by component, such as site deployed and API pending.
  Determine deployment requirements from the diff and repository release rules,
  using the child's description as input. Verified integration can complete
  work that requires no deployment. A closed, unmerged PR is closed/cancelled,
  not completed work.
- Show the proposed release batch, included changes, outstanding targets,
  approvals, and validation. Use existing deployment receipts or release records
  to establish which integrated changes are included at each target. A successful
  command or a newer timestamp alone does not prove deployment or installation.
- Show last-checked time, monitoring status, and unknown/stale evidence. Preserve
  the note and a dashboard export on handoff/stop. The dashboard must be
  reconstructable from durable records without original parent sessions.

## Reconcile, integrate, and ship

Read [integration and release](references/integration-and-release.md) before
reconciling local/remote history or preparing a combined release. It covers
unpublished local commits, PR merge correspondence, batching, and partial failure.

When final actions are authorized, use the repository's integration and release
workflows and `worktree-done` for assigned local cleanup. Keep integration,
deployment, and cleanup outcomes distinct. Cleanup must not erase the record of
merged work that still needs shipping. When authority or evidence is missing,
keep observing independent work and present the concrete pending decision.

On stop, checkpoint and report pending work, release outcomes, retained local
resources, and that monitoring has ended. Do not terminate task agents or delete
their workspaces merely because the coordinator session is ending.
