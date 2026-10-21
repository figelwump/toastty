# Tasks

A task is a piece of work you hand to an agent. You describe it, Toastty saves
it, makes a task space for it under a workspace, and starts the agent there.
The task keeps its own record, so it exists before its task space is ready and
after setup fails.

This page covers creating tasks from the CLI or from an agent, triage, moving
a task into its own git worktree, the sidebar Inbox, task stages with the
Status sidebar and the Tasks view, and `~/.toastty/tasks.toml`.

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
| `--workspace <id>` | The workspace the task belongs to. A subspace means its parent. An agent session defaults to its own workspace. Without one, triage chooses, or the task waits in the Inbox for you to pick one. |
| `--agent`, `--model`, `--effort` | The agent profile from `agents.toml` and its settings. Triage chooses what you leave out; `[defaults]` in `tasks.toml` fills anything still missing. |
| `--prompt <text>`, `--prompt-file <path>` | A first prompt, sent before the task text. |
| `--title`, `--slug` | The task's title and the task space's name. They default to the first line of the text. |
| `--request-id <id>` | The caller's key for this request. A repeat from the same agent session, or from the CLI outside one, with the same key returns the first task instead of making another. |
| `--start-work` | Make a git worktree during setup and start the agent there. See [Work in a git worktree](#work-in-a-git-worktree). |
| `--base <ref>`, `--branch-prefix <prefix>` | With `--start-work`: what the worktree starts from, and the first part of its branch name. |

A value you set is never changed. A request with an agent that is not in
`agents.toml`, a model or effort that agent does not take, a file that cannot
be read, or a first message longer than 64 KB fails at once and saves nothing.
So does a request that leaves out the agent when triage is off and `[defaults]`
names none. A file given as a symbolic link is copied as the file it points to.

To skip triage, set the workspace, agent, first prompt, and the model and
effort the agent takes. An agent that splits its work does this:

```bash
toastty task create --title "Split out the parser" --slug parser-split \
  --agent codex --model gpt-6.1-sol --effort high --prompt-file brief.md
```

Other verbs:

```bash
toastty task get <task-id>      # one task, with its setup state
toastty task list               # every task, oldest first
toastty task retry <task-id>    # run setup, or a move into a worktree, again after it failed
toastty task delete <task-id>   # delete the task and its attached files
toastty task workspace-choices  # open and recently closed workspaces
toastty task set-workspace <task-id> --workspace <id>   # place a waiting task
toastty task set-workspace <task-id> --recent <id>      # reopen a closed one
```

These are short forms of `action run task.create`, `query run task.get`,
`query run task.list`, `action run task.retry`, `action run task.delete`,
`query run task.workspace-choices` and `action run task.set-workspace`.

## Triage

Triage is one run of a command you choose, usually a model CLI, that fills in
what a task leaves out: the workspace, the agent, its model and effort, a first
prompt, a title and a slug. It runs only when `[triage] command` is set and the
task is missing the workspace, the agent, the first prompt, or a model or
effort its agent takes. A title or slug alone never starts it.

```toml
[triage]
command = "claude -p --model claude-sonnet-5-5 --effort medium --tools ''"
guidelines = """
A clear bug with a repro: codex, gpt-6.1-sol, high. Tell it to start work.
A design question: claude, claude-opus-5-5, xhigh. Tell it to shape first.
"""
timeout_seconds = 120
```

Toastty runs the command with `/bin/sh -c` in an empty temporary folder, with
your login shell's `PATH` and without the variables that tie a process to a
Toastty session. It writes instructions and a JSON description of the choices
to stdin, and stops the command after `timeout_seconds`.

The JSON holds the task text and the names of its files; the open top-level
workspaces with their IDs, titles, root directories and the `guidelines` from
their `[workspace."…"]` sections; the installed agent profiles that can take a
first prompt; and `[triage] guidelines` (or the contents of `guidelines_file`,
a path that is absolute, under `~`, or relative to `~/.toastty`). Values you
already chose are listed as fixed.

The command answers with one JSON object on stdout:

```json
{"workspace": "<workspace ID>", "agent": "codex", "model": "gpt-6.1-sol",
 "effort": "high", "first_prompt": "Start with the composer views.",
 "title": "Composer keeps a blank line", "slug": "composer-blank-line",
 "reason": "A composer bug in toastty."}
```

Toastty also reads the object from a fenced code block, after other text, or
from the result of `claude -p --output-format json`. `workspace` may also be a
root directory that exactly one open workspace has.

Toastty checks the answer. The workspace must be open and the agent an
installed profile; a model or effort counts only for an agent that takes one.
A value that fails a check, or a triage that fails or times out, leaves that
field to `[defaults]`, and `task get` reports what happened in `triageNote`.
Without a workspace, the task waits for you to pick one. The agent always
receives triage's first prompt, then your text exactly as written, then the
attached files.

## Pick a workspace

A task waits as `⚠ pick a workspace` when triage did not choose an open
workspace, its workspace closed, or triage is off and the task names none.
Open it from the Inbox. The Workspace menu lists open workspaces, then recently
closed ones. Choose one and press Start. Toastty reopens a closed workspace
with its title and one terminal in its root directory, without switching to it.
Triage then runs again with the workspace fixed, for anything else the task
still needs, and setup starts. Retry Triage asks triage again instead.

Toastty remembers the last 20 closed top-level workspaces that have a
directory, one per root directory.

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
workspace and agent, and its state: `routing…` while triage runs, `⚠ pick a
workspace` or `⚠ setup failed` with the reason, or `setting up`. Click a row
to see the whole task; use Retry, Delete or the workspace picker there or in
the row's context menu. A task that is moving into a worktree also shows here,
as `moving to worktree` with its current step, or as `⚠ worktree failed` with
the reason and Retry.

Deleting a task closes its task space only while nothing has used it. A task
space that has run an agent stays, without its link to the task.

## Stages

Toastty works out each task's stage from its record and from what it sees
now: the agents in its task space, its pull request, and `tasks.toml`. Nothing
stores the stage, so it never goes stale. The first rule that matches wins:

| Stage | When |
| --- | --- |
| Archived | the task was closed without finishing |
| Done | it was marked done or shipped; or it merged and its project has no `release_tags` |
| To ship | it merged, and its project has `release_tags` |
| Needs you | triage could not place it, setup or the move into a worktree failed, its task space closed before it finished, an agent asked for input or stopped with an error, or its pull request is open and not a draft while no agent works on it |
| Inbox | triage or setup is still running, or it is moving into a worktree |
| Running | anything else |

The pull request comes from the task space's `github-pr` annotation. Toastty
asks `gh` about it every two minutes while the task is open, when an agent's
turn ends in the task space, and when the Tasks view opens, and copies the
link and the merge onto the task record. Without `gh`, a linked pull request
with no agent working counts as waiting for review. Seeing a merge only
records it; merging and cleaning up stay with the Merge button.

Task spaces that an agent made with `workspace.create`, before they had a
record, are only watched: their done mark counts as Done, and the mark clears
when their work starts again. `toastty task adopt`, or Track as Task in the
Tasks view, gives one a record, so its history stays after it closes.
`task start-work` from one of its sessions also gives it a record.

## The sidebar and the Tasks view

The Tasks row at the top of the sidebar opens the Tasks view; its badge counts
the tasks that need you, and its ＋ creates a task. Below it, a switcher groups
the sidebar by **Projects** or by **Status**. The choice is saved for each
window.

- **Projects** is the workspace list. A task space whose task is To ship or
  Done leaves its card unless an agent in it is working or waiting for you;
  a footer under the card counts those tasks and opens the Tasks view.
- **Status** lists task spaces by stage: Needs you, Running, To ship (one line
  for each project), and a Done count. Each row carries its project's name.
  Top-level workspaces show only in Projects.

Both keep the Inbox at the top. Task space rows use square marks: blue for a
pull request waiting for review, violet ↑ for a merge waiting for a release,
a green check for done, and a dashed box for a task that has not started.
When an agent splits its work, the new tasks draw under the task that started
them, and that task shows how many of them have merged.

The Tasks view covers the workspace while it shows; selecting a workspace or
pressing Esc leaves it. It lists every task in the same groups, with Done and
Archived collapsed, and a detail pane with the task's text, stage, pull
request, branch, agent and history, and actions to open its task space or pull
request. A task that has not started shows the Inbox's controls there. An
error in `tasks.toml` shows as a banner at the top.

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

`[defaults]` fills the agent, model and effort that a request and triage leave
out. The default model and effort apply only with the default agent; a task
whose agent is another one gets that agent's own defaults.

`[triage]` is described in [Triage](#triage).

A `[workspace."<root directory>"]` table holds settings for one project,
matched on its root directory:

```toml
[workspace."~/GiantThings/repos/toastty"]
guidelines = "iOS tasks: read ios/AGENTS.md first."
create_hook = "sv exec -- scripts/dev/bootstrap-worktree.sh"
branch_prefix = "feat"
```

- `guidelines` go to triage with that workspace.
- `create_hook` is a shell command that Toastty runs with `/bin/sh -c` in a
  new worktree, with your login shell's `PATH`. It gets `TOASTTY_TASK_ID`,
  `TOASTTY_TASK_SLUG`, `TOASTTY_TASK_BRANCH`, `TOASTTY_TASK_WORKTREE`,
  `TOASTTY_TASK_BASE_REF` (the base commit) and `TOASTTY_TASK_REPO_ROOT` (the
  project directory). It may take up to 30 minutes. If it exits non-zero, the
  move fails with its last lines of output.
- `branch_prefix` is the default first part of worktree branch names.

Toastty also reads and checks these keys, which later features use:
`[defaults]` `merge` and `merge_prompt`, `[quick_entry]` (`shortcut`), and
`release_tags`, `release_prompt`, `merge` and `merge_prompt` in
`[workspace."…"]`. They have no effect yet.

An error in the file names its line, and `task create` fails with that message
until the file is fixed.

## Where tasks are stored

- `~/.toastty/task-records.json`: every task record.
- `~/.toastty/task-attachments/<task-id>/`: Toastty's copies of attached files,
  removed when the task is deleted.
- `~/.toastty/recent-workspaces.json`: the last closed top-level workspaces,
  for the workspace picker.

Deleting a task does not remove its worktree or branch.

Runtime-isolated runs keep both under their runtime home. See
[Privacy and Local Data](privacy-and-local-data.md).
