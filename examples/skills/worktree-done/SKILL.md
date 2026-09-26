---
name: worktree-done
description: Use when the user says they are done reviewing or testing this worktree and want its pull request merged. Verifies the worktree matches the PR, then enables auto-merge so GitHub merges it once required checks pass. Never infer user acceptance from an agent finishing, a ready PR, or passing checks.
---

# Worktree Done

The user's invocation accepts the version they reviewed and authorizes merging
this task's PR once the repository's required checks pass. It does not authorize
merging other PRs, deployment, or a release. Do not invoke it on the user's
behalf merely because implementation is finished.

Cleanup happens from outside this workspace with `worktree-cleanup`. Do not close
this workspace, remove its worktree, or delete its branch from inside it.

## Verify the accepted version

Work in this task's worktree (`git rev-parse --show-toplevel`). Find its PR with
`gh pr view --json number,state,isDraft,headRefOid,baseRefName,url,mergeStateStatus,statusCheckRollup`.
Stop and report, without merging, when:

- there is no PR, or it is closed or already merged;
- `git status --porcelain` shows uncommitted or untracked changes;
- after `git fetch`, local `HEAD` differs from the PR's `headRefOid`. New local
  commits, or remote commits the user has not reviewed, need their review first;
  do not commit or push new work as part of this acceptance;
- the PR's base is not the repository's default branch. Its base PR must merge
  first; GitHub then retargets this PR, and the user can run this again.

## Merge when checks pass

1. If the PR is a draft, mark it ready with `gh pr ready <number>`.
2. Run `gh pr merge <number> --auto --merge --match-head-commit <headRefOid>`. Use
   the repository's documented merge method instead of `--merge` when it has one.
   GitHub merges when the required checks pass, or at once if they already have.
3. If the command fails with `Pull request is in clean status`, GitHub refused to
   queue a PR that is already mergeable; auto-merge is not turned off. Recheck with
   `gh pr view <number> --json state,mergeable,mergeStateStatus,headRefOid,baseRefName`.
   If the PR is still open, `MERGEABLE`, `CLEAN`, at the accepted head, and on the
   same base, merge it directly with `gh pr merge <number> --merge --match-head-commit <headRefOid>`,
   using the same merge method as step 2. Otherwise report its state and stop.
4. If the repository has auto-merge turned off, report that and stop. Do not wait
   and merge manually; the user can merge through `worktree-cleanup` once checks
   pass.
5. Confirm the result with `gh pr view <number> --json state,autoMergeRequest`.

Report the PR, the accepted commit, and whether it merged or will merge when
checks pass. Mention that `worktree-cleanup` removes the workspace and worktree
after the merge. Keep the `github-pr` workspace chip.

`--match-head-commit` checks the head only when auto-merge is enabled. GitHub
keeps auto-merge on if someone with write access pushes later, so a later commit
would merge unreviewed. Push nothing to this branch while auto-merge is on.

## More work after acceptance

If the user asks for more changes before the PR merges, first run
`gh pr merge <number> --disable-auto` so the new commits cannot merge unreviewed.
Make the changes, verify them under repository rules, and ask the user to run
`worktree-done` again after reviewing the new version. If the PR already merged,
the follow-up work needs a new branch and PR.
