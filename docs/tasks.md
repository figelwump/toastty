# Tasks

A task is a piece of work you hand to an agent. You describe it, Toastty saves
it, makes a task space for it under a workspace, and starts the agent there.
The task keeps its own record, so it exists before its task space is ready and
after setup fails.

This page covers the quick entry panel, creating tasks from the CLI or from
an agent, triage, moving a task into its own git worktree, the sidebar Inbox,
task stages with the Status sidebar and the Tasks view, and
`~/.toastty/tasks.toml`.

## Quick entry

Press `Option+Shift+T` from any app, Toastty included, to open the quick entry
panel. Write the task, attach what helps, and press `Cmd+Return` or Create
Task. Toastty saves the task at once and shows "Task created · in the Inbox".
Focus goes back to the app you were in.

- **Attach files** by dropping them anywhere on the panel, including a
  screenshot's thumbnail, by pasting an image or a copied file with `Cmd+V`,
  or with Attach. Toastty copies each file when you add it, so a screenshot
  that macOS later moves or deletes is still attached. A task holds up to 10
  files.
- **Drop a link** to add it to the text.
- **Workspace and Agent** start on Auto. Pick one to pin it for this task.
  Auto leaves the choice to [triage](#triage), which picks among your open
  workspaces. When triage is off or cannot choose, the task waits in the
  Inbox as `⚠ pick a workspace`.
- The panel floats over other apps and full-screen windows and stays open
  while you switch apps, for example to take a screenshot. Drag its
  background to move it. `Esc` closes it without saving; the attached copies
  are deleted.
- Pressing the shortcut while the panel is open brings it back with your
  draft.

Other ways to open the same panel:

- **File > New Task…** and **New Task…** in the command palette. Both show
  the shortcut.
- The **＋** on the sidebar's Tasks row, and **New Task** in the Tasks view.
- **New Task from Selection…** in a terminal's context menu, with text
  selected. The selection is attached as `selection.txt`, and the terminal's
  workspace is picked.

Change the shortcut with `[quick_entry] shortcut` in `~/.toastty/tasks.toml`,
or turn it off with `shortcut = "none"`. Toastty reads it at launch and on
Reload Configuration. The shortcut needs no Accessibility permission. If
another app already uses it, Reload Configuration says so, and the shortcut
still works inside Toastty from the File menu. Smoke runs and test hosts do
not register it.

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
   attached files. The agent session is not workspace-scoped, so it can read
   and message other tasks (see [Coordinate tasks](#coordinate-tasks)). It is
   scoped only when the session that created the task was scoped; then it
   keeps that scope.

Toastty saves each step to disk as it happens. If setup fails, or Toastty quits
before setup ends, the task shows as failed, and Retry continues from the last
step that finished: it reuses the task space instead of making a second one.

When an agent creates a task, the new task space joins that agent's workspace
scope if the agent is scoped, and the agent session is recorded as the one that
spawned it. A task
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

## Coordinate tasks

An agent, inside Toastty or outside it, can follow other tasks and talk to
their agents by task ID. Toastty finds a task's current agent session each
time, so the ID keeps working after a relaunch, a fork, or a move into a
worktree.

- `toastty task get <task-id>` reports `agentState` (`notRunning`, `busy`,
  `waiting` for an approval or an answer, `idle`, or `error`, with the session
  and when its status last changed) and `lastReply`, the agent's latest
  message. Toastty reads the reply from the Claude Code or Codex transcript, or
  from the history other agents publish through Toastty's extension, and cuts it
  at 16 KB. It is `null` until Toastty has confirmed the session's transcript.
- `toastty task list` reports `agentState` for every task and returns a
  `cursor`. With `--changed-since <cursor>`, it lists only the tasks whose
  record, stage or agent state changed since that answer, and the IDs of deleted tasks
  in `deletedTaskIDs`. A cursor from before a relaunch gets every task back with
  `reset: true`. `--include-reply` adds each task's `lastReply`.
- `toastty task send <task-id> "<message>"` types the message into the task's
  agent and submits it. A busy agent queues it as typed input. It fails when the
  task has no running agent, and says so when the message was typed but may not
  have been submitted; check that terminal before you send it again.
- `toastty task watch <task-id> --until <condition>` tells the calling agent's
  own task once, by a one-line message, when the other task reaches the
  condition. A waiting agent can then end its turn instead of polling in a
  shell. `--notify <task-id>` names another task to tell.

Watch conditions:

| Condition | Holds when |
| --- | --- |
| `idle` | The agent finished a turn after the watch was made. A turn that ended before does not count, so you can send a request and then watch for its answer. An agent that Toastty restored after a relaunch counts once it finishes a turn. |
| `waiting` | The agent waits for an approval or an answer. |
| `ready-for-review` | The task's pull request waits for review, or its agent marked work without a pull request ready. |
| `merged` | Its pull request merged. |
| `to-ship` | It merged and waits for a release. |
| `done` | It is in the Done stage. |
| `archived` | It was archived. |

The stage conditions follow the [stages](#stages), in the order
`ready-for-review`, `merged`, `to-ship`, `done`. A condition still holds after
the task moves past it, so a watch fires even when the task skips a stage. For
example, a merged task also meets `ready-for-review`, and a merge in a project
without `release_tags`, which goes straight to Done, also meets `to-ship`. A
task marked done by hand meets only `ready-for-review` and `done`. The message
names the stage the task reached, which can be later than the one you watched
for. Toastty checks about once a second, so a stage that the task enters and
leaves again within that time can be missed; `ready-for-review` also ends while
an agent works in the task space again.

A watch is saved with the record of the task it notifies, so it survives a
relaunch, and it fires once. A watch whose task is deleted, or archived while
it waits for something else, fires with that reason. If the notified task's
agent is not running when a watch fires, the message goes out once it runs
again. `toastty task watches` lists watches, with `--task` or `--notify` to
filter them, and `toastty task unwatch <watch-id>` cancels one. Fired watches
stay listed for up to a day.

Outside Toastty, where there is no task to tell, `toastty task watch <task-id>
--until <condition> --wait` blocks until the watch fires, prints the outcome,
and exits 0, or 1 when the condition can never hold. `--timeout <seconds>`
bounds the wait and cancels the watch when it runs out. A `--wait` watch lasts
only while Toastty runs and while the command keeps polling it.

A milestone that is not a stage, such as "the API is defined", is a `task send`
from the task that reaches it. A task's agent finds its own task ID with
`toastty task get`, with no ID.

Any unscoped caller may read, message and watch any task. A workspace-scoped
session, which you set up on purpose, reaches only the tasks it may see in
`task list`.

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
| Needs you | the cleanup after its merge, archive or release stopped: "Merged · clean up?" |
| Archived | the task was closed without finishing |
| Done | it was marked done or shipped; or it merged and its project has no `release_tags` |
| To ship | it merged, and its project has `release_tags` |
| Needs you | triage could not place it, setup or the move into a worktree failed, its task space closed before it finished, an agent asked for input or stopped with an error, or its pull request is open and not a draft while no agent works on it |
| Inbox | triage or setup is still running, or it is moving into a worktree |
| Running | anything else, including a merge under way: "Merging…" while its agent checks or Toastty merges, "Waiting for checks" while GitHub's checks run |

The pull request comes from the task space's `github-pr` annotation. Toastty
asks `gh` about it every two minutes while the task is open, when an agent's
turn ends in the task space, and when the Tasks view opens, and copies the
link and the merge onto the task record. Without `gh`, a linked pull request
with no agent working counts as waiting for review. A merge made on GitHub
also cleans up the task space when that is safe; see
[Merge a task](#merge-a-task).

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
request, branch, agent and history, and its actions: open its task space or
pull request, Merge or Merge Without Checks, Cancel Merge, Mark Done, Archive…,
and Clean Up or Keep As Is after a cleanup stopped. A To ship project has a
**Release…** button when its project sets `release_prompt`; the sidebar's
Status To ship lines have one too. A task that has not started shows the
Inbox's controls there. An error in `tasks.toml` shows as a banner at the top.

## Merge a task

**Merge** on a task, from the Tasks view, the task space's top bar, its sidebar
menu or `Option+Shift+M`, is your acceptance of its pull request as it is now.

1. Toastty sends the project's `merge_prompt` to the task's agent. The default
   is `Use toastty-task-merge.`, a skill Toastty ships. A busy agent gets it
   once its turn ends; with no agent in the task space, Toastty starts the
   task's agent in a new tab there. The task shows "Merging…".
2. The skill checks what you cannot see at a glance: unresolved review threads,
   merge prerequisites in the description, tasks that must land first, and CI.
   If something blocks, it says why and ends its turn, and the task is back in
   Needs you. Otherwise it runs `toastty task merge --head <commit>`.
3. Toastty merges at exactly that commit with GitHub's merge API. If checks
   still run, the task shows "Waiting for checks" and Toastty merges when they
   pass. It never turns on auto-merge, so commits pushed later are not merged.
4. Toastty records the merge on the task first. Once the agent's turn ends, it
   closes the task space, removes the worktree and deletes the branch, the same
   way as the Merge button does for any task space.

Saying "merge it" to the task's agent runs the same skill. **Merge Without
Checks**, or `merge = "direct"` for the project, skips the agent and merges at
once. **Cancel Merge** stops a merge while the agent checks or Toastty waits for
checks: a `task merge` from the agent's turn that was checking is then refused.

A pull request merged on GitHub counts as your acceptance too. Toastty cleans up
its task space when no agent there is working and the worktree is clean at the
merged commit. Otherwise the task shows **Merged · clean up?** in Needs you;
**Clean Up** tries again and **Keep As Is** leaves everything where it is.

## Archive a task

**Archive…** closes a task without merging. Toastty first says what it will
do, then:

- closes the pull request only if you tick **Close PR #N on GitHub**;
- closes the task space, which ends its agents;
- removes the worktree. Uncommitted changes need your OK first;
- deletes the local branch when every commit on it is on the remote, and keeps
  it otherwise unless you choose to delete the unpushed commits. The remote
  branch always stays, so the pull request can be reopened.

A task space with unsaved documents, or a merge under way, is not archived.
Each step is saved as it finishes; if one stops, the task shows in Needs you
with the reason, and **Clean Up** continues from there. `toastty task archive`
does the same from the CLI.

## Finish without a pull request

For work that has no pull request, the agent runs `toastty task
ready-for-review`, and the task waits in Needs you. **Mark Done**, or
`toastty task mark-done`, finishes it.

## Release

With `release_tags` set, a merged task waits in To ship until a release tag
contains its merge commit. **Release…** on a project's To ship line makes a
release task: Toastty fetches the remote's default branch, and starts the
release agent with `release_prompt` in a new worktree on no branch at exactly
that commit, never in your project checkout. The fetch must succeed. The agent
also gets the list of tasks waiting to ship. `toastty task release` does the
same from the CLI.

Toastty looks for release tags every 15 minutes and when the Tasks view opens:
it fetches tags and counts only a tag the remote has at the same commit. A
release made outside Toastty counts too. When a tag contains a task's merge
commit, the task is Done, and the Tasks view shows the tag. A shipped release
task closes its task space and removes its worktree once its agent is at rest,
unless the worktree's commit is on no remote branch or tag.

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

```toml
[quick_entry]
shortcut = "opt+shift+t"   # the default; "none" turns it off
```

A shortcut joins modifiers and one key with `+`. Modifiers are `cmd`,
`ctrl`, `opt` (or `alt`) and `shift`. The key is a letter, a digit,
punctuation, `space`, `return`, `tab`, or `f1` to `f20`, named as a US
keyboard types it. It needs `cmd`, `ctrl` or `opt`, so it cannot take
ordinary typing away from other apps; a function key may stand alone.

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
- `release_tags` turns on the To ship stage for the project: a merged task
  waits there until a tag matching this pattern, such as `"v*"`, contains its
  merge commit, instead of going straight to Done. See [Release](#release).
- `release_prompt` is what a release task's agent gets first, such as
  `"Use toastty-release, then toastty-publish."`. Without it, Toastty shows no
  Release button for the project.
- `merge` is `"agent"`, the default, or `"direct"`; see
  [Merge a task](#merge-a-task).
- `merge_prompt` is what Merge sends to the task's agent, such as
  `"Use worktree-done."` for a skill of your own. The default is
  `"Use toastty-task-merge."`.

`merge` and `merge_prompt` can also go in `[defaults]`; a workspace's own
value wins.

An error in the file names its line, and `task create` fails with that message
until the file is fixed.

## Where tasks are stored

- `~/.toastty/task-records.json`: every task record.
- `~/.toastty/task-attachments/<task-id>/`: Toastty's copies of attached files.
  They are removed when the task is deleted, or a week after the task reached
  Done or Archived, once its task space has closed. The record keeps the file
  names, and its history says the files were removed. A task that leaves Done,
  because work started again, counts its week from its next finish. Toastty
  checks at launch and every 15 minutes.
- `~/.toastty/recent-workspaces.json`: the last closed top-level workspaces,
  for the workspace picker.

Deleting a task does not remove its worktree or branch; archiving it does.

Runtime-isolated runs keep both under their runtime home. See
[Privacy and Local Data](privacy-and-local-data.md).
