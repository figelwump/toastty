---
name: toastty-task-start
description: Use when a Toastty task's first message names this skill, and in any Toastty-managed session when the user asks to start implementing, start work, move the work into a worktree, or split agreed work into separate tasks. Takes a task from the user's request to the user's review - clarify, move implementation into its own git worktree with `toastty task start-work`, implement and verify, publish the pull request and evidence, and set the task's status.
---

# Toastty Task Start

Toastty runs each task in its own task space. The task's agent owns the task
from the user's request to the user's review: it reports progress, questions
and results to the user in that task space.

Run the commands below with `"$TOASTTY_CLI_PATH"`. If it is not set, report that
this skill must run inside a Toastty-managed agent session, and stop.

## Sandbox permissions

Every Toastty CLI command in this skill connects to the app's local socket.
In a sandboxed runtime, request the runtime's per-command sandbox escalation
on the first attempt. Do not try the command sandboxed first.

In Codex, use `sandbox_permissions="require_escalated"` with a short
justification that the command needs Toastty's local socket. Escalation runs
that invocation outside the sandbox; it does not restrict access to one socket.
Limit the request to the exact command. Do not request a broad approval prefix,
change sandbox settings, or widen Toastty's workspace scope. If escalation is
unavailable or denied by runtime policy or approval review, report the
restriction and stop.

## Which instructions win

The task's first message can have text from the user's `start_prompt` between
the skill line and the task. The repository has its own instructions, such as
`AGENTS.md` or `CLAUDE.md`, for building, testing, review, commits and pull
requests. Both take precedence over this skill where they differ. This skill
gives the defaults and Toastty's own rules.

## Show suggested UI changes as mockups

When you suggest a change to a UI, a design, or a user experience, at any step
of the task, include a mockup of it in the same answer. Publish it in a
Scratchpad in this task workspace, as `toastty-scratchpad` describes, and keep
it separate from the verification report. Do not describe the change only in
words. Show the current UI next to the change when that makes the difference
clear. If you are not sure which direction is best, mock up a few directions
next to each other and recommend one.

## 1. Read the request and check the location

The text after the skill line, or after "The task, as written:", is the user's
request. The user often writes it quickly and without context. The message
lists any attached files with their paths; read them.

The first message says where you are. A new task starts in the project's own
checkout, not in a worktree: do not edit files there. If the directory or
branch does not match the message, stop and say what you found.

If the request is for a different repository than this task's project, say so
and ask the user how to continue. `task set-workspace` does not move a task
that has started. When the user agrees, create a child task in that project
with `task create --workspace <id> --start-work` (see
[Split work into new tasks](#split-work-into-new-tasks));
`task workspace-choices` lists the workspace IDs.

## 2. Clarify

Read the code and documents the task touches. Then ask the user, in one
message, only the questions whose answers change the scope, the approach, or
how the user will accept the work. Give your recommended answer for each
question, and wait for the reply. If nothing is unclear, state the plan in two
or three lines and continue without waiting.

## 3. Choose where to work

- **A question or an investigation:** answer it here. Do not move it into a
  worktree, and do not edit files. Then report and set the status (step 7).
- **Implementation work:** move this task into its own worktree, as the next
  section describes.
- **Parts that should land as separate pull requests, or work in another
  repository:** give each part its own task (see
  [Split work into new tasks](#split-work-into-new-tasks)).

The user's request authorizes the work within its stated scope. Merging,
deployment, production changes and deleting the user's data still need the
user's explicit approval.

## Move this task into a worktree

1. Choose a branch prefix that describes the work and follows the repository's
   conventions, such as `feat`, `fix`, `refactor`, `docs`, or `chore`. Add
   `--base <branch>` only when the work must start from something other than
   the remote's default branch, such as a feature branch the work lands on or
   the branch of a stacked pull request.
2. Run `"$TOASTTY_CLI_PATH" task start-work --branch-prefix <prefix>`. In a
   session that is not a task yet, also pass `--title "<short title>"`.
3. If the command fails, report its error and stop. Otherwise end your turn
   at once with one short line saying that the work continues in the worktree.
   Run nothing else: Toastty waits for this turn to end, continues this
   conversation in a new session in the worktree, and then closes this one.

The continued session's first message names its worktree, branch and base.
Work only there, and do not run `start-work` again. If the move fails, the task
shows in the sidebar Inbox with the reason, and `toastty task get <task-id>`
reports it under `worktree`. The user can retry from the Inbox or with
`toastty task retry <task-id>`.

## 4. Implement and verify

Toastty runs the project's `create_hook` in a new worktree. If the repository's
instructions name a setup step for a fresh worktree that the hook did not run,
such as a bootstrap script, run it before you build or test.

Follow the repository's instructions for design, code style, tests, review and
commits. Then verify the work before you report it ready:

- Run the checks the repository requires, and the smallest set of tests that
  covers the changed behavior. Use the repository's verification skill or
  documented workflow when it has one.
- For a change the user can see or use, check it through the real surface
  where practical: the app, the CLI, the API or the browser.
- Record what you ran, on which commit, and what happened. A plan or code
  alone is not completion, and a summary without output is not proof.

Commit only the changes for this task.

## 5. Publish the pull request

In a repository that uses pull requests, push the task's branch and open or
update its pull request on the base the worktree started from, unless the user
limited publication. Keep it a draft while required checks run, and mark it
ready when they pass. Readiness does not authorize a merge.

- Set the workspace's `github-pr` annotation to the pull request, as
  `toastty-capabilities` describes. Toastty reads the pull request from it: the
  task shows as ready for review while the pull request is open, not a draft,
  and no agent works on it. Do not run `task ready-for-review` for work with a
  pull request.
- Open the pull request in a browser panel in this task workspace's right
  panel, as `toastty-capabilities` describes. Reuse a panel that already shows
  it.
- Follow the pull request's checks to their result. Use one waiter, such as
  `gh pr checks --watch`, and keep the turn active until it returns. Pending
  checks are not a blocker and not a reason to hand off. Only results for the
  pull request's current head commit count. An empty check list, or a waiter
  that exits before the checks start, is not a pass. An error from the query
  is an error, not a pending result. Marking the pull request ready can start
  more checks: follow those too. If a check fails, fix it within the task's
  scope and check again.
- After later changes, update the pull request's description and the evidence
  for the new commit.

In a repository without pull requests, report the verified commit instead.

## 6. Show the evidence

For implementation work, publish one verification report in this task
workspace's Scratchpad, as `toastty-scratchpad` describes.

- Start with a short summary that makes sense without the conversation: the
  problem or the requested feature, the cause when it is known, what changed,
  and the result.
- Then give each check: the command or user steps, the commit, the result, and
  its proof, such as terminal output, or screenshots or video for a visual
  change. Size the proof to the change. Link each material change and risk
  to the check that covers it, or list it as not covered.
- Look at the screenshots and video yourself, and confirm that they show in
  the report.
- After later changes, refresh the same report so it names the current commit.
- Publish or update the report after you open the pull request's panel, so
  that the report is the selected tab in the right panel.
- Do not change the user's selected workspace, tab or keyboard focus to show
  the report or the pull request.

This task owns the report, also when child tasks do the work. A child's summary,
or a report in the child's own workspace, is not proof: read the child's
evidence files yourself, check them, and publish the report with its proof here.

## 7. Report and set the status

Prepare the complete answer before you change the status. Finish with what you
found or changed, how you verified it, what remains and who owns it, and the
task's status. Point to the evidence in this task's Scratchpad.

- **A question for the user:** run
  `"$TOASTTY_CLI_PATH" task needs-reply --question "<the question in a few words>"`
  just before you end the turn. The task then waits in Needs you until the
  user answers. Also use it for blocked work, and report the blocker and the
  next action. Use it when continuing this task depends on the user's
  decision about a proposed change or plan, even when the explanation or
  investigation is complete. State the decision needed in your final answer.
  Check the conversation first: if the user already authorized the work,
  continue within that scope instead of asking for the same approval again.
- **A completed answer, investigation, plan, or other work without a pull
  request:** use this only when the requested work is complete and the task
  does not wait for a decision to continue that work. A request only for an
  answer, investigation, or plan can be complete when delivered, even if it
  suggests possible future work. An explanation or proposed fix alone does
  not complete requested or authorized implementation. Mark the task ready
  for review, so that the user can read the result and follow up before
  deciding the task is Done. Run
  `"$TOASTTY_CLI_PATH" --json task get` and confirm that its request matches
  this conversation. Then run
  `"$TOASTTY_CLI_PATH" --json task ready-for-review <task-id>`, require
  `ok=true`, and read the task again to confirm `readyForReviewAt` is set and
  `doneAt` is null. If you cannot verify the task's identity, do not change
  it, and say so.
- **Work with a pull request:** the user accepts it with the Merge button or by
  saying "merge it", which runs `toastty-task-merge`. Do not merge it yourself,
  and do not mark the task Done.
- **Work in child tasks:** do not mark this task ready for review or Done.
  Toastty finishes it when its children finish and at least one of them
  merged; a ready-for-review mark never clears and keeps it open. If this task
  still owns work after they merge, use `task needs-reply` or
  `task ready-for-review` to keep it open.
- **Done:** mark a task Done only when the user explicitly accepts the result
  and asks to finish it. Answering the question, finishing a turn, or having
  no file changes is not acceptance. Use `task mark-done <task-id>`.

## Split work into new tasks

When the agreed plan has parts that should land as separate pull requests, give
each part its own task:

```bash
"$TOASTTY_CLI_PATH" task create "<one-line summary>" --start-work \
  --agent <profile> --model <model> --effort <effort> \
  --prompt-file <brief.md> [--title <title>] [--slug <slug>] \
  [--branch-prefix <prefix>] [--base <branch>] [--workspace <id>]
```

- Choose the agent, model and effort for the part. You know the work, so Toastty
  does not need to choose them.
- Put everything the new agent needs in the prompt file: the goal, decisions
  already made, where to start, what done means, and the authorization the user
  gave, such as publishing a pull request.
- Use `--base` with a branch on the remote for work that builds on another
  part's branch.
- Each call returns a task ID while setup continues. Check one with
  `toastty task get <task-id>`, or add `--wait` to wait until its agent starts.
- The new tasks record this one as their parent. Coordinate them from here.
- Tell each new task how to report back: `toastty task send <this task's ID>
  "<message>"`. `toastty task get`, with no ID, shows this task and its
  `taskID`. Task IDs keep working after a relaunch; panel and session IDs do
  not. The message must include the paths of the new task's verification
  report and evidence files, such as screenshots and test output.

## Wait for other tasks

Do not poll in a shell loop. To continue when another task reaches a point,
run `"$TOASTTY_CLI_PATH" task watch <task-id> --until <condition>` and end your
turn. Toastty sends you one line, starting `[Toastty watch`, when the condition
holds or can never hold. Conditions: `idle` (its agent finished a turn after
you started watching), `waiting` (it waits for an approval or an answer),
`ready-for-review`, `merged`, `to-ship`, `done`, or `archived`.

To ask another task's agent something, run `toastty task send <task-id>
"<question>"`, then watch it `--until idle` and read the answer with
`toastty task get <task-id>`, under `lastReply`. A milestone that is not a
stage, such as "the API is defined", is a `task send` from the task that
reaches it.
