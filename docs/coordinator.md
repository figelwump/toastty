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
app shows it. The automatic first message is not shown. The coordinator's tool
calls, and the messages it writes between them, fold into one line per run of
work, such as `worked 48s · 3 tool calls · 1 note`; click the line to see each
step. Your messages, its final replies and its cards stay visible. While its
turn runs, the last line is a working row with the turn's time and its latest
step. The row appears as soon as you send a message, before the coordinator
starts. A run that stopped without a final reply shows its last message.
Providers that do not mark which messages are in-between show every message.
The coordinator's messages
show as Markdown: emphasis, code, lists, tables and links, which open in the
right panel. Raw HTML in a message shows as text, and images show as links.
Type in the box at the bottom
to send the coordinator a message. While its turn runs, the message waits and
goes in when the turn ends.

On first start, the agent can wait for setup, such as Claude Code's folder-trust
prompt. The message box stays disabled until the agent can take a message.
Use **Open terminal** beside the disabled box to review and answer the prompt.

A card is one line until you click it. An unanswered question is the
exception: it shows the first five lines of the question, a **Show more** link
when the text is longer, and its answer choices, so you can answer without
opening the card. Every card shows its task's live state: title,
project, stage, packet version, and **stale** when commits landed in the
task's worktree after the packet. An open packet card shows what changed,
what to look at, the checks with pass or fail and their logs, what was not
verified, and screenshot thumbnails. Its actions are:

- **Reply**, to the coordinator: it receives your text after a line that
  names the task, its ID, and the packet version. The coordinator passes a
  note for the task on with `task send`, as `Review note on packet vN: <your
  text>`, or answers a question about the task with a note. A reply on a
  packet card takes the task out of Needs you, as before. Your reply appears
  in the task's card thread.
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

Each task has one current card. Its thread includes your replies, an answer
you type in the task's terminal, and the notes the coordinator posts with
`--task`. It does not repeat the task agent's
conversation; open the task space to read that. Replies from a card appear only in its
thread, so the main conversation does not repeat them. Ordinary coordinator
messages stay in the main conversation; the coordinator uses a task note for
a reply that belongs in a thread. Earlier user replies with an **About <task>**
link also move into that task's thread.

Question cards can show answer choices. Click one, or type a reply. Both go to
the coordinator, which passes the answer on to the task. After a successful
send, the card shows **Answered** with your answer. If receipt is uncertain,
the choices stay disabled until the coordinator's transcript confirms the
answer or Toastty quits; check its terminal before you answer another way. An answer that the
coordinator queued during its turn is lost if the coordinator session ends
before that turn finishes. The chat no longer counts that question as
unanswered. The task keeps its live agent status and any other reason it needs you.
An answer typed in the task's own terminal also closes the question, as does
any later message to the task except a task watch notice. The card's badge
then shows the task's live status. Amber badges mark what needs you; a working
task has a neutral badge with a spinner.

Threads and answers survive a relaunch. Each card shows the latest 100 thread
entries; the full event log stays on disk.

When the coordinator posts about a task, you reply about it, or it publishes a
packet, its card moves to that time in the chat. Transcript messages stay in
place. A newer packet is marked **new**;
**Earlier reports** inside the card opens older reports. An unanswered
question stays visible when a packet arrives. A saved reply keeps the question
and packet version it was written for.

Before a task exists, the coordinator can post a project question without
`--task`. It shows the request, the reason for asking, and project choices.
Known projects show their titles. If two titles are the same, a tooltip shows
the path. Unknown choices stay literal. The answer keeps the posted ID or path.
A pick reaches the coordinator in a `Coordinator route answer: ` JSON envelope
with `questionID`, `replyID`, `question`, and `answer`. The coordinator resolves
the project, starts the task, and adds the pick to `routing.md`. The app saves
delivery state before sending. If receipt is uncertain, choices stay disabled
across relaunches until the provider echo confirms delivery; inspect the
coordinator terminal before starting the request another way.

A **stuck** card shows the agent's failure detail, **Open the task space**, and
**Archive it**. Archive uses the usual native confirmation and checks for work
that would be lost. Moving a started task between projects and handing it to
another agent are not offered; both need a safe change to its saved session
and worktree state.
**routing.md** in the chat's header opens the routing notes in the right panel.
`toastty coordinator show --task <task-id>` opens the chat and scrolls to that
task's current card.

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

Before your first message, the composer shows **Try:** suggestions. They fill
the composer so you can edit them before sending. Toastty's automatic launch
prompt does not hide them. Start a message with `@` to
pick a task or project. The list matches task slugs, task titles, and project
names. Use the arrow keys and Return to pick, or click an option.

A leading `@<task-slug>` sends the remaining text to the coordinator through
the same task envelope as a card reply. The question
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
hidden workspace called Coordinator, in `~/.toastty/coordinator`, with no
workspace scope. It does not run in your home directory, because Claude Code
asks again for folder trust there at each start; you trust
`~/.toastty/coordinator` once. The sidebar, the workspace switch shortcuts and the task project choices
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
toastty coordinator post question "Which project is dark mode for? Both projects have settings." --option "/repos/app" --option "/repos/site"
toastty coordinator post note --task <task-id> "The task now uses the feature branch."
toastty coordinator post note "Starting a fresh coordinator session."
```

`packet` and `task-started` name a task. `question` and `note` need text, at
most 4000 characters. A question can have up to six different choices, each at
most 120 characters after spaces at each end are removed. Add each choice with
`--option`; empty choices are rejected. The user can click a choice or type an
answer to a task question. A question without `--task` requires project choices;
it accepts only those choices and sends the pick to the coordinator. Use
unambiguous project paths or IDs as choices. A note with `--task` appears in that task's card thread. A note without
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
