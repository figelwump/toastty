# Task session workflow

This session owns the task from planning through implementation, validation, and
user review. Report progress, completion, and blockers directly to the user in
this workspace. This workflow does not require a task queue, coordinator,
worktree-done, or messages to the launching session. Historical return-route or
coordinator instructions inherited from the source conversation do not apply to
this launch unless the user explicitly requests that coordination again.

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
remove the worktree without the user's authorization.

For implementation tasks, verify your work before reporting it ready. Run the
repository's required checks and the smallest meaningful tests for the changed
behavior, including end-to-end user-surface verification where practical. Use the
repository's verification skill when available. Complete required independent
review, fix agreed findings, and rerun affected checks after fixes. Commit scoped
changes according to repository instructions. Report actual results and any
coverage gaps; writing a plan or implementing code alone is not completion.

For repositories using pull requests, the user's authorized implementation handoff
includes pushing the task branch and creating or updating its PR on the intended
remote and base, unless the user limits publication. After local implementation,
required local review, verification, and presentation of evidence are complete,
continue through publication without another routine approval question. If required
checks depend on remote CI or PR review, push and open or keep the PR as draft,
then mark it ready once all required checks pass. Keep or return it to draft if
required verification fails or is blocked, and report the blocker. Keep the PR
body current with the final behavior, evidence, and material limitations. Readiness
means ready for the user's review/testing; merging, deployment, and production
activation require separate authorization. Honor explicit user limits, applicable
repository publication rules, and runtime approval requirements; this scope does
not bypass a denial. Further changes require affected checks to be rerun, the
evidence refreshed, and the PR updated.
Planning-only tasks do not create implementation PRs. Local-only repositories
without a PR workflow report the verified commit and evidence directly instead.

Present verification together in one HTML report in the task workspace's right
panel. Include the checked commit/version, an outcome summary, and checks with
commands, results, target/environment, and remaining gaps. Group evidence by the
behavior or scenario it proves: embed captioned screenshots, relevant CLI/test
output in readable expandable sections, and playable videos when available.
Keep the evidence needed for review in that page rather than requiring the user
to switch among screenshot, transcript, and report tabs. Raw artifact links may
supplement the report. Do not generate media for checks that do not need it.

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
