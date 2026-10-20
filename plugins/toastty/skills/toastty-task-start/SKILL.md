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

## Pull requests

After you open a pull request from the worktree, set the workspace's
`github-pr` annotation as `toastty-capabilities` describes.
