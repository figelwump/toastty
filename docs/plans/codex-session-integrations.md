# Managed Codex and Claude Skills Plan

> September 2026 update: Plugin 0.4.2 keeps four built-in app skills.
> `worktree-create` and `worktree-done` are now opt-in personal workflows in
> [examples/skills/](../../examples/skills/README.md). Earlier packaging and
> exclusion decisions below are historical; see the
> [current workflow](../running-agents.md#worktree-tasks).

## Goal

Ship Toastty's user-facing skills automatically to managed Codex and Claude
Code sessions without asking users to run setup, install global skills, or
change hook trust. Ordinary Codex sessions must keep the Toastty skills
disabled; Claude Code receives the plugin only through the managed launch.

This replaces the earlier plan in this file. In particular, this slice does
not move Codex hooks from global configuration to process-scoped hooks. The
existing status-hook installer, permissions, preflight, and telemetry behavior
remain as they are on `main`.

## User-facing behavior

### Codex

On the first managed Codex launch, Toastty attempts to provision its bundled
skills-only plugin before starting Codex. There is no setup sheet and no
`/hooks` step for skills.

- New launches provision off the main actor. Restored sessions perform the same
  bounded preparation before their resume command is submitted.
- Success enables the four Toastty skills for that managed process only.
- Failure or timeout never blocks launch; Codex starts without the new skills.
- A later managed launch retries automatically.
- A verified, current installation is read-only on later launches: Toastty
  does not rewrite config, reinstall the plugin, or touch the marketplace.

After the first successful managed use, show one dismissible, non-blocking
Codex banner. A persisted per-agent flag prevents it from being shown again:

> Toastty enabled four skills for managed Codex sessions. Your global and
> project skill folders were not changed. View Skills…

`Toastty > Manage Toastty Skills…` opens a sheet with separate Codex and Claude
Code delivery statuses, the installed Codex plugin version, any pending Codex
update or repair issue, and these visible rows:

| Skill | Summary |
| --- | --- |
| `toastty:toastty-capabilities` | Control Toastty workspaces, panels, terminals, and managed agents. |
| `toastty:toastty-open-markdown` | Open plans and Markdown files for review inside Toastty. |
| `toastty:toastty-scratchpad` | Create and update visual diagrams, mockups, and summaries. |
| `toastty:worktree-create` | Move work into an isolated Git worktree and Toastty workspace. |

The sheet also explains the Codex and Claude delivery models and tells users
that Toastty does not change separately installed global skills. It provides
`Repair` and `Uninstall…` for the Codex plugin. Technical paths, the marketplace
registration, and harmless disabled-name tombstones live in a collapsed
details group. Repair applies immediately; running Codex sessions pick up the
result after restart. Uninstall is disabled while a managed Codex session may
still be using the installed skill files.
Uninstall removes only the Toastty plugin, Toastty marketplace registration,
and Toastty's staged plugin files. It does not edit Codex hooks or restore old
global skill links automatically.

### Claude Code

Every managed Claude Code launch receives the same four-skill plugin through a
session-only `--plugin-dir <path>` argument. Toastty does not add a Claude
marketplace, write `~/.claude/settings.json`, or globally install the plugin.
There is no Claude setup or install action because no persistent Claude
configuration is being managed. The first successful managed Claude launch
shows its own one-time non-blocking banner and links to the shared skill-detail
sheet:

> Toastty enabled four session-only skills for managed Claude Code sessions.
> Your global and project skill folders were not changed. View Skills…

If preparing or injecting the Claude plugin fails, launch Claude unchanged
apart from its existing Toastty status instrumentation.

## Plugin and skill layout

Keep one canonical, dual-host plugin at `plugins/toastty/`:

```text
plugins/toastty/
  .codex-plugin/plugin.json
  .claude-plugin/plugin.json
  skills/
    toastty-capabilities/
    toastty-open-markdown/
    toastty-scratchpad/
    worktree-create/
```

Both manifests use the same plugin name and version. A validator enforces
matching versions, the exact four-skill allowlist, skills-only manifests, and
the absence of hooks, MCP servers, apps, or agents.

`worktree-done` is not a generic end-user skill: it assumes a `main` landing
workflow and contains Toastty-repository validation policy. Move it back to a
real repo-local `.agents/skills/worktree-done/` directory and do not include it
in either plugin. Keep compatibility symlinks under `.agents/skills/` for the
four canonical plugin skills so development in this repository still works.

Rename the bundled app resource root from the Codex-specific
`CodexPluginMarketplace` to `ToasttyAgentPluginBundle`. It contains both the
Codex marketplace metadata and the shared plugin root; Claude reads the plugin
root directly.

The existing helper contract remains `TOASTTY_SKILLS_ROOT`. Toastty sets it to
the exact plugin version used by the managed process, so helpers never guess a
repository checkout or a host cache path. All Toastty-owned staged copies
normalize executable helper modes and clear inherited quarantine from the
staged files only; validation must also cover a packaged/notarized app artifact.

## Managed launch context

Set the already-defined `TOASTTY_AGENT` launch-context variable for every
managed agent and reserve it from caller overrides. Update `worktree-create`
so its default child agent is the current `codex` or `claude` value; an explicit
`--agent-command` still wins, and unknown/missing values continue to fall back
to `codex`. This keeps a Claude user in Claude when using the shared skill.

Do not reintroduce `TOASTTY_DEV_WORKTREE_ROOT` or `TOASTTY_DERIVED_PATH` in the
public skill. Repository-specific bootstrap and isolation remain owned by each
repository's instructions and launch tooling.

## Codex provisioning architecture

> **Superseded 2026-08-04 (profile-based delivery).** The mechanism described
> in this section — user-config marketplace registration, app-server
> `skills/config/write` disable-unions, and a per-process `-c skills.config`
> enable override — has been replaced by a profile-based mechanism that never
> writes to the user's `config.toml`. Population installs the bundled plugin
> into a throwaway `CODEX_HOME` through the Codex CLI, digest-verifies the
> produced cache bytes, and atomically swaps them into
> `$CODEX_HOME/plugins/cache/toastty/toastty/`. A Toastty-owned
> `$CODEX_HOME/toastty-managed.config.toml` overlay enables the plugin, and
> managed launches inject `--profile toastty-managed`; ordinary sessions see
> no Toastty skills and no disabled-name tombstones. A receipt sidecar under
> `~/.toastty/agent-plugins/codex/` supports cheap byte-verification on later
> launches, and a one-shot legacy cleanup uninstalls the old marketplace
> registration on first provisioning. Capability evidence:
> `docs/plans/evidence/codex-session-scoped-skills-2026-08-04.md`. The
> "no named Codex profile" non-goal below is superseded accordingly.
>
> This replacement covers every subsection through "Idempotence and updates",
> and the same correction applies wherever the rest of this document mentions
> marketplace registration, `skills.config` disables, disabled-name tombstones,
> or a `-c skills.config` managed activation (the user-facing sheet/uninstall
> descriptions above and the tests/non-goals below): the shipped mechanism
> writes none of those. Injection skips are typed and fail open — a
> caller-supplied `--profile`/`-p` flag, an opaque argv shape, or a
> caller-replaced `CODEX_HOME` launches Codex without Toastty skills.
> `docs/running-agents.md` and `docs/privacy-and-local-data.md` describe the
> shipped behavior.

### Required host-capability spike

Before design-dependent implementation, add a repeatable probe that uses a
temporary `HOME`, `CODEX_HOME`, and Claude config root and records sanitized
results under `docs/plans/evidence/`. It must prove against the supported real
CLIs that:

- `codex plugin add` over an installed local-marketplace plugin refreshes its
  installed path and bytes;
- `skills/config/write` preserves unrelated config text/comments and existing
  hook configuration/trust, rather than normalizing the whole file;
- the disabled qualified name used by app-server is the same name honored by
  ordinary `codex`, including a behavioral ordinary-vs-managed skill check;
- missing-skill tombstones are tolerated;
- the selected stable-path replacement or symlink strategy is reread safely;
- repeated Claude `--plugin-dir` flags are additive and accept the staged
  dual-host root; and
- skill provisioning does not cause an already trusted Codex hook to require
  trust again.

The probe fails closed and never points at the developer's real state. If a
host behavior is not supported, revise the design before continuing rather
than adding a parser or mutating config directly.

### State model

Refactor the branch's `CodexIntegrationManager` into an async,
skills-only `CodexSkillsManager`. Expose a small base availability
(`ready`, `notInstalled`, `failed`, or `unsupported`) plus installed/bundled
versions and derived `updatePending`/`repairPending` facts. Do not persist an
update-pending flag; derive it from the installed and bundled digests so it
cannot go stale across app restarts.

The manager serializes provisioning operations and returns an optional
`CodexSkillsLaunchConfiguration` containing the exact qualified skill names and
skills root. Hook readiness and `CodexStatusTrackingSource` are not part of this
model.

### Install and verify

Use Codex-owned interfaces for Codex state:

1. Read and validate the bundled manifest and content digest.
2. Inspect the configured Toastty marketplace and installed plugin with
   `codex plugin marketplace list --json` and `codex plugin list --json`.
3. Before Codex can discover a new plugin version, use Codex app-server's
   `skills/config/write` for the union of installed and bundled
   `toastty:<skill>` names with `enabled=false`.
4. Atomically stage the local marketplace at `~/.toastty/codex-plugin/`.
5. Add the stable local marketplace only when missing, then use
   `codex plugin add toastty@toastty --json` for both first install and
   reinstall/update. Do not use `plugin marketplace upgrade`: Codex documents
   that command as a Git-marketplace refresh, and an isolated local-marketplace
   probe showed it does not refresh the installed local plugin.
6. Reapply the disables and verify that Codex reports exactly the bundled four
   skills, all disabled in ordinary configuration. Compare the manifest
   version and a deterministic digest of the installed skill files at the
   `installedPath` returned by Codex, not just the skill names.
7. Return a launch configuration only after verification succeeds.

Keep app-server use scoped to the skill configuration API. Remove the branch's
production use of experimental app-server marketplace/plugin methods in favor
of the public Codex CLI plugin commands.

Install/update is transactional around Toastty's stable marketplace copy. The
initial capability spike below must select one verified strategy: versioned
source directories behind a stable registered symlink if Codex follows the
symlink safely, otherwise an atomic stable-directory replacement with an
explicit retained backup. On failure, restore the source pointer/directory and
use the old installed cache only if its existing path and digest still verify.
Do not synchronously reinstall an old plugin on the launch-critical path; if
the old installation cannot be proven good, launch without Toastty skills.

Record Toastty's marketplace ownership and exact registered source in a small
Toastty state file. Uninstall removes the marketplace only when that record and
Codex's current marketplace source both match Toastty's path and no foreign
installed plugin depends on it. A same-named user marketplace is a preserved
conflict, not something Toastty replaces.

### Managed activation

For a verified installation, inject only a deterministic process-scoped
`skills.config` override enabling the four qualified names and set
`TOASTTY_SKILLS_ROOT`. Reuse the existing safe executable-index logic for
direct Codex, `cdx`, resume, fork, and explicitly supported wrapper shapes.
Caller overrides conflict only when they target `skills` or `skills.config`
(or replace the effective config/CODEX_HOME); unrelated `-c` values remain
supported. Opaque argv shapes cause skills to be omitted rather than risking a
failed Codex launch.

No hook definitions are serialized or injected by this path. Existing global
hook detection still determines whether hook or notify/session-log telemetry
is authoritative.

### Idempotence and updates

Cache the last verified result against the resolved Codex executable identity
(path, inode, size, and modification time), `CODEX_HOME`, a content hash of
Codex config, plugin metadata, bundled plugin digest, and installed plugin
path/digest. If those signatures are unchanged, reuse the verified result
without starting Codex or writing files. If they changed, do a read-only
verification before deciding whether repair is needed. Cache unsupported
results too so an old CLI is not probed on every launch.

Every provisioning subprocess shares one hard operation deadline and is
terminated/reaped when it expires. The initial spike chooses a measured budget
in the 3–5 second range. A timeout ends provisioning for that launch; it never
continues updating in the background after the managed session starts.

Prevent failure storms. After two failures with identical executable/config/
bundle signatures, park the status at `failed` and launch without skills on
subsequent attempts. Retry only after a relevant signature changes or the user
chooses Repair.

When the bundled digest/version differs, install it immediately before the new
managed launch, even when other Codex sessions are active. Existing processes
keep running with whatever plugin state they already loaded; they may need a
restart before invoking Toastty skills again. Newly launched processes receive
the current verified version.

During app restoration, Toastty byte-verifies an unchanged installed bundle
without starting a subprocess. A missing, changed, or repair-requested bundle
runs the same four-second provisioning path synchronously before Toastty
submits the restored agent's resume command. This may delay restored panes once
after a skill-changing Toastty update, but ensures successfully prepared Codex
and Claude sessions resume with the current bundled skills. Failure remains
fail-open and the session resumes without Toastty skills.

Apply updates on any digest difference, including app downgrades; version
ordering is display information rather than the update decision. The plugin
manifest version must be bumped whenever shipped skill content
changes. The content digest still detects same-version changes in development
builds and exposes the mismatch in technical status; the release checklist and
review gate enforce the version bump.

For removed skills, keep Codex's disabled-name entry as a harmless tombstone.
This is how `toastty:worktree-done` is retired from users who installed the
five-skill development version.

## Claude Code launch architecture

Add `.claude-plugin/plugin.json` to the shared plugin. Before a managed Claude
launch, copy the validated plugin atomically to an immutable content-addressed
path such as:

```text
~/.toastty/agent-plugins/claude/<version>-<digest>/toastty/
```

If it already exists and validates, do not rewrite it. The digest is computed
over sorted relative paths and file bytes only, excluding timestamps, extended
attributes, and Finder metadata. Copying normalizes required executable modes
and removes quarantine only from the Toastty-owned staged copy. Inject
`--plugin-dir <that-plugin-root>` next to the existing generated `--settings`
argument and set `TOASTTY_SKILLS_ROOT=<that-plugin-root>/skills`.

Toastty, not Claude's plugin installer, advances this session-only copy because
the plugin is deliberately not installed in Claude. New launches select the
new content-addressed path after a Toastty update; running sessions keep their
old immutable path. These bundles are small, so the first slice retains old
versions rather than adding a risky live-session garbage collector. Bounded
cleanup can be added later with explicit session leases.

Respect existing user `--plugin-dir` flags: Toastty's flag is additive. Refuse
injection for an argv shape where the real Claude executable cannot be located
safely. Existing temporary `--settings` hook merging remains unchanged.

## Hook boundary and branch cleanup

Preserve the merged `main` behavior for Codex hooks and reconciliation while
retaining only skill-related pieces from this branch:

- Treat the merged implementations in `Sources/CodexReconciliation/`,
  `CodexHookEventPayloadDecoder.swift`, `CodexSessionLogWatcher.swift`,
  `ManagedAgentNativeSessionObserver.swift`, and the reconciliation portions of
  `SessionRuntimeStore.swift` as the baseline. Skills work must not alter their
  status, approval, root-turn, or subagent authority.
- For pure hook files such as `CodexStatusHookInstaller.swift`, compare against
  current `main` and remove only branch-introduced session-hook changes. Do not
  overwrite newer `main` behavior or manually reconstruct the files.
- `CodexStatusHookInstaller` continues installing and maintaining Toastty's
  owned global hook entries and stable forwarder.
- Existing hook setup/preflight UI remains `Set Up Agent Status Hooks…`.
- Existing users do not need to re-trust hooks because this feature does not
  change their hook definitions or command path.
- Do not remove Toastty-owned hooks during skills install, repair, update, or
  uninstall.
- Remove session-hook contracts, `hooks/list` assessment, inline hook TOML,
  `/hooks` guidance, and hook-migration language introduced by this branch.
- Keep notify/session-log fallback behavior exactly as it is on `main`.

Mixed files must be edited selectively rather than reverted wholesale so the
skill activation and resolved-Codex executable plumbing remain available. For
each mixed hunk, record whether it belongs to hooks or skills during review.
Add an architecture test that the skills manager cannot import or reference
hook paths, installer types, hook assessment APIs, or Codex reconciliation
types.

## Existing global skills

Toastty never inspects, moves, removes, or backs up skills under
`~/.codex/skills`, `~/.claude/skills`, or `~/.agents/skills`. The one-time
banner and shared skill-detail sheet explain that separately installed global
copies were not changed and point users to those discovery roots if duplicate,
unnamespaced Toastty skills appear. Cleanup remains an explicit user action.
Repository-local `.agents/skills` are never changed by runtime provisioning.

Update `scripts/agents/link-global-skills.sh` to exclude Codex and to require an
explicit development target. Repo-local `.agents/skills` remains the normal
way to exercise the skills while developing Toastty.

## Affected files

Plugin, validation, and resources:

- `plugins/toastty/.codex-plugin/plugin.json`
- new `plugins/toastty/.claude-plugin/plugin.json`
- `plugins/toastty/skills/**`
- `.agents/skills/**`
- `.agents/plugins/marketplace.json`
- `scripts/agents/validate-toastty-plugin.py`
- `scripts/agents/toastty-plugin-self-test.sh`
- `scripts/agents/link-global-skills.sh`
- `Project.swift`

Codex/Claude provisioning and launch:

- `Sources/App/Agents/CodexIntegrationManager.swift` (rename/refactor to
  `CodexSkillsManager.swift`)
- `Sources/App/Agents/CodexAppServerClient.swift` (skills config/list only)
- `Sources/App/Agents/CodexManagedLaunchIntegrationResolver.swift`
- `Sources/App/Agents/CodexSessionIntegration.swift` (replace with a
  skills-only contract/serializer)
- new `Sources/App/Agents/ClaudeSkillsBundleManager.swift`
- `Sources/App/Agents/AgentLaunchInstrumentation.swift`
- `Sources/App/Agents/ManagedAgentLaunchPlanner.swift`
- `Sources/App/Agents/AgentLaunchService.swift`
- `Sources/Core/Sessions/ToasttyLaunchContextEnvironment.swift`
- `Sources/App/Automation/AutomationCommandExecutor.swift`, where the socket and
  app-control managed-launch requests now pass the resolved Codex hint
- the existing shim and CLI request bridges

Keep `Sources/App/Automation/AutomationSocketServer.swift` transport-only. It
should not gain skills provisioning behavior. Likewise, avoid changes to
`Sources/CodexReconciliation/**` and the reconciliation paths in
`Sources/App/Sessions/SessionRuntimeStore.swift`; they are regression surfaces,
not skills integration points.

Hooks and UI cleanup/additions:

- `Sources/App/Agents/CodexStatusHookInstaller.swift`
- `Sources/App/Agents/AgentLaunchUI.swift`
- `Sources/App/Agents/AgentGetStartedSheet.swift`
- new `Sources/App/Agents/CodexSkillsManagementSheet.swift`
- `Sources/App/AppWindowView.swift` and a small notice/status store
- `Sources/App/Commands/ToasttyBuiltInCommand.swift`
- `Sources/App/Commands/ToasttyCommandMenus.swift`
- `Sources/App/CommandPalette/CommandPaletteActionHandler.swift`
- `Sources/App/ToasttyApp.swift`

Update the corresponding tests plus `README.md`, `docs/running-agents.md`,
`docs/privacy-and-local-data.md`, `docs/cli-reference.md`, and
`docs/socket-protocol.md` to remove the superseded setup/session-hook claims.
Edit `docs/privacy-and-local-data.md` surgically so the merged reconciliation
retention limits and local-data disclosures remain intact.

## Implementation sequence

0. Land and run the isolated host-capability spike above; record supported CLI
   versions and choose the verified Codex staging transaction.
1. Re-scope the plugin to four skills, add the Claude manifest, restore
   `worktree-done` as repo-local, neutralize the bundle resource name, and make
   validation enforce the dual-host contract.
2. Add `TOASTTY_AGENT` to managed launch context and make `worktree-create`
   preserve Codex/Claude provider continuity.
3. Implement immutable Claude bundle staging and additive `--plugin-dir`
   injection alongside existing Claude hook settings.
4. Reconcile the branch against the merged `main` hook and Codex reconciliation
   baseline: preserve its installer, preflight, payload decoding, status
   authority, UI wording, tests, and docs while stripping branch-introduced
   session-hook behavior out of the skills integration types.
5. Implement the async Codex skills manager, CLI-backed install/reinstall,
   disabled-first ordering, rollback, idempotent verification, and immediate
   update behavior.
6. Wire verified Codex skills into managed create/resume/fork launches. During
   synchronous workspace restoration, reuse a byte-verified current install or
   run bounded provisioning before the resume command is submitted.
7. Add the shared skills sheet and one-time per-agent non-blocking notices. Keep
   the existing Get Started hook flow separate.
8. Update docs, run the full verification gate, exercise real isolated Codex
   and Claude launches, review the combined diff, and commit.

## Tests and validation

Add focused tests for:

- exact dual-manifest version and four-skill allowlists;
- absence of `worktree-done` from app/plugin bundles and its repo-local use;
- helper execution from copied Codex and Claude plugin paths;
- `TOASTTY_AGENT` propagation and worktree child-agent defaults;
- first Codex launch install, disabled-before-discovery ordering, and managed
  process enablement;
- behavioral ordinary Codex exclusion and failed explicit use of a fixture
  skill, contrasted with successful managed-session discovery/use;
- no writes when a verified install and all fingerprints are unchanged;
- immediate update with active sessions, restored-session pre-resume update,
  rollback, repair, and uninstall without any hook-file access;
- installed-path content mismatch, downgrade-by-digest, failure backoff,
  unsupported-result caching, and tolerant parsing of added/omitted JSON fields;
- concurrent managed launches producing one serialized provisioning operation;
- preserved user marketplace registration and ownership-checked uninstall;
- retirement tombstones and proof that global and repository-local skills are
  never modified;
- install failure, timeout, unsupported Codex, malformed JSON, conflicting
  config, and opaque wrappers all launching without skills;
- direct Codex/`cdx`, resume, fork, supported wrapper, typed shim, menu,
  app-control, and socket launch shapes;
- Claude direct/resume/continue/wrapper shapes, additive user plugin dirs,
  duplicate-name collision behavior, immutable old/new versions, and failure
  fallback;
- unchanged global hook install/preflight/telemetry tests from `main`;
- the `CodexReconciliationTests` target and the root-progress, session-behavior,
  and subagent-reconciliation characterization tests remaining unchanged;
- `AutomationSocketServerManagedLaunchTests` covering Codex capability-hint and
  preflight routing through `AutomationCommandExecutor`;
- an already trusted global Codex hook remaining trusted after skills install,
  update, repair, managed launch, and uninstall;
- deterministic content digests, normalized helper modes, and quarantine-free
  Toastty-owned staged copies;
- shared sheet status/skills/summaries/actions, manual duplicate guidance, and
  one-time per-agent notice persistence.

Use temporary home and `CODEX_HOME` directories for all real compatibility
tests. Never mutate the developer's actual Codex, Claude, or Toastty state.

Validation after implementation:

1. Run plugin/skill validators and focused unit/script tests after each slice.
2. Regenerate the Tuist project, build the app, and run the dedicated
   `CodexReconciliationTests` target plus the merged characterization tests.
3. Use `.agents/skills/toastty-verify/SKILL.md` for the full local/remote gate
   and its QA decision.
4. Against isolated state, prove ordinary Codex lists all four skills disabled,
   cannot load a fixture skill, managed Codex exposes/loads it, and plugin
   reinstall upgrades the cached bytes without changing hooks.
5. Prove managed Claude lists the same four names from `--plugin-dir` while an
   ordinary Claude launch with clean isolated state does not.
6. Exercise failure, active-session update, and app-restart restore scenarios
   end to end through the real launch surface, not only manager tests.
7. Run Claude change-set review on the risky provisioning/launch diff and
   address accepted findings before commit.

## Edge cases and non-goals

- Multiple simultaneous launch requests serialize through the provisioning
  manager; use a cross-process file lock as well if the capability spike shows
  another Toastty/CLI process can mutate the same state concurrently.
- A first install or update proceeds immediately even when another managed
  Codex session is active. Existing processes may need restart before invoking
  Toastty skills again.
- Custom `CODEX_HOME` values get independent installation/status keys.
- A Codex downgrade that cannot load the plugin is `unsupported`, not repaired
  in a loop.
- Inside the Toastty development repository, repo-local compatibility skills
  may coexist with the namespaced plugin skills. Treat that as a documented
  dev-only condition and test that Codex emits no duplicate-name error; do not
  weaken ordinary user-session isolation to hide it.
- If Codex or Claude also discovers a user-installed global skill with the same
  plain name, leave it untouched, show manual duplicate guidance, and verify
  that the namespaced Toastty plugin remains callable for the managed session.
- Persistent disables always cover the union of old and new Toastty skill
  names before install/update. (Superseded: the profile-based mechanism
  writes no persistent disables; see the note above.)
- Do not create a `CODEX_HOME` overlay home, global Claude install, custom
  skill editor, hook migration, or hook trust bypass. (The earlier "no named
  Codex profile" non-goal is superseded by profile-based delivery.)
- Do not add automatic old-Claude-bundle deletion in the first slice.

## User-created skills (added 2026-08-04)

Beyond this plan's shipped four-skill plugin, the branch also delivers
user-authored skills from `~/.toastty/skills/<name>/SKILL.md` (validated
name/frontmatter contract, per-package and catalog-wide caps, symlinks and
special files rejected). Accepted packages are snapshotted into an immutable
content-addressed `toastty-user` plugin under `~/.toastty/agent-plugins/user/`
and delivered only to newly launched managed sessions: Codex through the same
`toastty-managed` profile overlay plus a `$CODEX_HOME/plugins/cache/toastty-user/`
cache, Claude Code through a second additive `--plugin-dir`. User-plugin
failures never affect shipped-skill delivery, ordinary sessions see nothing,
`TOASTTY_USER_SKILLS_ROOT` advertises the source directory to managed
sessions, and a startup sweeper garbage-collects superseded snapshots. The
management sheet gained a user section (package statuses, Rescan, open/create
folder). See `docs/running-agents.md` ("User-created skills") for the shipped
contract.

## References

- Codex plugin CLI and marketplace semantics are documented in the current
  Codex manual (`codex plugin` and `codex plugin marketplace`).
- Claude's official plugin documentation defines `.claude-plugin/plugin.json`
  and session-only `--plugin-dir` loading:
  <https://code.claude.com/docs/en/plugins>
- Claude's plugin reference documents plugin layout and versioned cache
  behavior: <https://code.claude.com/docs/en/plugins-reference>
