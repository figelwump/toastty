# Coordinator reviews

A review brief explains a change and the decision it needs. Each record belongs
to one task, GitHub pull request, destination branch and full commit ID. A new commit needs a new
brief and user approval. The brief contains the behavior change, decision,
verification, gaps, recommendation and evidence.

Toastty keeps reviews and copied evidence in its runtime config directory,
apart from task worktrees. They survive app restarts and task cleanup. A
storage load error remains visible and blocks writes; Toastty does not replace
an unreadable file with an empty review queue.

## Publish and read a brief

A coordinator or visible task agent publishes structured JSON:

```json
{
  "behaviorChange": "Quick entry creates tasks while the coordinator is off.",
  "decisionNeeded": "Approve the change after checking the report.",
  "verification": ["The quick-entry integration tests pass."],
  "gaps": ["The keyboard shortcut has not been checked on a second display."],
  "recommendation": "Approve after inspecting the screenshot.",
  "priority": "ready",
  "evidence": [{"kind": "report", "label": "Verification report"}]
}
```

```bash
toastty coordinator review publish <task-id> --head <full-commit-id> --base <branch> \
  --brief-file brief.json --evidence-file 0=report.html
toastty coordinator review list [--task <task-id>] [--limit <count>] [--after <review-id>]
toastty coordinator review get <review-id>
```

`--evidence-file` associates a file with the zero-based index of an evidence
entry. Repeat it for more files. Paths are resolved relative to the CLI's
working directory. Toastty copies regular files of up to 8 MiB each into managed
storage. It rejects symbolic links and caller-supplied managed filenames.
Evidence can also contain a web `url` and a bounded text `excerpt`.

Publishing the same task, PR, destination and head updates its existing brief until the user
acts. It cannot replace an accepted brief or supply a user decision. Required
fields are `behaviorChange`, `decisionNeeded` and `recommendation`; omitted
lists default to empty, and priority defaults to `ready`. Priorities are
`urgent`, `blocking` and `ready`. A native user priority override takes precedence
and persists separately from agent publications.

The app-control equivalents are `coordinator.review.publish`,
`coordinator.review.get` and `coordinator.review.list`. `publish` accepts `taskID`,
`head`, `baseRefName`, a `brief` object or JSON string, and optional `evidenceFiles` as a JSON
list of `{ "evidenceIndex": 0, "filePath": "/absolute/report.html" }` objects.
Workspace-scoped callers see only reviews of tasks they may read. List results
include `nextAfter`; pass it as `--after` until it is null. The default page
limit is 20, with a maximum of 100 and a byte budget.

## User decisions and task delivery

Approve & Merge refreshes the PR state and records the exact reviewed head and destination
before delivery. It sends the request to the task's agent in that task's checkout.
The agent follows the repository's instructions and merge skills. Existing
explicit project `merge_skill` and `merge_prompt` settings are still used.
A coordinator-side project-to-skill map is not required.

The request carries a stable intent ID and a guarded final command:

```bash
toastty task merge --head <approved-commit-id> --review-intent <intent-id>
```

Toastty refuses a different head or destination, a missing, replaced or cancelled
intent, or an intent
whose review service is unavailable. The final merge owner checks the destination before each attempt and uses the
approved head at the merge API. Existing task merges outside the review surface keep
their established behavior.

Request changes saves the feedback before delivery. A busy task agent receives
the request after its turn ends. If no task agent runs, Toastty starts it in the
task checkout. Neither operation requires the global coordinator to be running.

Delivery states are `pending`, `dispatching`, `delivered`, `uncertain` and
`failed`. A restart never automatically repeats an unfinished terminal write.
An explicit native Retry action creates a new intent after a failed or uncertain
delivery, or after an agent reports a delivered request blocked or failed. Earlier
intents remain in the review action history. App delivery details remain separate
from agent reports. Inspect the task first when submission is uncertain.

## Report progress and confirm results

Task agents report against the intent they received:

```bash
toastty coordinator review report <review-id> --intent <intent-id> \
  --outcome blocked --detail "A required check failed; see the CI run."
```

Outcomes are `queued`, `checking`, `blocked`, `failed`, `headChanged`, `merged`
and `changesRequested`. A report is advisory. Even a report of `merged` does
not confirm a merge. Toastty observes the PR state and requires its head to
match the reviewed commit before recording a confirmed merge. Duplicate
reports have no further effect, and reports for a replaced intent are refused.
Agent-facing commands can publish, read and report; user approval, feedback,
retry and priority changes are native actions.

The built-in queue reconciles current task and PR facts with these records.
It shows tasks without a matching brief explicitly, works while the coordinator
is unavailable, and orders urgent blockers, dependencies, then ready reviews.
