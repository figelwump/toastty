# Coordinator

The coordinator is one agent session that Toastty keeps running for you. You
tell it what you want done; it routes each request to a task in the right
project, follows the tasks, and tells you when one needs you. The work itself
happens in the tasks, each with its own agent. See [Tasks](tasks.md).

You talk to the coordinator in its chat: click **Coordinator** at the top of
the sidebar, run `toastty coordinator show`, or choose **Show Coordinator
Chat** in the command palette. The chat covers the
coordinator's terminal in the main area, and the right panel stays beside it.
While it does, the top bar shows only the Coordinator title, not the terminal's
tab. `toastty coordinator show-terminal`, or **Open terminal** in the chat's
header, shows the raw terminal instead.

## The chat

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
  text>` to the task's agent with `task send`. Switch the reply to
  **to coordinator** to ask the coordinator about the task instead. The coordinator receives your text after
  a line that names the task and its ID. Your reply appears in the task's card
  thread.
- **Merge**: asks first, naming what Merge does in the task's project from
  `tasks.toml`, then runs the same merge as the task's Merge button. The
  coordinator never merges on its own.
- **Full report** and the thumbnails open the packet's report in the right
  panel, at `toastty://coordinator/report/<task-id>/<version>`. It shows the
  screenshots before, after or side by side, at each width they were taken
  at. Select **Annotate**, click a screenshot, and write a note for each
  numbered mark. Marks stay with their screenshot when you change the view
  or width. **Send N marks to <task>** sends one `Review note on packet vN:`
  message to the task, with each note's screenshot name, then opens its card.
  The notes also appear once in that task's thread.
  Marks clear only after Toastty confirms delivery. If delivery fails, check
  the task terminal before sending again. The browser toolbar's annotation
  tool still sends viewport captures to an agent; use the report's controls
  for notes about a packet.
- **Open task space**, and the pull request link, which opens in the right
  panel.

Each task's cards show the same thread. It includes your replies to the task
or coordinator, notes the coordinator posts with `--task`, and replies from
that task's own agent conversation. Replies from a card appear only in its
thread, so the main conversation does not repeat them. Ordinary coordinator
messages stay in the main conversation; the coordinator uses a task note for
a reply that belongs in a thread. Earlier user replies with an **About <task>**
link also move into that task's thread.

Question cards can show answer choices. Click one, or type a reply, and choose
**to task** or **to coordinator**. The default is **to task** while the task's
agent waits for input, and **to coordinator** otherwise. Your chosen target
stays fixed while you compose the reply. After a successful send, the card
shows **Answered** with your answer. The chat no longer counts that question as
unanswered. The task keeps its live agent status and any other reason it needs you.

Threads and answers survive a relaunch. Each card shows the latest 100 thread
entries; the full event log stays on disk.

When a task publishes a newer packet, the chat adds a card for it at the end,
marked **new**, and the task's older packet cards collapse to one line.
**routing.md** in the chat's header opens the routing notes in the right panel.
`toastty coordinator show --task <task-id>` opens the chat and scrolls to that
task's newest packet card, or to its newest card when that is a question.

The sidebar's **Needs you** list shows the tasks waiting for you, and clicking
one opens its card in the chat; see
[The sidebar](tasks.md#the-sidebar). `Cmd+Shift+T` and **View > Show
Coordinator Chat** open the chat too. **All tasks**, beside the chat, lists
every task with its actions; see [All tasks](tasks.md#all-tasks).

Before your first message, the composer shows **Try:** suggestions. They fill
the composer so you can edit them before sending. Toastty's automatic launch
prompt does not hide them. Start a message with `@` to
pick a task or project. The list matches task slugs, task titles, and project
names. Use the arrow keys and Return to pick, or click an option.

A leading `@<task-slug>` sends the remaining text to the coordinator through
the same task envelope as a card's **to coordinator** reply. The question
appears in that task's card thread. Toastty keeps a card for the thread even
if the coordinator has not posted one yet. Known done and archived tasks remain
available for these questions. A leading project pick gives the coordinator an
explicit routing hint; it uses that project without asking again and records
your pick in `routing.md`. Only the first token is an address. Later `@`
tokens stay in the message. A complete, unique known token also works when
typed exactly. Partial or ambiguous tokens stay ordinary text unless you
pick from the list. If a picked target becomes unavailable, the draft stays
so you can choose again. Project tokens use the directory name, with spaces
percent-encoded; duplicate names require a list pick.

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
toastty coordinator post question --task <task-id> "Which base branch?" --option "Remote main" --option "Feature branch"
toastty coordinator post note --task <task-id> "The task now uses the feature branch."
toastty coordinator post note "Starting a fresh coordinator session."
```

Every kind except `note` names its task, and `question` and `note` need text, at
most 4000 characters. A question can have up to six different choices, each at
most 120 characters after spaces at each end are removed. Add each choice with
`--option`; empty choices are rejected. The user can click a choice or type an
answer. A note with `--task` appears in that task's card thread. A note without
it appears in the main chat.

Toastty appends each event to `events.jsonl` as one JSON line. It records the
card, choices, or reply and the session that posted it. Cards read the task's
current state when shown. Only the coordinator's own session, or a command
outside any agent session, may post; a task's agent reports through its task instead.

`toastty coordinator status` reports the coordinator's state (`off`,
`waitingForWindow`, `waitingForRestore`, `starting`, `running` or `failed` with
a reason), its workspace, terminal and session, and the paths of its files.

## Files

- `~/.toastty/coordinator/events.jsonl`: cards and thread replies, oldest first.
- `~/.toastty/coordinator/routing.md`: the coordinator's routing notes, with
  sections for projects, your picks and past tasks. Toastty creates it from a
  template the first time and never changes it after that; the coordinator adds
  to it, and you can edit it.

Runtime-isolated runs keep these under their runtime home.

## Phone

The coordinator's conversation is an ordinary agent conversation, so a paired
iPhone shows it like any other. Toastty also follows its transcript when remote
access is off, for the chat. Cards and packets do not show on the iPhone yet.
