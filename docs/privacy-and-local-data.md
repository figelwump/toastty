# Toastty Privacy and Local Data

Toastty is designed to run locally on your machine. The app itself does not send usage analytics or cloud telemetry.

## What Toastty writes locally

- `~/.toastty/config`
  - User-authored Toastty defaults such as `terminal-font-size`, `default-terminal-profile`, `enable-agent-command-shims`, `agent-hook`, and URL-opening preferences.
- `~/.toastty/config-reference`
  - Generated commented reference for every supported Toastty config key. Toastty rewrites this file on launch and when you open `Toastty > Open Config Reference…`.
- `~/.toastty/bin/` for ordinary runs, or `<runtime-home>/run/managed-agent-helpers/instance-<uuid>/` for each runtime-isolated app process when agent command shims are enabled
  - Managed `codex`, `cdx`, `claude`, `cursor-agent`, `opencode`, `mimo`, `mimocode`, and `pi` wrapper symlinks used to track manual agent invocations inside Toastty terminals. Toastty never creates a generic `agent` wrapper. Runtime-isolated processes also refresh compatibility wrappers under `<runtime-home>/bin/`, while their terminals use the immutable per-instance directory.
- macOS `UserDefaults` for Toastty
  - Small UI-managed settings such as the post-agent-launch sidebar default latch, plus any one-time legacy migration state.
- `~/.toastty/terminal-profiles.toml`
  - Named terminal profile definitions loaded at startup and on config reload.
- `~/.toastty/command-palette-usage.json`
  - Local per-command usage counts used only to rank command-palette results.
- `~/.toastty/workspace-layout-profiles.json`
  - Saved workspace and window layout snapshots, including window-local sidebar
    widths, window-local terminal font overrides, window-local local-document
    text-size overrides, per-browser page zoom overrides, persisted workspace
    annotation chips (`key`, chip text, and optional `http`/`https` URL per
    workspace, written by `workspace.set-annotation` callers such as agents and
    hook scripts), and managed agent
    native-resume metadata for restored Codex, Claude, OpenCode, MiMo Code, and Pi panels. Native-resume
    metadata can include the provider, provider-native session ID, provider
    session file path or Toastty-owned marker path, working directory, capture
    timestamp, and any explicit workspace-scope identifiers needed to restore a
    scoped session after app restart.
  - Ordinary launches read and write one canonical layout across display
    changes. When Toastty first migrates an older display-specific store, it
    copies the most recently updated valid display layout into the canonical
    profile and retains the legacy display profiles as local recovery copies.
    If that replaces an older `default` profile, the older profile is also
    preserved under a recovery-only profile ID before migration completes.
    Explicit `TOASTTY_LAYOUT_PROFILE` overrides remain isolated and do not fall
    back to the canonical user layout.
- `~/.toastty/annotation-styles.json`
  - The global annotation color map: one named or `#RRGGBB` color token per
    annotation key, shared across workspaces and layout profiles. First use
    records automatic as well as explicit colors so a live key cannot be
    recolored by another annotation call. Contains only keys and color tokens,
    never chip text or URLs. Runtime-isolated instances keep their own copy
    inside the runtime home.
  - The read-only `annotation.keys` app-control query exposes all registered
    key strings in the current runtime, including historical keys, to
    automation callers even when a managed session is workspace-scoped. Keys
    are caller-authored and may contain sensitive semantic labels. The query
    does not expose the stored colors, workspace IDs, usage counts, chip text,
    or URLs.
  - To remove a mistakenly disclosed historical key, quit every Toastty
    instance using that runtime home, remove that key's entry from
    `annotation-styles.json`, and relaunch Toastty. Do not edit the file while
    Toastty is running because the in-memory registry remains authoritative.
- `~/.toastty/recent-right-panel-items.json`
  - The locally persisted Recently Opened list for right-panel browsers, local
    document paths, and Scratchpad document IDs/titles. The list contains up to
    20 items and may contain URLs or local paths that identify the supporting
    material you opened.
- `~/.toastty/remote-access/devices.json`
  - Paired-device IDs, names, browser/native kind, scopes, timestamps,
    revocation state, and SHA-256 hashes of device credentials. Native records
    also contain the exact Tailscale login used for identity binding. Persistent
    native pairing-failure state is keyed by that identity so brute-force
    lockouts survive gateway restarts. Toastty never persists the credential
    tokens handed to browsers or native apps. The file and its parent directory
    use owner-only permissions (0600 file in a 0700 directory).
- `~/.toastty/remote-access/audit.json`
  - Up to 500 recent remote-access security and lifecycle events, including
    timestamps, action names, device IDs, and bounded non-identifying reason
    codes where relevant. It does not contain device names, message text,
    prompts, transcript content, credential values, pairing proofs, Tailscale
    logins, or gateway hostnames. The file and its parent directory use
    owner-only permissions.
- `~/.toastty/managed-agent-resume/`
  - Toastty-owned marker files for OpenCode and MiMo Code native resume records.
    Marker filenames are derived from hashed resume metadata. Marker contents
    include only provider plugin source, marker format version, and capture
    timestamp; the marker files do not store prompts, tool output, native
    session IDs, or working directories.
- `~/.toastty/scratchpad-documents/`
  - One JSON file per Scratchpad document, including the document ID, revision, title metadata, optional live-session link metadata, and HTML content. Individual Scratchpad content is limited to 1,048,576 UTF-8 bytes.
- `~/.toastty/shell/` (created by `Toastty > Install Shell Integration…`)
  - Managed shell-integration snippets. The installer also appends a `source` line to your shell init file (`~/.zshrc` for zsh, `~/.bash_profile` or `~/.profile` for bash, `~/.config/fish/config.fish` for fish).
- `~/.toastty/hooks/agent-hook`
  - An executable but inert, fully commented starter template that Toastty creates once and never overwrites. Toastty invokes it only when the user points the `agent-hook` config key at this path or another trusted executable.
- `~/.toastty/skills/` (created only through `Toastty > Manage Toastty Skills…` or by the user)
  - User-authored skill packages (`<name>/SKILL.md` plus supporting files). Toastty scans this directory read-only. Anything you (or an agent acting on your request) put here becomes agent-visible instructions in managed Codex, Claude Code, Cursor, OpenCode, MiMo Code, and Pi sessions, and is copied into the snapshot and cache locations below.
- `~/.toastty/agent-plugins/codex/`
  - Per-Codex-home receipt sidecars under `homes/<key>/` recording the verified plugin cache identity, so later managed launches can byte-verify without running Codex. A custom `CODEX_HOME` receives its own hashed `homes/<key>/` entry.
  - These receipts validate cached plugin bytes; they do not establish ownership of the managed profile file.
- `~/.toastty/agent-plugins/claude/`
  - Immutable validated Toastty plugin copies staged once and passed to managed Claude Code and Cursor processes with `--plugin-dir`. The Cursor manifest includes a bundled hook forwarder that activates only with complete managed Cursor session context. The same staged `skills/` subtree is also the source Toastty points managed Pi (`--skill`), OpenCode, and MiMo Code (`skills.paths` inside their config-content JSON) launches at directly — Cursor/Pi/OpenCode/MiMo Code delivery introduces no separate copy and no new on-disk location. Toastty does not register these copies in Claude's or Cursor's user configuration, and nothing is written to Cursor's, Pi's, OpenCode's, or MiMo Code's own config or data directories; the tree is only ever referenced per launch via an argv flag (Cursor, Pi) or per-launch environment JSON (OpenCode, MiMo Code).
- `~/.toastty/agent-plugins/user/`
  - Immutable content-addressed snapshots of the accepted user skill packages, built from `~/.toastty/skills/` and delivered only to managed launches (Claude and Cursor via a second additive `--plugin-dir`, Codex via the cache below, Pi via a second `--skill` flag, and OpenCode/MiMo Code via a second entry in the same `skills.paths` array), again with no separate copy or new write location per runtime.
  - A startup sweeper deletes only Toastty-owned artifacts under `~/.toastty/agent-plugins/` — superseded user snapshots and staged Claude plugin copies beyond the currently delivered one plus one previous verified fallback, and aged staging orphans. Receipts under `codex/homes/` are kept.
- `~/.toastty/codex-hooks/` (created by `Toastty > Set Up Agent Status Hooks…`)
  - A stable Codex hook forwarder script plus `telemetry-failures.log` when the forwarder cannot deliver hook events back to Toastty.
- `~/.toastty/run/managed-agent-launches/`
  - Owner-only per-launch directories for Claude and Codex files that their
    processes can revisit after startup. Claude directories contain the merged
    settings JSON, hook script, and any helper failure log. Codex directories
    contain the TUI session record, a fallback notification script when needed,
    and any helper failure log. These files contain launch configuration and
    bounded telemetry context, but not a separate copy of the provider
    transcript.
  - Toastty records the owning process ID in a private marker: the launch shim
    records the exact spawned Codex process, while Claude's launch helper uses
    Claude's reported process ID. Toastty removes a directory only after its
    managed session is inactive, a grace period has elapsed, and the recorded
    process ID is no longer present. A live or ambiguous PID is preserved rather
    than guessed about, including possible PID reuse. If this durable location
    cannot be used safely,
    Toastty falls back to the system temporary directory and then, if
    preparation still fails, launches without instrumentation.
- Toastty-owned files inside `$CODEX_HOME` (written automatically for supported managed Codex launches)
  - `$CODEX_HOME/plugins/cache/toastty/toastty/` and, when user skills are accepted, `$CODEX_HOME/plugins/cache/toastty-user/toastty-user/`: Toastty's plugin cache subtrees, produced by installing the plugin into a throwaway Codex home with the local Codex CLI, digest-verifying the bytes, and swapping them in atomically. User-authored skill content is copied into the `toastty-user` subtree.
  - `$CODEX_HOME/toastty-managed.config.toml`: a Toastty-owned profile overlay that enables those cached plugins only for processes launched with `--profile toastty-managed`. Its exact full-line ownership marker may appear anywhere because Codex can prepend profile-scoped settings. Toastty preserves those settings and unrelated TOML content when it refreshes its plugin entries; an existing file without the marker is treated as foreign and is never overwritten. The user's `config.toml` is never written by skills delivery (the only exception is the one-time legacy cleanup edit below), and ordinary Codex sessions are unaffected.
  - The startup sweeper also removes aged Toastty-owned transient litter (`.toastty-staging-*` / `.toastty-old-*` directories left by interrupted cache swaps) inside `$CODEX_HOME/plugins/cache/toastty/` and `$CODEX_HOME/plugins/cache/toastty-user/`; nothing else inside `CODEX_HOME` is touched by cleanup.
  - On the first provisioning after updating from an older Toastty, a one-shot cleanup deregisters the retired Toastty marketplace through Codex and removes the old `~/.toastty/codex-plugin/` staging. It also performs a one-time surgical edit of the user's `$CODEX_HOME/config.toml`: only the `[[skills.config]]` blocks the old mechanism wrote with `name = "toastty:…"` are removed (they would otherwise suppress the newly delivered skills); every other line is preserved byte-identically, and the original file is first backed up as `~/.toastty/agent-plugins/codex/homes/<key>/config-backup-<timestamp>.toml` — never written inside `$CODEX_HOME`.
  - Removing skills delivery means deleting only these Toastty-owned cache subtrees, the overlay, and the receipts; each is inert for ordinary sessions and safe to delete at any time.
- Global and repository-local skill directories
  - Toastty does not inspect, move, remove, or back up entries under `~/.codex/skills`, `~/.claude/skills`, `~/.cursor/skills`, `~/.agents/skills`, a repository's `.agents/skills`, Pi's `.pi/skills` or `$PI_CODING_AGENT_DIR/skills` (default `~/.pi/agent/skills`), or OpenCode/MiMo Code's project or home `.opencode/skills`, `.claude/skills`, `.agents/skills`, or `.mimocode/skills`. The skills sheet only provides manual guidance if separately installed copies cause duplicate entries or, for OpenCode/MiMo Code, unpredictable per-launch collisions.
- `~/.codex/hooks.json` (updated by `Toastty > Set Up Agent Status Hooks…`)
  - Toastty adds or updates only its own Codex hook entries while preserving unrelated hooks. Skills provisioning, repair, upgrades, and manual removal do not modify this file.
- `~/.cursor/hooks.json` and `~/.cursor/cli-config.json`
  - Toastty does not read or write these files for Cursor integration. Managed Cursor hooks and skills arrive through the launch-scoped plugin directory, so existing user and third-party configuration remains independent.
- Temporary launch artifact directories under the system temporary directory for managed agent sessions.
  - OpenCode and MiMo Code launches include a Toastty-owned per-session plugin file plus `telemetry-failures.log` when the plugin cannot deliver status events back to Toastty. The failure log records event type, session context, exit status, and CLI stderr, not full provider event payload JSON. These artifacts are removed when the managed session stops.
- `~/.toastty/history/pane-journals/`
  - Toastty-owned per-pane restore journals used by `zsh`, `bash`, and `fish` shell integration. These are imported into in-memory shell history on restore, but Toastty does not replace the shell's primary shared history file. For fish, Toastty skips pane-journal import and writes when `fish_history=''`.
- By default, `~/Library/Logs/Toastty/toastty.log`
  - Structured JSON logs.
- By default, `~/Library/Logs/Toastty/toastty.previous.log`
  - Rotated copy of the previous log file once the active log exceeds 5 MB.
- When runtime isolation is enabled for an isolated dev/test run, either by setting `TOASTTY_RUNTIME_HOME` directly or by setting `TOASTTY_DEV_WORKTREE_ROOT` and letting Toastty derive a runtime home under `artifacts/dev-runs/`:
  - `<runtime-home>/config`
  - `<runtime-home>/config-reference`
  - `<runtime-home>/annotation-styles.json`
  - `<runtime-home>/hooks/agent-hook`
  - `<runtime-home>/terminal-profiles.toml`
  - `<runtime-home>/command-palette-usage.json`
  - `<runtime-home>/workspace-layout-profiles.json`
  - `<runtime-home>/recent-right-panel-items.json`
  - `<runtime-home>/remote-access/devices.json`
  - `<runtime-home>/remote-access/audit.json`
  - `<runtime-home>/managed-agent-resume/`
  - `<runtime-home>/run/managed-agent-launches/`
  - `<runtime-home>/run/managed-agent-helpers/` (one owner-only directory per Toastty process containing immutable copies of the bundled CLI and agent-launch shim; a later launch removes directories only when their recorded owner PID is proven absent)
  - `<runtime-home>/agent-plugins/` (user-skill snapshots, staging, and receipts stay isolated here; the user-skill SOURCE is not isolated — isolated instances read the real `~/.toastty/skills/` unless `TOASTTY_USER_SKILLS_ROOT` redirects it, the override automated harnesses use)
  - `<runtime-home>/scratchpad-documents/`
  - `<runtime-home>/history/pane-journals/`
  - `<runtime-home>/logs/toastty.log`
  - `<runtime-home>/instance.json`
  - a dedicated `UserDefaults` suite derived from that runtime-home path

## What the configured agent hook receives

When `agent-hook` is configured, Toastty executes that user-provided script for
managed-session lifecycle and status events. Each invocation receives, on stdin
and in `TOASTTY_*` environment values, session and workspace metadata: the
event name, session ID, agent ID, workspace and panel UUIDs, the session
working directory, the accepted previous/next status kinds, the launch reason,
and the current instance's CLI and automation socket paths. Prompts, terminal
output, file lists, and file contents are not included. The script runs with
your user account's full permissions and inherits the app environment; only
configure a script you trust. Toastty logs hook invocations, nonzero exits,
timeouts, and launch failures to its structured local log. See
[Agent Hooks](agent-hooks.md).

## Agent reads of terminal output

Agents can read terminal output through Toastty's automation socket in workspaces
they can automate. Reads are allowed by default. To disable reads by other
sessions, right-click the terminal header and turn off **Allow Agents to Read
This Terminal**. The setting persists with the workspace layout; the terminal's
own active managed session remains exempt.

An eye indicator in the terminal header shows reads by other sessions. Hover
over it to see the readers and recent read activity, or click it to change the
read setting. A crossed-out eye marks a terminal with reads disabled. This
setting controls Toastty's terminal-read API, not the permissions of processes
running on your Mac.

## What Toastty reads locally for agent status

- For managed Codex sessions, Toastty reads the per-launch TUI session record it
  requested through `CODEX_TUI_SESSION_LOG_PATH` for root-turn and approval
  context. After Codex identifies its native session file, Toastty also watches
  that rollout JSONL for collaboration-agent lifecycle and identity mapping.
  When a collaboration event supplies an exact child thread ID, Toastty may
  briefly inspect a bounded prefix of the matching local child rollout to read
  its effective model identifier and reasoning effort. This lookup accepts only
  complete `turn_context` records, retains only those two metadata fields in
  memory, and does not log rollout contents. If a hook-authoritative Codex root
  is ready or idle while an active child row remains, Toastty may also watch
  that exact child rollout for a top-level `task_complete` or `turn_aborted`
  envelope from the child's current run. That recovery parser decodes only the
  event timestamp, terminal type, and available thread/turn identifiers; it
  does not retain or log completion-message or conversation content. The
  watcher stops when the child finishes, starts a new run, the root resumes
  work, the parent rollout changes, or the managed session ends.
  Toastty derives child-agent IDs, task/display names, and available plaintext
  descriptions for the live sidebar; task names are limited to 80 characters,
  descriptions to 512 characters, and opaque encrypted descriptions are
  discarded. Per managed session, Toastty retains at most 64 pending and 64
  resolved subagent metadata correlations and 16 recent auto-reviewed turn IDs.
  Active collaboration rows and 120-second finish tombstones are not
  cardinality-capped. The launch-log watcher retains at most 65,536 compact
  deduplication fingerprints per stream; after that ceiling, it preserves
  existing duplicate protection but processes new observations without
  retaining additional fingerprints and records a local warning. This
  reconciliation state is memory-only and discarded with its owning session or
  watcher. Child-agent display names can appear in Toastty's structured local
  logs. Toastty does not modify the Codex rollout files.
- For managed Claude sessions, Toastty's injected hooks report live prompt and
  interaction transitions, and Toastty reads the local Claude transcript file
  associated with the exact provider-native session to project normalized
  conversation history for Remote Access. Toastty does not modify that file.
- For managed Claude and Codex sessions, Toastty reads the short session name
  the provider CLI generated, so the sidebar can label a row with it. For
  Claude that is the newest `ai-title` record in the bound session's transcript;
  for Codex it is the newest matching record in
  `$CODEX_HOME/session_index.jsonl` (default `~/.codex`). Toastty reads a
  bounded amount from the end of each file, only when the session's reported
  status changes, and never modifies either file. The resolved name is stored
  in the local session registry snapshot and can appear in Toastty's structured
  local logs; no other content from those files is retained.
- For managed OpenCode, MiMo Code, and Pi sessions, Toastty's injected local
  plugin or extension reads the provider's current message snapshot and live
  lifecycle events to publish normalized conversation observations. Toastty
  retains at most 20,000 observations per managed session in process memory;
  they are not written as a separate transcript and are discarded when the
  Toastty app process exits. Pi's compact `pi-telemetry.jsonl` continues to
  exclude the full conversation batches.
- For managed Claude, OpenCode, MiMo Code, and Pi sessions, the same injected
  local hooks or extensions may retain a bounded direct-child identity, display
  name, and provider-reported model or effort metadata for the live sidebar.
  Toastty omits unavailable fields and does not derive them from child prompts
  or tool output. This activity state is held in memory and discarded when the
  owning session stops; helper failure logs do not include full provider event
  payloads.
- During Codex skill preparation, Toastty invokes the resolved local Codex CLI
  against a throwaway Codex home to produce the canonical plugin cache bytes,
  and once per legacy install to deregister the retired marketplace mechanism.
  It does not read or write skill enabled state in the user's Codex
  configuration. During optional status-hook setup, Toastty reads the local
  hook file to manage only its own entries. Toastty does not send this state to
  a remote Toastty service.

## What Toastty creates temporarily

- Automation mode creates a Unix domain socket at a short temp path derived from the active runtime home when runtime isolation is enabled, otherwise under `$TMPDIR/toastty-$UID/events-v1.sock`, unless `TOASTTY_SOCKET_PATH` overrides it.
- Automation runs can also write screenshots and state dumps under `artifacts/` or the directory provided via `--artifacts-dir`.
- `Toastty > Send Diagnostics…` validates its bundled `toastty-send-diagnostics` skill and CLI, then copies a short agent handoff containing their runtime-resolved absolute paths. Opening the dialog or copying the handoff does not collect or upload anything. When an agent follows the skill, it first writes doctor output and a redacted diagnostics JSON bundle to private per-run temporary paths. The bundle includes app/runtime metadata, socket probe results, shell-integration checks, shell probe output when provided, recent complete-line tails of redacted Toastty logs, and a sanitized in-memory audit of recent automation socket requests when the running app can provide it.
- Browser panel screenshot actions can write user-selected PNG files, place PNG data on the macOS pasteboard, or write temporary agent-share screenshots under the system temp directory in `toastty-browser-screenshots/`.
- Browser and Scratchpad annotation sends can write temporary annotated PNG files under the system temp directory in `toastty-browser-annotations/`, then send the selected managed agent a prompt containing those file paths plus the title, viewport, and numbered comments. Browser feedback also includes the page URL when available; Scratchpad feedback identifies the document and revision without exposing the bundled renderer's file URL.

## Permissions and platform integrations

- Toastty requests macOS notification permission the first time it attempts to deliver a desktop notification.
- Apps launched inside Toastty can trigger macOS camera and microphone permission prompts. Toastty declares those permissions so terminal-hosted child processes can ask for access, but Toastty itself does not capture audio or video on its own.
- The `shortcut-trace.sh` automation script requires Accessibility and Automation permissions because it drives keyboard shortcuts through `osascript`.
- Sparkle checks `https://updates.toastty.dev/appcast.xml` for available updates. No usage data or telemetry is sent with the request.
- Agent-authored Scratchpad content can load HTTPS font files when the document declares them. Other Scratchpad-generated network access remains blocked by content security policy.
- Toastty does not request contacts, calendars, photos, or location access.

## Remote Access networking

When enabled, Toastty listens for Remote Access only on IPv4 loopback. The
intended remote path is a private Tailscale Serve HTTPS origin that proxies to
that local listener; Toastty does not configure Tailscale, publish a LAN
listener, or enable Tailscale Funnel. The configured Tailnet origin is an exact
allowlist, and a presented non-matching Origin is rejected on every route.

A paired Toastty Mobile client, or a browser profile paired by an earlier
Toastty build, can receive normalized agent conversation content, status, a
bounded desktop status-detail excerpt, workspace/panel placement, and
working-directory metadata. New native pairings have read and send scope by
default. The current Mac UI can revoke one device, revoke all devices, or
disable Remote Access; it does not expose device-scope changes. Remote Access
activity is not sent to a Toastty cloud service. Network transport and tailnet
access remain subject to the user's Tailscale account, ACLs, DNS, and Serve
configuration. See [Remote Access](remote-access.md) for setup and revocation
guidance.

Workspace snapshots also describe open right-side panels across the workspace's
desktop tabs. A native client with read scope can request saved document
contents, Scratchpad HTML, and permitted local HTML assets for previews. File
access is bounded by the conversation's repository or recorded working
directory and files already open in the same workspace. Local HTML additionally
permits supported web assets from its containing directory; hidden files,
arbitrary neighboring documents, and paths escaping that directory are not
served as assets. These preview endpoints require native credentials and do
not accept legacy browser cookies. See [workspace panels and file
previews](remote-access.md#workspace-panels-and-file-previews) for the access
rules and mobile behavior.

Native pairing offers are memory-only. Their QR secret and fallback code are
discarded on success, cancellation, reissue, expiry, or when Remote Access is
disabled. Native credentials are bound to the exact Tailscale login stored in
the owner-only device file; the raw login, offer proofs, credential values, and
public gateway hostname are excluded from routine remote-access logs and audit
entries. The transcript tailer likewise does not put provider transcript paths
or filesystem error descriptions into its routine logs. Optional pending
interaction previews and status-detail excerpts travel only in bounded gateway
snapshots and are not copied to audit entries, logs, or diagnostics.

## Diagnostics upload

Toastty does not upload diagnostics automatically. The diagnostics flow is:

1. `toastty doctor` can run local checks and print remediation hints without writing a bundle or uploading anything. It reads local state and pings the local Toastty automation socket when one is present.
2. `toastty diagnostics collect` writes a local redacted JSON bundle and prints a human summary. It embeds recent complete-line log tails, without changing the source log files, and reduces those tails as needed to keep the reviewed bundle below the upload limit.
3. You review the JSON bundle.
4. Only after explicit approval, `toastty diagnostics submit --file <path> --yes` uploads that exact reviewed file to the Toastty diagnostics Worker. If the user provides follow-up contact details, `--contact <text>` can include them in the submitted diagnostics note without changing the local reviewed file.

In a supported managed session, a user can say “send Toastty diagnostics” to
invoke the shipped `toastty-send-diagnostics` skill. The **Send Diagnostics…**
menu instead copies a direct pointer to that same bundled skill and CLI, so it
does not depend on successful skill discovery. In both paths, the initial
request authorizes local collection only; the skill requires a separate
post-review approval before upload.

The uploaded report is stored in Cloudflare R2 under a temporary `reports/`
prefix. R2 lifecycle rules must delete that prefix after the configured
retention window; the bundle's `expiresAtMs` field is metadata only. Submitted
reports still contain diagnostic context such as local paths, socket paths,
runtime labels, shell init-file status, supported agent CLI resolution from the
probe, redacted embedded log text, and sanitized recent automation request
metadata such as command IDs, caller session IDs, selector IDs, boolean flags,
outcome, and duration. Toastty does not include freeform automation payload text
such as terminal input, pasted content, argv, environment values, file lists, or
file contents in that automation audit.

Contact text passed with `--contact` is intentionally included in cleartext in
the submitted diagnostics note so the developer team can follow up. Do not use
`--contact` for secrets or other unrelated private data.

Toastty diagnostics reports are retrieved through the diagnostics Worker admin
endpoint with `x-toastty-admin-key`; agents should use the repo-local
`toastty-diagnostics` skill rather than direct R2 credentials. The admin list
endpoint can return recent report IDs, submission times, expiration times,
optional admin URLs, app/runtime/socket summary fields, and diagnostics note
previews when present, but not full bundles, raw logs, environment values, or
secret-scan finding details. If the optional notification webhook is configured,
Toastty sends a summary-only notification containing the report ID, admin fetch
URL, a suggested `$toastty-diagnostics` prompt, and bounded summary fields. The
notification does not include the full diagnostics bundle, freeform note text,
raw logs, environment values, or secret-scan finding details.

## Logging behavior

Default logs are persistent so GUI builds have a supportable place to write diagnostics.

Logs can include:

- local file paths
- working directories
- config paths
- socket paths
- panel, workspace, and window identifiers
- runtime and error diagnostics

If you do not want a persistent log file:

- set `TOASTTY_LOG_FILE=none`, or
- set `TOASTTY_LOG_DISABLE=1`

You can also redirect logs to a custom path with `TOASTTY_LOG_FILE=/path/to/file.log`.

## Ghostty note

Toastty embeds Ghostty through a locally supplied `GhosttyKit.xcframework`. That artifact is built outside this repository.

For public releases, the recommended Ghostty build disables Sentry:

```bash
zig build -Demit-macos-app=false -Demit-xcframework=true -Dxcframework-target=universal -Dsentry=false
```

That keeps Toastty local-only and avoids initializing Ghostty crash reporting inside the embedded runtime.
