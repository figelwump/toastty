# Tasks

A task is a piece of work you hand to an agent. You describe it, Toastty saves
it, makes a task space for it under a workspace, and starts the agent there.
The task keeps its own record, so it exists before its task space is ready and
after setup fails.

This page covers the quick entry panel, creating tasks from the CLI or from
an agent, moving a task into its own git worktree, task stages with the
Status sidebar and the Tasks view, `~/.toastty/tasks.toml`, and optional
triage.

A task needs a workspace and an agent. You choose them when you create the
task; `[defaults]` in `tasks.toml` fills an agent, model or effort you leave
out, and a task without a workspace waits in Needs you until you pick one.
The agent's first message is the task text, followed by the attached files
and one line that tells the agent to run `toastty task needs-reply` before it
ends a turn with a question.

## Quick entry

Press `Option+Shift+T` from any app, Toastty included, to open the quick entry
panel. Write the task, attach what helps, and press `Cmd+Return` or Create
Task. Toastty saves the task at once and shows "Task created".
Focus goes back to the app you were in.

- **Attach files** by dropping them anywhere on the panel, including a
  screenshot's thumbnail, by pasting an image or a copied file with `Cmd+V`,
  or with Attach. Toastty copies each file when you add it, so a screenshot
  that macOS later moves or deletes is still attached. A task holds up to 10
  files.
- **Drop a link** to add it to the text.
- **Workspace and Agent** start chosen, and both go into the task.
  Workspace starts on the workspace of your last quick entry task, while it
  is open, wherever you open the panel. Before the first task, or when that
  workspace has closed, it starts on the project of the workspace selected
  in the main window; a selected task space counts as its project. Toastty
  keeps the last one in `~/.toastty/task-last-workspace.json`. Agent starts
  on the agent, model and effort of your last successful quick entry task,
  or the `[defaults]` preset before the first task. Cancelled and failed
  tasks do not change this choice. When a pill has no value, Create Task
  stays off and the panel says `Pick a workspace with ⌘1` or `Pick an agent with ⌘2`.
- **Pick from the keyboard:** `Cmd+1` opens the Workspace list and `Cmd+2`
  the Agent list. Type to filter, move with the arrow keys, and press
  `Return` to choose; the caret goes back to the task text. `Esc` closes
  only the list. The Workspace list refreshes each time you open it. It holds
  open top-level workspaces from all windows, including folders without Git
  repositories. Nested task spaces are excluded. If the selected workspace
  has closed, choose another one.
- **Agent, model and effort** are chosen together. The Agent list shows
  your Frequent presets first. A preset is eligible after its first successful
  task; recent use counts more, with a 14-day half-life, and the
  top five are shown. Until then the list shows the `[defaults]` preset from
  `tasks.toml`. Every task from quick entry counts its preset, including one
  the panel started on. Toastty keeps the counts in
  `~/.toastty/task-preset-usage.json`.
  The last-used preset can differ from the top Frequent preset. If it is
  outside the top five, the list shows it under Current. Presets whose
  agents are no longer offered are skipped when restoring the last choice.
  With the search empty, `1` to `5` pick a Frequent preset. With a preset
  highlighted, `Left Arrow` and `Right Arrow` change its effort. Typing also
  lists every agent and agent + model pair. **Choose agent, model, effort…**
  (`Cmd+Right Arrow`) opens three columns: `Tab` moves between them, and
  typing filters the one in focus. The Model column lists the models that
  you used to create tasks, followed by models that live sessions reported
  recently (while remote access is on). It keeps up to five distinct saved
  or live models per profile, plus the `[defaults]` model and **Default**;
  type any other model name to use it.
  Codex also loads its model catalog in the background when you open a new
  draft. These choices do not need remote access or a recent session. A new
  draft offers the last successful catalog at once and refreshes it in the
  background. The saved choices last until quit or **Reload Configuration**.
  With no saved catalog, the picker shows **Loading Codex models…**, or
  **Codex models unavailable** with **Retry** (`Cmd+R`). Retry loads the choices in the
  same picker and keeps your search and selection. Toastty
  runs the configured Codex executable's `debug models` command with its
  normal configuration and `CODEX_HOME`; extra arguments in the Toastty
  profile are not applied to this lookup. Custom wrapper commands are not
  queried. Catalog choices are suggestions,
  not a check of account access. If an older CLI does not support the command
  or the lookup fails, the existing choices and manual entry remain available.
  The app log records lookup duration, outcome, and model count on success.
  It does not record the command's output.
  An empty or failed refresh keeps the last available catalog. Choices
  already in an open draft stay available during a configuration reload.
  A column is hidden when the agent takes no model or no effort. The pill
  then shows `model · effort`, or the agent's name when no model is chosen.
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
| `--workspace <id>` | The workspace the task belongs to. A subspace means its parent. An agent session defaults to its own workspace. Without one, the task waits in Needs you for you to pick one. |
| `--agent`, `--model`, `--effort` | The agent profile from `agents.toml` and its settings. `[defaults]` in `tasks.toml` fills what you leave out. |
| `--prompt <text>`, `--prompt-file <path>` | A first prompt, sent before the task text. |
| `--title`, `--slug` | The task's title and the task space's name. They start from the first line of the text. An explicit title stays fixed. Otherwise, the task uses its agent session's title when available. The slug stays fixed. |
| `--request-id <id>` | The caller's key for this request. A repeat from the same agent session, or from the CLI outside one, with the same key returns the first task instead of making another. |
| `--start-work` | Make a git worktree during setup and start the agent there. See [Work in a git worktree](#work-in-a-git-worktree). |
| `--base <ref>`, `--branch-prefix <prefix>` | With `--start-work`: what the worktree starts from, and the first part of its branch name. |
| `--fork` | From a Claude Code or Codex session: start the agent as a fork of this session's conversation. See [Fork the conversation into new tasks](#fork-the-conversation-into-new-tasks). |

A value you set is never changed. A request with an agent that is not in
`agents.toml`, a model or effort that agent does not take, a file that cannot
be read, or a first message longer than 64 KB fails at once and saves nothing.
So does a request that leaves out the agent when `[defaults]` names none and
triage is off. A file given as a symbolic link is copied as the file it points to.

An agent that splits its work names the agent, its settings and a first
prompt:

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
toastty task workspace-choices [<task-id>]  # open and recently closed workspaces
toastty task set-workspace <task-id> --workspace <id>   # place a waiting task
toastty task set-workspace <task-id> --recent <id>      # reopen a closed one
toastty task set-workspace <task-id> --root <dir>       # open a project directory
```

These are short forms of `action run task.create`, `query run task.get`,
`query run task.list`, `action run task.retry`, `action run task.delete`,
`query run task.workspace-choices` and `action run task.set-workspace`.

## Pick a workspace

A task waits as `⚠ pick a workspace` when it names no workspace or its
workspace closed. It shows in Needs you; open it in the Tasks view. The
Workspace menu lists the open
workspaces, then recently closed ones. Choose one, and the main button names
it, as in **Start in toastty** or **Open toastty & Start**. Toastty opens a
closed workspace, or a project from `tasks.toml` that was never open, with one
terminal in its root directory, without switching to it. A reopened workspace
keeps its title; a new one is named after its directory. `[defaults]` then
fills anything else the task still needs, and setup starts.

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
   attached files, then the `task needs-reply` line. With `--fork`, the agent starts as a fork of the calling
   session's conversation instead (see
   [Fork the conversation into new tasks](#fork-the-conversation-into-new-tasks)).
   The agent session is not workspace-scoped, so it can read
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

Each step is saved as it happens. While the move runs, the task space's row
shows `Moving to worktree` and the current step. If one fails, the task shows
in Needs you as `⚠ worktree failed` with the reason, and Retry continues from
the last step that finished: after a failed hook, it runs the hook again in the
same worktree.

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

### Fork the conversation into new tasks

A fresh agent knows only what its prompt tells it. When the work took shape in
a long conversation, the agent of that conversation can give each new task a
copy of it instead:

```bash
toastty task create "Split the parser" --fork --start-work \
  --branch-prefix feat --prompt-file brief.md
```

`--fork` runs only from a Claude Code or Codex session that Toastty manages.
The new task's agent starts as a fork of the calling session's conversation.
The calling session keeps running: Toastty does not close it or type into it.

- The fork uses the caller's agent. `--agent` can name only that agent.
  `--model` and `--effort` set the fork's model and effort. Without them, the
  fork uses the model and effort of the caller's task when the caller is a
  task's agent, else the settings of the agent profile. `[defaults]` and
  triage do not apply to a fork.
- Setup makes the worktree, with `--start-work`, and the task space at once.
  Then it waits until the caller is not in a turn, so that the whole
  conversation is on disk, and until Toastty has identified that conversation.
  A fork never copies a turn that is still running. Forks that one turn asks
  for copy the same conversation when the caller stays idle until they start.
  If the caller starts a new turn before a fork starts, for example while a
  slow `create_hook` runs, that fork waits for the new turn too and copies it.
- The fork's first message starts with the start skill, if one is set. Then it
  names the task, its ID and task space, and the worktree and branch, if any.
  It tells the fork that it owns only this task, and how to report back: with
  `toastty task send <parent-task-id>` when the caller is a task's agent, else
  with `terminal.send-text` to the caller's terminal. The prompt, the task text
  and the attached files follow.
- `task create` returns at once. You cannot use `--wait` with `--fork`, because
  the fork starts only after the turn that runs the command ends.
- Setup ends when the fork reports a conversation of its own. Setup fails, with
  the reason, when the caller does not end its turn within 10 minutes, or when
  the fork does not report its conversation within 60 seconds. The caller does
  not change. Retry continues from the last step that finished: it waits again
  for a fork that still runs, or it forks again in the same task space.

`task get` reports the fork under `fork`: the caller's session and conversation,
and `conversationConfirmed`. The task records the caller's task as its parent,
and gets the workspace scope of any task that an agent creates.

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

## Starting tasks

A task whose setup or triage is still running, or that is moving into a
worktree, is Starting. It lists with Running, as `Setting up` or `Moving to
worktree` with the current step; a task space row shows the same text. A task
whose setup or move failed, or that waits for a workspace, lists with Needs
you as `⚠ pick a workspace`, `⚠ setup failed` or `⚠ worktree failed`. Select
it in the Tasks view to see the whole task and use Retry, Delete or the
workspace picker; its context menu has Retry and Delete too.

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
| Needs you | it has no workspace, setup or the move into a worktree failed, its task space closed before it finished, or an agent asked for input or stopped with an error |
| Starting | setup, or triage when it is on, is still running, or it is moving into a worktree. Lists show it with Running |
| Running | an agent that works or waits on its sub-agents; an agent that ended its turn to wait on another task through `task watch`, shown as "waiting for <task>"; and a merge under way: "Merging…" while its agent checks or Toastty merges, "Waiting for checks" while GitHub's checks run |
| Needs you | its agent ended a turn with a question and marked it with `task needs-reply`: "Asks: <question>". Reading the turn does not clear it. It clears when the task's agent starts its next turn, usually your answer, or when the agent runs `task ready-for-review` |
| Needs you | its pull request is open and not a draft while no agent works on it, or its agent marked work without a pull request ready with `task ready-for-review` |
| Needs you | its agent finished a turn you have not read yet: "Claude finished · waiting for you". Once you read the answer, or after a relaunch restores the agent, the task is Idle |
| Idle | anything else: its agent is idle at its prompt, or no agent runs in its task space |

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

`Cmd+Shift+A` includes open task spaces ready for review or waiting for your
reply, even after you read the agent’s answer or its session exits. They follow unread panels and agents
that need input, and precede working agents in the cycle.

The Tasks row at the top of the sidebar opens the Tasks view; its badge counts
the tasks that need you, and its ＋ creates a task. Below it, a switcher groups
the sidebar by **Projects** or by **Status**. The choice is saved for each
window.

- **Projects** is the workspace list. A task space whose task is To ship or
  Done leaves its card's task space list unless an agent in it is working or
  waiting for you. After the card's task spaces, the project's 3 most recently
  merged To ship tasks show as rows. A footer line after them has **Show N more** when the
  project has more To ship tasks, and the Done count. Without To ship rows,
  the footer counts To ship tasks instead.
- **Status** lists task spaces by stage: Needs you, Running, Idle, To ship,
  and a Done count. Each row carries its project's name, except under To ship.
  A task and the tasks it started list together, in the group of the most
  urgent one: an idle parent whose child needs you lists in Needs you, dimmed,
  with the child under it. Group counts include only the tasks whose own stage
  is in that group, and a row listed in a group its own stage is not in is
  dimmed. The selected task's family keeps its group and position until you
  select another row, so reading a finished turn dims the row instead of
  moving it from under the pointer; a task that starts to need you moves at
  once.
  To ship starts collapsed to one line that names each project and its count.
  Click it to expand the group in place; the choice resets when the sidebar
  hides or the app quits. Expanded, each project has a header as in the Tasks
  view, with its 3 most recently merged tasks under it, then **Show N more**
  when the project has more.
  Top-level workspaces show only in Projects.

A To ship row opens the Tasks view with the task selected. The task space
closed at the merge; if you kept it open, the row opens it instead. **Show N more**
opens the Tasks view at To ship with the first task the sidebar did not show
selected, and the To ship and Done counts open it at their group. The newest
merge comes first; a task with no merge time uses its latest change. A To ship
task whose task space is still open keeps its task space row and does not show
a second time.

Task space rows use square marks: green for a finished turn (filled while it
is unread, when the Tasks view also shows the title in bold), amber ? for a
question that waits for your reply, blue for a pull request waiting for review, violet ↑ for a merge waiting for a release, a green
check for done, and a dashed box for a task that is starting.
When an agent splits its work, the new tasks draw under the task that started
them, and that task shows how many of them have merged.

The sidebar and Tasks view use the task's agent session title when it is
available. Until then, they keep the initial task title. An explicit task
title stays fixed. A task space made without a task record uses its first
named agent session. Session title changes do not rename branches or directories.

The Tasks view covers the workspace while it shows; selecting a workspace or
pressing Esc leaves it. It lists every task in the same groups, with Done and
Archived collapsed, and a detail pane with the task's text, stage, pull
request, branch, agent and history, and its actions: open its task space or
pull request, Merge or Merge Without Checks, Cancel Merge, Mark Done, Archive…,
and Clean Up or Keep As Is after a cleanup stopped. A To ship project has a
**Release…** button when its project can release (see
[Release](#release)); the sidebar's
Status To ship project headers have one too when the group is expanded. A task that is starting, or whose setup or
move failed, shows its setup controls there. An error in `tasks.toml` shows as a banner at the top.
`Cmd+Shift+T`, or **View > Show Tasks**, shows the Tasks view; pressed again,
it hides the view and returns to the workspace it covered. Up and Down Arrow
move the selection through the rows the list shows, skipping collapsed Done
and Archived, and the detail pane follows. When the selected task leaves the
list, for example after **Archive…** or **Mark Done** into collapsed Done, the
next row is selected, or the previous one when it was the last.

### The command palette

Type `task`, `done` or `merge` in the command palette to act on the current
task: the row selected in the Tasks view while it shows, otherwise the task
whose task space is selected. The palette lists the detail pane's actions that
apply now, as **Task: Merge**, **Task: Merge Without Checks**, **Task: Cancel
Merge**, **Task: Mark Done**, **Task: Archive…**, **Task: Clean Up** and
**Task: Keep As Is**, plus **Task: Open PR** and, from the Tasks view, **Task:
Open Task Space**. Each row names the task and its stage. The actions run as
the detail pane's buttons do, with the same confirmations. **Task: Merge**
shows `Option+Shift+M` when it acts on the selected task space.

**Release <project>…** starts a release for each open project with a
`release_skill` or a `release_prompt`, as the To ship line's **Release…**
does, even when nothing waits to ship. It is hidden while a release of that project is under way.

### Context menus

Right-click a task's row to act on it: its task space row in the sidebar, its
row in the sidebar's Status segment, a To ship row, or its row in the Tasks
view. The menu
lists what the detail pane offers now, with the same confirmations: **Open
Task Space** and **Open PR #N**, then Merge or Merge Without Checks, Cancel
Merge, Mark Done, **Archive…**, Clean Up or Keep As Is, and **Delete Task** for
a task whose task space closed. An action that does not apply is left out.
**Open Task Space** is left out when the window already shows the task space;
there **Merge** shows `Option+Shift+M`. A task that is starting, or whose setup
or move failed, offers Retry and Delete. A task space row keeps its workspace items, such as
**Move to top level** and **Close workspace**, below a divider. It has no
**Mark as done** item, since a task is done when it merges or you mark it done.

## Merge a task

**Merge** on a task, from the Tasks view, the task space's top bar, its sidebar
menu or `Option+Shift+M`, is your acceptance of its pull request as it is now.

1. Toastty sends the task's agent `Use the <merge_skill> skill.` when a
   `merge_skill` is set, then `merge_prompt` if one is set, then the pull
   request you accepted. With neither set, the skill is `toastty-task-merge`,
   which Toastty ships. A busy
   agent gets the message once its turn ends; with no agent in the task
   space, Toastty starts the task's agent in a new tab there. The task shows "Merging…".
2. The skill checks what you cannot see at a glance: unresolved review threads,
   merge prerequisites in the description, tasks that must land first, and CI.
   If something blocks, it says why and ends its turn, and the task is back in
   Needs you. Otherwise it runs `toastty task merge --head <commit>`.
3. Toastty merges at exactly that commit with GitHub's merge API. If checks
   still run, the task shows "Waiting for checks" and Toastty merges when they
   pass. It never turns on auto-merge, so commits pushed later are not merged.
   The pull request may target a feature branch while that branch's own pull
   request stays open. Explicit merge prerequisites still apply. A child that
   carries unmerged parent work into another branch must wait for that work
   to merge first.
   Toastty saves the target branch with a waiting merge and stops if the pull
   request is retargeted. Older saved waits with no target require you to
   accept the merge again.
4. Toastty records the merge on the task first. Once the agent's turn ends, it
   closes the task space, removes the worktree and deletes the branch, the same
   way as the Merge button does for any task space. In a project with
   `release_tags`, the cleanup runs the same way, and the task then waits in
   To ship until a release tag contains its merge; see [Release](#release).

Saying "merge it" to the task's agent runs the same skill. **Merge Without
Checks**, or `merge = "direct"` for the project, skips the agent and merges at
once. **Cancel Merge** stops a merge while the agent checks or Toastty waits for
checks: a `task merge` from the agent's turn that was checking is then refused.

A pull request merged on GitHub counts as your acceptance too. Toastty cleans up
its task space when no agent there is working and the worktree is clean at the
merged commit. Otherwise the task shows **Merged · clean up?** in Needs you;
**Clean Up** tries again and **Keep As Is** leaves everything where it is.
If the recorded worktree was already removed, Clean Up uses the task's recorded
repository to close the remaining task space and check its branches. The task
space must have one exact PR link, remain marked done, and have no unsaved
documents or terminals in another worktree. A recreated directory or a remaining
Git worktree registration stops recovery; Toastty does not remove either one.

This includes older task spaces tracked with `task adopt`. Without a saved
checkout path, cleanup requires the worktree to be gone; an existing checkout
stays for review. Toastty closes only the idle space with one exact PR URL chip.
In that case, it keeps every branch and leaves spaces with agents, running commands, unsaved
documents, or terminals in another worktree open. The primary checkout is
never removed.
While a merged task's task space stays open, its header no longer offers Merge:
it shows **Done · PR #N**, with **Archive Task…** in its menu, or **Cleanup
Stopped** while a stopped cleanup waits for you.

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

A task without a worktree or a pull request can also be archived when you
close its task space; see
[Finish without a pull request](#finish-without-a-pull-request).

## Finish without a pull request

For work that has no pull request, the agent runs `toastty task
ready-for-review`, and the task waits in Needs you. **Mark Done**, or
`toastty task mark-done`, finishes it.

The header of a task space without a pull request offers **Archive Task…**.
It is available before and after the agent reports completion, including for
a task already marked done. It opens the archive confirmation and uses the
same checks as [Archive a task](#archive-a-task).

A task that has no worktree and no pull request often answers in place. When
you close its task space, Toastty asks what happens to the task:

- **Mark Done** closes the task space and marks the task done.
- **Archive** closes the task space and archives the task.
- **Keep** closes the task space. The task stays in Needs you as "task space
  closed".
- **Cancel**, or Esc, closes nothing.

Toastty asks when you close the task space's last pane (Close Pane or Cmd+W),
close its last tab, close the workspace, or close its last session from the
sidebar. When that close also needs a confirmation, for example because an
agent still runs, the question includes the warning, so you see one dialog.
Toastty does not ask when an agent or the terminal's shell exits, when an
agent, the CLI, automation or the iPhone app closes the task space, after a
merge or an archive, when the session moves into a worktree, or when Toastty
quits. Toastty also does not ask for a task
with a worktree or a pull request, or for a task that is already done or
archived.

## Release

With `release_tags` set, a merged task waits in To ship until a release tag
contains its merge commit. A project can release from Toastty when
`tasks.toml` gives it a `release_skill` or a `release_prompt`. **Release…** on
its To ship line makes a release task: Toastty fetches the remote's default
branch, and starts the release agent in a new worktree on no branch at exactly
that commit, never in your project checkout. The fetch must succeed. The
agent's first message starts with `Use the <release_skill> skill.` when a
release skill is set, then `release_prompt` if one is set, then the list of
tasks waiting to ship. `toastty task release` does the
same from the CLI, and **Release <project>…** in the command palette does it
for an open project even when its To ship list is empty.

Toastty looks for release tags every 15 minutes and when the Tasks view opens:
it fetches tags and counts only a tag the remote has at the same commit. A
release made outside Toastty counts too. When a tag contains a task's merge
commit, the task is Done, and the Tasks view shows the tag. The release adds
no cleanup for the task: its merge already ran it. A shipped release task
closes its task space and removes its worktree once its agent is at rest,
unless the worktree's commit is on no remote branch or tag.

## Skills for task events

At each point where Toastty hands work to an agent, `tasks.toml` can name the
skill the agent uses. The message then starts with one line, `Use the <name>
skill.`, followed by that event's prompt text, if any, and the facts Toastty
adds, such as the task text or the pull request.

| Event | Triggered by | Setting | Default |
|---|---|---|---|
| Task starts (first message) | Create Task | `start_skill` | none |
| Move into a worktree | the agent, from its start skill | none: the shipped `toastty-task-start` | |
| Merge | the Merge button or the palette | `merge_skill` | `toastty-task-merge` (shipped) |
| Release | **Release…**, the palette or `toastty task release` | `release_skill` | none |
| Archive, clean up, done | Toastty itself | none | |

```toml
[defaults]
start_skill = "task-start"
merge_skill = "toastty-task-merge"

[workspace."~/GiantThings/repos/emptyos"]
release_skill = "emptyos-release"
release_prompt = "Wait for my approval before any production change."  # optional extra text
```

- `start_skill` also starts a first message that triage or `--prompt` wrote,
  and the first message of a fresh session that continues a moved task in its
  worktree. A forked session already has the conversation, so it gets no
  second skill line.
- With only `merge_prompt` set, Merge sends that prompt as written, with no
  skill line. Each key is looked up on its own, so a `merge_skill` in
  `[defaults]` also comes before a project's own `merge_prompt`.
- Toastty does not check that the skill is installed. Name a skill the task's
  agent can load: one in `~/.toastty/skills/`, the repository's
  `.agents/skills/`, or one Toastty ships.

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

`[defaults]` fills the agent, model and effort that a request leaves out. The default model and effort apply only with the default agent; a task
whose agent is another one gets that agent's own defaults.

`[triage]` is described in [Optional: triage](#optional-triage).

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

- `guidelines` go to triage, when it is on, with that workspace.
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
- `release_prompt` is text a release task's agent gets after the release
  skill line, such as `"Wait for my approval before any production change."`.
  A project with `release_skill`, `release_prompt` or both shows a Release
  button; with neither, it shows none.
- `merge` is `"agent"`, the default, or `"direct"`; see
  [Merge a task](#merge-a-task).
- `merge_prompt` is text Merge sends to the task's agent after the merge skill
  line. Set alone, it replaces the default message.
- `start_skill`, `merge_skill` and `release_skill` name skills; see
  [Skills for task events](#skills-for-task-events). A skill name is one word
  with no spaces.

`merge`, `merge_prompt` and the three skill keys can also go in `[defaults]`;
a workspace's own value wins. A `release_skill` in `[defaults]` lets every
project release.

An error in the file names its line, and `task create` fails with that message
until the file is fixed.

## Optional: triage

Triage is off unless `[triage] command` is set in `tasks.toml`. When it is
set, Toastty runs that command, usually a model CLI, once for a task that
leaves out the workspace, the agent, the first prompt, or a model or effort
its agent takes. It chooses what is missing, and may add a first prompt, a
title and a slug. A title or slug alone never starts it. Quick entry always
names the workspace and agent, so there triage only adds a first prompt, a
title and a slug, and any model or effort the preset leaves out.

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
Toastty session, and stops it after `timeout_seconds`. It writes instructions
and a JSON description of the choices to stdin: the task text and file names,
the open top-level workspaces (with the `guidelines` from their
`[workspace."…"]` sections), the projects that are not open
(`closed_workspaces`), the installed agent profiles that can take a first
prompt, `[triage] guidelines` (or the contents of `guidelines_file`, a path
that is absolute, under `~`, or relative to `~/.toastty`), and the values
already chosen, as fixed.

The command answers with one JSON object on stdout, also read from a fenced
code block, after other text, or from `claude -p --output-format json`:

```json
{"workspace": "<workspace ID>", "agent": "codex", "model": "gpt-6.1-sol",
 "effort": "high", "first_prompt": "Start with the composer views.",
 "title": "Composer keeps a blank line", "slug": "composer-blank-line",
 "reason": "A composer bug in toastty."}
```

`workspace` may also be a root directory that exactly one open workspace has,
or the root of one of `closed_workspaces`. A project that is not open is only
a suggestion: the task waits in Needs you with it chosen first. The workspace
must be open and the agent an installed profile; a value that fails a check,
or a triage that fails or times out, leaves that field to `[defaults]`, and
`task get` reports what happened in `triageNote`. The agent receives triage's
first prompt, then your text exactly as written, then the attached files. For
a task that waits for a workspace, the Tasks view also offers **Retry Triage**.

## Where tasks are stored

- `~/.toastty/task-records.json`: every task record.
- `~/.toastty/task-attachments/<task-id>/`: Toastty's copies of attached files.
  They are removed when the task is deleted, or a week after Toastty first
  saw the task Done or Archived with its task space closed. Toastty looks at
  launch and every 15 minutes, and not while `tasks.toml` has an error. A task
  that leaves Done, for example because work started again, starts a new week
  at its next finish. The record keeps the file names, and its history says
  the files were removed; such a task can no longer be retried.
- `~/.toastty/recent-workspaces.json`: the last closed top-level workspaces,
  for the workspace picker.

Deleting a task does not remove its worktree or branch; archiving it does.

Runtime-isolated runs keep both under their runtime home. See
[Privacy and Local Data](privacy-and-local-data.md).
