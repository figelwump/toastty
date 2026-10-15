# Quick Tasks

A quick task is a request that you add once. Toastty then decides where it
belongs and starts an agent for it. The task waits in the **Inbox** at the top
of the sidebar until its agent starts. Then it becomes a normal task space under
its workspace.

The flow has four steps:

1. **Add.** You add the task with `task.create`. Toastty saves it, and any
   files you attached, on this Mac at once.
2. **Triage.** A model that you choose makes one headless call. It picks the
   workspace, the agent profile, the model, the effort, a title and a slug.
3. **Create.** Your create script makes the task's directory, for example a git
   worktree, and prints its path.
4. **Start.** Toastty creates a task space under the workspace, with a terminal
   in that directory. It launches the agent there with a first prompt and
   limits the session's scope to the task space. The Inbox row then goes away.

Tasks start only agent profiles that are configured in `~/.toastty/agents.toml`
and installed. These are the same profiles that Toastty Mobile can start. See
[Running Agents](running-agents.md#agentstoml).

Every step is optional, and each is set in `~/.toastty/tasks.toml`:

- Without `[triage]`, each task needs a workspace from you.
- Without `[create]`, the task space opens in the workspace's own directory.
- Without `[start]`, the first prompt is the task alone.

## Adding a task

```bash
"$TOASTTY_CLI_PATH" action run task.create text="The sidebar unread dot stays on" \
  files="$HOME/Desktop/repro.png"

# Fix choices that triage must not change:
"$TOASTTY_CLI_PATH" action run task.create text="Update the pricing copy" \
  workspace="$WORKSPACE_ID" profileID=codex reasoningEffort=high
```

- **Files:** images, PDFs and plain-text files can be attached. You can attach
  up to 4 files, at most 4 MiB each and 8 MiB in total.
- **Where files are kept:** Toastty copies each file into
  `~/.toastty/tasks/attachments/`. The agent gets the copy's path in its first
  prompt. Copies are deleted 7 days after the agent starts. A task that is
  still in the Inbox keeps its files.
- **Workspace-scoped sessions** cannot use the task actions or the `task.list`
  query, because triage can place a task in any workspace.

## The Inbox

The Inbox group is shown only when it has tasks. Each row has a dashed box and
a word tag. It never uses a session status color, because no session exists
yet.

| Tag | Meaning | What you can do |
| --- | --- | --- |
| `routing…` | Triage is running, or the task waits for the task before it. Triage runs one task at a time. | Delete |
| `setting up` | The create script is running, or the agent is starting. | Delete |
| `⚠ pick a workspace` | Triage could not place the task. The row says why. | Pick a workspace and Start, Retry Triage, Delete |
| `⚠ setup failed` | The script failed, the agent did not start, or Toastty quit during setup. | Retry, pick another workspace, Delete |

Click a row to see the whole task, its files and the reason. Right-click a row
for the same actions. You can also use the CLI:

```bash
"$TOASTTY_CLI_PATH" query run task.list
"$TOASTTY_CLI_PATH" action run task.place taskID="$TASK_ID" workspace="$WORKSPACE_ID"
"$TOASTTY_CLI_PATH" action run task.retry taskID="$TASK_ID"
"$TOASTTY_CLI_PATH" action run task.delete taskID="$TASK_ID"
```

Retry never starts a second agent for the same task:

- A directory that the create script already made is used again.
- A task space that an earlier attempt made is used again.
- If an agent already runs in that task space, the task counts as started.

Delete stops triage or setup. It does not remove a directory or a task space
that setup already made.

## `tasks.toml`

Toastty writes a commented template to `~/.toastty/tasks.toml` on first launch.
In a runtime-isolated run, the file is `<runtime-home>/tasks.toml`. After you
edit it, use **Toastty › Reload Configuration**.

```toml
[triage]
profile = "claude"            # "claude" or "codex", from agents.toml
model = "claude-haiku-5-5"    # optional, for the triage call
effort = "low"                # optional
timeout-seconds = 60          # optional, 5 to 600
guidance = """
toastty is the macOS and iOS app. website is the marketing site.
Hard or unclear work: claude, claude-opus-5-5, xhigh.
Clear, bounded work: codex, gpt-6.1-sol, high.
"""

[create]
script = "~/.toastty/skills/worktree-create/scripts/task-create.sh"
timeout-seconds = 120         # optional, 5 to 1800

[start]
skill = "task-start"
```

The parser accepts only these tables and keys. Values are quoted strings or
whole numbers. Use triple quotes for text on more than one line.

### Triage

Triage runs the profile's own `claude` or `codex` binary. A profile whose
command is a wrapper cannot be used for triage.

The call runs in an empty temporary folder, with no tools and no saved
session. Toastty's `TOASTTY_*` variables are removed from its environment.

- **Claude:** runs `claude -p` with your hooks turned off.
- **Codex:** runs `codex exec` without `~/.codex/config.toml` or your rules,
  and with its shell, apps, browser, web search and other tools turned off.
  Codex triage therefore uses the default OpenAI provider and your existing
  login. If a later Codex removes one of those feature names, triage fails and
  the task waits for you instead of running with tools.

What triage gets:

- the task text and the names of its files
- each top-level workspace that has a directory, with its title, its directory,
  and the titles of its 5 newest task spaces
- each agent profile that can start, with the models and effort values it
  accepts
- your `guidance` text and any choices you fixed

The task text and the workspace list go to the triage provider.

Toastty checks every value triage returns:

- The workspace must be open, top level, and have a directory.
- The agent must be able to start.
- The model must be one safe word.
- The effort must be one that the agent accepts.

A value that fails a check is dropped. If triage is not sure, does not answer,
or picks no usable workspace, the task waits with `⚠ pick a workspace`. Any
valid parts of its answer are filled in.

Slugs are unique within a workspace. A slug that is already used gets `-2`,
`-3` and so on.

### The create script

The script runs in the workspace's directory with these variables:

| Variable | Value |
| --- | --- |
| `TOASTTY_TASK_ID` | The task's ID. It is the same on every retry. |
| `TOASTTY_TASK_SLUG` | Lowercase words joined by hyphens, at most 40 characters |
| `TOASTTY_TASK_BRANCH_PREFIX` | `feat`, `fix`, `debug`, `refactor`, `test`, `docs` or `chore` |
| `TOASTTY_TASK_TITLE` | The task's title |
| `TOASTTY_TASK_STATE_DIR` | A private folder for this task in this workspace, which the script can use to remember what it made. A task moved to another workspace gets a new, empty folder. |

Its last non-empty line on stdout must be a JSON object:

```json
{"directory": "/Users/me/repos/toastty-ios-unread-dot", "branch": "fix/ios-unread-dot", "baseRef": "d18c9655"}
```

- Only `directory` is required. It must be an absolute path to an existing
  directory, and a leading `~` is allowed.
- Exit 0 means success. On any other exit, the last line on stderr is shown in
  the Inbox.
- The script gets no TTY, and `GIT_TERMINAL_PROMPT=0` is set, so a prompt
  fails instead of waiting.

Make the script safe to run twice for one task. A retry runs it again when an
earlier run made a directory but its output was lost, for example after a
timeout or a quit. A simple way is to write the result to
`$TOASTTY_TASK_STATE_DIR` and print it again on the next run.

A timeout or Delete stops the script and every process in its process group.

### The first prompt

```text
/toastty-user:task-start
The sidebar unread dot stays on after I open a session from the iOS app.

Read the following files attached to this task on this Mac:
'/Users/me/.toastty/tasks/attachments/7C1E…/3A9F….png'

Task space: ios-unread-dot, in workspace toastty
Directory: /Users/me/repos/toastty-ios-unread-dot
Branch: fix/ios-unread-dot, from d18c9655
```

The skill line depends on the agent:

- **Claude:** `/toastty-user:<skill>`
- **Codex:** `$toastty-user:<skill>`
- **Other agents:** a plain request to use the skill

If the skill is not one of your accepted user skills, Toastty leaves out the
`toastty-user:` part.

## Related docs

- [Configuration](configuration.md)
- [Running Agents](running-agents.md)
- [CLI Reference](cli-reference.md)
- [Privacy and Local Data](privacy-and-local-data.md)
