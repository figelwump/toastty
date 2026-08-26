# Running Agents

Toastty can launch coding agents directly into terminal panels, with built-in session telemetry that drives sidebar status, unread badges, and desktop notifications.

## Quick start

1. If you want to type `codex`, `cdx`, `claude`, `opencode`, `mimo`, `mimocode`, `pi`, or supported wrappers directly into Toastty terminals, open the Getting Started panel with the top-bar `Get Started…` button, then use `Toastty > Install Shell Integration…` for automatic setup or copy the panel's manual setup command
2. Toastty automatically exposes four session-only skills to supported managed Codex, Claude Code, OpenCode, MiMo Code, and Pi launches; no skills setup is required. You can also add your own skills under `~/.toastty/skills` (see [User-created skills](#user-created-skills))
3. If you use Codex and want the most complete status updates, choose `Toastty > Set Up Agent Status Hooks…`; it opens the Getting Started panel's Codex hooks section
4. If you want dedicated header buttons, Agent menu entries, command palette results, and optional keyboard shortcuts, open `Agent > Manage Agents...` inside Toastty or use the Getting Started panel's `Open agents.toml` link
5. Uncomment or add a profile in `~/.toastty/agents.toml`
6. Use `Toastty > Reload Configuration` to load the updated profiles without relaunching
7. Click the agent name in the `Agent` menu, top bar, or command palette, or press its keyboard shortcut

Toastty sends the configured command into the focused terminal panel and starts tracking the session automatically.

Automation can also launch managed `codex`, `claude`, `opencode`, `mimocode`, or `pi` sessions through
`agent.launch` without an `agents.toml` profile. Configure `agents.toml` when
you want manual UI launch entries, shortcuts, custom argv, wrapper shim names,
or custom initial-prompt support.

## agents.toml

Agent profiles live in `~/.toastty/agents.toml`. Each TOML table defines one launchable profile:

```toml
[codex]
displayName = "Codex"
argv = ["codex"]
shortcutKey = "c"

[claude]
displayName = "Claude Code"
argv = ["claude"]

[opencode]
displayName = "OpenCode"
argv = ["opencode"]

[mimocode]
displayName = "MiMo Code"
argv = ["mimo"]

[pi]
displayName = "Pi"
argv = ["pi"]
```

### Fields

Top-level options:

| Option | Default | Description |
|---|---|---|
| `showTopBarButtons` | `true` | Set to `false` to hide dedicated agent launch buttons from the top bar. Agent menu entries, command palette results, keyboard shortcuts, and typed-command shims still work. |

Profile fields:

| Field | Required | Description |
|---|---|---|
| `displayName` | yes | Label shown in the Agent menu, command palette, and top-bar buttons when enabled |
| `argv` | yes | The exact command Toastty executes, as a JSON-style string array |
| `manualCommandNames` | no | For built-in `[codex]` / `[claude]` / `[opencode]` / `[mimocode]` / `[pi]` profiles only, the extra executable basenames Toastty should shim for manual typed wrapper launches. Entries must be basenames with no paths or spaces. |
| `initialPromptPlacement` | no | Set to `"trailing"` only for profiles whose command accepts the first prompt as the final argv argument. Automation `agent.launch initialPrompt=...` uses this to opt custom profiles or shell-helper profiles into prompt passing. |
| `shortcutKey` | no | Single ASCII letter or digit; registers `Cmd+Opt+<key>` |

### Automation launch options

The `agent.launch` app-control action accepts optional structured launch
arguments for automation:

- App-control delivery preserves the current AppKit first responder, so a
  background launch does not reroute the user's next physical keystrokes.
  Manual launches from the Agent menu, top bar, command palette, or shortcut use
  the normal focused-target behavior.
- `cwd` must be an existing directory. Toastty starts the terminal command with
  `cd <cwd> && ...`, records the managed session in that directory, and uses it
  for repository-root inference. Pass an absolute path or a `~`-expanded path;
  relative paths are rejected.
- `initialCommands=<command>` runs one or more raw single-line shell snippets
  after `cwd` setup and before the final agent command, in the same shell,
  joined with `&&`. Use this for explicit caller-owned setup such as
  `direnv allow`. A failing initial command stops the later agent command in
  the terminal, but `agent.launch` has already succeeded once the command line
  is delivered. Commands such as `direnv allow` change trust for files in the
  target tree; pass them only when the caller explicitly requested that trust
  change. Structured `env.NAME=value` assignments apply to the final agent
  command, not to `initialCommands`; export values inside `initialCommands` when
  setup commands need them.
- `env.NAME=value` injects caller-provided environment values before Toastty's
  managed launch context. Environment keys must use shell variable syntax,
  values must not contain NUL bytes, and duplicate definitions across
  `env.NAME`, `env`, and `environment` payloads are rejected. Toastty also
  rejects exact-key collisions with its managed context and provider
  instrumentation keys: `TOASTTY_SESSION_ID`, `TOASTTY_PANEL_ID`,
  `TOASTTY_SOCKET_PATH`, `TOASTTY_CLI_PATH`, `TOASTTY_CWD`,
  `TOASTTY_REPO_ROOT`, `TOASTTY_AGENT`, `TOASTTY_SKILLS_ROOT`,
  `TOASTTY_USER_SKILLS_ROOT`, `TOASTTY_MANAGED_AGENT_SHIM_BYPASS`,
  `CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT`, `CODEX_TUI_RECORD_SESSION`,
  `CODEX_TUI_SESSION_LOG_PATH`, and `TOASTTY_PI_TELEMETRY_LOG_PATH`.
- `model=<value>` makes an explicit, action-local model selection for Codex,
  Claude Code, OpenCode, MiMo Code, or Pi. Omit it to use the exact configured
  profile argv and any provider defaults. Toastty translates an explicit value
  to `--model` for each provider.
- `reasoningEffort=<value>` makes an explicit, action-local reasoning selection
  for Codex (`--config model_reasoning_effort=<TOML string>`), Claude Code
  (`--effort`), or Pi (`--thinking`). OpenCode and MiMo Code do not support this
  parameter; Toastty rejects the whole launch before changing the target panel
  or managed-session state and never maps it to an OpenCode-family `variant`.
- `initialPrompt` appends the first prompt as a trailing argv argument only when
  the resolved profile supports it. Blank values are ignored; nonblank prompts
  must not contain NUL bytes and are limited to 65,536 UTF-8 bytes.

Model and reasoning values are syntax-checked without a built-in catalog: each
must be nonblank, no more than 256 UTF-8 bytes, contain no control characters,
and not begin with `-`. The provider CLI remains authoritative for whether a
delivered model or reasoning value exists and is valid upstream. Explicit
selections replace equivalent, safely parseable settings already present in a
configured profile while preserving unrelated flags and Toastty's managed
instrumentation. Toastty fails the launch clearly when a wrapper, executable,
or equivalent flag shape is ambiguous instead of risking a conflicting argv.
The live `agent.launch` action descriptor advertises `supportedProfileIDs` on
both parameters so automation can feature-detect this support.

Built-in Codex and Claude automation launches support `initialPrompt` when the
resolved argv is exactly one direct first-party command (`codex`, `cdx`, or
`claude`). Implicit automation profiles for `codex` and `claude` also support
it when no `agents.toml` profile exists. Profiles with extra arguments,
subcommands, wrappers, shell helpers such as `argv = ["scodex"]`, and custom
profiles such as `[gemini]`, must declare
`initialPromptPlacement = "trailing"` before `initialPrompt` is accepted. Pi
launches currently do not support `initialPrompt` unless a profile declares that
placement explicitly.

### Profile ID rules

The TOML table name (the value in `[brackets]`) becomes the profile's internal ID. IDs must be lowercase, start with a letter, and contain only `a-z`, `0-9`, `-`, and `_`.

IDs are used in session telemetry, the automation socket protocol, and — critically — to decide whether Toastty applies agent-specific instrumentation at launch time.

### Shortcut conflicts

If two agent profiles share the same `shortcutKey`, or an agent shortcut conflicts with a terminal-profile shortcut, Toastty disables the conflicting binding and logs a warning on startup or config reload.

## Well-known profile IDs

Toastty recognizes five well-known profile IDs that receive first-party instrumentation: `codex`, `claude`, `opencode`, `mimocode`, and `pi`. Any other ID launches the configured command without agent-specific wiring.

### How matching works

The special handling is keyed on **the profile ID (table name)**, not on the command in `argv`. This is an important distinction:

```toml
[codex]                      # gets Codex instrumentation (ID is "codex")
argv = ["codex"]

[codex]                      # still gets Codex instrumentation (ID is "codex")
argv = ["/usr/local/bin/my-codex-wrapper"]

[my-codex]                   # no special handling (ID is "my-codex")
argv = ["codex"]
```

The profile ID is stored as an `AgentKind` internally. When a launch resolves to `AgentKind.codex`, `AgentKind.claude`, `AgentKind.opencode`, `AgentKind.mimocode`, or `AgentKind.pi`, Toastty activates the corresponding instrumentation path. When the ID is anything else, the command runs as-is with only the base session context injected.

Configured profiles appear in the `Agent` menu, as top-bar buttons, and in the command palette as `Run Agent: <Display Name>`. Add `showTopBarButtons = false` before any profile table to keep configured agent launch buttons out of the top bar while preserving the menu, command palette, and shortcuts.

### Wrapper-compatible launch commands

Built-in Claude, OpenCode, MiMo Code, and Pi instrumentation also works when the configured
command uses a wrapper or prefix command and the actual agent command still
appears as its own `argv` element in a recognized launch shape. Codex uses the
same rule for its existing fallback instrumentation, but injects its managed
skills profile flag only when it can prove the exact Codex executable insertion
point without crossing a `--` boundary. Opaque wrapper or subcommand shapes still
launch with fallback telemetry and without Toastty skills instead of risking a broken command. For predictable
manual tracking of those wrapper executables when you type them into a Toastty
terminal, declare the wrapper basename in `manualCommandNames`. When that field
is present on a built-in profile, Toastty uses that explicit list for the
profile's extra manual wrapper shims instead of inferring additional wrapper
names from `argv[0]`.

Examples:

```toml
[codex]
displayName = "Codex"
argv = [
  "agent-safehouse",
  "--workdir=/Users/name/src/project",
  "codex",
  "--dangerously-bypass-approvals-and-sandbox",
]
manualCommandNames = ["agent-safehouse"]

[claude]
displayName = "Claude Code"
argv = [
  "run-sandboxed.sh",
  "claude",
  "--dangerously-skip-permissions",
]
manualCommandNames = ["run-sandboxed.sh"]

[opencode]
displayName = "OpenCode"
argv = [
  "agent-safehouse",
  "opencode",
]
manualCommandNames = ["agent-safehouse"]

[mimocode]
displayName = "MiMo Code"
argv = [
  "agent-safehouse",
  "mimo",
]
manualCommandNames = ["agent-safehouse"]

[pi]
displayName = "Pi"
argv = [
  "agent-safehouse",
  "pi",
]
manualCommandNames = ["agent-safehouse"]
```

Toastty inserts its agent-specific flags or environment after resolving the actual
`codex`, `claude`, `opencode`, `mimo` / `mimocode`, or `pi` command in those
examples, not after the wrapper binary.

If you prefer shell helpers, menu launches can also target a shell function or
wrapper script directly:

```toml
[codex]
displayName = "Codex"
argv = ["scodex"]
```

That launches from the Agent menu because Toastty sends the rendered command to
your shell. Because Toastty cannot resolve an opaque shell function to a safe
Codex executable before launch, it skips the managed skills profile injection
and keeps fallback telemetry. See the manual-command shim section below for the
additional limitation on typing shell functions directly.

### What `codex` enables

When the profile ID is `codex`, Toastty:

1. **Automatically enables five Toastty skills only for the managed process**. Toastty populates a Toastty-owned plugin cache at `$CODEX_HOME/plugins/cache/toastty/toastty/` (installed through the local Codex CLI against a throwaway Codex home, digest-verified, then swapped in atomically), writes a Toastty-owned profile overlay at `$CODEX_HOME/toastty-managed.config.toml` that enables that cached plugin, and injects `--profile toastty-managed` after the resolved Codex executable. This activates `toastty-capabilities`, `toastty-open-markdown`, `toastty-scratchpad`, `toastty-send-diagnostics`, and `worktree-create` for exactly the flagged process across direct `codex`/`cdx`, resume, fork, and documented wrapper-prefix launch shapes. The overlay's exact full-line Toastty marker establishes ownership wherever it appears; Codex may prepend profile settings, which Toastty preserves along with unrelated TOML content. An existing file without that marker is treated as foreign and is never overwritten. Cache receipts verify the installed plugin bytes but do not determine profile ownership. The user's `config.toml` is never written, and ordinary Codex sessions see no Toastty skills. Injection fails open with no skills when the caller already passes a `--profile` or `-p` flag, when the argv shape is opaque, or when the launch sets a `CODEX_HOME` different from the one Toastty provisioned. Provisioning is fail-open and capped at four seconds; verified installs are reused on later launches through cheap byte checks against receipts under `~/.toastty/agent-plugins/codex/`. A changed bundled version installs immediately, even while other Codex sessions run; existing processes pick up the change after restart. Restored sessions prepare the current bundle before their resume command is submitted, fall back to an older verified cache (reported as stale) when a refresh fails, and launch without skills when nothing verifies. The first provisioning after updating from an older Toastty also removes the retired marketplace-based install through Codex, and surgically deletes the retired mechanism's disabled `toastty:*` `[[skills.config]]` entries from the user's `config.toml` (they would otherwise silently suppress the profile-delivered skills), preserving every other line and writing a timestamped backup under `~/.toastty/agent-plugins/codex/` first. `Toastty > Manage Toastty Skills…` shows delivery statuses for Codex, Claude Code, and the shared Pi/OpenCode/MiMo Code card, all five skill summaries, your user-created skills, manual duplicate guidance, plus Codex status and a Repair control.
2. **Uses installed Codex status hooks when available**. `Toastty > Set Up Agent Status Hooks…` installs a stable Toastty-owned forwarder at `~/.toastty/codex-hooks/forwarder.sh` and adds it to `~/.codex/hooks.json`. Codex may ask you to review and trust that command once; Toastty does not bypass Codex hook trust by default. Skills provisioning never adds, removes, or changes hooks.
3. **Routes Codex hook JSON** through `toastty session ingest-agent-event --source codex-hooks` for `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `PreToolUse`, `SubagentStart`, `SubagentStop`, and `Stop`. These events drive **Working**, actionable **Needs approval**, **Ready**, native resume metadata, and Codex collaboration-agent rows for managed Codex sessions. A recognized `PreToolUse` spawn event also captures the delegated task name and any plaintext description Codex exposes. Newer Codex builds leave the task name readable but may provide the message as opaque ciphertext, which Toastty discards. When session recording context shows Codex is using an auto-reviewer through `approvals_reviewer`, Toastty suppresses the matching auto-reviewed approval prompt instead of surfacing it as a user approval. When the reviewer field is omitted in a resumed session, Toastty treats the permission request as ambiguous instead of immediately showing **Needs approval**.
4. **Creates a notification script when hooks are unavailable** that pipes Codex notification payloads into `toastty session ingest-agent-event --source codex-notify` as a compatibility completion path.
5. **Injects Codex config for the notification fallback** with `-c notify=["/bin/sh", "<script-path>"]` to route notify events through that script.
6. **Enables session recording** by setting `CODEX_TUI_RECORD_SESSION=1` and `CODEX_TUI_SESSION_LOG_PATH=<path>`, and disables Codex enhanced keyboard reporting with `CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT=1` so terminal keyboard modes are not left behind after exit.
7. **Starts local session watchers**. Toastty polls the durable per-launch TUI session log (every 250 ms) for Codex root-turn and auto-review approval context; when hooks are unavailable, that log also provides the compatibility status fallback. After Codex reports native resume metadata, Toastty separately watches that session's native rollout JSONL for collaboration-agent lifecycle and the spawn-tool-to-child-agent identity mapping. When hooks are installed, hooks remain authoritative for collaboration lifecycle, while rollout events provide correlation metadata and a task-label fallback. Toastty joins that mapping with available `PreToolUse` metadata regardless of arrival order. When hooks are unavailable, the rollout watcher also provides the compatibility collaboration-lifecycle fallback.
8. **Filters Codex thread metadata** so spawned subagent hook or notify completions do not clear the parent session's **Working** state. Codex `Stop` hooks must match the latched root thread or root turn before they can mark a managed session **Ready**; `Stop` hooks do not establish the root identity by themselves.
9. **Logs helper delivery failures**. The installed Codex hook forwarder writes failures to `~/.toastty/codex-hooks/telemetry-failures.log`; fallback notify helper failures go to `telemetry-failures.log` inside the durable per-launch artifacts directory.

To remove Toastty's Codex state by hand (for example after deleting the app),
delete the plugin cache subtrees under `$CODEX_HOME/plugins/cache/toastty/` and
`$CODEX_HOME/plugins/cache/toastty-user/`, the `toastty-managed.config.toml`
overlay, and the receipts under `~/.toastty/agent-plugins/codex/`. All of it is
inert for ordinary Codex sessions, and the next managed launch simply
re-provisions whatever is missing; hooks, the user's `config.toml`, unrelated
Codex state, and all globally or repository-locally installed skills are never
part of Toastty's skill state.

Toastty shows one nonblocking notice the first time it successfully provides
skills to each agent. It does not inspect or modify `~/.codex/skills`,
`~/.claude/skills`, or `~/.agents/skills`; if old unnamespaced Toastty skills
appear alongside the `toastty:` entries, remove those global copies manually.

Typed `cdx` launches use the same Codex instrumentation path as typed `codex`
launches when Toastty's managed command shims are enabled.

### What `claude` enables

When the profile ID is `claude`, Toastty:

1. **Adds the five Toastty skills without installing into Claude's user state**. Toastty stages an immutable validated plugin copy and passes it to supported managed launches with an additive `--plugin-dir`. When user-created skills are accepted, Toastty passes a second additive `--plugin-dir` pointing at the immutable user-skills snapshot; user-plugin failures never affect the shipped Toastty skills. Existing user `--plugin-dir` arguments remain in place. After an app update, restored sessions stage the current bundle before the resume command is submitted. If staging fails or the launch shape is opaque, Claude still launches without Toastty skills.
2. **Creates a hook script** that calls `toastty session ingest-agent-event --source claude-hooks`
3. **Resolves existing Claude settings** — if the profile's `argv` includes `--settings`, Toastty reads and merges with those settings rather than replacing them
4. **Injects lifecycle hooks** into the merged Claude settings JSON under `hooks`:
   - `SessionStart` — captures Claude's native session ID, transcript path, and working directory for restored-session resume
   - `UserPromptSubmit` — fires when the user submits a prompt
   - `Stop` — fires when Claude stops
   - `PostToolUse` for `Agent` and `Task` — tracks asynchronously launched Claude subagents with available launch metadata
   - `SubagentStart` — tracks children launched by Claude dynamic workflows
   - `SubagentStop` — removes completed Claude subagent rows
   - `PreToolUse` (wildcard matcher) — fires before any tool use
   - `PermissionRequest` (wildcard matcher) — fires on permission requests
   - `Notification` (wildcard matcher) — fires on Claude notifications; Toastty currently maps `idle_prompt` to **Ready**, `permission_prompt` to **Needs approval**, and `elicitation_dialog` to **Needs approval**
5. **Writes a private process-lifetime settings file** and passes `--settings <path>` to Claude

These hooks report state changes that Toastty translates into sidebar status (working, needs approval, ready). `SessionStart` also persists Claude native resume metadata so restored managed Claude panels can run `claude --resume <session-id>` instead of starting a fresh session. Non-actionable notifications such as `auth_success` are ignored.
When the helper script cannot deliver a hook event back to Toastty, it appends the CLI error to `telemetry-failures.log` inside the durable per-launch artifacts directory, but still exits successfully so Claude keeps running. Toastty keeps the directory available for the owning Claude process and removes it only after the session is inactive and that process is proven to have exited.

### What `opencode` and `mimocode` enable

When the profile ID is `opencode` or `mimocode`, Toastty:

1. **Creates a temporary OpenCode-compatible plugin** inside the per-session launch artifacts directory. Toastty does not write to `.opencode`, `.mimocode`, or global provider config files.
2. **Injects the plugin through provider config content**. OpenCode launches receive `OPENCODE_CONFIG_CONTENT`; MiMo Code launches receive `MIMOCODE_CONFIG_CONTENT`. If a launch environment already sets the matching config-content variable, Toastty does not overwrite it and launches without status instrumentation.
3. **Adds the five Toastty skills through the same config content**. Toastty extends that JSON blob with a `"skills": {"paths": [...]}` entry (plain absolute paths, never `file://`) pointing at the same staged shipped-skills tree used for Claude's `--plugin-dir` and, when user-created skills are accepted, the same staged user-skills snapshot — no new staging, caches, or config files. Because opencode and mimocode replace the `skills` object wholesale across config layers rather than merging it, a user's own `skills.paths` entries in global or project config are shadowed for the duration of a managed session (the `plugin` and `instructions` arrays in the same blob still merge normally). A discovered skill of the same name elsewhere in opencode/mimocode's discovery locations can win or lose against Toastty's injected copy nondeterministically, run to run. This collision is real in practice: repositories that mirror the shipped skills into `.agents/skills` (Toastty's own repos do), or home-level copies such as `~/.agents/skills/worktree-create`, collide with the injected set by name — harmless when the copies carry the same content, unpredictable when they diverge. The skills sheet's duplicate guidance covers removing stale copies. MiMo Code also auto-discovers project `.opencode/skills`, `.claude/skills`, `.agents/skills`, and `.mimocode/skills`, plus those same four directories and `~/.codex/skills` under `$HOME`, independent of anything Toastty injects.
4. **Reports status through** `toastty session ingest-agent-event --source opencode-plugin` or `--source mimocode-plugin`. Toastty maps `session.status`, `session.idle`, `permission.asked`, `permission.replied`, and `session.error` into sidebar **Working**, **Ready**, **Needs approval**, and **Error** states.
5. **Tracks direct provider sub-sessions** after the root session identity is known. Direct children appear as sidebar child rows, receive model updates from their own assistant-message metadata, and are removed on child or root termination. Nested descendants are intentionally not projected onto the root. Recognized effort-named model variants such as `low`, `medium`, `high`, and `xhigh` appear as reasoning effort; arbitrary custom variant names are omitted instead of being presented as an effort level.
6. **Captures native resume metadata** when plugin hooks expose a provider session ID. An explicit `--session` / `-s` launch argument seeds an initial root-identity hint, which the first root message or root-creation event confirms or replaces; fresh launches claim the same identity from those hooks. The plugin writes a Toastty-owned per-session marker under `~/.toastty/managed-agent-resume/` (or `<runtime-home>/managed-agent-resume/` for isolated runs) and reports only the native session ID, marker path, and working directory back to Toastty.
7. **Logs helper delivery failures** to `telemetry-failures.log` inside the temporary launch artifacts directory. The plugin logs event type, session context, exit status, and CLI stderr; it does not write full provider event payloads to the failure log.

Capability evidence: `docs/plans/evidence/opencode-session-scoped-skills-2026-08-05.md` and `docs/plans/evidence/mimo-session-scoped-skills-2026-08-05.md`.

Typed `opencode`, `mimo`, and `mimocode` launches use the same instrumentation path when Toastty's managed command shims are enabled. The built-in `mimocode` shim falls back to the real `mimo` executable when no `mimocode` executable exists on `PATH`.

### What `pi` enables

When the profile ID is `pi`, Toastty:

1. **Injects a bundled Toastty-owned Pi extension** with `--extension <toastty-pi-extension.js>`. Toastty does not install files into Pi's user extension directories.
2. **Adds the five Toastty skills through repeatable `--skill` flags**. Toastty inserts `--skill <shipped skills tree>` and, when user-created skills are accepted, `--skill <user skills snapshot tree>` at the same insertion point as its extension flag — the same staged trees used for Claude's `--plugin-dir`, no new staging. Injection is skipped, fail open, when the caller's argv already contains `--no-skills` or `-ns`, or when the launch shape is opaque; a caller-supplied `--skill` flag is left in place and Toastty's own flags are additive. Pi auto-discovers skills from `<cwd>/.pi/skills`, `.agents/skills` in `cwd` and every ancestor directory up to the enclosing git root, `$PI_CODING_AGENT_DIR/skills` (default `~/.pi/agent/skills`), and `~/.agents/skills`; a same-named discovered skill silently wins over an injected `--skill`, with no visible diagnostic in non-interactive mode. Pi also only surfaces injected (and discovered) skills to the model when the `read` tool is enabled — a `--tools` allowlist that omits `read` makes them invisible even though they still loaded.
3. **Preserves user extensions**. User-provided `--extension` / `-e` arguments remain in `argv`; Pi treats extensions as additive, so Toastty adds its extension alongside them.
4. **Respects Pi extension opt-out flags**. If `--no-extensions` or `-ne` appears before `--`, Toastty does not inject its Pi extension for that launch.
5. **Reports compact telemetry** through `toastty session ingest-agent-event --source pi-extension`, covering the submitted prompt, final assistant summary, semantic tool-call progress, tool errors, and changed-file paths when Pi exposes them. Successful tool results update changed-file metadata without replacing the sidebar with generic `Finished ...` messages.
6. **Captures native resume metadata** from Pi's extension context, including the native session ID, session file path, and working directory.
7. **Tracks the standard Pi `subagent` extension when it is observable**. Single and parallel invocations create one child row per unambiguous task and add the model reported by Pi's streamed result metadata. Sequential chains reuse one row for the currently reported step so future steps are not shown as concurrently running. Pi's standard result contract does not expose a child thinking level, so Toastty does not infer one. Other custom subagent tools remain untracked unless they emit the same exact lifecycle metadata.
8. **Avoids prompt and tool-output forwarding**. The extension records bounded metadata only and is a no-op outside Toastty when required `TOASTTY_*` environment variables are absent.

Capability evidence: `docs/plans/evidence/pi-session-scoped-skills-2026-08-05.md`.

## User-created skills

Alongside the five shipped skills, Toastty delivers your own skills to managed
Codex, Claude Code, OpenCode, MiMo Code, and Pi sessions.

- **Authoring**: create `~/.toastty/skills/<name>/SKILL.md` with YAML
  frontmatter containing `name` and a non-empty `description`. The directory
  name must match the frontmatter name exactly: lowercase letters, digits, and
  hyphens only, at most 64 characters. A package may contain additional
  supporting files and folders next to `SKILL.md`. User skills are user
  state: runtime-isolated dev instances (worktree-derived or explicit runtime
  homes) read the same real `~/.toastty/skills` source, while their
  snapshots, staging, and receipts stay isolated under the runtime home.
  Automated harnesses that need full isolation set `TOASTTY_USER_SKILLS_ROOT`
  in the app's environment to redirect the source directory.
- **Validation**: hidden directories (names starting with `.`) are ignored.
  Symbolic links and special files are rejected. Per-package caps are 5 MB and
  a folder depth of 8, with `SKILL.md` itself capped at 256 KB. Catalog-wide
  caps are 32 accepted packages, 10 MB, and 500 files; breaching a catalog-wide
  cap excludes all user packages until the total shrinks. Excluded packages
  never affect the shipped Toastty skills. Run
  `"$TOASTTY_CLI_PATH" setup skills list` for the same read-only inventory and
  exclusion diagnostics shown in the management sheet.
- **Delivery**: accepted packages are snapshotted into an immutable,
  content-addressed `toastty-user` plugin under `~/.toastty/agent-plugins/user/`
  (version `0.1.0-<hex12>`). Managed Codex launches receive it through the same
  `toastty-managed` profile overlay and a `$CODEX_HOME/plugins/cache/toastty-user/`
  cache; managed Claude Code launches receive it through a second additive
  `--plugin-dir`; managed OpenCode and MiMo Code launches receive it through a
  second entry in the same `skills.paths` array as the shipped tree; managed
  Pi launches receive it through a second `--skill` flag. New or changed skills
  appear in subsequently launched managed sessions — running sessions keep the
  skills they launched with. As with the shipped plugin, a changed set installs
  immediately even while sessions run: the on-disk cache bytes are swapped
  under a running session, whose already-loaded skill instructions persist in
  memory while file-backed skill scripts it invokes later may reflect the newer
  set. Removing every user skill converges the same way — the snapshot is
  invalidated and subsequently launched managed sessions receive no user
  skills. Ordinary (non-managed) sessions of any of these agents see nothing.
- **Management**: the user section of `Toastty > Manage Toastty Skills…` lists
  each package with its accepted or excluded status, offers `Rescan`, and can
  open or create the user skills folder.
- A startup sweeper deletes superseded snapshots under
  `~/.toastty/agent-plugins/`, keeping the newest snapshot plus one previous
  verified fallback.

## Launch flow

When you trigger an agent launch (menu click, top-bar button, command palette submission, keyboard shortcut, or socket command):

1. **Resolve target** — Toastty picks the focused terminal panel in the selected workspace, or falls back to the first terminal panel in the workspace
2. **Check panel state** — The panel must be at an interactive prompt; Toastty asks Ghostty for the surface prompt state and refuses to launch into a panel that appears busy
3. **Prepare instrumentation** — Based on the profile ID, Toastty sets up agent-specific scripts, config files, and environment variables. Files that Claude or Codex can revisit use a private durable per-launch directory; startup-scoped OpenCode, MiMo Code, and Pi artifacts remain temporary
4. **Render shell command** — Toastty builds a single shell command line with any explicit `cd <cwd>` and initial setup commands first, then all `TOASTTY_*` context variables inline, the instrumentation environment, and the profile's `argv`
5. **Start session** — A session record is created in the session runtime store with initial status "Idle / Ready for prompt"
6. **Send to terminal** — The rendered command line is sent to the target terminal panel and submitted
7. **Begin monitoring** — For Codex, trusted installed hooks report primary status, the session log watcher tracks root-turn context, and notify/session recording own telemetry for the full launch when hooks are untrusted or unsupported; for Claude, hooks report events back through the CLI; for OpenCode and MiMo Code, the temporary plugin reports status events back through the CLI; for Pi, the bundled extension reports events back through the CLI

When the agent process exits and the session is stopped, Toastty cleans up OpenCode, MiMo Code, and Pi launch artifacts immediately. Claude and Codex per-launch directories are swept conservatively after the session becomes inactive: Toastty requires an owner marker, a grace period, and proof that the recorded process ID is no longer present. Live or ambiguous PIDs are preserved, including possible PID reuse.

### Restore and native resume

For managed Codex, Claude, OpenCode, MiMo Code, and Pi launches, Toastty also
records the provider's native session ID, session file path or Toastty-owned
marker path, working directory, and capture time in the workspace layout. If the
managed session is workspace-scoped, Toastty stores the explicit scope with the
same native resume record so app restart restores the scoped session instead of
widening it. Codex records are reported by hooks when available and can fall
back to provider session-file discovery; Claude records are reported by the
per-launch `SessionStart` hook and can fall back to provider session-file
discovery; OpenCode and MiMo Code records come from their temporary Toastty
plugin; Pi records come from the bundled Pi extension. When a restored terminal
panel has a valid record, Toastty runs the provider resume command for that
native session instead of starting a fresh profile command. Claude resumes with
`claude --resume <session-id>`, OpenCode and MiMo Code resume with
`opencode --session <session-id>` and `mimo --session <session-id>`, and Pi
resumes with `pi --session <session-file-path>`.

Before resuming, Toastty validates that both the recorded session file and
working directory still exist. If either is missing, Toastty clears the stale
record and falls back to normal terminal startup. If observation of a later
launch times out or cannot safely disambiguate simultaneous same-agent,
same-directory launches, Toastty leaves any existing record unchanged rather
than replacing it with an uncertain session.

## Manual command shims

Outside the Agent menu, Toastty can also track manual `codex`, `cdx`, `claude`,
`opencode`, `mimo`, `mimocode`, and `pi`
invocations typed directly into Toastty terminals. By default, Toastty prepends
managed wrappers for those commands into the terminal `PATH`, and those wrappers
prepare the same managed-session context before handing off to the real binary.
For Codex, the typed shim automatically prepares the same session-only skills
as a UI launch and runs the same status-hook preflight. If hooks still need
first-time setup or cannot be verified, Toastty shows the setup warning before
the real Codex process starts. Choosing **Set Up Hooks** in that warning installs
the hooks and continues the original launch; an installation failure is reported
without starting Codex. Skills provisioning itself never prompts or blocks the
launch. Once Toastty owns the hook entries, routine hook maintenance runs
automatically in the background.
`manualCommandNames` only controls extra executable
names Toastty should intercept; it does not control status-hook setup.

If you are setting this up from inside the app, the top-bar `Get Started…`
button opens the Getting Started panel. Use `Toastty > Install Shell
Integration…` for automatic setup, or copy the panel's manual setup command.

If a built-in `[codex]`, `[claude]`, `[opencode]`, `[mimocode]`, or `[pi]` profile uses extra wrapper executables for
typed launches, list those wrapper basenames in `manualCommandNames`. Entries
must be basenames only, with no paths or spaces, and must not be built-in
profile IDs such as `codex`, `claude`, `opencode`, `mimocode`, or `pi`. Toastty
installs managed wrappers for those names too, so commands such as
`run-sandboxed.sh claude ...`, `agent-safehouse codex ...`,
`agent-safehouse opencode ...`, `agent-safehouse mimo ...`, or
`agent-safehouse pi ...` can start managed sessions when typed directly in a
Toastty terminal.

If you leave `manualCommandNames` empty, Toastty still keeps recognizing simple
built-in wrapper-prefix profiles for compatibility, such as
`run-sandboxed.sh claude ...`, `agent-safehouse codex ...`, or
`agent-safehouse mimo ...`.

`manualCommandNames` is limited to built-in `[codex]`, `[claude]`, `[opencode]`,
`[mimocode]`, and `[pi]` profiles, and the wrapper command still needs to leave
the real `codex`, `claude`, `opencode`, `mimo` / `mimocode`, or `pi` command
visible later in `argv`. Toastty uses that later `argv` element to pick the
correct built-in instrumentation path.

Shell functions and aliases are different: they are resolved by the shell before
`PATH` lookup, so Toastty's managed command shims cannot intercept them.
This means:

- Agent menu launches can use shell functions such as `scodex` or `sclaude`
  because Toastty sends text to the shell.
- Typing `scodex` or `sclaude` manually into a terminal pane will not start a
  managed Toastty session unless those names are real executables on `PATH` and
  are listed in `manualCommandNames`.
- A shell helper can still lead to a managed session if its body calls a
  shimmed executable by bare name on `PATH`, such as
  `run-sandboxed.sh claude ...`.
- Standalone wrapper executables that hide `codex`, `claude`, `opencode`, `mimo`,
  `mimocode`, or `pi` inside the
  wrapper implementation are not supported for manual typed launches. For
  manual tracking, keep the real agent command as its own `argv` element in the
  configured wrapper chain.

If you do not want Toastty intercepting those commands, set this in
`~/.toastty/config`:

```toml
enable-agent-command-shims = false
```

For the full Toastty config reference, including the other supported keys in
`~/.toastty/config`, see [Configuration](configuration.md).

That opt-out affects only manual built-in agent invocations inside Toastty
terminals, including wrapper executables declared through
`manualCommandNames`. Agent menu launches still use the built-in
profile-ID-based instrumentation described above.

If you change this flag while Toastty is already running, new terminals and new
shell processes pick it up immediately. Existing shells may need a new shell or
pane before their `PATH` and `TOASTTY_AGENT_SHIM_DIR` environment fully match
the new setting.

## Session context environment

Every agent launched through Toastty receives these environment variables, set inline in the rendered shell command:

| Variable | Description |
|---|---|
| `TOASTTY_SESSION_ID` | Unique session UUID |
| `TOASTTY_PANEL_ID` | UUID of the terminal panel the agent was launched into |
| `TOASTTY_SOCKET_PATH` | Path to Toastty's automation Unix socket. Built-in Claude, Codex, OpenCode, MiMo Code, and Pi helpers use this explicit value directly rather than relying on CLI socket discovery fallback. |
| `TOASTTY_CLI_PATH` | Path to the bundled `toastty` CLI executable |
| `TOASTTY_AGENT` | Managed provider ID. The `worktree-create` skill preserves `codex` or `claude` when it launches the handoff session. |
| `TOASTTY_CWD` | Resolved launch working directory: explicit automation `cwd` when supplied, otherwise the target or restored panel working directory when available |
| `TOASTTY_REPO_ROOT` | Git repository root inferred from the resolved launch working directory when available |
| `TOASTTY_SKILLS_ROOT` | Delivered shipped Toastty plugin `skills/` path for supported managed Codex, Claude Code, OpenCode, MiMo Code, and Pi launches (the verified Toastty-owned Codex plugin cache, or the immutable staged plugin copy also reused for Claude's `--plugin-dir`, pi's `--skill`, and OpenCode/MiMo Code's `skills.paths`); set only when the shipped tree was actually injected, absent when preparation, verification, or safe argument/config insertion is unavailable. Reserved and read-only for agents; never write into it |
| `TOASTTY_USER_SKILLS_ROOT` | User skill-package source directory (the real `~/.toastty/skills` even for runtime-isolated instances). Advertised on managed launches so agents can create user skills there on request; the directory is not created automatically. Setting the same variable in the app's own environment overrides the source directory — the isolation escape hatch automated harnesses use |
| `TOASTTY_MANAGED_ARTIFACT_OWNER_FILE` | Internal owner-marker path for Claude and Codex process-lifetime launch files. Toastty helpers maintain this marker for conservative cleanup. Reserved and read-only for agents. |

Agent-specific variables are added on top of these (for example, `CODEX_TUI_RECORD_SESSION` and `CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT` for Codex launches).

## Notifications and badges

Actionable lifecycle events — `needs_approval`, `ready`, and `error` — drive:

- **Unread badges** on the workspace tab in the sidebar
- **macOS desktop notifications** (if the user has granted notification permission)

While a managed agent session is active, Toastty suppresses overlapping terminal-originated desktop notifications for that panel so the session status path stays authoritative.

### Nested sessions and background activity

When a managed session launches another managed agent through Toastty automation,
Toastty records the launching session as the parent. Child sessions in the same
workspace appear beneath that parent as expandable sidebar rows instead of
duplicating the same work at the top level. A child in another workspace keeps
its canonical row there and receives a parent label for context.

The same child-row surface includes provider-reported background activity, such
as a Codex collaboration agent or a Claude in-process subagent. Child rows show
their provider status when available, and parent rows expand automatically when
a child needs approval or reports an error. A parent can also show a waiting
projection while children or other background tasks are still outstanding, so a
brief ready/idle event does not make an orchestration wave look complete. A
short resuming grace period prevents stale ready state from flashing between
waves. The child-row tooltip shows a detected model identifier and reasoning
effort when the owning provider exposes them with a stable child identity.
Missing values are omitted; Toastty does not fill gaps from the parent model or
from a prompt-derived guess.

For Codex, `SubagentStart` and `SubagentStop` hooks are the authoritative source
for collaboration-agent rows when trusted session hooks own telemetry. Session-recording
events correlate the spawn tool-use ID with the child agent ID; the matching
`PreToolUse` hook supplies the delegated task name and any available plaintext
description. Toastty
keeps a small bounded pending join so either event may arrive first, but metadata
cannot create, reopen, or finish a row. In fallback-owned sessions,
session-recording events provide the compatibility lifecycle fallback and may
still supply the label or a plaintext description. Newer Codex builds encrypt
delegated task messages while leaving the task name readable; opaque ciphertext
payloads are dropped whether they arrive via hook `tool_input` or the session
recording, so the named row shows no description rather than ciphertext. This
avoids duplicate rows and lets hook-tracked agents remain visible until Codex
reports their completion. If the root is ready or idle but a trusted
`SubagentStop` hook was missed, Toastty can reconcile the row from the exact
provider-thread child rollout. This recovery path accepts only a top-level
`task_complete` or `turn_aborted` event timestamped at or after that child's
most recent `SubagentStart`; it ignores older terminal history and does not
finish rows from a timeout or inferred message text.

For Claude, asynchronous `Agent` and `Task` results create labeled subagent
rows and include Claude's resolved child model when the launch response provides
it; Claude's hook payload does not currently provide child effort. `SubagentStop`
removes the rows. Dynamic Workflow results do not expose
their child IDs, so `SubagentStart` creates one generic row per Workflow child;
those lifecycle-owned rows remain visible through Claude's aggregate Workflow
snapshot until their matching `SubagentStop` events arrive.

Toastty-owned provider integrations report this activity through the internal
`session background-activity` CLI command and `session.background_activity`
socket event. Custom agents should normally use the ordinary `session status`,
`session update-files`, and `session stop` commands instead.

### Later flags

Use `Cmd+Shift+L` to flag or clear the focused managed session for later follow-up.

Later flags are intentionally a lower-priority reminder, not a pin. When you use `Cmd+Shift+A`, Toastty first targets unread panels, then sessions that need approval or show errors, then forward working sessions. Later-flagged sessions only surface after those higher-priority cases are exhausted.

Toastty also clears the later flag automatically when the session meaningfully advances. In practice that means the flag goes away when the session resumes working from a non-working state or transitions into a new actionable state such as `needs_approval`, `ready`, or `error`.

### Watch running commands

Use `Cmd+Shift+M` while the focused terminal is running a foreground command to watch that command as a temporary session-style row in the sidebar.

This is separate from managed agent launches. Toastty uses the same unread-badge and desktop-notification path for watched commands, reporting success as `Command finished` and non-zero exits as `Command failed`. The watch stays tied to that terminal panel until the foreground command completes.

Watched commands are intentionally not later-flaggable. The watch itself is already the reminder, so Toastty hides the later-flag affordance for those rows instead of stacking both features on the same panel.

## Custom and third-party agents

For agents that are not one of Toastty's built-in instrumented IDs (`codex`, `claude`, `opencode`, `mimocode`, or `pi`), Toastty still provides the base `TOASTTY_*` session context. Toastty has already created the session before your command starts, so the agent (or a wrapper script) should update and stop that existing session via the injected `TOASTTY_CLI_PATH`:

```bash
"$TOASTTY_CLI_PATH" session status --session "$TOASTTY_SESSION_ID" --kind working --summary "Thinking"
"$TOASTTY_CLI_PATH" session update-files --session "$TOASTTY_SESSION_ID" --file changed.txt
"$TOASTTY_CLI_PATH" session stop --session "$TOASTTY_SESSION_ID"
"$TOASTTY_CLI_PATH" notify "Done" "Agent finished"
```

Manual integrations can report any supported session state, including `error`, through `session status --kind ...`.

The `toastty session ingest-agent-event` subcommand is a CLI-local helper for built-in Claude, Codex, OpenCode, MiMo Code, and Pi instrumentation. It is not a general-purpose integration point.

## Instructions for agents

If a user asks you to help configure Toastty agent profiles, your goal is to produce or update `~/.toastty/agents.toml` with valid launch profiles that match the user's local setup.

### Recommended workflow

1. Check whether `~/.toastty/agents.toml` already exists. If it does, inspect and preserve existing profiles unless the user explicitly wants a replacement.
2. Try to detect locally installed coding agents using best-effort heuristics such as checking the user's `PATH`, common wrapper scripts, or explicit executable paths the user mentions.
3. Prefer Toastty's well-known profile IDs when they apply:
   - Use profile ID `codex` when the launch command is Codex
   - Use profile ID `claude` when the launch command is Claude Code
   - Use profile ID `opencode` when the launch command is OpenCode
   - Use profile ID `mimocode` when the launch command is MiMo Code, even when the executable is `mimo`
   - Use profile ID `pi` when the launch command is Pi
4. For any other agent, choose a lowercase ID that matches Toastty's ID rules and reflects the command being launched, such as `gemini` or `amp`.
5. Propose the exact `agents.toml` contents to the user before writing the file. Confirm profile IDs, display names, launch commands, and optional shortcuts.
6. Only create or update `~/.toastty/agents.toml` after the user confirms.

### Discovery guidance

Discovery is heuristic. Do not claim that Toastty can authoritatively identify every installed agent.

When probing a system, prefer evidence in this order:

1. Commands already mentioned by the user
2. Existing `~/.toastty/agents.toml` entries that should be preserved or extended
3. Executables available on the user's `PATH`
4. User-specific wrapper scripts or absolute executable paths

Common launch commands you may encounter include:

| Agent | Typical command | Suggested profile ID |
|---|---|---|
| Codex | `codex` | `codex` |
| Claude Code | `claude` | `claude` |
| OpenCode | `opencode` | `opencode` |
| MiMo Code | `mimo` or `mimocode` | `mimocode` |
| Pi | `pi` | `pi` |
| Gemini CLI | `gemini` or `gemini-cli` | match the executable name |
| Aider | `aider` | `aider` |
| Custom wrapper | absolute path or script name | stable lowercase ID that matches the wrapper |

The command you detect should usually become the first element of `argv`. For agents other than Toastty's built-in instrumented IDs, prefer using the executable name as the profile ID when that produces a valid Toastty ID. Include additional fixed flags in later array entries only when the user wants them every time Toastty launches that profile.

### Generation rules

Generate TOML that follows the same schema documented above:

- `displayName` should be a readable label for menus and toolbar buttons
- `argv` must be a TOML string array
- `shortcutKey` is optional and must be a single ASCII letter or digit

Remember that only the profile IDs `codex`, `claude`, `opencode`, `mimocode`, and `pi` receive first-party Toastty instrumentation. If you launch one of those agents under another ID, the command still runs, but Toastty will not inject the built-in session hooks for that agent.

### Example suggestion

If you detect both Codex and Claude Code on the user's `PATH`, a reasonable proposal is:

```toml
[codex]
displayName = "Codex"
argv = ["codex"]
shortcutKey = "c"

[claude]
displayName = "Claude Code"
argv = ["claude"]
shortcutKey = "l"
```

If the user confirms, you can create or update `~/.toastty/agents.toml` with the agreed contents.

## Troubleshooting

**"No agents configured"** — `~/.toastty/agents.toml` does not exist or has no uncommented profiles. Open `Agent > Manage Agents...` inside Toastty to create or edit it.

**"The target terminal is not at an interactive prompt"** — Toastty asks Ghostty whether the terminal surface is currently at a prompt. Wait for the current command to finish, or use a different panel.

**Agent launches but sidebar does not update** — If the profile ID is not `codex`, `claude`, `opencode`, `mimocode`, or `pi`, Toastty does not inject instrumentation automatically. Either use a well-known profile ID or report status manually via the `toastty` CLI. For OpenCode and MiMo Code, an existing `OPENCODE_CONFIG_CONTENT` or `MIMOCODE_CONFIG_CONTENT` value makes Toastty preserve the caller's config and skip its status plugin. For Pi, `--no-extensions` and `-ne` intentionally disable Toastty's injected extension for that launch.

**Shortcut does not work** — Check for conflicts with other agent or terminal-profile shortcuts. Toastty logs a warning when it detects a conflict.

**Claude settings conflict** — If your Claude profile includes `--settings` pointing to a file, Toastty merges its hooks into those settings. If the settings argument is malformed or the file cannot be read, Toastty logs a warning and launches without instrumentation.

**Telemetry helper failures** — For Codex's stable session-hook forwarder, inspect `~/.toastty/codex-hooks/telemetry-failures.log`. Claude and Codex per-launch helper failures live under `~/.toastty/run/managed-agent-launches/<session>/telemetry-failures.log` (or the equivalent runtime-isolated path). OpenCode and MiMo Code use their temporary per-session launch directories, and Pi writes compact `pi-telemetry.jsonl` while the session is active. The helper scripts keep the agent process running, but they preserve socket and CLI stderr instead of discarding it.
