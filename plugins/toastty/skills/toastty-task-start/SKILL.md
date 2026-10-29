---
name: toastty-task-start
description: Use in a Toastty-managed session when the user asks to start implementing, start work, or move the work into a worktree, or when agreed work should split into separate tasks. Moves this task into its own git worktree with `toastty task start-work`, or creates new tasks that start in their own worktrees with `toastty task create --start-work`.
---

# Toastty Task Start

Toastty gives a task its own git worktree when its work starts. It fetches the
base, adds the worktree next to the main checkout, runs the project's
`create_hook`, and continues this conversation there. Do not create the
worktree, write a handoff, or fork the session yourself.

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

## Move this task into a worktree

When the user says to implement, start work, or move to a worktree:

1. Choose a branch prefix that describes the work and follows the repository's
   conventions, such as `feat`, `fix`, `refactor`, `docs`, or `chore`. Add
   `--base <branch>` only when the work must start from something other than
   the remote's default branch, such as the branch of a stacked pull request.
2. Run `"$TOASTTY_CLI_PATH" task start-work --branch-prefix <prefix>`. In a
   session that is not a task yet, also pass `--title "<short title>"`.
3. If the command fails, report its error and stop. Otherwise end your turn
   at once with one short line saying that the work continues in the worktree.
   Run nothing else: Toastty waits for this turn to end, continues this
   conversation in a new session in the worktree, and then closes this one.

The continued session's first message names its worktree and branch. Work only
there, and do not run `start-work` again. If the move fails, the task shows in
the sidebar Inbox with the reason, and `toastty task get <task-id>` reports it
under `worktree`. The user can retry from the Inbox or with
`toastty task retry <task-id>`.

## Split work into new tasks

When the agreed plan has parts that should land as separate pull requests, give
each part its own task:

```bash
"$TOASTTY_CLI_PATH" task create "<one-line summary>" --start-work \
  --agent <profile> --model <model> --effort <effort> \
  --prompt-file <brief.md> [--title <title>] [--slug <slug>] \
  [--branch-prefix <prefix>] [--base <branch>]
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
  not.

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

## Pull requests

After you open a pull request from the worktree, set the workspace's
`github-pr` annotation as `toastty-capabilities` describes.
