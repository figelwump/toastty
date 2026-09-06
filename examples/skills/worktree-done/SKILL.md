---
name: worktree-done
description: Use this skill from the parent when the user wants to review, merge, or finish a Toastty worktree task or its PR, assess codebase consistency and relevant in-flight work, and perform authorized child-session, workspace, worktree, and branch cleanup.
---

# Worktree Done

This example personal skill reviews and, when authorized, lands a task from the
parent session using the target repository's integration and verification rules. The user can name the task; discover
its validated commit without requiring them to supply a SHA.

## Resolve the task and authority

- Require `TOASTTY_CLI_PATH` and `TOASTTY_SESSION_ID`. If absent, stop with
  `error: worktree-done must run inside a Toastty-managed agent session`.
  Use `toastty-capabilities` to discover the running CLI's supported queries
  and actions before controlling sessions or workspaces.
- Resolve the task using the parent's launch record,
  `git worktree list --porcelain`, `WORKTREE_HANDOFF.md`, and live
  workspace/session metadata.
  Match branch and canonical checkout path, then workspace and session IDs;
  titles alone are insufficient. Ask only when the target remains ambiguous.
- Resolve the landing branch and its checkout from the user's instruction,
  the handoff, and repository rules. Use upstream/default-branch information
  as evidence when needed; do not hardcode `main` or assume the task's base
  branch is the destination. Honor required PR, CI, review, and merge gates.
- Run integration from the landing checkout and cleanup from a parent session
  outside both the target checkout and target workspace. Canonicalize paths
  through symlinks and compare directory boundaries, not string prefixes. If
  invoked from the child, prepare the readiness handoff and direct the user
  to the parent; do not delete the active session or expand its workspace scope.
- A request to merge and clean up authorizes both actions; do not ask again
  at each step. A merge-only request does not authorize termination or deletion.
  A readiness report, finished goal, or passing test does not authorize a merge.
- A review-only request authorizes assessment and a report, not changes to the
  task branch, PR state, or child workspace. Do not advance into landing,
  evidence archiving for cleanup, process termination, or deletion without the
  corresponding authorization. Keep feedback in the parent report/Scratchpad;
  posting PR comments or requesting changes from the child needs authorization
  for that action, which may already be part of the task.

## Establish readiness

- Read repository instructions first (`AGENTS.md`/`CLAUDE.md`), then the local
  verify skill they name, then relevant build/test docs and CI configuration.
  Use those to select and report the required review and checks for this diff.
  If no verification guidance exists, choose the smallest meaningful checks
  supported by the project and state what remains unverified.
- Read the child's session-linked Scratchpad and review/test evidence. Match
  `ValidatedCommit: <full SHA>` to the committed task branch tip. For an older
  task without that field, establish the commit from existing evidence or
  complete the missing verification before proceeding; do not equate “done”
  with verified. A newer tip needs updated review and verification.
- For a PR, verify its repository, base branch, head branch, and live head SHA
  against the task identity. Integration requires the PR head, task branch tip,
  and `ValidatedCommit` to agree, with required review and CI covering that head.
  Do not silently choose the newer of conflicting tips. For review-only work,
  assess an explicitly identified current commit and label missing or stale
  readiness evidence; it need not prevent useful read-only feedback.
- Before integration, confirm the child is idle and will not continue writing.
  Capture the branch tip and worktree status, including untracked files and
  content fingerprints for artifacts that will be removed. Status paths alone
  cannot detect later edits to an already-untracked handoff.
  Preserve uncommitted or unpublished work; never stash, reset, or force it
  away. Treat the handoff as an artifact to preserve, not a product change.
- Before integration, check the landing checkout can accept it without mixing
  unrelated local changes. Preserve those changes; do not clear them to make room.
  Refresh the destination only as the repository requires, without discarding
  local commits or bypassing its integration policy.

## Parent assessment

Integration requires a completed parent assessment of the exact task commit.
Run this pass before merging if no current assessment exists, even when the user
only said “merge.” It also supports review-only requests and complements
repository-required independent review, CI, and human testing.

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
  cosmetic preferences do not become new gates. Keep the report in the parent
  Scratchpad or other durable task record.
- The child owns fixes. Return actionable findings to the user and, when
  authorized, resume the existing child for accepted corrections. Existing task
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
  and affected checks. Observe repository requirements for human testing and
  approval. No permanent monitoring service is part of this workflow.

## Preserve evidence, land, and verify

- Before closing anything, export the child's linked Scratchpad while the
  session link still exists. Copy the export and handoff into a new, unique
  task directory under the parent checkout's `artifacts/worktree-done/`,
  outside the checkout being removed. Do not overwrite an earlier archive.
  Include the source SHA, target branch, workspace/session IDs, and validation
  evidence in the archive. Keep these records out of product commits; use the
  repository's ignored artifact location, or a durable parent-owned directory
  outside the repository if `artifacts/` would dirty the landing checkout.
  If required evidence cannot be preserved, retain the workspace and worktree.
- Integrate the validated source commit through the repository's established
  merge or PR workflow. Recheck that the source tip and status have not changed
  before landing; stop if they have. Do not push or publish unless authorized.
  Resolve conflicts only within the agreed behavior; a material behavior
  decision still needs the user.
- Inspect the landed diff for accidental handoff files or other task artifacts.
  Validate the actual landed result with the repository's required checks,
  including generation/build and runtime checks when applicable. Record the
  landed SHA and the exact commands, targets, and results in the parent archive
  or Scratchpad. Earlier child checks do not prove that integration works.
- If validation fails, keep the child workspace, worktree, and branch available
  while making authorized, scoped corrections. Do not claim completion merely
  because the merge succeeded.

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
  are stopped and documents are saved or archived. Never close the parent's
  workspace. If the CLI cannot safely perform this step, report it as pending
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
