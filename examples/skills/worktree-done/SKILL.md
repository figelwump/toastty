---
name: worktree-done
description: Review, integrate, or finish a Toastty worktree task or PR from a session outside the task. When no target is named, discover open PRs and local worktrees with open Toastty workspaces in the current repository. Assess each task, then perform authorized integration and local task cleanup.
---

# Worktree Done

This example personal skill assesses and, when authorized, lands a task using
its repository's integration and verification rules. The finishing session can
be the original parent or another session; the original parent need not stay
active. The user can name the task or PR without supplying a commit SHA, or omit
the target to process the discovered tasks in the current repository.

## Resolve the task and authority

- Require `TOASTTY_CLI_PATH` and `TOASTTY_SESSION_ID`. If absent, stop with
  `error: worktree-done must run inside a Toastty-managed agent session`.
  Use `toastty-capabilities` to discover the running CLI's supported queries
  and actions before controlling sessions or workspaces.
- Resolve the task using the durable local launch record,
  `git worktree list --porcelain`, `WORKTREE_HANDOFF.md`, and live
  workspace/session metadata.
  Match branch and canonical checkout path, then workspace and session IDs;
  titles alone are insufficient. Ask only when the target remains ambiguous.
  Before controlling local resources, verify the finishing session's workspace
  scope. Add only workspaces assigned by the user or this authorized workflow;
  a launch record establishes identity, not authority. Respect `scope_denied`.
- For remote-only PRs, review and integrate through the repository workflow
  without requiring a local task workspace. Local cleanup is inapplicable when
  no task-owned resources exist; do not guess resources from a PR title.
- Resolve the landing branch and its checkout from the user's instruction,
  the handoff, and repository rules. Use upstream/default-branch information
  as evidence when needed; do not hardcode `main` or assume the task's base
  branch is the destination. Honor required PR, CI, review, and merge gates.
- Run integration from a clean landing checkout (or isolated integration
  checkout when needed) and cleanup from a finishing session
  outside both the target checkout and target workspace. Canonicalize paths
  through symlinks and compare directory boundaries, not string prefixes. If
  invoked from the child, prepare the readiness handoff and direct the user
  to run this skill from another session; do not delete the active session
  or expand its workspace scope.
- A request to merge and clean up authorizes both actions; do not ask again
  at each step. A merge-only request does not authorize termination or deletion.
  A readiness report, finished goal, or passing test does not authorize a merge.
- A review-only request authorizes assessment and a report, not changes to the
  task branch, PR state, or child workspace. Do not advance into landing,
  evidence archiving for cleanup, process termination, or deletion without the
  corresponding authorization. Keep feedback in the finishing report or
  task record;
  posting PR comments or requesting changes from the child needs authorization
  for that action, which may already be part of the task.

## Discover tasks when no target is named

- Honor an explicit task, PR, or repository scope. Otherwise infer the repository
  from the current checkout and Toastty session metadata; ask only if those
  cannot identify one repository. Do not search all of the user's repositories.
- Discover all open PRs in that repository, including additional result pages,
  and local Git worktrees matched to currently open Toastty workspaces. Use
  canonical checkout paths and branch/repository identity, not workspace titles.
  Include local tasks without PRs; an open workspace is discovery evidence, not
  proof that its task is ready. Exclude the landing checkout from local task
  candidates. If PR access is unavailable, continue with local discovery and
  report the access limit rather than treating it as zero open PRs.
- Combine both sources into one task list, deduplicating a PR and its matching
  local worktree. Preserve repository identity for fork PRs; a matching branch
  name alone does not establish a local resource association. Report uncertain
  matches without guessing which resources belong to the PR.
- Briefly state the discovered scope, then assess every candidate through the
  workflow below without asking the user to choose one. Discovery does not
  grant merge, push, session-control, or cleanup authority; apply the user's
  existing authorization to each task and prepare any remaining approval as
  one concrete batch. Respect workspace scope and the finishing-session rule;
  retain a task containing the current session and report its handoff separately.
- Use dependencies and overlapping changes to choose an order. Recheck the
  destination and affected assessments after each integration. Keep blocked,
  draft, or still-active tasks pending and continue with independent candidates;
  do not land dependent work past a blocker. End with a result or blocker for
  every candidate, or state that no candidates were found with any discovery
  limits. This is one discovery pass, not an ongoing monitor.

## Establish readiness

- Read repository instructions first (`AGENTS.md`/`CLAUDE.md`), then the local
  verify skill they name, then relevant build/test docs and CI configuration.
  Use those to select and report the required review and checks for this diff.
  If no verification guidance exists, choose the smallest meaningful checks
  supported by the project and state what remains unverified.
- Read the PR handoff and its review/test evidence, or the durable local task
  note when there is no PR. An optional Scratchpad can add visual context but
  is not required. Match `ValidatedCommit: <full SHA>` to the source tip. If
  evidence is missing or stale, establish the assessed head and complete the
  required verification before integration; do not equate “done” with verified.
- For a PR, verify its repository, base branch, head branch, and live head SHA
  against the task identity. Integration requires the PR head, any assigned
  local task branch tip, and `ValidatedCommit` to agree, with required review
  and CI covering that head.
  Do not silently choose the newer of conflicting tips. For review-only work,
  assess an explicitly identified current commit and label missing or stale
  readiness evidence; it need not prevent useful read-only feedback.
- Before integration, coordinate the task owner and recheck the source head.
  For an assigned local child, confirm it is idle and will not continue writing.
  For local resources, capture the branch tip and worktree status, including
  untracked files and content fingerprints for artifacts that will be removed. Status paths alone
  cannot detect later edits to an already-untracked handoff.
  Preserve uncommitted or unpublished work; never stash, reset, or force it
  away. Treat the handoff as an artifact to preserve, not a product change.
- Before integration, check the landing checkout can accept it without mixing
  unrelated local changes. Preserve those changes; do not clear them to make room.
  Refresh the destination only as the repository requires, without discarding
  local commits or bypassing its integration policy.

## Project assessment

Integration requires a completed project assessment of the exact task commit.
Run this pass before merging if no current assessment exists, even when
integration is authorized without a separate review request. It also supports
review-only requests and complements
repository-required independent review and CI; human testing follows deployment.

- Review the task diff in the context of existing code: design and ownership
  boundaries, established abstractions and naming, duplicate capability,
  maintenance cost, API and data contracts, failure handling, security and data
  preservation, and missing tests or documentation. Keep mechanical style
  checks with existing formatters/linters; explain concrete consequences for
  design findings.
- Inspect the intended target branch and relevant open PRs and active worktrees
  in the same repository. Use their identified commit heads, prioritizing shared
  files, interfaces, data models, configuration, and overlapping product scope.
  Record which work was examined and any access or discovery limits; do not
  claim compatibility with work you could not inspect.
- Distinguish Git conflicts from semantic incompatibility: changes can merge
  cleanly while disagreeing about a contract or expected behavior. Start with
  read-only inspection. When a specific interaction cannot be resolved that
  way, use a disposable integration worktree for the candidate and the relevant
  changes expected to land first, then run focused checks. Record the tested
  commits, order, commands, and results. Keep this worktree outside child
  workspaces and use detached commits; never stash or change task/landing
  checkouts for the experiment. Remove only this disposable worktree when the
  checks finish, preserving useful results in the report; report any teardown
  failure. This review-owned teardown does not authorize task cleanup. Do not
  rebase the children's branches, test every possible combination, or require
  a speculative build for every review.
- Report the assessed task/PR head, target SHA, relevant peer SHAs, coverage
  limits, blocking findings, optional suggestions, and any recommended merge
  order. Unresolved material conflicts or correctness risks block integration;
  cosmetic preferences do not become new gates. Keep the report in the durable
  task record; a Scratchpad can present it. Publish findings on the
  PR only when authorized.
- The task owner owns fixes. Return actionable findings to the user and, when
  authorized, resume the existing child for accepted corrections. If that agent
  is unavailable, arrange an authorized replacement using the PR and task record.
  Existing task
  authorization can cover routine fixes within scope; review-only requests do
  not add permission to initiate edits. Changed code
  invalidates readiness; require an updated PR/branch head, affected review and
  checks, and revised human-testing evidence where needed. Reassess the changed
  areas before landing. Do not silently take over the child's implementation
  or expand its task to satisfy an optional suggestion.
- For review-only requests, stop after the report. Before an authorized merge,
  recheck the live PR/task head, target branch, and relevant peer heads against
  this assessment. A changed task head needs fresh readiness evidence; changes
  to the target or related work need an updated conflict/interaction assessment
  and affected checks. Observe repository requirements for approval; human testing
  follows deployment unless the PR names a pre-merge manual check. No permanent monitoring service is part of this workflow.

## Preserve evidence, land, and verify

- Before local cleanup, preserve the task handoff and status note, source identity, PR/review
  links and verification evidence in a unique task directory outside the checkout
  being removed. Use the repository's ignored artifact location or a durable
  directory outside Git; never overwrite an earlier archive. Include canonical
  checkout/branch and workspace/session IDs for resources to be removed.
  Export any existing linked child Scratchpad while its session link remains.
  Absence of a Scratchpad is valid; inability to preserve required evidence is
  a reason to retain resources. Keep machine metadata out of public PRs.
- Integrate the validated source commit through the repository's established
  merge or PR workflow. Recheck that the source tip and any local task status
  have not changed before landing; stop if they have. Do not push or publish
  unless authorized.
  Resolve conflicts only within the agreed behavior; a material behavior
  decision still needs the user.
- Inspect the landed diff for accidental handoff files or other task artifacts.
  Validate the actual landed result with the repository's required checks,
  including generation/build and runtime checks when applicable. Record the
  landed SHA and the exact commands, targets, and results in the durable task
  record. Earlier child checks do not prove that integration works.
- If validation fails, keep the child workspace, worktree, and branch available
  while making authorized, scoped corrections. Do not claim completion merely
  because the merge succeeded.
- Preserve the PR-to-landed-commit correspondence in the task record.
  Integration does not prove deployment. Use the repository release workflow
  to establish delivery separately.

## Authorized cleanup

Proceed only after integration is verified and cleanup is authorized. If the
user requested only a merge, report its result and leave cleanup pending.

- Recheck the recorded source tip and worktree status before stopping the child.
  Any new edits or commits require reconciliation before cleanup. Inventory the
  target workspace for other sessions, terminals, unsaved documents, or work
  unrelated to this task; leave it open if closing it would discard that work.
- Stop only task-owned development servers or runtime instances using their
  recorded identities and repository cleanup instructions. Terminate the actual
  child agent process through supported Toastty terminal controls when authorized;
  marking a session stopped is bookkeeping, not proof that its process exited.
  Follow `toastty-capabilities` closing rules and never override an unsaved
  document block. Verify task writers have exited; if the available API only
  updates tracking, inspect processes tied to the checkout or retain it.
- Close the task workspace using supported controls once its owned processes
  are stopped and documents are saved or archived. Never close the finishing
  session's workspace. If the CLI cannot safely perform this step, report it as pending
  and retain the worktree rather than inventing a command or broad kill pattern.
- Immediately before filesystem removal, recheck the source SHA and worktree
  status and artifact contents against the captured values. Inspect ignored
  files too: preserve user data and configuration, and discard only confirmed
  disposable build output. Only remove task artifacts that were
  archived and unchanged; any other uncommitted or untracked content blocks
  deletion. Use `git worktree remove` without `--force`, then `git branch -d`
  for the fully merged local branch. Never use `git branch -D`.
- Ancestry proves ordinary merges; squash or rebase requires establishing that
  the validated source changes landed using the repository's integration
  evidence and diff inspection. If safe branch deletion refuses, leave the
  branch and report it. Do not force deletion to make cleanup appear complete.

Report the source and landed SHAs, verification, evidence archive, and which
processes, workspace, worktree, and branch were removed or retained. On partial
failure, report the completed step and remaining work. On a retry, inspect the
recorded landed result first so an already integrated task is not merged again.
