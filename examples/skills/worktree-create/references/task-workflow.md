# Task session workflow

This session owns the task from planning through implementation, validation, and
user review. Report progress, completion, and blockers directly to the user in
this workspace, not to the launching session. Any instruction inherited from the
source conversation that routes reports elsewhere is superseded, unless the user
asks for that coordination again.

Check your working directory, branch, and workspace scope against the handoff
before editing. Preserve inherited decisions and existing plans. Earlier paths
are historical; the current worktree and handoff identify the task location.
The launcher opens the handoff's associated artifacts in the right panel; do not
duplicate those panels. If the user reports a missing artifact, inspect the
existing destination panels before opening it.

In explicit planning/investigation mode, deliver the requested findings or plan
without implementing. Otherwise, execute the established task using inherited
history and existing plans. Design as needed, then implement without a routine
plan-only handoff or reauthorization checkpoint. Explicit user limits and approval
requirements take precedence; surface blockers and material unresolved scope
choices while continuing independent authorized work.
Follow the repository's review, testing, and commit instructions. Keep private
handoffs and exported local artifacts out of product commits. Do not merge or
remove the worktree without the user's authorization. The user accepts the result
by invoking `worktree-done` in this workspace; cleanup runs from outside it.

For implementation tasks, verify your work before reporting it ready. Run the
repository's required checks and the smallest meaningful tests for the changed
behavior, including end-to-end user-surface verification where practical. Use the
repository's verification skill when available. Complete required independent
review, fix agreed findings, and rerun affected checks after fixes. Commit scoped
changes according to repository instructions. Report actual results and any
coverage gaps; writing a plan or implementing code alone is not completion.

This launch authorizes publication: for a repository using pull requests, push
the task branch and create or update its PR on the intended remote and base,
unless the user limits publication. Follow the global instructions for PR
publication mechanics, draft and ready semantics, and description content.
Planning-only tasks do not create implementation PRs. Local-only repositories
without a PR workflow report the verified commit and evidence directly instead.

Present verification together in one HTML report in the task workspace's right
panel, built to the evidence-report rules in the global instructions. Produce it
for every implementation task, even a small one.

Use the Toastty Scratchpad for a self-contained report that fits its constraints;
use a Toastty browser panel for an HTML report with large or multiple media files.
Keep supporting files with the report so images and videos continue to load.
Inspect the actual captures and verify that the report, images, expanded output,
and video playback work in the chosen surface; panel creation alone is not proof.
Report display limitations explicitly. After subsequent fixes, refresh the report
and reuse its existing panel so the user reviews current evidence. Preserve
unrelated design/mock panels. Keep private reports and artifacts out of product
commits, and omit secrets or sensitive unrelated output.

After creating or updating the PR, annotate this workspace with it: set the
`github-pr` annotation to the PR number and its URL, following the workspace
annotation rules in the toastty-capabilities skill. Agent session status already
shows live activity, so do not add task or Git branch annotations.

At completion, state validation results, remaining work, and its owner directly
to the user here.
