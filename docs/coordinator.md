# Coordinator

The coordinator is one agent session that Toastty keeps running for you. You
tell it what you want done; it routes each request to a task in the right
project, follows the tasks, and tells you when one needs you. The work itself
happens in the tasks, each with its own agent. See [Tasks](tasks.md).

This first version has no chat view. You talk to the coordinator in its
terminal: click **Coordinator** at the top of the sidebar, or run
`toastty coordinator show-terminal`. A later version adds a chat beside the
sidebar. The sidebar's **Needs you** list shows the tasks waiting for you; see
[The sidebar and the Tasks view](tasks.md#the-sidebar-and-the-tasks-view).

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
subscription unasked. Set `TOASTTY_COORDINATOR_AUTOSTART=1` in the environment
to start it in one of those runs, or `TOASTTY_COORDINATOR_AUTOSTART=0` to keep it
off anywhere.

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
chat view will show each card from the task's live state, so a card holds only
what names it. Only the coordinator's own session, or a command outside any
agent session, may post; a task's agent reports through its task instead.

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
access is off, for the chat view.
