# Tasks

A task is a piece of work you hand to an agent. You describe it, Toastty saves
it, makes a task space for it under a workspace, and starts the agent there.
The task keeps its own record, so it exists before its task space is ready and
after setup fails.

This page covers creating tasks from the CLI or from an agent, moving a task
into its own git worktree, the sidebar Inbox, and `~/.toastty/tasks.toml`.

## Create a task

```bash
toastty task create "Composer keeps a blank line after send" \
  --workspace "$WORKSPACE_ID" --agent codex --model gpt-6.1-sol --effort high
```

`task create` returns as soon as Toastty has saved the task. Setup continues in
the background. Add `--wait` to wait until the agent has started or setup has
failed; the command then exits with 1 on a failed setup, or when the wait passes
`--timeout` seconds (default 180).

| Option | Description |
|---|---|
| `<text>` or `--text` | The task, as written. The agent receives it unchanged. |
| `--file <path>` | A file to attach. Repeat for more files. Toastty keeps its own copy. |
| `--workspace <id>` | The workspace the task belongs to. A subspace means its parent. An agent session defaults to its own workspace. |
| `--agent`, `--model`, `--effort` | The agent profile from `agents.toml` and its settings. Missing values come from `[defaults]` in `tasks.toml`. |
| `--prompt <text>`, `--prompt-file <path>` | A first prompt, sent before the task text. |
| `--title`, `--slug` | The task's title and the task space's name. They default to the first line of the text. |
| `--request-id <id>` | The caller's key for this request. A repeat from the same agent session, or from the CLI outside one, with the same key returns the first task instead of making another. |
| `--start-work` | Make a git worktree during setup and start the agent there. See [Work in a git worktree](#work-in-a-git-worktree). |
| `--base <ref>`, `--branch-prefix <prefix>` | With `--start-work`: what the worktree starts from, and the first part of its branch name. |

A task needs a workspace and an agent. A request without them, with an agent
that is not in `agents.toml`, with a file that cannot be read, or whose first
message would be longer than 64 KB fails at once and saves nothing. A file
given as a symbolic link is copied as the file it points to.

Other verbs:

```bash
toastty task get <task-id>      # one task, with its setup state
toastty task list               # every task, oldest first
toastty task retry <task-id>    # run setup, or a move into a worktree, again after it failed
toastty task delete <task-id>   # delete the task and its attached files
```

These are short forms of `action run task.create`, `query run task.get`,
`query run task.list`, `action run task.retry` and `action run task.delete`.

## What setup does

1. Toastty finds the workspace's root directory: the git root of its first
   terminal, or that terminal's directory outside a repository. It saves the
   root on the workspace and on the task, where it never changes.
2. It makes a task space nested under the workspace, with one terminal in the
   root directory. The task space is named after the task's slug and is not
   selected, so your focus stays where it is.
3. It starts the agent in that terminal. The agent's first message is the first
   prompt, then the task text exactly as written, then the paths of the
   attached files. The agent session is scoped to its task space.

Toastty saves each step to disk as it happens. If setup fails, or Toastty quits
before setup ends, the task shows as failed, and Retry continues from the last
step that finished: it reuses the task space instead of making a second one.

When an agent creates a task, the new task space joins that agent's workspace
scope, and the agent session is recorded as the one that spawned it. A task
created from an agent in another task's task space records that task as its
parent (`parentTaskID`).

## Work in a git worktree

A task's agent starts in the project directory, where you shape the work with
it. When the work should start, the agent moves the task into its own git
worktree:

```bash
toastty task start-work --branch-prefix fix
```

The shipped `toastty-task-start` skill tells managed agents to run this when you
ask them to implement the work, and then to end their turn. The command returns
at once. Toastty then:

1. Fetches the base and pins the commit the fetch returned. The base is the
   remote's default branch unless `--base` names a branch on the remote or a
   local commit. If the fetch fails, for example offline, Toastty uses the last
   fetched commit and says so in `task get`. Starts from the same repository
   take turns at this step, so each reads its own `FETCH_HEAD`.
2. Adds the worktree next to the repository's main checkout, named
   `<repository>-<slug>`, on the branch `<prefix>/<slug>`. A name that is taken
   locally or on the remote gets `-2`, `-3` and so on. The prefix comes from
   `--branch-prefix`, else the workspace's `branch_prefix`, else `task`.
3. Runs the workspace's `create_hook`, if there is one, in the worktree.
4. Waits for the agent's turn to end, so that the whole conversation is on disk,
   and until Toastty has identified that conversation, which can take a few
   seconds after an agent starts.
5. Opens a new terminal tab in the task space and forks the Claude Code or Codex
   conversation into it, working in the worktree.
6. Waits until the fork reports a conversation of its own, then closes the old
   session's pane. If that pane is its workspace's last, the agent exits
   instead and the shell stays.

The old session stays open when the fork does not start within 60 seconds, when
someone typed into the old session after the move began, or when it started new
work. Other agents cannot be forked: they start fresh in the worktree with the
task text, and their old session stays. The task's project directory, and so its
`tasks.toml` section, does not change.

Each step is saved as it happens. If one fails, the task shows in the Inbox with
the reason, and Retry continues from the last step that finished: after a
failed hook, it runs the hook again in the same worktree.

`start-work` runs from the agent session whose work moves. From a session in a
top-level workspace, it first makes a task, named with `--title` or the
session's title, and a new task space under the workspace for the worktree.
From a task space that has no task, that task space becomes the task's. It is
refused for a session that already works in another git worktree, and for a
task that already has one.

### Split work into new tasks

An agent that knows the work can create tasks that start in their own worktrees,
with every choice set:

```bash
toastty task create "Split the parser" --start-work --base feat/parser \
  --agent codex --model gpt-6.1-sol --effort high --prompt-file brief.md
```

Setup makes the worktree before the task space, so the task space's terminal
and the agent both start in it. The agent's first message names the worktree
and branch, then gives the prompt and the task text.

## The Inbox

Tasks whose setup has not finished appear in an Inbox group at the top of the
sidebar. It is hidden when it is empty. A row shows the task's title, its
workspace and agent, and `setting up` or `⚠ setup failed` with the reason.
Click a row to see the whole task; use Retry or Delete there or in the row's
context menu. A task that is moving into a worktree also shows here, as
`moving to worktree` with its current step, or as `⚠ worktree failed` with the
reason and Retry.

Deleting a task closes its task space only while nothing has used it. A task
space that has run an agent stays, without its link to the task.

## `~/.toastty/tasks.toml`

The file is optional. Like `agents.toml`, it is read from your home directory
in every run, including runtime-isolated dev runs. Toastty reads it each time a
task is created, so a change applies to the next task.

```toml
[defaults]
agent = "claude"
model = "claude-opus-5-5"
effort = "high"
```

`[defaults]` fills the agent, model and effort that a request leaves out. The
default model and effort apply only with the default agent; a request that
names another agent gets that agent's own defaults.

A `[workspace."<root directory>"]` table holds settings for one project,
matched on its root directory:

```toml
[workspace."~/GiantThings/repos/toastty"]
create_hook = "sv exec -- scripts/dev/bootstrap-worktree.sh"
branch_prefix = "feat"
```

- `create_hook` is a shell command that Toastty runs with `/bin/sh -c` in a
  new worktree, with your login shell's `PATH`. It gets `TOASTTY_TASK_ID`,
  `TOASTTY_TASK_SLUG`, `TOASTTY_TASK_BRANCH`, `TOASTTY_TASK_WORKTREE`,
  `TOASTTY_TASK_BASE_REF` (the base commit) and `TOASTTY_TASK_REPO_ROOT` (the
  project directory). It may take up to 30 minutes. If it exits non-zero, the
  move fails with its last lines of output.
- `branch_prefix` is the default first part of worktree branch names.

Toastty also reads and checks these tables and keys, which later features use:
`[triage]` (`command`, `guidelines` or `guidelines_file`, `timeout_seconds`),
`[defaults]` `merge` and `merge_prompt`, `[quick_entry]` (`shortcut`), and
`guidelines`, `release_tags`, `release_prompt`, `merge` and `merge_prompt` in
`[workspace."…"]`. They have no effect yet.

An error in the file names its line, and `task create` fails with that message
until the file is fixed.

## Where tasks are stored

- `~/.toastty/task-records.json`: every task record.
- `~/.toastty/task-attachments/<task-id>/`: Toastty's copies of attached files,
  removed when the task is deleted.

Deleting a task does not remove its worktree or branch.

Runtime-isolated runs keep both under their runtime home. See
[Privacy and Local Data](privacy-and-local-data.md).
