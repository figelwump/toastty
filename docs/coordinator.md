# Coordinator

The coordinator is one agent session that Toastty keeps running for you. You
tell it what you want done; it routes each request to a task in the right
project, follows the tasks, and tells you when one needs you. The work itself
happens in the tasks, each with its own agent. See [Tasks](tasks.md).

You talk to the coordinator in its chat: click **Coordinator** at the top of
the sidebar, run `toastty coordinator show`, or choose **Show Coordinator
Chat** in the command palette. The chat covers the
coordinator's terminal in the main area and opens **Today** in the right panel.
While it does, the top bar shows only the Coordinator title, not the terminal's
tab. `toastty coordinator show-terminal`, or **Open terminal** in the chat's
header, shows the raw terminal instead.

## The chat

The header names the agent and model and shows the live task and project
counts. Its project buttons filter task cards, Today, and All tasks together.
The coordinator's messages and notes with no task stay visible. The selection
stays with this native window while its pages are open. The buttons hide when
the chat is too narrow.

The chat shows the coordinator's conversation and the cards it posts, in time
order. The conversation comes from the coordinator's transcript, as the iPhone
app shows it; tool calls fold to one line each. The coordinator's messages
show as Markdown: emphasis, code, lists, tables and links, which open in the
right panel. Raw HTML in a message shows as text, and images show as links.
Type in the box at the bottom
to send the coordinator a message. While its turn runs, the message waits and
goes in when the turn ends.

On first start, the agent can wait for setup, such as Claude Code's folder-trust
prompt. The message box stays disabled until the agent can take a message.
Use **Open terminal** beside the disabled box to review and answer the prompt.

A card is one line until you click it. It shows its task's live state: title,
project, stage, packet version, and **stale** when commits landed in the
task's worktree after the packet. An open packet card shows what changed,
what to look at, the checks with pass or fail and their logs, what was not
verified, and screenshot thumbnails. Its actions are:

- **Reply**, to the task: Toastty sends `Review note on packet vN: <your
  text>` to the task's agent with `task send`, and the task leaves Needs you
  until its next packet. Switch the reply to **to coordinator** to ask the
  coordinator about the task instead. The coordinator receives your text after
  a line that names the task and its ID; the chat shows only your text, with
  an **About <task>** link that opens the task's card.
- **Merge**: asks first, naming what Merge does in the task's project from
  `tasks.toml`, then runs the same merge as the task's Merge button. The
  coordinator never merges on its own.
- **Full report** and the thumbnails open the packet's report in the right
  panel, at `toastty://coordinator/report/<task-id>/<version>`. It shows the
  screenshots before, after or side by side, at each width they were taken
  at. The report is an ordinary browser panel, so its annotation mode works.
- **Open task space**, and the pull request link, which opens in the right
  panel.

When a task publishes a newer packet, the chat adds a card for it at the end,
marked **new**, and the task's older packet cards collapse to one line.
**routing.md** in the chat's header opens the routing notes in the right panel.
`toastty coordinator show --task <task-id>` opens the chat and scrolls to that
task's newest packet card, or to its newest card when that is a question.

The sidebar's **Needs you** list shows the tasks waiting for you, and clicking
one opens its card in the chat; see
[The sidebar](tasks.md#the-sidebar). `Cmd+Shift+T` and **View > Show
Coordinator Chat** open the chat too.

## Today and All tasks

The right panel has **Today** and **All tasks** tabs. Switching tabs keeps the
chat in the center. Both tabs receive live task changes through the same
coordinator state as the chat.

Today shows counts for **Needs you**, **Running**, and **To ship**, followed by
tasks that need you, running tasks, and tasks merged or released today. These
counts and lists follow the project filter. A completed task appears because
of its merge or release time, not because it was marked done today. Intake
stays hidden while there are no intake sources. Click a task row to open its
card in the center chat when it has one; otherwise it opens the task space.

All tasks lists tasks in stage groups with their current actions. **Done** and
**Archived** start closed. Merge asks for confirmation and names the project's
merge policy. Release, the row menus, and setup controls use the same actions
as the sidebar. See [All tasks](tasks.md#all-tasks).

`toastty coordinator tasks`, `Cmd+Option+T`, and **Show All Tasks** in the
command palette open All tasks in the right panel. The sidebar project's
**To ship** and **Done** counts open it with that project's filter and the
selected group open. The `coordinator.tasks.show` action also accepts `group`
and `project`. A project value can be its stable ID or a unique display title;
an ambiguous title fails instead of choosing a project. Projects keep separate
identities even when their titles match.

Toastty ships these pages at `toastty://coordinator/today` and
`toastty://coordinator/tasks`. The tabs share one panel, so changing the tab
does not need to change its initial URL. Reports and other links can still
open beside the chat in the right panel.

## How it runs

At launch, Toastty starts the agent that `[coordinator]` in
`~/.toastty/tasks.toml` names, Claude Code unless you change it. It runs in a
hidden workspace called Coordinator, in your home directory, with no workspace
scope. The sidebar, the workspace switch shortcuts and the task project choices
leave this workspace out, and it does not hold up quitting Toastty.

The agent's first message is `Use the toastty-coordinator skill.` The shipped
skill tells it to read `toastty task list` and its routing notes, to route
requests with `toastty task create`, and to wait for tasks with
`toastty task watch --wait` instead of polling. It never merges, approves or
releases work; Merge stays with you, on each task.

The coordinator keeps no state of its own. When its session exits, Toastty
starts a fresh one in the same terminal, and the new session rebuilds from the
task records and the routing notes. The skill ends a session at a natural break
when its context fills. If sessions stop within a minute of starting three times
in a row, Toastty stops starting them and `toastty coordinator status` says why.
Fix the cause, then use Reload Configuration to try again.

When Toastty quits with the coordinator running, it resumes the same
conversation at the next launch, as it does for other agent sessions.

## Configure it

```toml
[coordinator]
agent = "claude"          # an agent profile ID, or "none" to turn it off
model = "claude-opus-5-5"
effort = "high"
```

Every key is optional. `model` and `effort` apply only when the profile takes
them. A change applies to the next coordinator session: Reload Configuration
reads it, and a running session keeps going until it exits.

Toastty starts the coordinator only in your own Toastty. Test hosts, smoke runs
and runtime-isolated dev runs do not start it, so they never use your agent
subscription unasked. In a dev run, opening the coordinator from the sidebar or
with `Cmd+Shift+T` starts it then; automation and test runs never do. Set
`TOASTTY_COORDINATOR_AUTOSTART=1` in the environment to start it at launch in
one of those runs, or `TOASTTY_COORDINATOR_AUTOSTART=0` to keep it off anywhere.

## Cards

The coordinator tells you about a task by posting a card:

```bash
toastty coordinator post task-started --task <task-id>
toastty coordinator post packet --task <task-id>
toastty coordinator post question --task <task-id> "Which base branch?"
toastty coordinator post note "Starting a fresh coordinator session."
```

Every kind except `note` names its task, and `question` and `note` need text, at
most 4000 characters. Toastty appends each card to `events.jsonl` as one JSON
line with its ID, time, kind, task, text and the session that posted it. The
chat shows each card from the task's live state, so a card holds only what
names it. Only the coordinator's own session, or a command outside any agent
session, may post; a task's agent reports through its task instead.

`toastty coordinator status` reports the coordinator's state (`off`,
`waitingForWindow`, `waitingForRestore`, `starting`, `running` or `failed` with
a reason), its workspace, terminal and session, and the paths of its files.

## Files

- `~/.toastty/coordinator/events.jsonl`: the cards, oldest first.
- `~/.toastty/coordinator/routing.md`: the coordinator's routing notes, with
  sections for projects, your picks and past tasks. Toastty creates it from a
  template the first time and never changes it after that; the coordinator adds
  to it, and you can edit it.

Runtime-isolated runs keep these under their runtime home.

## Phone

The coordinator's conversation is an ordinary agent conversation, so a paired
iPhone shows it like any other. Toastty also follows its transcript when remote
access is off, for the chat. Cards and packets do not show on the iPhone yet.
