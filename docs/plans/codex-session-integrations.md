# Codex Session Integrations Plan

## Goal

Make Toastty-specific Codex skills and lifecycle telemetry available only to
Codex processes launched as managed Toastty sessions. Ordinary Codex launches
must not receive Toastty skill descriptions or execute Toastty hooks.

The implementation must preserve unrelated user plugins, skills, profiles,
hooks, and configuration. Older or incompatible Codex builds must continue to
launch with Toastty's existing notify/session-log telemetry fallback; Toastty
must never reinstall global hooks automatically.

## Confirmed Codex behavior

The current supported path was verified against `codex-cli 0.146.0` using an
isolated `CODEX_HOME` and local test marketplace:

- Inline `-c hooks={...}` definitions are discovered as process-scoped
  `sessionFlags` hooks.
- Hook definitions merge with user hooks and retain normal exact-hash trust.
- A plugin can remain globally enabled while each of its skills is persistently
  disabled by stable names such as `toastty:toastty-scratchpad`.
- A managed launch can enable those names with a process-scoped
  `-c skills.config=[...]` override.
- Disabled plugin skills contribute no skill name or description to the ordinary
  prompt.
- The launch override preserves unrelated persistent skill-disable entries.
- `skills/config/write` can write a disabled name before the plugin is installed,
  avoiding a transient window where a newly installed plugin exposes its skills.
- Hook hashes are per definition rather than hashes of the merged hook set. An
  isolated probe confirmed that adding session hooks leaves an existing trusted
  user hook trusted and produces the same session-hook hash with or without the
  user hook.

Do not use a named Codex profile for activation. Codex has one selected profile,
and Toastty must not replace or synthesize a user's model, sandbox, MCP, or other
profile settings.

## Architecture

### 1. Package the Toastty skill set as a skills-only plugin

Add a repo-owned local marketplace and `toastty` plugin. The plugin contains
only user-facing Toastty workflows:

- `toastty-capabilities`
- `toastty-open-markdown`
- `toastty-scratchpad`
- `worktree-create`
- `worktree-done`

Make the plugin copies canonical and keep `.agents/skills/<name>` compatibility
symlinks so repo-local Codex, Claude, and generic-agent workflows continue to
work. Do not package Toastty development, verification, diagnostics, release,
or publishing skills.

Refactor helper invocations inside the five skills to resolve scripts relative
to `TOASTTY_SKILLS_ROOT`, a stable path injected into managed sessions. Setup
copies the bundled marketplace/plugin to `~/.toastty/codex-plugin/`, and the
environment value points at that copy's `skills/` directory. Skills fail with a
clear "run inside Toastty" message when the variable is unavailable. They must
not assume the current repository, `~/.agents/skills`, Codex's versioned cache,
or `PLUGIN_ROOT`.

Bundle the marketplace/plugin directory in the Toastty app so setup works
offline from the installed application. Keep the standalone linking script for
Claude/generic-agent development, but stop recommending global Codex links.

### 2. Install skills disabled, then enable them per managed launch

Replace the narrow global-hook setup operation with a Codex integration setup
operation:

1. Resolve the actual Codex executable and its `CODEX_HOME`.
2. Copy the bundled marketplace/plugin atomically to the stable
   `~/.toastty/codex-plugin/` location.
3. Derive the exact skill-name allowlist from the copied plugin manifest, then
   start Codex app-server long enough to call its atomic
   `skills/config/write` operation for every `toastty:<skill>` name with
   `enabled=false`.
4. Add/refresh the stable local Toastty marketplace and install/update the
   `toastty` plugin.
5. Reapply the manifest-derived disables after install and verify through
   `skills/list` that the installed skill set exactly matches the allowlist and
   remains disabled in the ordinary configuration. A newly added plugin skill
   therefore cannot leak during an upgrade.
6. Detect legacy standalone Toastty skills in Codex's global roots. Move only
   exact Toastty-owned symlinks or byte-identical copies into a timestamped
   `~/.toastty/legacy-codex-skills-backup/` directory after explicit setup
   consent; preserve modified or ambiguous directories and report that they
   still leak into ordinary Codex sessions.

Managed Codex launches inject a deterministic
`-c skills.config=[{name="toastty:...",enabled=true},...]` override. If setup is
missing, verification fails, or Codex lacks the required config support, skip
skill activation without blocking the agent launch.

Installation ordering is fail-safe: the persistent disabled entries are written
before `codex plugin add`, so interruption cannot expose Toastty skills globally.
Use Codex's config writer rather than rewriting TOML in Toastty, verify the
result after every write, and re-verify drift during startup maintenance.

Provide an explicit uninstall action that removes the installed plugin and
marketplace registration, preserves/restores any backed-up legacy skill copies
only with user confirmation, and reports the harmless disabled-name tombstones
that Codex's current config API cannot delete individually.

### 3. Replace global hooks with process-scoped hooks

Keep the stable `~/.toastty/codex-hooks/forwarder.sh`; its command and all seven
hook definitions remain constant, while session, panel, socket, and CLI values
continue to arrive only through `TOASTTY_*` environment variables.

For supported managed launches, inject deterministic inline definitions for:

- `SessionStart`
- `UserPromptSubmit`
- `PermissionRequest`
- `PreToolUse`
- `SubagentStart`
- `SubagentStop`
- `Stop`

Do not bundle these operational hooks in the plugin. Plugin hooks would be
globally discovered whenever the plugin is enabled.

Turn `CodexStatusHookInstaller` into a narrowly owned migration/forwarder
component:

- maintain the stable forwarder;
- remove only Toastty-owned current and legacy entries from
  `~/.codex/hooks.json`;
- preserve every unrelated user hook;
- never add global hook entries again.

If legacy global Toastty hooks cannot be removed, do not inject duplicate
session hooks for that launch. Continue using the legacy hooks or the fallback
and surface the cleanup failure.

Do not remove working global Toastty hooks merely because the app updated.
Record explicit completion of the new integration setup, explain that the new
session hook identities require one Codex trust review, and only then migrate
the owned global entries. The notify/session-log path covers the re-trust gap.

### 4. Assess capability and trust without breaking launches

Add a small Codex app-server client used during setup and preflight. With the
same process-scoped skill and hook overrides that the real launch will receive,
query `skills/list` and `hooks/list` to produce a typed assessment:

- plugin skills present and enabled for the managed process;
- all seven session hook definitions parsed;
- hook trust status (`trusted`, `untrusted`, or changed);
- legacy global Toastty hook presence;
- warnings/errors or unsupported APIs.

Run the probe off the UI thread with a hard 1.5-second timeout. Cache only
structural support by resolved Codex binary path, version, effective
`CODEX_HOME`, and integration-definition hash. Re-read local trust/config state
when its file hashes change, and recheck negative/untrusted results on the next
launch so a user trust action takes effect promptly.

Only select hook-primary telemetry when all expected session hooks are trusted.
When hooks are supported but not yet trusted, still inject them so Codex can
offer `/hooks` review, but retain notify/session-log telemetry for that launch.
If probing or launch preparation fails, omit the new overrides and launch with
the existing fallback. Never pass `--dangerously-bypass-hook-trust`.

The probe and real launch share one deterministic serializer and pass each
override as a distinct argv element, never through a rendered shell fragment.
Reuse the existing resolved-Codex insertion contract, inject only immediately
after the actual Codex executable for recognized direct/subcommand/wrapper
shapes, never inject after `--`, and refuse injection in favor of fallback for
opaque shapes.

Lock the selected telemetry source for the lifetime of a managed session. If a
user trusts hooks midway through a fallback-owned session, hook events remain
ignored until the next managed launch; this prevents hook/notify duplication
without inventing a new event-sequence protocol.

Pass an optional resolved Codex executable/capability hint through the existing
managed-launch request so typed shims and UI/menu launches use the same logic.
Unresolvable shell functions or opaque wrappers degrade to fallback instead of
being executed as probes.

### 5. Update setup, status, and legacy UI

Rename the user-facing setup command from agent-status hooks to Codex
integration. The setup sheet should report these independently:

- plugin installed and expected skills globally disabled;
- legacy standalone skill conflicts;
- global Toastty hooks removed;
- session hooks supported;
- session hooks awaiting Codex trust, with `/hooks` guidance;
- fallback mode for incompatible Codex versions.

Retain existing socket/preflight fields unchanged in this slice where that
avoids breaking older command shims, but stop routing any action to global hook
installation. Their eventual deprecation is a separate compatibility decision.
Startup maintenance performs safe legacy cleanup and forwarder refresh only.

## Affected areas

Expected production code:

- `Sources/App/Agents/CodexStatusHookInstaller.swift` (narrow to migration and
  forwarder maintenance, or split into a new Codex integration component)
- `Sources/App/Agents/AgentLaunchInstrumentation.swift` (stable skill/hook TOML
  generation and argv insertion)
- `Sources/App/Agents/ManagedAgentLaunchPlanner.swift` (assessment and telemetry
  source selection)
- `Sources/Core/Sessions/ManagedAgentLaunchPlan.swift` and the CLI/socket bridge
  (resolved executable/capability hint while retaining wire compatibility)
- `Sources/App/Agents/AgentGetStartedSheet.swift`, `AgentLaunchUI.swift`, command
  menu/palette files, and `Sources/App/ToasttyApp.swift` (setup and migration UX)
- `Project.swift` and app resource lookup code (bundled plugin marketplace)
- a scoped Codex app-server/config client and a shared integration contract for
  the plugin allowlist, hook definitions, serializer, and assessment types
- `plugins/toastty/**`, `.agents/plugins/marketplace.json`, the five compatibility
  skill links, and `scripts/agents/link-global-skills.sh`

Expected documentation:

- `README.md`
- `docs/running-agents.md`
- `docs/privacy-and-local-data.md`
- `docs/cli-reference.md`
- `docs/socket-protocol.md`

## Implementation sequence and ownership

After plan approval, the primary agent first lands the small shared integration
contract (skill-name manifest reader, hook builder signature, serializer, and
assessment types). Then use three non-overlapping implementation workers in
this worktree:

1. **Plugin/skills worker:** owns plugin and marketplace files, the five skill
   sources/compatibility links, path-portability fixes, the linking script, and
   static/plugin validation tests.
2. **Hook/runtime worker:** owns deterministic session-hook configuration,
   forwarder/legacy-global cleanup, launch instrumentation, and focused unit
   tests. It does not touch setup UI or plugin files.
3. **Setup/probe worker:** owns the scoped app-server client, capability/trust
   assessment, managed-launch request plumbing, setup/preflight UI, and focused
   tests. It consumes the constants/contracts from workers 1 and 2 rather than
   duplicating them.

The primary agent integrates the slices, resolves overlap, updates
documentation, runs review/validation, and creates the scoped commit. Workers
must not revert or rewrite changes owned by another worker.

## Tests and validation

Add or update tests for:

- plugin manifest/marketplace schema, exact shipped skill allowlist, and app
  resource inclusion;
- skill helper execution from a copied, cache-like plugin directory;
- ordinary prompt excludes all `toastty:*` plugin skills while managed config
  includes them;
- managed skill activation preserves an unrelated disabled skill;
- persistent skill disables are written before plugin installation;
- foreign user hooks survive migration byte-for-byte while Toastty-owned hooks
  are removed;
- a trusted foreign user hook remains trusted before, during, and after a
  managed launch with injected session hooks;
- deterministic seven-hook TOML and trust hashes across repeated launches;
- direct Codex, `cdx`, supported wrappers, typed shims, menu/automation launch,
  resume, and fork argument insertion;
- untrusted/changed hooks retain notify fallback; trusted hooks select hook
  telemetry;
- old/unsupported Codex, missing plugin artifacts, opaque wrappers,
  malformed probe output, timeout, and launch-preparation failure all degrade
  without blocking Codex;
- injection is refused before `--` boundary violations and unknown wrapper or
  subcommand shapes rather than risking a hard-failing Codex launch;
- no duplicate telemetry when legacy global hooks remain;
- setup update, partial failure, retry, uninstall, and downgrade behavior;
- concurrent setup/config activity preserves unrelated skill settings and
  post-write verification catches drift;
- paths containing spaces, Unicode, and backslashes round-trip through the one
  argv serializer without changing hook hashes.

Use isolated temporary `CODEX_HOME` fixtures for all real Codex compatibility
tests; never mutate the developer's actual Codex config or plugin cache.

Validation after integration:

1. Run focused unit/script/plugin validation after each slice.
2. Regenerate the Tuist project and build the app cleanly.
3. Run `.agents/skills/toastty-verify/SKILL.md` to select the complete repository
   gate, including remote/local smoke and app tests.
4. Exercise setup and two real managed launches against an isolated Codex home:
   ordinary launch has zero Toastty skill context and no Toastty hooks; managed
   launch has five skills and seven session hooks.
5. Verify first-launch untrusted fallback, `/hooks` trust, and second-launch
   hook-primary telemetry end to end.
6. Repeat config-activation assertions through real TUI/debug-prompt, `exec`,
   resume, and fork launch shapes rather than relying only on app-server lists.
7. Run Claude change-set review on each risky integration slice and on the final
   combined diff; address accepted findings before commit.
8. Use independent user-perspective QA if `toastty-verify` selects it for the
   setup/status UI changes.

## Explicit non-goals

- Do not create or merge derived user Codex profiles.
- Do not automatically install global hooks for older Codex versions.
- Do not use hook-trust bypass flags.
- Do not package Toastty developer/release/operator skills for end users.
- Do not add a general custom-skill editor or new plugin-management surface in
  this slice; the first release establishes the built-in Toastty skill pack and
  session-only activation contract.
