# Tasks

A task is a piece of work you hand to an agent. You describe it, Toastty saves
it, makes a task space for it under a workspace, and starts the agent there.
The task keeps its own record, so it exists before its task space is ready and
after setup fails.

This page covers creating tasks from the CLI or from an agent, triage, the
sidebar Inbox, and `~/.toastty/tasks.toml`.

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
toastty task retry <task-id>    # run setup again after it failed
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
scope, and the agent session is recorded as the one that spawned it.

## The Inbox

Tasks whose setup has not finished appear in an Inbox group at the top of the
sidebar. It is hidden when it is empty. A row shows the task's title, its
workspace and agent, and its state: `routing…` while triage runs, `⚠ pick a
workspace` or `⚠ setup failed` with the reason, or `setting up`. Click a row
to see the whole task; use Retry, Delete or the workspace picker there or in
the row's context menu.

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

`[defaults]` fills the agent, model and effort that a request and triage leave
out. The default model and effort apply only with the default agent; a task
whose agent is another one gets that agent's own defaults.

`[triage]` is described in [Triage](#triage). A `[workspace."<root
directory>"]` section's `guidelines` go to triage with that workspace.

Toastty also reads and checks these keys, which later features use:
`[defaults]` `merge` and `merge_prompt`, `[quick_entry]` (`shortcut`), and
`create_hook`, `branch_prefix`, `release_tags`, `release_prompt`, `merge` and
`merge_prompt` in workspace sections. They have no effect yet.

An error in the file names its line, and `task create` fails with that message
until the file is fixed.

## Where tasks are stored

- `~/.toastty/task-records.json`: every task record.
- `~/.toastty/task-attachments/<task-id>/`: Toastty's copies of attached files,
  removed when the task is deleted.
- `~/.toastty/recent-workspaces.json`: the last closed top-level workspaces,
  for the workspace picker.

Runtime-isolated runs keep both under their runtime home. See
[Privacy and Local Data](privacy-and-local-data.md).
