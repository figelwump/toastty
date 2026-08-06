# Toastty Privacy and Local Data

Toastty is designed to run locally on your machine. The app itself does not send usage analytics or cloud telemetry.

## What Toastty writes locally

- `~/.toastty/config`
  - User-authored Toastty defaults such as `terminal-font-size`, `default-terminal-profile`, `enable-agent-command-shims`, and URL-opening preferences.
- `~/.toastty/config-reference`
  - Generated commented reference for every supported Toastty config key. Toastty rewrites this file on launch and when you open `Toastty > Open Config Reference…`.
- `~/.toastty/bin/` for ordinary runs, or `<runtime-home>/bin/` when runtime isolation is enabled and agent command shims are enabled
  - Managed `codex`, `cdx`, `claude`, `opencode`, `mimo`, `mimocode`, and `pi` wrapper symlinks used to track manual agent invocations inside Toastty terminals.
- macOS `UserDefaults` for Toastty
  - Small UI-managed settings such as the post-agent-launch sidebar default latch, plus any one-time legacy migration state.
- `~/.toastty/terminal-profiles.toml`
  - Named terminal profile definitions loaded at startup and on config reload.
- `~/.toastty/command-palette-usage.json`
  - Local per-command usage counts used only to rank command-palette results.
- `~/.toastty/workspace-layout-profiles.json`
  - Saved workspace and window layout snapshots, including window-local sidebar
    widths, window-local terminal font overrides, window-local local-document
    text-size overrides, per-browser page zoom overrides, and managed agent
    native-resume metadata for restored Codex, Claude, OpenCode, MiMo Code, and Pi panels. Native-resume
    metadata can include the provider, provider-native session ID, provider
    session file path or Toastty-owned marker path, working directory, capture
    timestamp, and any explicit workspace-scope identifiers needed to restore a
    scoped session after app restart.
- `~/.toastty/recent-right-panel-items.json`
  - The locally persisted Recently Opened list for right-panel browsers, local
    document paths, and Scratchpad document IDs/titles. The list contains up to
    20 items and may contain URLs or local paths that identify the supporting
    material you opened.
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
- `~/.toastty/skills/` (created only through `Toastty > Manage Toastty Skills…` or by the user)
  - User-authored skill packages (`<name>/SKILL.md` plus supporting files). Toastty scans this directory read-only. Anything you (or an agent acting on your request) put here becomes agent-visible instructions in managed Codex, Claude Code, OpenCode, MiMo Code, and Pi sessions, and is copied into the snapshot and cache locations below.
- `~/.toastty/agent-plugins/codex/`
  - Per-Codex-home receipt sidecars under `homes/<key>/` recording the verified plugin cache identity, so later managed launches can byte-verify without running Codex. A custom `CODEX_HOME` receives its own hashed `homes/<key>/` entry.
- `~/.toastty/agent-plugins/claude/`
  - Immutable validated Toastty plugin copies staged once and passed to managed Claude Code processes with `--plugin-dir`. The same staged `skills/` subtree is also the source Toastty points managed Pi (`--skill`), OpenCode, and MiMo Code (`skills.paths` inside their config-content JSON) launches at directly — pi/opencode/mimocode delivery introduces no separate copy and no new on-disk location. Toastty does not register these copies in Claude's user configuration, and nothing is written to pi's, opencode's, or mimocode's own config or data directories; the tree is only ever referenced per-launch via an argv flag (pi) or per-launch environment JSON (OpenCode, MiMo Code).
- `~/.toastty/agent-plugins/user/`
  - Immutable content-addressed snapshots of the accepted user skill packages, built from `~/.toastty/skills/` and delivered only to managed launches (Claude via a second additive `--plugin-dir`, Codex via the cache below, pi via a second `--skill` flag, and OpenCode/MiMo Code via a second entry in the same `skills.paths` array), again with no separate copy or new write location per runtime.
  - A startup sweeper deletes only Toastty-owned artifacts under `~/.toastty/agent-plugins/` — superseded user snapshots and staged Claude plugin copies beyond the currently delivered one plus one previous verified fallback, and aged staging orphans. Receipts under `codex/homes/` are kept.
- `~/.toastty/codex-hooks/` (created by `Toastty > Set Up Agent Status Hooks…`)
  - A stable Codex hook forwarder script plus `telemetry-failures.log` when the forwarder cannot deliver hook events back to Toastty.
- Toastty-owned files inside `$CODEX_HOME` (written automatically for supported managed Codex launches)
  - `$CODEX_HOME/plugins/cache/toastty/toastty/` and, when user skills are accepted, `$CODEX_HOME/plugins/cache/toastty-user/toastty-user/`: Toastty's plugin cache subtrees, produced by installing the plugin into a throwaway Codex home with the local Codex CLI, digest-verifying the bytes, and swapping them in atomically. User-authored skill content is copied into the `toastty-user` subtree.
  - `$CODEX_HOME/toastty-managed.config.toml`: a Toastty-owned profile overlay (with an ownership marker) that enables those cached plugins only for processes launched with `--profile toastty-managed`. The user's `config.toml` is never written by skills delivery (the only exception is the one-time legacy cleanup edit below), and ordinary Codex sessions are unaffected.
  - The startup sweeper also removes aged Toastty-owned transient litter (`.toastty-staging-*` / `.toastty-old-*` directories left by interrupted cache swaps) inside `$CODEX_HOME/plugins/cache/toastty/` and `$CODEX_HOME/plugins/cache/toastty-user/`; nothing else inside `CODEX_HOME` is touched by cleanup.
  - On the first provisioning after updating from an older Toastty, a one-shot cleanup deregisters the retired Toastty marketplace through Codex and removes the old `~/.toastty/codex-plugin/` staging. It also performs a one-time surgical edit of the user's `$CODEX_HOME/config.toml`: only the `[[skills.config]]` blocks the old mechanism wrote with `name = "toastty:…"` are removed (they would otherwise suppress the newly delivered skills); every other line is preserved byte-identically, and the original file is first backed up as `~/.toastty/agent-plugins/codex/homes/<key>/config-backup-<timestamp>.toml` — never written inside `$CODEX_HOME`.
  - Uninstall removes only these Toastty-owned cache subtrees, the overlay (when its ownership marker is present), and the receipts, after confirmation.
- Global and repository-local skill directories
  - Toastty does not inspect, move, remove, or back up entries under `~/.codex/skills`, `~/.claude/skills`, `~/.agents/skills`, a repository's `.agents/skills`, pi's `.pi/skills` or `$PI_CODING_AGENT_DIR/skills` (default `~/.pi/agent/skills`), or opencode/mimocode's project or home `.opencode/skills`, `.claude/skills`, `.agents/skills`, or `.mimocode/skills`. The skills sheet only provides manual guidance if separately installed copies cause duplicate entries or, for opencode/mimocode, unpredictable per-launch collisions.
- `~/.codex/hooks.json` (updated by `Toastty > Set Up Agent Status Hooks…`)
  - Toastty adds or updates only its own Codex hook entries while preserving unrelated hooks. Skills provisioning, repair, upgrade, and uninstall do not modify this file.
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
  - `<runtime-home>/terminal-profiles.toml`
  - `<runtime-home>/command-palette-usage.json`
  - `<runtime-home>/workspace-layout-profiles.json`
  - `<runtime-home>/recent-right-panel-items.json`
  - `<runtime-home>/managed-agent-resume/`
  - `<runtime-home>/agent-plugins/` (user-skill snapshots, staging, and receipts stay isolated here; the user-skill SOURCE is not isolated — isolated instances read the real `~/.toastty/skills/` unless `TOASTTY_USER_SKILLS_ROOT` redirects it, the override automated harnesses use)
  - `<runtime-home>/scratchpad-documents/`
  - `<runtime-home>/history/pane-journals/`
  - `<runtime-home>/logs/toastty.log`
  - `<runtime-home>/instance.json`
  - a dedicated `UserDefaults` suite derived from that runtime-home path

## What Toastty reads locally for agent status

- For managed Codex sessions, Toastty reads the temporary TUI session record it
  requested through `CODEX_TUI_SESSION_LOG_PATH` for root-turn and approval
  context. After Codex identifies its native session file, Toastty also watches
  that rollout JSONL for collaboration-agent lifecycle and identity mapping.
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
  logs. Toastty does not modify the Codex rollout file.
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
- `Toastty > Copy Diagnostics Collection Snippet…` copies an agent snippet that first runs `toastty doctor --json` into a temporary local file, then writes a redacted diagnostics JSON bundle to a per-run temporary path with restrictive permissions. The bundle includes app/runtime metadata, socket probe results, shell-integration checks, shell probe output when provided, embedded redacted Toastty log contents, and a sanitized in-memory audit of recent automation socket requests when the running app can provide it.
- Browser panel screenshot actions can write user-selected PNG files, place PNG data on the macOS pasteboard, or write temporary agent-share screenshots under the system temp directory in `toastty-browser-screenshots/`.
- Browser annotation sends can write temporary annotated PNG files under the system temp directory in `toastty-browser-annotations/`, then send the selected managed agent a prompt containing those file paths plus the page title, URL, viewport, and numbered comments when available.

## Permissions and platform integrations

- Toastty requests macOS notification permission the first time it attempts to deliver a desktop notification.
- Apps launched inside Toastty can trigger macOS camera and microphone permission prompts. Toastty declares those permissions so terminal-hosted child processes can ask for access, but Toastty itself does not capture audio or video on its own.
- The `shortcut-trace.sh` automation script requires Accessibility and Automation permissions because it drives keyboard shortcuts through `osascript`.
- Sparkle checks `https://updates.toastty.dev/appcast.xml` for available updates. No usage data or telemetry is sent with the request.
- Agent-authored Scratchpad content can load HTTPS font files when the document declares them. Other Scratchpad-generated network access remains blocked by content security policy.
- Toastty does not request contacts, calendars, photos, or location access.

## Diagnostics upload

Toastty does not upload diagnostics automatically. The diagnostics flow is:

1. `toastty doctor` can run local checks and print remediation hints without writing a bundle or uploading anything. It reads local state and pings the local Toastty automation socket when one is present.
2. `toastty diagnostics collect` writes a local redacted JSON bundle and prints a human summary.
3. You review the JSON bundle.
4. Only after explicit approval, `toastty diagnostics submit --file <path> --yes` uploads that exact reviewed file to the Toastty diagnostics Worker. If the user provides follow-up contact details, `--contact <text>` can include them in the submitted diagnostics note without changing the local reviewed file.

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
