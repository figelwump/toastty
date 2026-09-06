# Integration and release

Use the target repository's Git, verification, and release procedures. This
reference coordinates those procedures; it does not introduce a deployment
engine or replace repository approval rules.

## Account for local and remote work

- Resolve the authorized remote/repository and destination, then refresh its
  refs. Inspect relevant local branches and assigned worktrees, including dirty
  state, against the fresh remote history. Record incoming remote work, outgoing
  local work, divergence, and the exact heads observed. If fetching fails, label
  the remote view stale and defer actions that need a current view.
- Keep discovery separate from integration scope. Show unassigned local work
  when it affects the plan, but do not push every discovered branch. Preserve
  unrelated edits, untracked data, local commits, and other agents' work.
- Ahead/behind counts are an initial clue. A squash or rebase can leave a local
  branch whose changes already landed under different commit IDs. Use the PR's
  recorded merge result and Git/diff evidence to establish correspondence;
  patch similarity alone is not proof of complete integration. Ambiguous cases
  remain unresolved rather than being shipped twice or deleted.
- Local-only commits intended for delivery need the same review and validation
  as remote PR work. Route them through the repository's PR workflow when
  required, including commits made locally on the destination branch. Never
  bypass review by pushing that branch directly. Local-only restrictions remain
  in effect until the user authorizes publication.
- During authorized integration, bring eligible local and remote changes
  together using the repository's merge policy. Use an isolated checkout when
  the destination has unrelated edits. Coordinate task writers before changing
  their branch. Do not auto-stash, reset, force-push, or discard work to reconcile
  divergence. An unresolved behavior conflict needs a decision or an owned fix.
- Validate the integrated result and push through the permitted workflow. If
  the destination moved or a normal push is rejected, refresh and reassess the
  changed history and affected checks; do not force the previous plan through.
  Use repository release preflights to verify the exact revision is available on
  the intended remote before deployment. A local merge is not remote delivery.

## Propose one coherent release

- Compare eligible integrated work with the observed deployed revision or
  artifact at each affected target. Include already-merged but undeployed work,
  even if its PR is closed or local workspace was removed. Reconstruct this
  from Git/PR merge records and existing release evidence, not just the list of
  currently open PRs. Identify missing history or unsupported targets explicitly.
  An unknown baseline blocks execution for the affected target until the
  repository's release workflow establishes a supported starting state; continue
  independent assessment rather than treating unknown work as eligible.
- Derive targets and prerequisites from the combined diff and release guides.
  Two PRs touching the site may need one site deployment. Another change may
  additionally need an API deployment, migration, package publication, or client
  installation. Deduplicate compatible target operations, not arbitrary shell
  commands; preserve required ordering and compatibility checks.
- Select exact source revisions/artifacts and record which changes they include.
  A proposed batch may discuss unmerged candidates, but executable plans must
  use eligible, validated integration results. Account for all changes in each
  selected revision, including other merged work since the deployed baseline.
  If unwanted or unready work would be included, revise the batch using the
  repository's release strategy; do not silently deploy it with the selected PRs.
- Produce the repository's existing release-plan artifact where available. Name
  included PRs/local changes, targets, source revisions/digests, prerequisites,
  order, checks, outstanding approvals, and recovery/rollback procedure. Use a
  compact local plan only when the repository has no equivalent. Reuse existing
  status, preparation, dry-run, and validation commands; report their actual
  targets and whether they mutate local, disposable, or production state.
- Honor repository review of meaningful release decisions as well as code
  review. Preparation can itself have side effects: inspect its contract and
  stay within authorized scope. Prepared work does not authorize applying it.
  Preserve existing standing integration/release authorization when it covers
  the selected changes and targets.

## Execute and reconcile the outcome

- Before acting, refresh source and target evidence and use the repository's
  concurrency protections. Reprepare stale plans as its workflow requires.
  Record the selected plan and in-progress operation before starting it so a
  resumed session can inspect the same operation instead of starting another.
- Execute the authorized plan through the existing release tooling. Verify each
  required target against its expected revision/artifact and required health
  checks. Publishing an artifact, deploying a service, and installing on a
  computer are different outcomes; display only the ones actually established.
- On failure or disconnect, determine whether the recorded operation is still
  running before retrying. Follow that workflow's resume/rollback contract;
  never launch an overlapping release or improvise the remaining commands.
  Keep successful, failed, rolled-back, pending, and unknown target states
  explicit. Do not move an entire task to Complete after only a partial release.
- Preserve the integrated source and release evidence after task cleanup. Later
  polls should detect drift or rollback and update delivery status from observed
  state; a task's previous Complete label is not permanent proof it is deployed.
