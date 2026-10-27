# Toastty CLI Reference

Toastty bundles a `toastty` CLI that communicates with the running app over its automation Unix socket. The CLI is used both for agent/session reporting and for machine-first app control of a normal running Toastty instance.

When Toastty launches an agent it injects `TOASTTY_CLI_PATH` into the environment, pointing at that app instance's executable copy. Runtime-isolated builds stage an immutable per-instance copy; ordinary installed builds use the bundled executable directly. All examples below assume you invoke the CLI through that path.

## Global options

| Option | Description |
|---|---|
| `--json` | Return structured JSON instead of human-readable text |
| `--socket-path <path>` | Override the automation socket path |
| `-h`, `--help` | Print usage information |

**Socket resolution order:** `--socket-path` flag > `TOASTTY_SOCKET_PATH` env var > app-resolved default socket path. For runtime-isolated launches, that default starts from the stable runtime-home-derived socket path and can resolve to a per-process sibling such as `events-v1-<pid>.sock` if the stable path is already owned by a live listener.

## Smoke test

For a one-command local validation of the CLI's default live-control surface against a normal Toastty launch, run:

```bash
./scripts/automation/smoke-cli-live-control.sh
```

This smoke builds the app, launches a runtime-isolated non-automation instance, reads that run's `instance.json`, and validates the CLI against the matching live socket. It also strips inherited `TOASTTY_*` launch context first so an existing managed-agent shell session does not accidentally target some other running Toastty instance.

## Commands

### `doctor`

Run local checks for common Toastty troubleshooting issues.

```
toastty [--json] [--socket-path <path>] doctor
```

`doctor` checks the resolved automation socket, runtime metadata, shell
integration, managed agent shims, and log readability. For shell integration,
it first looks for the runtime marker exported by Toastty's managed interactive
shell snippet and confirms that the recorded shell is still in the invoking
process chain. This works when `doctor` runs beneath Codex, Claude Code, or
another child process. When no runtime marker is present, it falls back to
checking standard shell init files for direct Toastty references; custom startup
chains cannot be confirmed by that static fallback alone.

The command reads local state and actively connects to the local Toastty
automation socket for a ping when one is present. Human output is a
pass/warn/fail checklist with remediation hints. With `--json`, the CLI returns
the same structured check report for agents and scripts.

The command does not write a diagnostics bundle, upload anything, or attempt
automatic fixes. It exits non-zero only when at least one check fails.

### `setup guide`

Print a bundled guide for an agent to follow.

```
toastty setup guide [--topic onboarding|workflows] [--format text|md]
```

The default `onboarding` topic is the agent-guided Getting Started guide. The
`workflows` topic explains how to turn a user's way of working into a workflow
skill: the Toastty building blocks, example workflows, how the built-in task
lifecycle starts and merges tasks, and rules for writing one. The onboarding
guide's "Pick a workflow" step reads it.

The default `text` format is optimized for terminal reading. Use `--format md`
when another agent or tool should preserve Markdown headings and code fences.
With `--json`, the response contains `topic`, `format`, and `content`.

```bash
"$TOASTTY_CLI_PATH" setup guide
"$TOASTTY_CLI_PATH" setup guide --format md
"$TOASTTY_CLI_PATH" setup guide --topic workflows --format md
```

### `setup skills list`

List the skills Toastty can make available to new supported managed agent launches.

```
toastty setup skills list
```

The read-only inventory includes Toastty's eight shipped skills and accepted
user-authored packages under `~/.toastty/skills`. Invalid user packages appear
in an excluded section with the same diagnostic used by `Toastty > Manage
Toastty Skills…`. A missing user-skills directory is an empty catalog and is
not created by this command.

Running sessions keep the skills they launched with. Supported managed Codex,
Claude Code, Cursor, Grok Build, OpenCode, MiMo Code, and Pi launches receive the current inventory
when they start; unsupported launch shapes or provisioning failures proceed
without Toastty skills.

```bash
"$TOASTTY_CLI_PATH" setup skills list
```

With `--json`, the response is a versioned object containing
`schemaVersion`, `userSkillsRoot`, `skills`, and `globalDiagnostics`. Every
skill entry includes `name`, `source` (`shipped` or `user`), and `inclusion`
(`included` or `excluded`). Shipped entries include `summary`; excluded user
entries include `diagnosticCode` and `diagnosticMessage`. Exclusions do not
change the successful exit status. Text output is intended for people and is
not a stable parsing contract.

### `setup install-shell-integration`

Dry-run or install Toastty's shell integration for zsh, bash, or fish.

```
toastty setup install-shell-integration [--shell zsh|bash|fish] [--dry-run | --apply]
```

Without `--apply`, the command reports planned file writes only; `--dry-run`
names that default explicitly so agent-composed commands carry visible
read-only intent, and it is a usage error combined with `--apply`. With
`--apply`, it writes Toastty's managed shell snippet and updates the selected
shell init file. Run this from a Toastty terminal pane so the CLI can verify the
Toastty launch context.

### `setup install-hooks`

Dry-run or install agent status hooks. Codex is the only agent that needs a
global hook file; other supported agents receive status integration through
Toastty-managed launches.

```
toastty setup install-hooks --agent codex [--dry-run | --apply]
```

Without `--apply`, the command reports planned writes to the Codex hooks file
and Toastty forwarder script; `--dry-run` names that default explicitly and is
a usage error combined with `--apply`. With `--apply`, it writes those files
directly.
Codex may ask the user to trust updated hooks the next time it starts.

### `diagnostics collect`

Collect a local redacted diagnostics JSON bundle. This command reads local disk
state and probes the Toastty socket; collection itself does not upload anything.

```
toastty diagnostics collect [--shell-probe <file>] [--note <text>] [--out <file>]
```

The JSON includes recent, complete-line tails of embedded redacted logs,
app/runtime metadata, shell integration status, system metadata, socket probe
details, and a sanitized
in-memory audit of recent automation socket requests when the running app can
provide it. The automation audit records command/action/query IDs, caller and
selector IDs, safe boolean flags, outcome, and duration; it omits freeform
payload text such as terminal input, pasted content, argv, environment values,
file lists, and file contents. If `--out` is omitted, the CLI writes to a
temporary path. The printed summary includes the same shared check counts used
by `toastty doctor`, the final bundle size, and whether either embedded log was
truncated. Collection preserves the original log files and automatically
reduces embedded log tails when necessary so the reviewed JSON remains below
the diagnostics upload limit.

### `diagnostics submit`

Submit an already-collected diagnostics JSON bundle to the configured Toastty
diagnostics Worker.

```
toastty diagnostics submit --file <file> [--contact <text>] [--endpoint <url>] [--yes] [--dry-run] [--allow-secret-scan-warning]
```

Without `--yes`, the command validates the file and prints the upload summary
without sending anything. `--dry-run` also validates and previews without
uploading, even when `--yes` is present. With `--yes` and no `--dry-run` or
`--contact`, it uploads the exact JSON bytes from `--file`; it does not rebuild
or re-redact the bundle.

When `--contact <text>` is provided, the source file is left unchanged. The
submit command appends `Contact: <text>` to the diagnostics note in the in-memory
upload payload, then validates and secret-scans that final payload before any
upload. Contact text remains cleartext in the submitted diagnostics note.

Endpoint resolution order is `--endpoint`, `TOASTTY_DIAGNOSTICS_ENDPOINT`, then
the endpoint embedded at build time. The upload key is read from
`TOASTTY_DIAGNOSTICS_UPLOAD_KEY`, `TOASTTY_DIAGNOSTICS_UPLOAD_KEY_FILE`, or a
build-injected value.

The submit command refuses bundles that are missing redaction metadata, use an
old schema/redaction version, exceed the upload size limit, or still appear to
contain high-confidence secret patterns. Use `--allow-secret-scan-warning` only
after manually reviewing a false positive.

On success, the Worker returns a `reportID`. Operators can fetch the stored
report through the diagnostics Worker admin endpoint, or from an agent session
with:

```bash
sv exec -- .agents/skills/toastty-diagnostics/scripts/fetch-diagnostics-report.py
sv exec -- .agents/skills/toastty-diagnostics/scripts/fetch-diagnostics-report.py <reportID>
```

The no-argument form lists recent submissions. The report-ID form fetches and
saves the selected report envelope for deeper analysis.

Managed agents can use the shipped `toastty-send-diagnostics` skill when the
user says “send Toastty diagnostics.” `Toastty > Send Diagnostics…` copies a
direct handoff containing the runtime-resolved bundled skill and CLI paths, so
the same workflow remains available when skill discovery did not load it.

### `action list`

List the always-on app-control actions exposed by the running app.

```
toastty action list
```

Human-readable output prints one command per line as `id<TAB>summary`. With `--json`, the CLI returns the raw socket response, including each command descriptor's `id`, `summary`, `selectors`, `parameters`, and `aliases`.

```bash
"$TOASTTY_CLI_PATH" action list
"$TOASTTY_CLI_PATH" --json action list
```

### `action run`

Run an app action against a live Toastty instance. This surface is available in normal launches by default; it does not require automation mode.

```
toastty action run <id> [--window <id>] [--workspace <id>] [--panel <id>] [--stdin <key>] [key=value ...]
```

Selectors map directly to the socket request's `windowID`, `workspaceID`, and `panelID` arguments. Additional `key=value` arguments are passed through as action arguments. Repeating the same key produces an array, which is how repeatable arguments such as `files=... files=...` are encoded.

The CLI sends `key=value` arguments as strings. The app-control executor coerces supported argument types such as booleans (`true`, `false`, `1`, `0`, `yes`, `no`), integers, UUIDs, and string arrays.

`--stdin <key>` reads UTF-8 stdin and sends it as the named argument. Use it for payloads that are awkward to pass as a shell argument, such as Scratchpad HTML content or Scratchpad patch JSON.

```bash
"$TOASTTY_CLI_PATH" action run window.sidebar.toggle --window "$WINDOW_ID"
"$TOASTTY_CLI_PATH" action run workspace.rename --workspace "$WORKSPACE_ID" title="Infra"
"$TOASTTY_CLI_PATH" action run workspace.set-annotation \
  --workspace "$WORKSPACE_ID" \
  key=github-pr \
  text="PR #4512" \
  url=https://github.com/example/repo/pull/4512
"$TOASTTY_CLI_PATH" action run workspace.clear-annotation --workspace "$WORKSPACE_ID" key=github-pr
"$TOASTTY_CLI_PATH" action run panel.create.local-document \
  --workspace "$WORKSPACE_ID" \
  filePath=/tmp/README.md \
  placement=newTab
"$TOASTTY_CLI_PATH" action run terminal.drop-image-files \
  --panel "$PANEL_ID" \
  files=/tmp/README.md \
  files=/tmp/installer.dmg \
  allowUnavailable=true
"$TOASTTY_CLI_PATH" --json action run workspace.create \
  --window "$WINDOW_ID" \
  title=background-worktree \
  activate=false
"$TOASTTY_CLI_PATH" action run workspace.select \
  --window "$WINDOW_ID" \
  index=2 \
  focusUnreadSessionPanel=true
"$TOASTTY_CLI_PATH" action run workspace.move \
  --window "$WINDOW_ID" \
  index=3 \
  toIndex=1
"$TOASTTY_CLI_PATH" action run workspace.tab.move \
  --workspace "$WORKSPACE_ID" \
  index=2 \
  toIndex=1
"$TOASTTY_CLI_PATH" action run panel.scratchpad.set-content \
  sessionID="$TOASTTY_SESSION_ID" \
  filePath=artifacts/scratchpad.html \
  title="Review notes"
printf '%s' "$html" | "$TOASTTY_CLI_PATH" action run panel.scratchpad.set-content \
  --stdin content \
  sessionID="$TOASTTY_SESSION_ID" \
  createPolicy=additional \
  purpose="Independent comparison" \
  title="Separate artifact"
"$TOASTTY_CLI_PATH" --json query run panel.scratchpad.list \
  sessionID="$TOASTTY_SESSION_ID"
printf '%s' "$html" | "$TOASTTY_CLI_PATH" action run panel.scratchpad.set-content \
  --stdin content \
  sessionID="$TOASTTY_SESSION_ID" \
  documentID="$DOCUMENT_ID"
printf '%s' "$patch" | "$TOASTTY_CLI_PATH" --json action run panel.scratchpad.patch-content \
  --stdin patch \
  sessionID="$TOASTTY_SESSION_ID" \
  documentID="$DOCUMENT_ID" \
  expectedRevision=3
"$TOASTTY_CLI_PATH" --json action run panel.scratchpad.export \
  sessionID="$TOASTTY_SESSION_ID" \
  documentID="$DOCUMENT_ID"
```

Set `DOCUMENT_ID` from the `documentID` returned by the creation action or
from the matching entry in `panel.scratchpad.list`.

`workspace.create` accepts optional `title`, `activate`, and `parent`
arguments. When `activate=false`, Toastty appends the workspace without
changing the currently visible selection, returns the created `workspaceID`,
`windowID`, and `parentWorkspaceID`, and marks the background workspace as
`New` in the sidebar until the user visits it once.

When a managed agent session calls `workspace.create`, the new workspace nests
under the caller's workspace as a **task space** and records the caller as its
spawning session. Pass `parent=none` for a top-level workspace, or
`parent=<workspaceID>` to nest under a specific workspace in the same window.
Task spaces do not appear as their own sidebar cards; they render as compact rows
in a Task Spaces group inside the parent card, sorted ready, needs approval,
error, working, idle, then done. Working task spaces keep workspace order as
progress reports arrive. Idle task spaces sort by their latest session status
update, newest first. Done task spaces use the later of their latest session
status update and the time they were marked done. Ready, needs approval, and
error task spaces sort by the latest update from a session that sets that row's
status; updates from sessions in other states do not move the row. Equal or
missing times use workspace order; rows with no time follow rows with a time.
Hovering over the list holds its order, and the selected row keeps its slot
until selection changes. The spawning session's row shows a ⑂ chip that filters
the group to its task spaces. Nesting stays one level deep, so a parent that is
itself a task space resolves to its root. Closing a parent keeps its
task spaces open as top-level workspaces.

An explicit `parent` that is not a workspace in the target window is rejected
before anything is created. A scoped caller needs automation access to the
requested parent and to the root it resolves to.

`workspace.set-parent` nests an existing workspace under a top-level workspace
in the same window (`parent=<workspaceID>`) or detaches it (`parent=none`);
`parent` is required. The caller needs automation access to the workspace, the
requested parent, and the root it resolves to. Reparenting keeps the workspace's
original spawning session; a workspace that had none records the caller. The
sidebar offers the same detach through "Move to top level" on a task space row.

`workspace.snapshot` reports `parentWorkspaceID`, `spawningSessionID`, and
`subspaceWorkspaceIDs`. The parent ID is returned even when the parent is
outside the caller's scope; `null` means the workspace has no parent. Knowing
the parent ID does not grant automation access to that workspace.
`subspaceWorkspaceIDs` omits workspaces outside the caller's scope.

`workspace.set-done` marks a task space's task done, and `workspace.clear-done`
clears the mark. With no `workspaceID` or `windowID`, a managed agent's call
targets its own workspace rather than the selected one; a caller whose session
Toastty no longer runs must name the workspace. Only task spaces hold the mark:
`workspace.set-done` rejects a top-level workspace, and moving a task space to top
level drops it. The sidebar shows a done task space with a check in place of its
idle box and sorts it last; the box also toggles the mark by click. The mark
clears itself when an agent in the workspace starts new work: a newly launched
agent, or a turn that begins from idle, ready, or error. The rest of the turn
that set the mark, including its end, keeps it, and restored sessions and
process watches do not count. `workspace.list` and `workspace.snapshot` report
it as `done`.

```bash
"$TOASTTY_CLI_PATH" action run workspace.set-done
```

`workspace.select` accepts a `workspaceID` selector or a 1-based `index`
argument. The index counts every workspace in the window's order, including
task spaces; the sidebar's numbered shortcuts count only top-level cards, so
prefer `workspaceID` for task spaces. By default it changes only the selected
workspace and preserves that workspace's selected tab and focused panel. Set `focusUnreadSessionPanel=true`
when foreground navigation should also focus the newest unread managed-session
panel visible in the selected workspace tab.

`workspace.move` and `workspace.tab.move` use 1-based `index` and `toIndex`
arguments. Reordering keeps the selected workspace or tab selected, but changes
which item each numeric shortcut targets because shortcuts follow the current
visual order.

`workspace.set-annotation` sets or updates one structured `key -> (text, url?)`
chip rendered under the workspace name in the sidebar, and
`workspace.clear-annotation` removes one by key. The caller chooses the key;
Toastty never derives it from the displayed text. Use a stable semantic identity
for the annotation kind rather than copying its current value into the key. For
example:

- Linear issue: `key=linear`, `text=LIN-030`, plus its verified canonical URL
  when available.
- GitHub pull request: `key=github-pr`, `text="PR #1931"`, plus its verified pull
  URL when available. Use `PR #<number>` for all pull request chips, including
  primary annotations in task space rows.
- GitHub issue: `key=github-issue`, `text="Issue #482"`, plus its verified issue
  URL when available.
- Git branch: `key=git-branch`, `text=feat/hooks-chips`; a URL is usually
  omitted.

Before choosing a key, callers can run:

```bash
"$TOASTTY_CLI_PATH" --json query run annotation.keys
```

The query returns `{"keys": [...]}` in bytewise key order. It is
runtime-global and intentionally available to workspace-scoped callers, so it
can include historical keys and keys registered from workspaces outside the
caller's scope. Keys are caller-authored and may themselves contain sensitive
semantic labels. The response does not include colors, workspace IDs, usage
counts, chip text, or URLs.

Reuse an exact catalog key only when its semantic meaning clearly matches. Do
not fuzzy-match ambiguous keys. Before setting the annotation, also query the
target `workspace.snapshot`: setting a key already present in that workspace
replaces that chip's text and URL. Omit `color` when reusing a catalog key so
its existing global claim remains authoritative.

The same exact key updates one chip within a workspace. Multiple annotations of
the same kind therefore need distinct stable keys. Include a URL only when it
was supplied or verified; do not guess one from the label. Validation rules:

- `key` is trimmed, lowercased, and must be 1-32 characters of ASCII letters,
  digits, `.`, `_`, and `-`. Invalid or overlong keys are rejected, never
  truncated.
- `text` is trimmed, NFC-normalized, must be non-empty, and is limited to 80
  user-perceived characters. Control characters, newlines, Unicode
  line/paragraph separators, and bidi override/isolate controls are rejected;
  emoji, including zero-width-joiner sequences, are allowed.
- `url` is optional and must be an absolute `http` or `https` URL. Chips with
  a URL render as clickable links routed through Toastty's URL-opening
  preferences.
- `color` is optional: one of `neutral`, `green`, `amber`, `red`, `violet`,
  `blue`, or `#RRGGBB`. The first annotation for a key claims its global color
  across all workspaces and layout profiles. Omitting `color` records a stable
  automatic `#RRGGBB` claim; automatic claims avoid every color already
  recorded for another key as well as reserved error red and Toastty amber.
- While at least one annotation with that key exists, later calls may omit
  `color` or repeat the claimed color, but cannot replace it. A conflict fails
  with `ANNOTATION_COLOR_LOCKED` and leaves both the annotation and style
  unchanged. Explicitly requested colors may intentionally duplicate semantic
  colors used by other keys.
- If Toastty cannot read inactive layout profiles while checking an unlocked
  replacement, the call fails closed with `ANNOTATION_USAGE_UNAVAILABLE` and
  changes nothing.
- Clearing the last annotation unlocks the claim. A later colorless annotation
  reuses it; a later first-use call with an explicit color replaces it. Saved
  annotations in inactive layout profiles count as existing uses.
- Existing keys without a recorded claim are assigned and persisted once during
  startup migration. Automatic colors may therefore change once when upgrading
  from the earlier unrecorded fallback behavior. Existing explicit colors stay
  unchanged.
- A workspace holds at most 12 annotations. Updating an existing key remains
  allowed at the limit.
- Setting an identical annotation again reports `didMutateState=false`, unless
  `primary` changes which annotation is primary.

A task space's row in its parent's Task Spaces group shows one annotation chip:
the workspace's primary annotation, or its `github-pr` annotation when
none is marked primary. Pass `primary=true` to make an annotation primary; a
workspace has at most one, so this replaces any earlier choice. `primary=false`
removes the role only when this key holds it, and omitting `primary` leaves it
unchanged. Clearing the primary annotation clears the role. The row chip
truncates past about 12 characters, so keep primary text short, such as
`PR #1234` or `ENG-512`; the chip's tooltip shows the full text.

When all working sessions in a task space are waiting on background work, its row
shows a `waiting` status pill. At narrow widths, the row drops the annotation
before the waiting pill to keep room for the title. The hover card keeps both
the session's waiting status and every annotation.

Prefer `action list --json` to discover the current canonical IDs. Common actions include:

- `window.create`
- `window.sidebar.toggle`
- `workspace.create`
- `workspace.select`
- `workspace.move`
- `workspace.rename`
- `workspace.set-annotation`
- `workspace.clear-annotation`
- `workspace.set-parent`
- `workspace.set-done`
- `workspace.clear-done`
- `workspace.close`
- `workspace.tab.create`
- `workspace.tab.select`
- `workspace.tab.move`
- `workspace.tab.rename`
- `workspace.tab.close`
- `workspace.split.horizontal`
- `workspace.split.vertical`
- `workspace.split.right`
- `workspace.split.down`
- `workspace.split.left`
- `workspace.split.up`
- `workspace.split.right.with-profile`
- `workspace.split.down.with-profile`
- `panel.close`
- `panel.create.browser`
- `panel.create.local-document`
- `panel.scratchpad.set-content`
- `panel.scratchpad.patch-content`
- `panel.scratchpad.update-metadata`
- `panel.scratchpad.make-default`
- `panel.scratchpad.unbind`
- `panel.scratchpad.rebind`
- `panel.scratchpad.export`
- `panel.focus-mode.toggle`
- `agent.launch`
- `config.reload`
- `terminal.send-text`
- `session.exit-after-turn`
- `terminal.drop-image-files` (historical name; drops local file paths of any type)
- `task.create`, `task.start-work`, `task.retry`, `task.delete`, `task.set-workspace` (see [`task`](#task))

Explicit foreground navigation through workspace/tab selection and
`workspace.focus-panel` participates in Toastty's session navigation history.
Focusing a panel selects its containing workspace/tab and restores its window.
A new visit after Back clears Forward. Background creation, metadata updates,
and read-only queries do not create visits; use panel-targeted queries when
inspecting another terminal without changing the user's location.

Descriptors can also advertise compatibility aliases. Those aliases are accepted by the socket executor, but canonical IDs are preferred for new integrations.

Successful `workspace.split.*` actions return the target `workspaceID` and the
new terminal `panelID`. Use that `panelID` for a subsequent `agent.launch`
instead of inferring the target from workspace focus or a snapshot.

`panel.close` is non-interactive when invoked through the CLI. It closes the
focused panel in the selected workspace without presenting an AppKit alert. If
the terminal still has a running process, the command fails with
`CONFIRMATION_REQUIRED`; pass `terminateRunningProcess=true` to explicitly
terminate that process and close the panel:

```bash
"$TOASTTY_CLI_PATH" action run panel.close \
  --workspace "$TOASTTY_WORKSPACE_ID" \
  terminateRunningProcess=true
```

That parameter applies only to running terminal processes. It never discards
an unsaved local-document draft or interrupts a document save. Those states
return `CONFIRMATION_REQUIRED` or `CLOSE_BLOCKED` without showing a modal. If
Toastty cannot assess the terminal runtime, the default close also fails closed
with `CLOSE_BLOCKED`; explicit process termination remains available.

Scratchpad actions are intended for agent and automation integrations. A managed session can bind several open Scratchpads in its workspace tab, while each document belongs to at most one live session. Closing a panel removes its active binding but preserves its content for later reopening. Closed documents are not available to agent actions.

- `panel.scratchpad.set-content` requires `sessionID` plus either `filePath` or `content`. It accepts optional `title`, `purpose`, `expectedRevision`, `documentID`, and `createPolicy`, resolves relative `filePath` values from the active session's `cwd` when available, and returns `windowID`, `workspaceID`, `panelID`, `documentID`, `revision`, and `created`. A supplied `documentID` selects an open document bound to the same session and tab; it cannot be combined with `createPolicy=new` or `additional`. `createPolicy=reuse` updates the explicit default or sole bound document, or creates one when the session has no bindings. `createPolicy=additional` creates another bound Scratchpad without changing the default. Legacy `createPolicy=new` creates a fresh default and unbinds only the previous default, preserving other bindings and documents. Updates without a document ID fail if several documents are bound with no explicit default; `additional` creation still works. New Scratchpads open the source session's right panel without activating another window, workspace, or tab or moving keyboard focus to the Scratchpad.
- `panel.scratchpad.patch-content` requires `sessionID`, `expectedRevision`, and `patch` as a JSON string, and accepts optional `documentID` to select a bound document. It returns `windowID`, `workspaceID`, `panelID`, `documentID`, `previousRevision`, `revision`, `appliedEdits`, and `created=false`, and never creates a Scratchpad. Patch JSON is limited to 262,144 UTF-8 bytes. The top-level object only accepts nonempty `replacements`; each replacement only accepts `oldText` and `newText`. Replacements apply sequentially; each `oldText` must be non-empty and occur exactly once in the current intermediate HTML. Successful patches reload the generated iframe.
- `panel.scratchpad.update-metadata` requires `sessionID`, `documentID`, and at least one of `title` or `purpose`; it accepts optional `expectedRevision`. Omitted fields stay unchanged, empty `purpose` clears it, and empty `title` becomes `Scratchpad`. A successful metadata change increments the document revision.
- `panel.scratchpad.make-default` requires `sessionID` and a bound `documentID`. The first binding becomes default automatically; after the default is removed, the sole remaining binding becomes default. With several remaining bindings, call this action to choose one explicitly.
- `panel.scratchpad.unbind` requires `sessionID` and `documentID`. It removes the binding while keeping the open panel and its persisted content.
- `panel.scratchpad.rebind` binds an existing open Scratchpad panel to another active managed session in the same workspace tab. It requires destination `sessionID` and targets the Scratchpad by `--panel`, workspace/window selectors, or the focused/active Scratchpad. Existing destination bindings remain intact.
- `panel.scratchpad.export` writes an open Scratchpad document to an app-chosen local HTML file and returns `filePath`, `workspaceID`, `panelID`, `documentID`, `revision`, and `title`. With `sessionID`, optional `documentID` or `panelID` selects a member of that session's bindings rather than asserting the default. Panel-only export also works for an open unbound Scratchpad.
- `agent.launch` starts a managed agent profile in a resolved terminal panel. It
  requires `profileID` and accepts optional `cwd`, repeatable
  `initialCommands=<command>`, repeatable `env.NAME=value`, `model`,
  `reasoningEffort`, `initialPrompt`, `forkFromSessionID`, and repeatable
  `additionalDirectories` arguments. `cwd` must be absolute or
  `~`-expanded and becomes both the launch
  directory and the session working directory; `initialCommands` are raw
  single-line shell snippets rendered after `cd <cwd>` and before the final
  agent command; `env.NAME` entries are injected before Toastty's managed launch
  context on the final agent command and are not exported to
  `initialCommands`; `model` selects a model for `codex`, `claude`, `cursor`, `grok`,
  `opencode`, `mimocode`, or `pi`; `reasoningEffort` selects reasoning for
  `codex`, `claude`, `grok`, or `pi`; and `initialPrompt` is appended only for supported profiles.
  OpenCode and MiMo Code reject `reasoningEffort` atomically and do not map it
  to `variant`. Omit either selection to retain the configured argv/provider
  default. Explicit selections replace safely parseable equivalent profile
  flags; ambiguous executable, wrapper, or flag shapes fail without launch.
  Explicit `--workspace` and `--panel` selectors must be UUIDs. Async
  app-control launches briefly wait when the selected terminal surface has not
  mounted yet, while terminals reported as busy or exited still fail
  immediately.
  Values are syntax-checked (nonblank, at most 256 UTF-8 bytes, no control
  characters, and no leading dash), while the provider CLI makes the final
  upstream validity decision after delivery.
  Callers own side effects and trust changes in `initialCommands`, such as
  `direnv allow`. Built-in `codex`, `claude`, `cursor`, `grok`, `opencode`, `mimocode`, and `pi` automation launches work
  even when the user has not created `~/.toastty/agents.toml`. CLI/app-control
  `agent.launch` preserves the current AppKit first responder; focus the target
  workspace or panel separately when it should become the interactive keyboard
  target. When an active managed session invokes `agent.launch`, Toastty records
  that caller as the new session's parent. Same-workspace sessions with their
  own terminal panels have normal sidebar rows, with parent context in hover
  details. Background agents without their own panels remain nested;
  cross-workspace child sessions can also appear as navigation rows under the parent.
  The result's `command` is the composed invocation evidence, including managed
  instrumentation and environment assignments; inspect it without printing or
  logging unrelated environment values.

  For Codex and Claude, `forkFromSessionID` names an active **Toastty managed
  session**, not a provider-native ID. Toastty checks access to its workspace,
  resolves its current confirmed native conversation, and requires the same
  provider, a different target panel and an explicit existing `cwd`. Missing,
  stale or unsupported source metadata fails without launching a fresh session.
  The child inherits the saved conversation and gets a distinct identity; later
  parent messages do not transfer. `initialCommands` cannot be combined with a
  fork. Use direct first-party interactive profiles; ambiguous wrappers, existing
  resume/fork/cwd options and positional prompts are rejected.

  Codex uses its native `fork` command with an explicit working-directory option.
  Claude uses the confirmed transcript path with `--resume`, `--fork-session`,
  and `--system-prompt-snapshot off` to refresh directory context (requires Claude
  Code 2.1.257 or later). Successful command delivery is not proof the provider
  accepted those options; check the resulting native identity and cwd.

  `additionalDirectories` grants Codex/Claude access to explicitly named existing
  directories using `--add-dir`. It does not change the primary cwd or Toastty
  workspace scope. Pass only needed directories, such as a shared artifact
  directory the task reads. These options preserve selected model and effort.

```bash
"$TOASTTY_CLI_PATH" action run agent.launch \
  --workspace "$WORKSPACE_ID" \
  profileID=codex \
  model=gpt-5.6-codex \
  reasoningEffort=high \
  cwd="$HOME/new-work-tree" \
  "initialCommands=direnv allow" \
  env.TOASTTY_DEV_WORKTREE_ROOT="$HOME/new-work-tree" \
  initialPrompt="/work-on POP-1234"
```

`terminal.send-text` writes directly to the resolved terminal surface and does
not move AppKit keyboard focus. This lets automation prepare or start work in a
background workspace without causing the user's next physical keystrokes to go
to that hidden terminal. To make a terminal the interactive keyboard target,
select/focus the workspace or panel separately before sending text. Pass
`expectedSessionID=<id>` when the caller knows which managed session owns the
panel; Toastty rejects the request before delivery if that active session is
missing, ended, or replaced. This check is independent of the selected
workspace tab and is not bypassed by `allowUnavailable=true`.

`session.exit-after-turn` asks Toastty to type the agent's native `/exit` when
the running turn of the panel's managed Claude Code or Codex session completes.
It requires `expectedSessionID`, and the session must be in a running turn in a
top-level workspace; a session in a task space is refused, because a task space is
marked done when its work is finished instead. The
exit is skipped if anyone typed into the panel or sent it a phone message during
the turn, if the turn ends without completing, or if a new turn starts first.
After Toastty delivers the exit and confirms exit status 0, Jump to Next Active
skips that session's completion notice unless the panel has another unread
notice. The unread badge and final terminal output stay available. Failed or
skipped exits keep the completion eligible for navigation.
An agent calls it as its last tool action and then gives its final answer:

```bash
toastty action run session.exit-after-turn --panel "$TOASTTY_PANEL_ID" \
  "expectedSessionID=$TOASTTY_SESSION_ID"
```

Patch JSON uses exact text replacements:

```json
{
  "replacements": [
    {
      "oldText": "<section id=\"risk\">Old copy</section>",
      "newText": "<section id=\"risk\">New copy</section>"
    }
  ]
}
```

### `query list`

List the always-on app-control queries exposed by the running app.

```
toastty query list
```

Like `action list`, human-readable output prints `id<TAB>summary`, and `--json` returns the full descriptor payload.

```bash
"$TOASTTY_CLI_PATH" query list
"$TOASTTY_CLI_PATH" --json query list
```

### `query run`

Query a live Toastty instance without changing workspace/tab selection or
keyboard focus. Some queries initialize runtime state: `panel.browser.state`
can create a browser runtime and start loading its configured destination.

```
toastty query run <id> [--window <id>] [--workspace <id>] [--panel <id>] [key=value ...]
```

Query selectors and `key=value` argument handling follow the same rules as `action run`.

Use explicit workspace/panel IDs for discovery, inspection, status reporting,
and verification. Do not select a workspace/tab or focus a panel for those
tasks. `workspace.select` changes the user's visible workspace; selection and
focus actions are appropriate only for user-authorized navigation.

```bash
"$TOASTTY_CLI_PATH" query run annotation.keys
"$TOASTTY_CLI_PATH" query run agent.profile.state profileID=codex
"$TOASTTY_CLI_PATH" query run workspace.snapshot --workspace "$WORKSPACE_ID"
"$TOASTTY_CLI_PATH" query run terminal.visible-text --panel "$PANEL_ID" contains="ready"
"$TOASTTY_CLI_PATH" query run terminal.visible-text --panel "$OTHER_PANEL_ID" tail=80 includeScrollback=true
```

Prefer `query list --json` to discover the current canonical IDs. Common queries include:

- `annotation.keys`
- `agent.profile.state`
- `workspace.list`
- `workspace.snapshot`
- `terminal.state` (returns `windowID`, `workspaceID`, `panelID`, and terminal metadata)
- `terminal.visible-text` (accepts `contains`, `tail`, and `includeScrollback`;
  returns `text`, `lineCount`, `truncated`, and `includesScrollback`)
- `panel.local-document.state`
- `panel.browser.state`
- `panel.scratchpad.lookup`
- `panel.scratchpad.list`
- `panel.scratchpad.state`
- `task.get`, `task.list`, `task.workspace-choices`, `task.watches` (see [`task`](#task))
- `coordinator.status`, `coordinator.chat.state` (see [`coordinator`](#coordinator))

`agent.profile.state` requires `profileID` and reports the executable that
profile would run in Toastty's launch environment, skipping Toastty's command
shims. Use it before checking a provider CLI's native launch or fork support.
It reads configuration and filesystem metadata without launching an agent,
starting a shell, or changing selection or focus. It takes no workspace or
panel selector and is available to workspace-scoped callers.

The result includes `profileID`, `displayName`, `command` (the profile's first
argv entry), `argumentCount`, `source` (`configured` or `implicit`),
`commandIsExplicitPath`, nullable `executablePath`, `resolved`,
`fallbackProbeUsed`, `directExecutableProbeUsed`, and nullable `failure`.
Profile arguments and environment values are not returned. If `resolved` is
false, `failure` is `command_not_found`, `explicit_path_not_executable`, or
`explicit_path_not_absolute`. Absolute paths are checked directly; relative
and `~` paths are not resolved. The query does not run a new login-shell path
probe. `fallbackProbeUsed` and `directExecutableProbeUsed` are diagnostic
flags for those probes and are false on this query path. An unknown or
unavailable profile fails the query. A wrapper profile reports the wrapper
executable, not a provider hidden inside it.

`terminal.visible-text` may target any terminal panel in a workspace the
caller can automate, not only the caller's own panel. Reads by another session
are shown in the read panel's header, and a panel the user marked private
returns `PANEL_READ_DENIED` to every session except its own.

`workspace.list` returns `workspaces`, one entry per workspace in window
order, without selecting or focusing anything. Each entry has `windowID`,
`workspaceID`, 1-based `index` within its window, `title`, `isSelected`,
`annotations` (the same shape as `workspace.snapshot`), `done` (the task space
done mark), `isCoordinator` (true for the hidden
[coordinator](coordinator.md) workspace), and `terminalCwds`,
the sorted working directories of the workspace's terminal panels across all
tabs. `activeSessions` lists each managed agent session in the workspace as
`{sessionID, agent, panelID}`, `busyTerminalCount` counts terminals running a
command, and `unsavedDocumentCount` counts local documents with unsaved or saving
changes. `workspace.close` does not ask before discarding them, so tooling should
check these fields first. The top-level `callerIsScoped` is true when the caller's
workspace scope filtered the list. `--window` limits the list to one window. A workspace-scoped caller sees
only workspaces in its scope.

`workspace.snapshot` describes the selected tab's main-area slots in
`slotMappings`. Terminal entries carry `title`, `cwd`, `shell`, `profileID`,
`shortcutNumber`, `promptState`, `isBusy`, `sessionID`, `agent`, and
`readable`, so an agent can pick a sibling terminal by name or state without
reading its text.

`workspace.snapshot` includes the selected workspace tab's right-panel tabs at
`rightPanel.tabs`. Each tab includes `panelID`, `panelKind`, `webDefinition`,
and `title`, plus `filePath` for local documents, `url` for browsers, and
`scratchpadDocumentID`, `scratchpadRevision`, and `scratchpadSessionID` for
Scratchpads. Fields that do not apply are null. Right-panel tabs belonging to
unselected workspace tabs are not included. Query a known panel ID directly
rather than selecting a tab to discover it; report missing identity as a
discovery limit when the supported queries cannot supply it.

`workspace.snapshot` also returns `annotations` as an array of
`{key, text, url, color, primary}` objects sorted by key in bytewise order. `url` is
null for text-only chips, `color` is the effective token for the key —
the explicit global color when one was set, otherwise the stable automatic
`#RRGGBB` fallback — and `primary` is true for the workspace's primary
annotation.

`annotation.keys` takes no selector and returns `keys`, the bytewise-sorted
array of annotation keys previously registered in the current runtime. The
catalog is historical rather than an active-usage listing and is intentionally
runtime-global even for workspace-scoped callers.

`panel.browser.state --panel "$PANEL_ID"` returns browser navigation and host
attachment state. It can start a hidden panel's first load; repeated queries
for an unchanged destination do not restart navigation. Browser creation and
app restoration do not eagerly load every hidden panel. Background pages still
consume memory and can perform ongoing work, so query only needed panels.

- `stateRestorableURL` is the configured/persisted destination. `observedURL`
  is the actual WebKit URL or null, with no requested-URL fallback; a pending
  or failed load may leave the previous document's URL visible.
- `navigationState` is `idle`, `loading`, `finished`, or `failed`. `idle` means
  no observed document-navigation result, including the internal start page
  and same-document history changes that produce no navigation callbacks.
  `finished` requires WebKit's completion callback for the current navigation;
  it does not establish HTTP success, SPA readiness, visual correctness, or
  video playback. An invalid destination reports `failed`.
- `title` is WebKit's current title or null. `isLoading` reports WebKit loading
  activity; false alone does not establish success. `navigationError` is null
  or `{domain, code, message}` for the current failed navigation; starting a
  new navigation clears the old error.
- `hostLifecycleState` is `detached`, `attached`, or `ready` and describes UI
  attachment independently. `ready` means attached to a window. A detached
  browser can finish navigation, though screenshot requests remain unsupported
  while detached.

For background verification, poll the explicit panel with a bounded deadline
(for example once per second for up to 30 seconds). Stop on a query error,
`finished`, or `failed`, and check the observed destination against the expected
page and any known redirect. A timeout or missing navigation fields on an older
app leaves verification incomplete. Preserve the last state and report the
limit; do not change selection or focus to obtain a stronger result.

`panel.scratchpad.state` returns Scratchpad panel metadata, including the document ID, revision, linked session ID when present, host lifecycle state, current bootstrap diagnostics, and content hashes for automation checks.

`panel.scratchpad.list` requires `sessionID` and returns metadata for all open
Scratchpads bound to that active session: `sessionID`, `defaultDocumentID` (or
null), and `scratchpads`. Each entry includes `windowID`, `workspaceID`,
`tabID`, `panelID`, `documentID`, `sessionID`, `title`, `purpose` (or null),
`revision`, `updatedAt`, and `isDefault`. This query does not create, export,
focus, or expose document content. Use `documentID` from the list to select
an artifact for subsequent actions.

`panel.scratchpad.lookup` requires `sessionID` and accepts optional
`documentID`. It preserves its single-object shape and returns metadata for
the selected bound document, including `purpose`, `updatedAt`, `isDefault`,
`bindingCount`, and `defaultDocumentID`. Without `documentID`, it returns the
explicit default or sole bound document, or `linked: false` when none are bound. If several documents
are bound without a default, session-only lookup fails instead of choosing an
arbitrary document. It does not infer a link from focus state.

### Internal managed-agent commands

These commands are used by Toastty-owned command shims and app integration code.
They are not intended as third-party agent integration APIs. Custom agents should
use `session start`, `session status`, `session update-files`, and
`session stop` directly.

```
toastty agent prepare-managed-launch --agent <id> --panel <id> --arg <value> [--arg <value> ...] [--cwd <path>] [--preflight-policy skip|interactive] [--resolved-codex-executable <path>] [--codex-home <path>]
toastty agent managed-launch-preflight-decision --token <id>
```

`agent prepare-managed-launch` asks the running app to build the managed launch
plan for a built-in agent command. `--arg` is repeatable and supplies the exact
agent command argv. `--preflight-policy` defaults to `skip`; `interactive`
allows the app to pause a Codex launch for status-hook setup guidance.
Unsupported, untrusted, or unresolvable hooks can continue with Toastty's
notify/session-recording fallback; skills preparation remains automatic and
fail-open.

Toastty's own command shim may add `--resolved-codex-executable` and
`--codex-home` after resolving a direct `codex` or `cdx` launch. These optional
hints let the app prepare skills against the same executable and Codex home
without guessing. Older shims omit them, and opaque wrappers still launch with
fallback telemetry but without managed skills.

When interactive preflight is required, the response reports
`kind: "preflightRequired"` with a token. The shim then calls
`agent managed-launch-preflight-decision --token <id>` and either continues with
the returned decision or exits before starting the real agent command.

### `task`

Create and manage tasks. See [Tasks](tasks.md) for what setup does and for
`~/.toastty/tasks.toml`.

```
toastty task create [<text>] [--file <path> ...] [--workspace <id>] [--agent <id>] [--model <id>] [--effort <level>] [--prompt <text> | --prompt-file <path>] [--title <text>] [--slug <slug>] [--request-id <id>] [--start-work [--base <ref>] [--branch-prefix <prefix>]] [--fork] [--wait [--timeout <seconds>]]
toastty task start-work [--base <ref>] [--branch-prefix <prefix>] [--title <text>] [--slug <slug>]
toastty task get [<task-id>]
toastty task retry|delete <task-id>
toastty task set-workspace <task-id> (--workspace <id> | --recent <id> | --root <dir>)
toastty task list [--changed-since <cursor> [--wait --until created [--timeout <seconds>]]] [--include-reply] [--parent <task-id>]
toastty task workspace-choices [<task-id>]
toastty task send <task-id> (<text> | --text-file <path>)
toastty task watch <task-id> --until <condition> [--notify <task-id> | --wait [--timeout <seconds>]]
toastty task unwatch <watch-id>
toastty task watches [--task <task-id>] [--notify <task-id>]
toastty task adopt [--workspace <id>]
toastty task merge [<task-id>] [--head <commit>]
toastty task cancel-merge [<task-id>]
toastty task clean-up <task-id>
toastty task ready-for-review [<task-id>]
toastty task packet publish [<task-id>] --file <packet.json> [--screenshot <path> ...]
toastty task packet get [<task-id>] [--version <n>]
toastty task mark-done <task-id>
toastty task archive <task-id> [--close-pr] [--delete-unpushed] [--discard-changes]
toastty task release [--workspace <id>]
```

`task create` returns once the task is saved; `--wait` polls `task.get` until
the agent has started (exit 0), or setup failed, the task waits for a
workspace, or the wait timed out (exit 1). Relative `--file` and
`--prompt-file` paths resolve against the current directory, and the CLI reads
`--prompt-file` itself. With `--start-work`, setup makes a git worktree and
starts the agent there; it needs a workspace. With `--fork`, from a Claude Code
or Codex session, the agent starts as a fork of that session's conversation
after its current turn ends, and the calling session keeps running; `--wait`
cannot be used with it. See
[Fork the conversation into new tasks](tasks.md#fork-the-conversation-into-new-tasks).

Without `--workspace`, and outside an agent session, the task waits in the
Needs you for a workspace. `[defaults]` in `tasks.toml` fills an agent, model or
effort you leave out; optional [triage](tasks.md#optional-triage) fills them
first when `[triage]` is set up.
`task set-workspace` places a task that waits for a workspace, in an open one,
in a recently closed one from `task workspace-choices`, which Toastty reopens,
or in a project directory (`--root`), which Toastty opens as a new workspace.
With triage on, `task workspace-choices <task-id>` also shows the project
triage suggested for that task, if any.

`task start-work` runs from an agent session and moves its task into a git
worktree; see [Work in a git worktree](tasks.md#work-in-a-git-worktree). It
returns once the move is saved, and the agent should then end its turn: the
move forks the conversation after the turn ends. `task get` reports the move
under `worktree`, and `task retry` continues a move that failed.

`task get` and `task list` report each task's `stage`: its `group` (`needsYou`,
`running`, `toShip`, `done` or `archived`), `needsUser`, and for
Needs you the `attention` and `reason`. See [Stages](tasks.md#stages).
`task adopt` gives a task space without a record one; it defaults to the
calling agent's task space.

`task send`, `task watch` and `task list --changed-since` let an agent follow
and talk to other tasks by task ID; see
[Coordinate tasks](tasks.md#coordinate-tasks). `task watch` tells the calling
agent's own task, or the `--notify` task, once with a one-line message when the
condition holds. With `--wait`, it blocks instead and exits 0 when the condition
held, or 1 when it can never hold or `--timeout` ran out.
`task list --changed-since <cursor> --wait --until created` blocks until a task
appears after the cursor that the calling session did not create, such as one
made in quick entry, then prints the list at that cursor and exits 0. It also
returns at once when the cursor is from an earlier launch. Exits 1 when
`--timeout` runs out.

`task merge` is what a merge skill runs once its checks pass; without a task
ID it merges the calling agent's own task. Toastty merges at the checkout's
commit, refuses with `--head` when the checkout moved past the checked commit,
waits for checks that still run, and cleans up after the agent's turn ends.
`task cancel-merge` stops a merge the user accepted. `task archive` closes a
task without merging; it refuses with the reason, and `--close-pr`,
`--delete-unpushed` and `--discard-changes` allow what it would otherwise
refuse or leave. `task clean-up` retries a cleanup that stopped.
`task packet publish` stores the next version of the task's review packet
from a JSON file, copies the `--screenshot` files it names, and marks the task
ready for review; `task packet get` reads the newest packet, or `--version <n>`,
with `stale` when the worktree moved past it. Relative paths resolve against
the current directory, and without a task ID both act on the calling agent's
own task. See [Review packets](tasks.md#review-packets).
`task ready-for-review` marks work without a pull request ready, and
`task mark-done` finishes it. `task release` starts a release task for a
project with `release_skill` or `release_prompt`. See [Merge a task](tasks.md#merge-a-task),
[Archive a task](tasks.md#archive-a-task) and [Release](tasks.md#release).
`task list --parent` lists the tasks one task started.

These commands are short forms of
`action run task.create|task.start-work|task.retry|task.delete|task.set-workspace|task.adopt|task.send|task.watch|task.unwatch|task.merge|task.cancel-merge|task.clean-up|task.ready-for-review|task.packet.publish|task.packet.get|task.mark-done|task.archive|task.release`
and `query run task.get|task.list|task.workspace-choices|task.watches`.
`window.tasks.show` and `window.tasks.hide`, from before the coordinator chat
replaced the Tasks view, now open the chat, as `coordinator.chat.show` does.

```bash
"$TOASTTY_CLI_PATH" task create "Fix the unread dot" --agent codex --effort high --wait
```

### `coordinator`

```text
toastty coordinator post packet|task-started|question|note [<text> | --text <text>] [--task <task-id>] [--option <answer>]...
toastty coordinator status
toastty coordinator show-terminal
toastty coordinator show [--task <task-id>]
toastty coordinator tasks
```

`coordinator post` adds a card to the coordinator's chat. Every kind except
`note` names its task, and `question` and `note` need text. Only the
coordinator's own session, or a command outside any agent session, may post.
A question can include repeated `--option` flags, in display order. It accepts
up to six different, nonempty choices, each at most 120 characters after trimming
spaces at each end. Other kinds reject choices. A note with `--task` goes into that
task's card thread; a note without it appears in the main chat.
`coordinator status` reports whether the coordinator runs, and where its files
are. `coordinator show` shows the coordinator chat over its hidden workspace;
with `--task`, the chat opens and scrolls to that task's newest packet card,
or to its newest card when that is a question.
`coordinator show-terminal` shows the same workspace with its raw terminal.
`coordinator tasks` shows [All tasks](tasks.md#all-tasks) there instead of the chat.
These are short forms of
`action run coordinator.post|coordinator.chat.show|coordinator.show-terminal|coordinator.tasks.show`
and `query run coordinator.status`. `query run coordinator.chat.state` lists
what the chat shows, for automation. See [Coordinator](coordinator.md).

### `notify`

Emit a macOS desktop notification.

```
toastty notify <title> <body> [--workspace <id>] [--panel <id>]
```

| Argument / Option | Required | Description |
|---|---|---|
| `<title>` | yes | Notification title |
| `<body>` | yes | Notification body |
| `--workspace <id>` | no | Target workspace UUID |
| `--panel <id>` | no | Target panel UUID |

```bash
"$TOASTTY_CLI_PATH" notify "Build Complete" "All tests passed"
```

### `session start`

Create a new agent session for a terminal panel.

```
toastty session start --agent <id> --panel <id> [--session <id>] [--cwd <path>] [--repo-root <path>]
```

| Option | Required | Env var fallback | Description |
|---|---|---|---|
| `--agent <id>` | yes | `TOASTTY_AGENT` | Agent profile ID |
| `--panel <id>` | yes | `TOASTTY_PANEL_ID` | Terminal panel UUID |
| `--session <id>` | no | `TOASTTY_SESSION_ID` | Session ID (auto-generated if omitted) |
| `--cwd <path>` | no | `TOASTTY_CWD` | Panel working directory |
| `--repo-root <path>` | no | `TOASTTY_REPO_ROOT` | Git repository root |

Returns the resolved session ID.

### `session status`

Update the status of an active session. This drives the sidebar indicator and can trigger unread badges and desktop notifications.

```
toastty session status --session <id> --kind <kind> --summary <text> [--panel <id>] [--detail <text>]
```

| Option | Required | Env var fallback | Description |
|---|---|---|---|
| `--session <id>` | yes | `TOASTTY_SESSION_ID` | Existing session ID |
| `--kind <kind>` | yes | — | One of `idle`, `working`, `needs_approval`, `ready`, `error` |
| `--summary <text>` | yes | — | Short status line (non-empty) |
| `--panel <id>` | no | `TOASTTY_PANEL_ID` | Panel UUID |
| `--detail <text>` | no | — | Additional detail text |

**Kind values:**

| Kind | Meaning | Triggers notification? |
|---|---|---|
| `idle` | Waiting for input | no |
| `working` | Actively processing | no |
| `needs_approval` | Awaiting user approval | yes |
| `ready` | Finished, ready for review | yes |
| `error` | Error state | yes |

```bash
"$TOASTTY_CLI_PATH" session status \
  --session "$TOASTTY_SESSION_ID" \
  --kind working \
  --summary "Analyzing code"
```

### `session background-activity`

Report child-agent or provider-subagent activity for an active managed session.
This is an internal command used by Toastty-owned provider instrumentation; it
is not a general-purpose third-party integration API.

```
toastty session background-activity start|finish \
  --session <id> --activity <id> --kind child_agent|subagent \
  [--panel <id>] [--display-name <text>] [--command <text>] [--pid <pid>]
```

| Option | Required | Env var fallback | Description |
|---|---|---|---|
| `start` / `finish` | yes | — | Add/update or finish the activity |
| `--session <id>` | yes | `TOASTTY_SESSION_ID` | Parent managed session |
| `--activity <id>` | yes | — | Stable activity identifier |
| `--kind <kind>` | yes | — | `child_agent` or `subagent` |
| `--panel <id>` | no | `TOASTTY_PANEL_ID` | Parent terminal panel UUID |
| `--display-name <text>` | no | — | Activity label shown in the sidebar |
| `--command <text>` | no | — | Optional provider command/context text |
| `--pid <pid>` | no | — | Positive process ID for stale-activity checks |

`start` creates or refreshes a child row; `finish` removes it. The corresponding
socket event also supports provider-owned `sync` payloads for replacing the
current subagent set and reporting pending background-task counts. Outstanding
activity contributes to the parent session's waiting projection. Toastty-owned
ingestors may also attach bounded `modelIdentifier` and `reasoningEffort`
strings to `start` and `sync` socket payloads; those internal fields are not
exposed as public CLI flags.

### `session update-files`

Report files changed during a session.

```
toastty session update-files --session <id> --file <path> [--file <path> ...] [--panel <id>] [--cwd <path>] [--repo-root <path>]
```

| Option | Required | Env var fallback | Description |
|---|---|---|---|
| `--session <id>` | yes | `TOASTTY_SESSION_ID` | Existing session ID |
| `--file <path>` | yes | — | Changed file path (repeatable) |
| `--panel <id>` | no | `TOASTTY_PANEL_ID` | Panel UUID |
| `--cwd <path>` | no | `TOASTTY_CWD` | Base directory for relative paths |
| `--repo-root <path>` | no | `TOASTTY_REPO_ROOT` | Git repository root |

Multiple `--file` arguments can be provided. Relative paths are resolved against `--cwd`. File updates are coalesced server-side with a 0.5-second window per session.

```bash
"$TOASTTY_CLI_PATH" session update-files \
  --session "$TOASTTY_SESSION_ID" \
  --file src/main.rs \
  --file Cargo.toml
```

### `session stop`

End an active session.

```
toastty session stop --session <id> [--panel <id>] [--reason <text>]
```

| Option | Required | Env var fallback | Description |
|---|---|---|---|
| `--session <id>` | yes | `TOASTTY_SESSION_ID` | Existing session ID |
| `--panel <id>` | no | `TOASTTY_PANEL_ID` | Panel UUID |
| `--reason <text>` | no | — | Reason for stopping |

```bash
"$TOASTTY_CLI_PATH" session stop \
  --session "$TOASTTY_SESSION_ID" \
  --reason "User cancelled"
```

### `session scope`

Manage cooperative workspace scope for an active managed session. Workspace
scope is an orchestration guardrail, not a security sandbox; see
[Workspace Scope](agents/workspace-scope.md) for semantics and enforcement
coverage.

```
toastty session scope show [--session <id>]
toastty session scope set-current [--session <id>]
toastty session scope set --workspace <id> [--workspace <id> ...] [--session <id>]
toastty session scope add --workspace <id> [--workspace <id> ...] [--session <id>]
toastty session scope clear [--session <id>]
```

| Subcommand | Description |
|---|---|
| `show` | Print whether the session is unrestricted or workspace-scoped. With `--json`, returns `sessionID`, `isScoped`, `workspaceIDs`, and `effectiveWorkspaceIDs`. |
| `set-current` | Scope the current managed session to its current workspace only. Requires `TOASTTY_PANEL_ID` and can only target the caller session. |
| `set` | Replace the explicit workspace scope with the supplied workspace IDs. |
| `add` | Add workspace IDs to the existing explicit scope. |
| `clear` | Return the session to unrestricted automation. |

When `--session` is omitted, the CLI uses `TOASTTY_SESSION_ID`. `set-current`
also uses `TOASTTY_PANEL_ID` to verify the current panel still belongs to a
Toastty workspace. Use `set` or `add` for another active session or for
additional workspaces the user explicitly assigned.

### `session ingest-agent-event`

Process agent lifecycle events from stdin. This is a CLI-local command used by the built-in Claude, Codex, Cursor, Grok Build, OpenCode, MiMo Code, and Pi instrumentation. It reads structured event JSON from stdin and translates it into source-specific socket events, including status updates, stops, file updates, correlated Cursor hook events, Codex hook/notify events, and provider-native resume-record updates when the source supports them. Cursor hook input is capped at 65,536 bytes; oversized input is drained without being retained and then rejected so the provider's hook pipe can close cleanly.

```
toastty session ingest-agent-event --source <source> [--session <id>] [--panel <id>]
```

| Option | Required | Env var fallback | Description |
|---|---|---|---|
| `--source <source>` | yes | — | `claude-hooks`, `codex-hooks`, `codex-notify`, `cursor-hooks`, `grok-hooks`, `opencode-plugin`, `mimocode-plugin`, or `pi-extension` |
| `--session <id>` | no | `TOASTTY_SESSION_ID` | Session ID |
| `--panel <id>` | no | `TOASTTY_PANEL_ID` | Panel UUID |

This command is not intended for third-party integrations. Custom agents should use `session status` and `session stop` directly.

Toastty's built-in Claude, Codex, Cursor, Grok Build, OpenCode, MiMo Code, and Pi launch helpers invoke this command with an explicit `TOASTTY_SOCKET_PATH` injected at launch time. That injected value is the authoritative resolved socket path for the target app instance, including runtime-isolated fallback cases. If a helper cannot reach the app, it keeps the agent process alive. Cursor's launch-scoped forwarder suppresses delivery failures and writes no separate log; Codex's installed status-hook forwarder writes to `~/.toastty/codex-hooks/telemetry-failures.log`; Claude and Codex per-launch helpers write under `~/.toastty/run/managed-agent-launches/` (or the runtime-isolated equivalent), where files remain available until Toastty can prove the owning process exited. OpenCode and MiMo Code helper failures remain in their temporary per-session launch directories, and Pi writes its compact telemetry there while the session is active.

## Environment variables

When Toastty launches an agent, these variables are injected into the agent's environment:

| Variable | Description |
|---|---|
| `TOASTTY_CLI_PATH` | Absolute path to this Toastty instance's staged `toastty` CLI copy |
| `TOASTTY_SESSION_ID` | Session ID for the current agent run |
| `TOASTTY_PANEL_ID` | Terminal panel UUID |
| `TOASTTY_SOCKET_PATH` | Resolved automation socket path for the target app instance |
| `TOASTTY_CWD` | Resolved launch working directory: explicit automation `cwd` when supplied, otherwise the target or restored panel working directory when available |
| `TOASTTY_REPO_ROOT` | Git repository root inferred from the resolved launch working directory when available |

Most CLI flags fall back to their corresponding environment variable when not provided explicitly, so agents launched by Toastty can often omit flags like `--session` and `--panel`.

To recover the owning Toastty window for the current thread, query the current panel:

```bash
window_id="$("$TOASTTY_CLI_PATH" --json query run terminal.state --panel "$TOASTTY_PANEL_ID" \
  | python3 -c '
import json, sys
data = json.load(sys.stdin)
value = data["result"].get("windowID")
if not value:
    raise SystemExit("missing windowID in terminal.state result")
print(value)
')"
```

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Runtime error (socket failure, validation error, bad response) |
| `64` | Usage error (invalid arguments, missing required flags) |

## Agent ID format

Agent IDs must be lowercase, start with a letter (`a-z`), and contain only letters, digits, hyphens, and underscores. Examples: `claude`, `codex`, `my-agent`, `custom_agent_2`.

## JSON output

When `--json` is passed, responses follow the automation protocol envelope:

```json
{
  "protocolVersion": "1.0",
  "kind": "response",
  "requestID": "...",
  "ok": true,
  "result": { ... }
}
```

Error responses set `ok: false` and include an `error` object with `code` and `message` fields.

For `action list` and `query list`, `result.commands` contains an array of descriptors.
Parameters may include `supportedProfileIDs` when support varies by agent profile:

```json
{
  "id": "workspace.rename",
  "kind": "action",
  "summary": "Rename a workspace.",
  "selectors": ["windowID", "workspaceID"],
  "parameters": [
    {
      "name": "title",
      "summary": "Title text.",
      "valueType": "string",
      "required": true,
      "repeatable": false
    }
  ],
  "aliases": []
}
```

## Custom agent integration example

A minimal wrapper script that reports status back to Toastty:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Toastty injects TOASTTY_CLI_PATH, TOASTTY_SESSION_ID, etc.
cli="$TOASTTY_CLI_PATH"
session="$TOASTTY_SESSION_ID"

"$cli" session status --session "$session" --kind working --summary "Starting"

# ... do work ...

"$cli" session update-files --session "$session" --file output.txt
"$cli" session status --session "$session" --kind ready --summary "Done"
"$cli" session stop --session "$session"
"$cli" notify "Agent finished" "Check the results"
```

See [running-agents.md](running-agents.md#custom-and-third-party-agents) for the full integration guide.
