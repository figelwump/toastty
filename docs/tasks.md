# Tasks

A task is a piece of work you hand to an agent. You describe it, Toastty saves
it, makes a task space for it under a workspace, and starts the agent there.
The task keeps its own record, so it exists before its task space is ready and
after setup fails.

This page covers the quick entry panel, creating tasks from the CLI, from
an agent, or from Toastty Mobile, moving a task into its own git worktree, task stages with the
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

While [the coordinator](#the-coordinator) exists, the same panel sends your
text to it, and the coordinator makes the task; see
[Quick entry with the coordinator](#quick-entry-with-the-coordinator). The
rest of this section describes the panel with no coordinator, and what
`Option+Cmd+Return` does with one.

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

Toastty Mobile has the same form: **+** on its Home screen and content shared
from another app open **New Task**, with this panel's workspaces, Frequent
presets and `[defaults]`. A task created there counts toward Frequent and the
last workspace here. See
[Creating a task](remote-access.md#creating-a-task) in Remote Access.

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
| `--root <dir>` | The project's directory, instead of `--workspace`. Toastty uses the open workspace on it, or opens the project once every other check passed, so a request that fails opens nothing. |
| `--external-ref <id>`, `--external-url <url>` | The issue or report the task came from, such as `github:owner/repo#123`, and its http or https page. The Tasks view shows it as **Source**. |
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

A task created from another task's agent records that task as its parent. A
parent that has no pull request and no worktree of its own finishes when its
child tasks finish: once each child is To ship, Done or Archived and at least
one merged, the parent moves to To ship or Done after you read its last turn.
You do not mark it done or archive it. A parent agent that still has work to
do after the children merge keeps its task open with `task needs-reply` or
`task ready-for-review`. See [Stages](#stages).

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
  and when it entered that state) and `lastReply`, the agent's latest
  message. Toastty reads the reply from the Claude Code or Codex transcript, or
  from the history other agents publish through Toastty's extension, and cuts it
  at 16 KB. It is `null` until Toastty has confirmed the session's transcript.
- `toastty task list` reports `agentState` for every task and returns a
  `cursor`. With `--changed-since <cursor>`, it lists only the tasks whose
  record, stage or agent state changed since that answer, and the IDs of deleted tasks
  in `deletedTaskIDs`. A cursor from before a relaunch gets every task back with
  `reset: true`. `--include-reply` adds each task's `lastReply`.
- Both commands report how long the task has been in its state; see
  [How long a task has been in its state](#how-long-a-task-has-been-in-its-state).
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
task marked done by hand meets only `ready-for-review` and `done`. A task
that finishes through its child tasks counts as merged with them: in To ship it
meets `ready-for-review`, `merged` and `to-ship`, and in Done all four. The message
names the stage the task reached, which can be later than the one you watched
for. Toastty checks about once a second, so a stage that the task enters and
leaves again within that time can be missed; `ready-for-review` also ends while
an agent works in the task space again.

A watch is saved with the record of the task it notifies, so it survives a
relaunch, and it fires once. A watch whose task is deleted, or archived while
it waits for something else, fires with that reason. So does a watch for
`merged` or `to-ship` when Toastty's last merge of the task stopped without
merging, until a new merge starts; see [Merge a task](#merge-a-task). If the notified task's
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

### How long a task has been in its state

Toastty has no rule for a task that is stuck. `task get` and `task list` report
each state with the time it started, and the coordinator compares those times
with your policy.

| Field | Meaning |
| --- | --- |
| `stage.changedAt` | When the task entered its [stage](#stages): the `group`, and inside Needs you the `attention`. |
| `agentState.changedAt` | When the agent entered its `state`. A status report that repeats the state does not move it. `null` when no agent runs. |
| `agentState.interruptedAtQuit` | `true` when the agent was in a turn (`busy` or `waiting`) when Toastty quit or crashed, and has not started a turn since. |
| `agentState.lastOutputAt` | When the agent's transcript last changed. |
| `lastUserInputAt` | When you last worked in the task space. |
| `pullRequest` | GitHub's last answer about the task's pull request: `state`, `isDraft`, `mergeStateStatus`, `checks` and `checksPendingSince`. |

- **Stage.** A stage that lasts under 3 seconds does not move
  `stage.changedAt`: when an agent's status flickers between two tool calls
  and the stage returns, the earlier time stays. [Webhook events](#webhooks-for-task-events)
  use the same rule. Toastty saves the time with the task record, so a task
  whose stage is the same after a relaunch keeps its earlier time. A linked
  pull request counts as waiting for review until GitHub's first answer, as in
  the first minutes after a relaunch. That guess does not move the time:
  `stage.changedAt` is `null` until the answer comes, unless the task waited
  for review before.
- **Relaunch.** A relaunch restores each agent at its prompt. A task that was
  Running leaves that stage, so its stage time starts at the relaunch, and
  `interruptedAtQuit` says that its turn was cut off. Toastty saves the start
  of each turn at once, so a crash counts too. The mark clears when the
  task's agent starts its next turn. `agentState.changedAt` starts again when
  the agent is restored.
- **Output.** For Claude Code and Codex, `lastOutputAt` is the modification
  time of the transcript file. For agents that publish their history through
  Toastty's extension, it is the time of the newest entry. A long tool call
  or a sub-agent can write nothing to the transcript for a long time. It is
  `null` until Toastty has confirmed the session's transcript.
- **Your input.** `lastUserInputAt` moves when you type, paste or drop a file
  into a terminal in the task space, and when you send its agent a message, a
  steer or a stop from Toastty Mobile. Text that Toastty or the CLI types,
  such as `task send` and `terminal.send-text`, does not count. Toastty saves
  it about once a minute, so after a relaunch it can be up to a minute early.
- **Checks.** `checks` is `pending`, `failing` or `passing`, and `null` when
  the commit has no checks. One failed check reports `failing` while others
  still run. `mergeStateStatus` is GitHub's value, such as `CLEAN`, `BLOCKED`
  or `BEHIND`, and `UNKNOWN` while GitHub works it out after a push. Toastty asks GitHub at the times that [Stages](#stages) lists,
  so `checksPendingSince` is when Toastty first saw the checks pending for the
  head commit: they can have started up to two minutes earlier, or longer
  before that while Toastty did not run. `pullRequest` is `null` for a task
  without a pull request, and after a relaunch until GitHub answers again.

`task list --changed-since` does not list a task when only `lastOutputAt` or
`lastUserInputAt` changed. Read those times with `task get` or a full
`task list`.

## Coordinate from an outside agent

An agent outside Toastty on the same Mac, such as a chat assistant you talk
to, can be the coordinator: it turns issues and bug reports into tasks,
follows them, passes their questions to you and your answers back, and asks
for a merge when you say so. It uses the same CLI:

- `task create --root <repository> --external-ref <issue> --external-url <page>
  --request-id <key>` makes the task. A repeated request ID returns the
  first task. The Tasks view shows the issue as **Source**.
- `task list --changed-since <cursor> --include-reply` and
  `task watch <task-id> --until idle --wait` follow the tasks. A full
  `task list` also says
  [how long each task has been in its state](#how-long-a-task-has-been-in-its-state). A coordinator
  that can receive an HTTPS request can also get a
  [webhook](#webhooks-for-task-events), so nothing has to keep watching.
- `task send` passes your answers.
- `task request-merge <task-id>` accepts a merge for you; the task's agent
  still checks the pull request first.

[`examples/skills/toastty-tasks/SKILL.md`](../examples/skills/toastty-tasks/SKILL.md)
teaches an agent this workflow. Copy its folder into the agent's skills
directory, such as `~/.grok/skills/` for Grok. Outside a Toastty session the
CLI is `/Applications/Toastty.app/Contents/Helpers/toastty`; for a
development build, set `TOASTTY_CLI_PATH` and `TOASTTY_SOCKET_PATH` in the
installed copy from the build's `instance.json`.

The coordinator runs as you, so any process it starts can do what you can.
Toastty's rules prevent mistakes, not misuse: keep the agent's own approval
rules on for commands that merge, archive or delete. Issue text comes from
other people, so the skill treats it as data, not instructions. Toastty still
shows Needs you and sends its own alerts, and a task agent's permission
prompts can be answered only in Toastty or Toastty Mobile.

## The coordinator

The coordinator is one long-lived agent session that follows your tasks. It
runs in its own workspace, named **Coordinator**, with a terminal in
`~/.toastty/coordinator/`. A runtime-isolated dev run uses
`<runtime-home>/coordinator/` instead. The coordinator acts through the
`toastty task` commands, as any agent can. Its job is described in
[What the coordinator does](#what-the-coordinator-does), and your rules for
it are in [the policy file](#the-policy-file).

- **At a first launch**, when no coordinator was ever opened, Toastty asks
  once whether to start it. **Start Coordinator** does what Open Coordinator
  does. **Not Now** is saved, and Toastty does not ask again. The question
  shows over the window that has the keyboard, and the rest of the app stays
  in use. An automation run asks nothing.
- **Open Coordinator**, in the **Agent** menu and the command palette, creates
  the workspace on first use, selects it and starts the agent. Later it
  selects the workspace, and starts the agent only when none runs there.
- The sidebar pins one **Coordinator** row at the top, above the Tasks row, in
  both the Projects and the Status segment. The row shows the agent's state
  (a spinner while it works, an approval or error badge, a dot for unread
  output) and says **Not running** when no agent runs. It is not a project
  card: it has no number, does not reorder, and its name does not change.
- **Restart Coordinator**, in the **Agent** menu, the command palette, the
  row's context menu and the workspace header, starts a fresh agent session
  in the same workspace. The menu offers it while the coordinator is open. An
  agent that still runs is ended: the new session starts in a new terminal,
  and then the old terminal closes. A start that fails leaves the running
  agent alone. A terminal at its shell prompt is used again.
- After a relaunch, Toastty restores the workspace and resumes the agent's
  conversation, as it does for any agent pane. When there is nothing to
  resume, the row shows **Not running** until you open or restart it.
- Closing the workspace removes the coordinator. **Open Coordinator** then
  makes a new one. The files in its folder stay.

Claude Code asks whether you trust a folder the first time it runs there.
Toastty creates the coordinator's folder and writes every file in it, so
before it starts Claude Code there it names that one folder as trusted in
Claude Code's config file (`.claude.json` in your home folder, or in
`CLAUDE_CONFIG_DIR` when Toastty's environment or the `claude` profile's
`env NAME=value …` prefix sets it). It follows Claude Code's own rules for
that file: it holds the file's lock, reads the file again under the lock,
changes only the folder's entry in the text and replaces the file in one
step. It trusts no other folder. When it cannot write the entry, for example
because Claude Code never ran on this Mac or because it cannot tell which
config file the profile uses, Claude Code asks in its terminal and
[the chat](#the-coordinators-chat) says so. The same happens when only your
shell's startup files set `CLAUDE_CONFIG_DIR`: Toastty does not see that
value, so the entry goes to the config file in your home folder, which that
Claude Code does not read.

The coordinator is not a task. It has no task record, so `task list`, the
Tasks view, the Status segment's groups, webhook events and its own digests
never show it. It
is not a project either: a task cannot be placed in its workspace, nothing
nests under it, and quick entry and the workspace picker do not offer it. A
task that the coordinator creates has no parent task. Without `--workspace` or
`--root`, that task has no workspace yet, as a task from quick entry:
[triage](#optional-triage) places it when it is on, and otherwise it waits in
Needs you for one.

`toastty coordinator send` gives the coordinator a message:

```bash
toastty coordinator send "Task 1B32… is ready for review."
```

Toastty types the message when the agent is at an open prompt, and holds it in
order otherwise: while the agent works or waits for an approval, while text
that you typed in the coordinator's terminal may still be in its prompt, while
the agent starts, and while no agent runs. It types one message for each open
prompt. The answer says `sent`, or `queued` with the position and the reason.
`sentUnconfirmed` means the terminal did not confirm the Return key: Toastty
does not type that message again, and holds the next ones until a turn runs.
A message that was typed with its Return, but starts no turn within 10
seconds while the agent is at rest, does not hold the next ones: Toastty
opens the prompt again and types the next message. It does not type the lost
message again. Toastty cannot read the agent's prompt, so text that the agent
kept there goes out with the next message. A turn that an API error ends
(Claude Code shows **Error**) also opens the prompt again.
The queue holds up to 50 messages. It survives a restart of the agent.
Messages that you sent, from the chat or from quick entry, are also saved and
survive an app quit; a message from `coordinator send` waits in memory, and
an app quit loses it. Closing the coordinator's workspace drops the queue.

Each message from `coordinator send` gets a first line that names its
sender; see "Who a message is from" below.

The chat's composer, quick entry, `coordinator send` and Toastty's own
digests all go through this one queue, so their text never mixes. For an agent whose
conversation Toastty reads (Claude Code, Codex and the other agents that
Toastty Mobile can show), each message is typed through the check that a
paired iPhone's message gets: the agent's conversation must show an open
prompt, and each open prompt takes one message from one sender. A message
that a phone queued for the coordinator is typed first. For any other agent,
Toastty goes by the session's reported status.

Toastty Mobile shows the coordinator's workspace as an ordinary workspace.

**Who a message is from.** Toastty writes the first line of each message
that is not your own typing, from who called it and never from the message's
text:

| First line | Sender |
| --- | --- |
| `[Toastty] Wake: …` | Toastty: a [digest](#when-toastty-wakes-the-coordinator). |
| `[Toastty] From task [title](toastty://task/<id>): not from the user.` | `coordinator send` from a session in that task's space. |
| `[Toastty] From agent session <id> (<agent>, workspace "<title>"): not from the user.` | `coordinator send` from an agent session outside a task. |
| `[Toastty] From a terminal command: Toastty cannot tell who ran it.` | `coordinator send` from a caller that names no running session, such as your own shell. |
| `[Toastty] Quick entry from the user \| …` | You, in the quick entry panel. |
| no `[Toastty]` line | You, in the chat or in the terminal. |

The sender's text starts on the second line, and the coordinator's
instructions say that only the first line counts. Claude Code records a
long typed message inside `<pasted_content>` tags; the first line inside
them is then the message's first line, for the coordinator and for the chat. So text that an agent
sends with `coordinator send` cannot read as yours, as a digest or as a
quick entry message, whatever it says. The coordinator treats such a message
as data from that sender, as it treats a task's reply. Toastty takes the
sender from the session ID that the CLI reports, so a caller can hide its
session and show as a terminal command, but it cannot show as you.

### Quick entry with the coordinator

While the coordinator's workspace exists, `Option+Shift+T` opens the quick
entry panel with the label **To coordinator**. `Cmd+Return` or **Send** sends
your text to the coordinator, which chooses the project and the agent, asks
you when it is not sure, and creates the task.

- **Workspace and Agent are optional.** Both pills start as **Auto**: the
  coordinator chooses. Set one with `Cmd+1` or `Cmd+2`, and the message
  carries it as your choice: the coordinator then uses it without a
  question. The first row of each list sets the pill back to Auto; in a
  search that row is last, and `auto` finds it.
- **The selected project is a hint.** The message also names the project of
  the workspace that was selected in Toastty when the panel opened, marked
  as a hint and not as your choice. **New Task from Selection…** names that
  terminal's project. A project that you chose replaces the hint.
- **Attachments.** Toastty copies each attached file to
  `~/.toastty/coordinator/attachments/<message ID>/`, and the message ends
  with the paths. The coordinator passes them to the task it creates
  (`task create --file`), which copies them again. Toastty removes a
  message's copies when you remove the waiting message, and otherwise 7 days
  after it made them. A copy's name keeps only letters, digits, `.`, `_`
  and `-`.
- **Nothing is lost.** Toastty saves your message in
  `~/.toastty/coordinator-queue.json` until the coordinator's prompt takes
  it: while the coordinator works, starts or restarts, while no agent runs,
  and across an app quit. A quick entry message never goes into a running
  turn; it waits for the turn's end. The toast says **Sent to the coordinator**, or why
  the message waits. The panel's header says so before you send, when the
  coordinator is not running or starting. Messages from the chat's field are
  saved in the same way.
- **See and remove a waiting message** in the coordinator's chat: it shows as
  **Queued** with **Edit** and **Remove**. Remove also deletes the copies of
  its files. Edit puts the text into the chat's field as Toastty would type
  it, with its first line, and its files go back above the field as
  attachments.
- **Typed once.** Toastty saves that it starts to type a message before the
  text goes to the terminal. If Toastty quits in that moment, the message is
  not typed again after the relaunch: it shows as **Paused**, and the chat
  asks you to check the conversation and to choose **Send next** or
  **Remove**. The same holds for a message that **Steer now** was typing. While Toastty cannot write `coordinator-queue.json`, it does
  not type a message that the file lists as waiting, because a relaunch
  could then type it a second time: the message waits, the chat says that
  Toastty could not save it, and Toastty tries again every 5 seconds.
- **Create the task directly** with `Option+Cmd+Return` or **Create**.
  This is the panel without a coordinator: the task goes to the workspace
  and the agent of the pills, and a pill that shows Auto uses the value it
  would start on without a coordinator (see [Quick entry](#quick-entry)),
  also after you set it and went back to Auto; the button's tooltip names
  both. In a list, `Option+Cmd+Return` chooses the row and then creates the
  task, as `Cmd+Return` chooses it and then sends.
- **In the chat** a quick entry message shows your text, and under it your
  choices and the names of the files. The terminal shows the message as
  typed.

A message looks like this in the coordinator's terminal:

```text
[Toastty] Quick entry from the user | project chosen: "toastty" (workspace 65A904AE-…) | agent chosen: codex, model gpt-6.1-sol, effort high
The unread dot stays on after I read the session on the phone.

Read the following files attached to this message on this Mac:
`/Users/you/.toastty/coordinator/attachments/7C1B…/Screenshot.png`
```

With no choice, the first line is `[Toastty] Quick entry from the user |
selected in Toastty, a hint only: "emptyos" (workspace 4AAE2AAF-…)`.

### The coordinator's chat

On macOS 15 and later, the coordinator's panel shows the agent's conversation
as a chat, with the same message views as Toastty Mobile. The terminal runs
under it. On macOS 14 the panel shows the terminal.

- **Send.** Type in the field under the conversation and press Return.
  Shift-Return or Option-Return starts a new line. At an open prompt the
  message is typed there. The field's hint names the quick entry shortcut,
  which sends to the coordinator from any app.
- **Steer or queue while the coordinator works.** While a turn runs, Return
  types your message into that turn, so the coordinator reads it before the
  turn ends: this is **Steer**, the default. The chip beside the send button
  says **Steer**. Choose **Queue** on the chip, or press Command-Return, and
  the message waits in the chat as **Queued** and is typed when the turn
  ends. The chip shows **Queue** in the accent color, so a message that will
  not go into the running turn is easy to see. After a send the chip goes
  back to Steer, and a choice of Queue ends with its turn. When the turn
  cannot take a steer, the chip, the button and the send fall back to Queue
  together: the agent is not Claude Code or Codex, it asks a question or for
  a permission, you typed in its terminal during the turn, or its terminal
  is not ready. After the terminal refused a steer's text, the rest of that
  turn queues too. A message with files steers like any other: its files go
  in as their paths. Claude Code reads a steered message when its current
  step ends, for example when a command it runs finishes.
- **Waiting messages.** **Edit** puts a waiting message back in the field,
  **Remove** drops it, and **Steer now** types a waiting message that you
  wrote in the chat into the running turn, where it then shows as
  **steered**. A waiting message is saved, so it is still there after a
  relaunch.
- **Only what you write in the chat steers.** A message from quick entry
  always waits for the turn's end, also while a turn runs, and its row
  offers no Steer now. **Edit** puts it back in the field with Toastty's
  first line, and sent from there it still waits. Toastty's digests and
  messages from `coordinator send` always wait too.
- **Attach files.** The **+** button next to the field attaches files
  (**Files…**) or photos from the Photos library (**Photos…**). You can also
  drop files or images on the field or anywhere on the chat, and paste a
  copied file or image. Pasted or dropped text stays text. Each file shows
  above the field, an image with a preview; **×** removes it. A message can
  have up to 10 files of up to 50 MB each, and files alone can be a message.
  A photo in a format that Claude cannot read, such as HEIC, is sent as a
  JPEG. When you send, Toastty copies the files to
  `~/.toastty/coordinator/attachments/<message ID>/` and the message ends
  with their paths, as a message from the quick entry panel does. The chat
  shows your text and the names of the files, also on a waiting message,
  which counts its files. **Edit** puts a waiting message's files back above
  the field; they stay in their folder until the message that names them is
  sent and expires, or is removed.
- **Stop.** While a turn runs and the field is empty, the button stops the
  turn, as Escape in the terminal does. Messages that waited are
  then **Paused**, so none starts a new turn right after the stop. **Send
  next** lets them go again. A digest from Toastty does not wait for paused
  messages.
- **Terminal.** The **Terminal** button in the panel's header shows the
  terminal in place of the chat, and **Chat** switches back. Use the terminal
  for a login, a folder-trust or a permission prompt, and to answer a
  question: the chat shows such a prompt but cannot answer it, and it says so
  above the field. The choice is not saved: a relaunch shows the chat.
- **An agent that has not started.** A login or a folder-trust question comes
  before the agent reports anything to Toastty. While the agent's process
  runs and the agent has not reported its session, the chat says that the
  agent is starting, and a message you send shows as **Queued · waits for the
  agent to start**. After 8 seconds the chat says that the agent may wait for
  your answer in the terminal. **Show Terminal** shows the terminal. After
  your answer there, the chat shows the notice for a draft in the terminal,
  and **Send Anyway** types the waiting message.
- **A draft in the terminal.** When you typed in the terminal and did not
  send that text, messages and digests wait, and the chat says why. **Send
  Anyway** tells Toastty that the terminal's prompt is empty: the next
  message is then typed there. The same holds after you answered a login or
  a folder-trust question in the terminal before the agent started: Toastty
  cannot tell those keys from a draft, so choose **Send Anyway**.
- **Digests.** A message that Toastty typed (see below) shows as one muted
  line, such as "Toastty · 2 updates · 14:05". A click opens the full text.
- **Messages from agents.** A message that `coordinator send` brought shows
  as one muted line that names its sender, such as "From task Fix the unread
  dot · 14:07". A click opens the full text. It never shows as your message.
- **Task chips.** A link `[title](toastty://task/<id>)` in the coordinator's
  text shows as a chip with the task's stage color, its current title and its
  pull request number. A click opens the task's space, and that space's
  header then shows **← Coordinator** until you are back. A link to a task
  that does not exist, and any other `toastty:` link, is plain text. Other
  links open only `http` and `https` pages, in your browser.

Toastty reads the coordinator's conversation while the coordinator's
workspace is open, also with Remote Access off, because it must see what
happens at the prompt to type there safely. A relaunch shows the same
conversation, because the agent resumes it.

`toastty coordinator open|restart|status` run the same actions as the command
palette; see the [CLI reference](cli-reference.md#coordinator).

### What the coordinator does

The coordinator follows your tasks and keeps them moving. It does not do
their work. Its instructions are the text of the `toastty-coordinator` skill,
which Toastty ships. Toastty has no rule about a task that is stuck: the
coordinator decides, by the skill's defaults and by your policy.

On each [wake](#when-toastty-wakes-the-coordinator) it reads `toastty task
list`, compares
[how long each task has been in its state](#how-long-a-task-has-been-in-its-state)
with your policy, reads the last reply of a task that looks stuck, acts, and
sets its next check.

| Situation | What the coordinator does by default |
| --- | --- |
| Toastty restarted while an agent worked | Tells the task to continue. |
| An agent waits at a permission prompt | Never answers it. Tells you after 10 minutes. |
| An agent asks a question | Answers when your policy, or an earlier answer of yours, settles it, and tells you. Otherwise passes the question to you with the answer it suggests. |
| An agent ended a turn, and the task is not done | Reads the reply. It then waits for CI, notes the task or pull request the agent waits for and tells the agent when that merged, treats the reply as a question, or tells the agent to open its pull request or to mark the work ready. |
| CI failed | Tells the task to fix it, or to rerun a check your policy names as a flake. |
| CI runs for more than 30 minutes | Looks at the run, and tells you when it is queued or hangs. |
| The pull request has merge conflicts | Tells the task to rebase and resolve them. |
| An agent is busy, with no output for 30 minutes | Never interrupts. Tells you which command seems to hang. |
| Setup failed | Retries it once, then tells you. |
| No agent runs, an agent stopped with an error, or a merge or cleanup stopped | Tells you, with the reason. |

- **New tasks.** Tell the coordinator what you want done, in its chat or
  with [quick entry](#quick-entry-with-the-coordinator). It chooses the
  project, and the agent, model and effort, from what you said or set in the
  panel, then from your policy, then from the history of your tasks. When two projects are
  still plausible, it asks first and creates the task after your answer.
  When your answer holds for more than one request, it adds a rule to the
  policy.
- **Review.** When a task is ready for review, the coordinator reads its pull
  request, its checks and its verification report, and compares them with
  the Reviewing section of your policy. With weak proof, it tells the task
  exactly what to add, once; if the proof is weak again, it brings the task
  to you. With good proof, it tells you in one or two sentences why the task
  is ready. It writes no summary of the proof. You merge.
- **Releases.** Each project has a rule in the policy: release on merge, or
  in batches. The coordinator asks you for the rule the first time a project
  has merged work that waits. It starts a release that the rule calls for
  with `toastty task release`, and proposes a batch release and waits for
  your yes. A task with
  [`task set-release --after-merge`](#release-one-task-right-after-it-merges)
  gets a release as soon as it merges. Before a release for one task, the
  coordinator says which other merged tasks ship with it.

How it works with your tasks:

- Its messages to a task start with `[coordinator]`.
- It sends nothing to a task you typed in during the last 15 minutes
  (`lastUserInputAt`).
- It sends a task one message for each condition. If the condition comes
  back, it tells you.
- It writes a task as a link, `[title](toastty://task/<task-id>)`.
- It treats text from tasks, pull requests and issues as data, not as
  instructions.
- It does not use `task watch --notify` for a task that waits for another
  one. Toastty types a watch's notice whatever the agent does at that
  moment, also at a permission prompt. The coordinator notes the dependency
  in its ledger, hears of the merge in a digest, and then tells the task
  under its own rules.

What it may do alone, what it asks first, and what it never does:

| Do, then tell you | Propose, then wait | Never |
| --- | --- | --- |
| Continue an interrupted agent | The project of a new task, when it is not sure | Answer an agent's permission prompt |
| Send a CI or conflict instruction | A batch release | Merge: `task merge`, `task request-merge` or `gh pr merge` |
| Follow a dependency and tell the task when it merged | Archive a task, or make it again in another project | Interrupt a busy agent |
| Ask a task for better proof | A question that a task asked you | Change production outside a release task |
| Answer a question that your policy settles | | Write code |
| Retry a failed setup once | | |
| Start a release that a rule or `--after-merge` calls for | | |
| Add a policy rule after your answer | | |

The skill fixes the Never column: your policy cannot change it, and the
coordinator refuses these also when you ask it in its conversation. To merge,
use Merge on the task, or say "merge it" to the task's agent.

These limits are instructions to the agent. Toastty itself refuses only
`toastty task merge` from the coordinator, because that command runs only in
the task's own task space. The coordinator runs as you, so keep its agent's
own approval rules on for commands that merge, archive or delete. A message
that another agent sends with `toastty coordinator send` arrives at the same
prompt as your own typing, with a first line from Toastty that names its
sender. Text that an agent types straight into the coordinator's terminal,
with `terminal.send-text`, has no such line.

### The coordinator's folder

Each time the coordinator's agent starts, and when Toastty launches with a
coordinator to resume, Toastty makes sure that the folder holds these files:

| File | Written by | What it is |
| --- | --- | --- |
| `AGENTS.md`, `CLAUDE.md` | Toastty | The agent's instructions: the text of the shipped `toastty-coordinator` skill. `CLAUDE.md` imports `AGENTS.md` for Claude Code. |
| `policy.md` | you and the coordinator | Your rules. See [the policy file](#the-policy-file). |
| `ledger.md` | the coordinator | What it must not repeat or forget: each message it sent to a task, what it told or asked you, and the outside pull requests it watches. |
| `attachments/` | Toastty | Copies of the files you attached to a quick entry message, in one folder for each message, kept out of the repository. See [Quick entry with the coordinator](#quick-entry-with-the-coordinator). |

- **The instructions are Toastty's.** An agent reads its folder's instruction
  file at each start and each time its conversation is resumed. So the
  coordinator has its instructions after a restart and after a relaunch,
  and a new version of Toastty brings new instructions to a conversation
  that began under the old one. Toastty replaces both files whenever their
  text differs, so do not edit them: put your rules in `policy.md`. An agent
  that reads neither file can load the `toastty-coordinator` skill by name.
  If Toastty cannot write the instructions, it does not start the
  coordinator's agent, and after a relaunch it does not resume it: the row
  says **Not running**, and `toastty coordinator status` gives the reason as
  `startFailure`.
- **The policy and the ledger are yours.** Toastty creates `policy.md` with
  its section headings only, and `ledger.md` with its title, when the file
  is missing. It never writes either file again, also when you emptied it.
- **The folder is a git repository.** At the first start, Toastty runs `git
  init` there and commits `policy.md`. The repository has its own identity,
  `Toastty Coordinator`, and does not sign commits, so a commit works without
  your git settings. `AGENTS.md`, `CLAUDE.md`, `ledger.md` and `.claude/` are
  kept out through `.git/info/exclude`, so a commit holds a change of the
  policy and nothing else. Toastty leaves a folder that already is a
  repository as it is. If git is missing, the coordinator still starts, and
  tells you that a change of the policy cannot be undone.

### The policy file

`policy.md` holds your choices. A rule there wins over the skill's defaults,
except for the Never column. You can edit it at any time; the coordinator
reads it on each wake. The coordinator writes most of it by asking you:

```markdown
# Coordinator policy

## Projects
- Computer update, Things, publishing → emptyos.
- Website copy or layout → toastty, docs/.

## Agents
- Toastty bug with a repro: codex, gpt-6.1-sol, high, start work at once.
- Design or product question: claude, claude-opus-5-5, xhigh; shape first.

## Reviewing
- Good proof = a scenario list, each checked through the real UI or CLI;
  screenshots or video for UI changes. Unit tests alone are not enough.

## Unblocking
- Tell me about permission prompts after 10 minutes.
- CI pending over 45 minutes on toastty is unusual; look before telling me.

## Releases
- www: on merge.
- Toastty Mac app: batch; remind me at 8 waiting or every Monday.

## Notes (kept by the coordinator)
- toastty: testLongSidebarScroll fails on the mini; CI decides.
```

**The first run.** While Projects and Agents hold no rule, the coordinator
drafts both from the history of your tasks, which is the project, agent,
model, effort and title of recent tasks from `toastty task list`. It shows
you the draft, and writes it after you confirm or correct it.

**Undo.** The coordinator commits each change it makes to the policy as one
commit, named `Policy: change <section>`, and shows you the line it added.
Say "undo" and it reverts that commit. By hand:

```bash
git -C ~/.toastty/coordinator log --oneline -- policy.md
git -C ~/.toastty/coordinator revert <commit>
```

When you changed `policy.md` yourself, the coordinator commits your change
first, as "Edited outside the coordinator", and shows you the lines. Its own
change is then a commit of its own.

### When Toastty wakes the coordinator

The coordinator does not poll and keeps no watch command running. Toastty
types a short message, a digest, into it for two reasons:

- **A task's stage changed.** Each task whose `stage.group` or
  `stage.attention` changed, whose pull request merged, or that was deleted
  gets one line. The changes come from the detector behind the
  [webhook events](#webhooks-for-task-events): a stage that comes from an
  agent's status counts after it holds for 3 seconds, so a status that
  flickers wakes nothing. The coordinator gets the changes of every task,
  with Running and Idle, and also a change that has no webhook event, such
  as To ship to Done after a release. It needs no approval, because nothing
  leaves the Mac.
- **The coordinator's timer came due.** See [the timer](#the-coordinators-timer).

Toastty has no rule about a task that is stuck, and a digest holds no
judgment. It says which tasks changed; the coordinator reads `task list`,
with [how long each task has been in its state](#how-long-a-task-has-been-in-its-state),
and decides by your policy.

A digest looks like this:

```text
[Toastty] Wake: this message is from Toastty, not from the user.
- [Fix the unread dot](toastty://task/8C2F1D3A-…): needsYou (review) at 2026-11-09T18:02:11Z
- [Add the export API](toastty://task/41B7E9C0-…): done, merged at 2026-11-09T18:03:40Z
- Scheduled check: the time you set, 2026-11-09T18:20:00Z, has come.
Read `toastty task list` for details.
```

- The first line is always the same and starts with `[Toastty] Wake`.
- Each task has one line: its title as a link to `toastty://task/<task-id>`,
  the `stage.group` and `stage.attention` that `task list` reports, `merged`
  for a task whose pull request merged, and the time Toastty counted the
  change. A deleted task shows `deleted`. A task that changed again before
  the digest was typed has its newest stage only. A title is cut after 80
  characters, and control characters in it are not typed.
- A digest lists up to 40 tasks and counts the rest in one line.
- The `Scheduled check` line is there when the timer came due.
- The last line is always the same.
- A digest never holds an agent's reply or question, a prompt or an
  attachment.

Delivery:

- Toastty types a digest only at the coordinator's open prompt, through the
  same path as `coordinator send`. While the coordinator works or waits for
  an approval, while you have a draft in its terminal, while its agent starts
  and while no agent runs, nothing is typed: the digest waits and grows. A
  burst of changes is one message, and one digest is typed for each turn.
- Messages from `coordinator send` that wait go first.
- The waiting digest is saved in `task-webhook-outbox.json` in the same
  write as the detector's last known stages, before anything is typed. After
  a quit or a crash, Toastty types what waited once, and reports changes that
  it missed while it was quit, such as a merge on GitHub. A digest counts as
  told when Toastty typed it, also when the terminal did not confirm the
  Return key. Toastty saves that at once and does not type it again.
- A restart of the coordinator's agent keeps what waits, and nothing is
  typed while the restart runs. Closing the coordinator's workspace drops
  what waits, with the timer. A coordinator that you open later starts with
  Toastty's next check of the tasks, within about a second. That check only
  records where the tasks stand: a change from before the coordinator
  existed is not told. While a webhook is approved, one exception applies: a
  stage that was inside its 3 seconds at that moment is told once it counts.
- Toastty follows task changes for the coordinator only while its workspace
  exists. The coordinator is not a task, so its own turns wake nothing.

### The coordinator's timer

Before it ends a turn, the coordinator says when Toastty wakes it next if no
task changes first:

```bash
toastty coordinator wake --in 20m
toastty coordinator wake --at 2026-11-09T18:30:00Z
toastty coordinator wake --clear
```

- `--in` takes `s`, `m`, `h` and `d`, such as `90s`, `20m`, `2h` or `1h30m`.
  `--at` takes an ISO 8601 time. The time must be at least 1 minute from now.
- Toastty saves the time. A time that came while Toastty was quit wakes the
  coordinator once after the relaunch.
- **Every digest that Toastty types removes the time**, whether the digest
  was for a task change or for the timer, and whether the time had come or
  not. The coordinator sets its next check again in the turn that the digest
  starts. A time that it sets during a turn stays until the next digest.
- **With no time set, the timer is 1 hour after the last digest, while a
  task is open.** A task is open until it is Done or Archived; a task that
  waits for a release is open. With no time set and no open task there is no
  timer. Before the first digest, the hour counts from the moment the
  coordinator's workspace was created.
- `--clear` removes the time the coordinator set, so the 1 hour default
  applies again.

`toastty coordinator status` shows `wake.nextWakeAt` with `wake.nextWakeSource`
(`coordinator` or `default`), `wake.lastWakeAt`, and `wake.pendingTaskCount`,
the number of tasks whose changes wait for the next digest.

## Webhooks for task events

A coordinator that can receive an HTTPS request, such as a bot that wakes
when something POSTs to its URL, can get task events from Toastty instead of
keeping a watch running:

```bash
toastty webhook add grok https://hooks.example.com/wake --auth bearer \
  --secret-hint "In the bot's routine panel, open Webhook and copy the Sender key." --wait
```

1. `webhook add` registers the webhook. It waits for your approval and
   receives nothing until then. The key (the secret the receiver checks) can
   come on stdin with `--secret-stdin`. Without it, you paste the key when
   you approve, and `--secret-hint` tells you where to find it.
2. The sidebar shows **1 webhook** next to Tasks, and the Tasks view shows a
   banner. **Review…** shows where events go, which events, for which tasks,
   and how requests sign in, and asks for the key when Toastty has none. The
   hint shows under the key field as the requester wrote it; Toastty does not
   check it. The key is kept in the login Keychain. Only **Approve** in that
   sheet approves the webhook; no command can. **Deny** removes the webhook
   and its key.
   `webhook add --wait` waits for your decision: it exits 0 when you approve,
   3 when you deny, and 4 when `--timeout` runs out.
3. Toastty then POSTs a small JSON event when a task enters Needs you, or
   needs you for a new reason (`task.needs_you`), merges (`task.merged`),
   finishes (`task.done`), or is archived or deleted. `--events` can also add
   `running` and `idle`. `--root` and `--external-ref-prefix` limit the
   events to some tasks.

Each event has `eventID`, `type`, `occurredAt`, `webhook`, and `task` with
its `id`, `title`, `projectRoot`, `externalRef`, `stage` (`group` and
`attention`), `question`, `pullRequestURL` and `mergedAt`. It never carries
an agent's reply, the prompt or attachments; read those with `task get`. The
`Toastty-Event-ID` header repeats the event ID, so a receiver can drop a
duplicate.

`--auth` sets how a request proves it came from Toastty:

- `bearer`: `Authorization: Bearer <secret>`.
- `header:<Name>`: `<Name>: <secret>`.
- `hmac` (the default): `Toastty-Signature: t=<unix>,v1=<hex>`, an HMAC-SHA256
  of `<t>.<body>` with the secret. Reject a `t` older than a few minutes.
- `none`: only for `http://127.0.0.1` and `localhost`, for tests.

Addresses must use HTTPS, except 127.0.0.1 and localhost. Toastty does not
follow redirects. Logs and `webhook list` show only the host, since a path
can hold a token, and never the secret.

Delivery:

- A stage that comes from the agent's status counts after it holds for 3
  seconds, so a passing status sends nothing. Merges, Done, archives and
  deletions count at once. A review stage and a merge made on GitHub show
  after the next pull request check, up to 2 minutes later.
- Toastty saves each event before it sends it, sends one at a time to each
  webhook, and retries failures after 5 s, 15 s, 45 s and so on, up to 10
  minutes apart, for a day. A newer stage replaces an older one still
  waiting for the same task; merged, done, archived and deleted events are
  kept. Retries start again when the Mac wakes.
- After a relaunch, Toastty sends the events still waiting, does not repeat
  changes it already sent, and reports changes it missed while it was quit,
  such as a merge on GitHub.
- HTTP 401, 403 or 410 stops the webhook, and the Tasks view shows a banner.
  **Enter new key…** there, or `webhook rotate-secret`, sets a new key and
  starts it again; changes made while it was stopped are not sent.
- An event is a wake-up hint. `task list --changed-since` stays the source of
  truth; run it when an event arrives and from time to time.

Changing a webhook's address, events, filters or `--auth` with `webhook set`,
or editing `~/.toastty/task-webhooks.json`, needs approval again. A new
key or hint does not. A workspace-scoped session cannot manage webhooks.
Toastty checks for task changes only while a webhook is approved or the
[coordinator](#when-toastty-wakes-the-coordinator)'s workspace exists. While
that workspace exists the checks do not stop, so a webhook that you approve
or start again then begins with the next check: it can get a change that was
under way in the seconds before.

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
| To ship or Done | it has no pull request and no worktree of its own, it started child tasks, and they all finished: each child is To ship, Done or Archived, and at least one merged. It is To ship while a child waits for a release, shown as "Child tasks merged · waiting for a release", and Done once every child that is not archived is Done. This also applies after its task space closed, unless it still waits for a reply or a review |
| Idle | anything else: its agent is idle at its prompt, or no agent runs in its task space |

A parent that finishes through its child tasks stores nothing: its stage
follows theirs. A new child that is not finished moves it back to Idle, and its
agent's next turn moves it to Running. Its task space stays open, and Projects
hides it as for any To ship or Done task. Children that were archived, or
marked done without a merge, do not finish a parent alone; it stays Idle, and
you decide.

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

In a tracked task, an unread reply remains reachable while merge checks run,
including when its parent requested the merge. Accepting a merge does not
mark the reply read. Quiet unread replies in Done, Archived or To ship tasks
are skipped; working agents, approval requests and errors remain reachable.

The Tasks row at the top of the sidebar opens the Tasks view; its badge counts
the tasks that need you, and its ＋ creates a task. Below it, a switcher groups
the sidebar by **Projects** or by **Status**. The choice is saved for each
window.

- **Projects** is the workspace list. A task space whose task is To ship or
  Done leaves its card's task space list unless an agent in it is working or
  waiting for you. After the card's task spaces, a To ship line with the
  purple To ship mark lists the project's other To ship tasks, with the Done
  count on its right. Like
  Status, it starts collapsed; click it to expand it in place, and the choice
  resets when the sidebar hides or the app quits. Expanded, the 3 most
  recently merged To ship tasks show as rows, then **Show N more** when the
  project has more. When every To ship task shows as a task space row, the
  footer counts To ship tasks instead.
- **Status** lists task spaces by stage: Needs you, Running, Idle, To ship,
  and a Done count. Each row carries its project's name, except under To ship.
  A task and the tasks it started list together, in the group of the most
  urgent one: an idle parent whose child needs you lists in Needs you, dimmed,
  with the child under it. Group counts include only the tasks whose own stage
  is in that group, and a row listed in a group its own stage is not in is
  dimmed. Inside a group, tasks keep the Projects order: by project, then in
  the order their task spaces opened, so a row moves only when its stage
  changes its group. The selected task's family keeps its group until you
  select another row, so reading a finished turn dims the row instead of
  moving it from under the pointer; a task that starts to need you moves at
  once. A parent without a pull request moves to To ship or Done when its
  children finish, so the whole family leaves Idle. A parent in To ship counts
  in its project's To ship line with its children.
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

**Open Coordinator** and, once its workspace is open, **Restart Coordinator**
are described in [The coordinator](#the-coordinator). The **Agent** menu has
both.

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

The status mark at the start of a task space row is also a done checkbox, on
the Mac and on iPhone. While the task has an open pull request, or a merge is
under way, the mark only shows the status: the task finishes through Merge or
Archive, as the detail pane offers. iPhone hides its Done swipe too. The Mac
refuses a done mark that any phone sends for such a task; an older iPhone
reports that it could not update the task. A done mark the task already
has can still be cleared. A subspace without a task record keeps the
checkbox.

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

   If the merge stops without merging, for example because the checkout is
   no longer at the `--head` commit the skill checked, or a waiting merge is
   refused, nothing changes on GitHub. Toastty shows no alert that you must
   dismiss, since an agent or a shell may have started the merge. Instead it
   sends a desktop notification and records the reason on the task: the
   task's row shows **⚠ merge stopped**, the Tasks view gives the reason, and
   **Merge** is offered again. `toastty task get` reports it as
   `mergeFailure` until a new merge starts, and a `task watch --until merged`
   or `--until to-ship` then ends as one that can never fire.
4. Toastty records the merge on the task first. Once the agent's turn ends, it
   closes the task space, removes the worktree and deletes the branch, the same
   way as the Merge button does for any task space. In a project with
   `release_tags`, the cleanup runs the same way, and the task then waits in
   To ship until a release tag contains its merge; see [Release](#release).

Saying "merge it" to the task's agent runs the same skill. From outside the
task, `toastty task request-merge <task-id>` does what Merge does, and always
through the task's agent, also with `merge = "direct"`. `toastty task merge`
itself runs only from an agent in the task's task space or in its parent
task's, so a shell or an outside coordinator cannot skip the agent's checks
by mistake. **Merge Without
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

A task that split its work into child tasks needs neither: it finishes when
its children finish. See [Split work into new tasks](#split-work-into-new-tasks).

The header of a task space without a pull request offers a green **Complete
Task** button when its current stage is Ready for review. It marks the task
Done and keeps its conversation, workspace, and worktree. Active work or a
reply request takes priority over an earlier ready mark.

At other stages, including Done, the header offers **Archive Task…**. It opens
the archive confirmation and uses the same checks as
[Archive a task](#archive-a-task). Archive also stays available in the task menu.

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
tasks waiting to ship. A parent that is To ship only through its child tasks
has no merge of its own, so the list names its children, not the parent. A
To ship line that holds only such a parent offers no **Release…**. `toastty task release` does the
same from the CLI, and **Release <project>…** in the command palette does it
for an open project even when its To ship list is empty.

Toastty looks for release tags every 15 minutes and when the Tasks view opens:
it fetches tags and counts only a tag the remote has at the same commit. A
release made outside Toastty counts too. When a tag contains a task's merge
commit, the task is Done, and the Tasks view shows the tag. The release adds
no cleanup for the task: its merge already ran it. A parent whose children
shipped becomes Done with them. A shipped release task
closes its task space and removes its worktree once its agent is at rest,
unless the worktree's commit is on no remote branch or tag.

### Release one task right after it merges

You can ask for one task to be released right after it merges, also in a
project that releases in batches. Tell the task's agent or your coordinating
agent, or run the command yourself:

```bash
toastty task set-release <task-id> --after-merge
toastty task set-release <task-id> --clear
```

A task's agent can leave out the task ID to set the request on its own task.

Toastty saves the request on the task and shows it. Toastty does not start a
release because of it. The agent that starts your releases reads the request
when the task reaches To ship, and then runs `toastty task release`.

- The request is allowed on an open task and on a To ship task. Toastty
  refuses it on a Done or archived task and on a release task.
- A second request keeps the time of the first one. `--clear` removes the
  request, and is also accepted on a task that has none.
- `task get` and `task list` report it as `releaseAfterMerge`, with
  `requestedAt`. A set or a clear lists the task in
  `task list --changed-since`.
- The request stays after Toastty relaunches.
- While the task is open or To ship, its rows in the sidebar and in the Tasks
  view show a small violet bolt, and the Tasks view's detail pane shows
  **Release: Right after merge**. The app has no control for it.

## Skills for task events

At each point where Toastty hands work to an agent, `tasks.toml` can name the
skill the agent uses. The message then starts with one line, `Use the <name>
skill.`, followed by that event's prompt text, if any, and the facts Toastty
adds, such as the task text or the pull request.

| Event | Triggered by | Setting | Default |
|---|---|---|---|
| Task starts (first message) | Create Task | `start_skill` | `toastty-task-start` (shipped) |
| Move into a worktree | the agent, when you ask it to implement the work | none: part of the shipped `toastty-task-start` | |
| Merge | the Merge button or the palette | `merge_skill` | `toastty-task-merge` (shipped) |
| Release | **Release…**, the palette or `toastty task release` | `release_skill` | none |
| Archive, clean up, done | Toastty itself | none | |

```toml
[defaults]
start_prompt = "Ask me before you open a pull request."  # optional extra text
merge_skill = "toastty-task-merge"

[workspace."~/GiantThings/repos/emptyos"]
release_skill = "emptyos-release"
release_prompt = "Wait for my approval before any production change."  # optional extra text
```

- The shipped `toastty-task-start` takes a task from your request to your
  review. Its agent clarifies the request, moves implementation into its own
  worktree, verifies the work, publishes the pull request and a Scratchpad
  report, and sets the task's status. The repository's own instructions, such
  as `AGENTS.md`, win where they differ. `start_skill = "none"` sends no skill
  line.
- `start_prompt` is text the first message gives after the skill line, for
  rules that apply only to tasks. It adds to the start skill and does not
  replace it. Rules for all agent work, such as code review, belong in your
  global agent instructions (`~/.codex/AGENTS.md`, `~/.claude/CLAUDE.md`),
  which the agent reads already.
- A first message that does not name the shipped start skill ends with one
  line that tells the agent to run `task needs-reply` before it ends a turn
  with a question. The shipped skill already says this.
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
[coordinator]
agent = "claude"            # the default
model = "claude-opus-5-5"
effort = "high"
```

`[coordinator]` sets the agent profile, model and effort that
[the coordinator](#the-coordinator) starts with. Without it, the coordinator
runs your `claude` profile with that profile's own model and effort.
`[defaults]` does not apply to it. Toastty reads the table each time it starts
the coordinator's agent, and a resumed conversation keeps what it started
with.

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
- `start_prompt` is text a task's first message gives after the start skill
  line; see [Skills for task events](#skills-for-task-events).
- `start_skill`, `merge_skill` and `release_skill` name skills; see
  [Skills for task events](#skills-for-task-events). A skill name is one word
  with no spaces.

`merge`, `merge_prompt`, `start_prompt` and the three skill keys can also go in `[defaults]`;
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

- `~/.toastty/task-records.json`: every task record. A Toastty build without
  external references keeps the tasks but drops their `externalRef` when it
  saves the file.
- `~/.toastty/task-attachments/<task-id>/`: Toastty's copies of attached files.
  They are removed when the task is deleted, or a week after Toastty first
  saw the task Done or Archived with its task space closed. Toastty looks at
  launch and every 15 minutes, and not while `tasks.toml` has an error. A task
  that leaves Done, for example because work started again, starts a new week
  at its next finish. The record keeps the file names, and its history says
  the files were removed; such a task can no longer be retried.
- `~/.toastty/recent-workspaces.json`: the last closed top-level workspaces,
  for the workspace picker.
- `~/.toastty/task-webhooks.json` and `~/.toastty/task-webhook-outbox.json`:
  task webhooks and the events waiting to send. Webhook secrets and approvals
  are in the login Keychain. The outbox file also holds the task changes that
  wait for the coordinator, and its timer.
- `~/.toastty/coordinator/`: the coordinator's instructions, your policy and
  its ledger, in a git repository; see
  [The coordinator's folder](#the-coordinators-folder).

Deleting a task does not remove its worktree or branch; archiving it does.

Runtime-isolated runs keep both under their runtime home. See
[Privacy and Local Data](privacy-and-local-data.md).
