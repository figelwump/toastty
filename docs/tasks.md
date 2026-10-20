# Tasks

A task is a piece of work you hand to an agent. You describe it, Toastty saves
it, makes a task space for it under a workspace, and starts the agent there.
The task keeps its own record, so it exists before its task space is ready and
after setup fails.

This page covers the quick entry panel, creating tasks from the CLI or from
an agent, the sidebar Inbox, and `~/.toastty/tasks.toml`.

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
  Auto leaves the choice to triage, or to `[defaults]` for the agent. Until
  triage is available, a task needs a pinned workspace.
- The panel floats over other apps and full-screen windows and stays open
  while you switch apps, for example to take a screenshot. Drag its
  background to move it. `Esc` closes it without saving; the attached copies
  are deleted.
- Pressing the shortcut while the panel is open brings it back with your
  draft.

Other ways to open the same panel:

- **File > New Task…** and **New Task…** in the command palette. Both show
  the shortcut.
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
| `--workspace <id>` | The workspace the task belongs to. A subspace means its parent. An agent session defaults to its own workspace. |
| `--agent`, `--model`, `--effort` | The agent profile from `agents.toml` and its settings. Missing values come from `[defaults]` in `tasks.toml`. |
| `--prompt <text>`, `--prompt-file <path>` | A first prompt, sent before the task text. |
| `--title`, `--slug` | The task's title and the task space's name. They default to the first line of the text. |
| `--request-id <id>` | The caller's key for this request. A repeat from the same agent session, or from the CLI outside one, with the same key returns the first task instead of making another. |

A task needs a workspace and an agent. A request without them, with an agent
that is not in `agents.toml`, with a file that cannot be read, or whose first
message would be longer than 64 KB fails at once and saves nothing. A file
given as a symbolic link is copied as the file it points to.

Other verbs:

```bash
toastty task get <task-id>      # one task, with its setup state
toastty task list               # every task, oldest first
toastty task retry <task-id>    # run setup again after it failed
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
scope, and the agent session is recorded as the one that spawned it.

## The Inbox

Tasks whose setup has not finished appear in an Inbox group at the top of the
sidebar. It is hidden when it is empty. A row shows the task's title, its
workspace and agent, and `setting up` or `⚠ setup failed` with the reason.
Click a row to see the whole task; use Retry or Delete there or in the row's
context menu.

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

```toml
[quick_entry]
shortcut = "opt+shift+t"   # the default; "none" turns it off
```

A shortcut joins modifiers and one key with `+`. Modifiers are `cmd`,
`ctrl`, `opt` (or `alt`) and `shift`. The key is a letter, a digit,
punctuation, `space`, `return`, `tab`, or `f1` to `f20`, named as a US
keyboard types it. It needs `cmd`, `ctrl` or `opt`, so it cannot take
ordinary typing away from other apps; a function key may stand alone.

Toastty also reads and checks these tables, which later features use:
`[triage]` (`command`, `guidelines` or `guidelines_file`, `timeout_seconds`),
`[defaults]` `merge` and `merge_prompt`, and
`[workspace."<root directory>"]` (`guidelines`, `create_hook`,
`branch_prefix`, `release_tags`, `release_prompt`, `merge`, `merge_prompt`).
They have no effect yet.

An error in the file names its line, and `task create` fails with that message
until the file is fixed.

## Where tasks are stored

- `~/.toastty/task-records.json`: every task record.
- `~/.toastty/task-attachments/<task-id>/`: Toastty's copies of attached files,
  removed when the task is deleted.

Runtime-isolated runs keep both under their runtime home. See
[Privacy and Local Data](privacy-and-local-data.md).
