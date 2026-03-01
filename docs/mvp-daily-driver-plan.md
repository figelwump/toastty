# Toastty Daily-Driver MVP Plan

Date: 2026-02-28
Status: completed (M1-M4 implemented and validated; post-MVP continuation active)
Supersedes execution priority of `docs/implementation-plan.md` until this MVP is complete.

## 1) Goal

Ship a practical MVP that can replace the current daily Ghostty workflow for core coding sessions.

Primary outcome:
- reliable keyboard-driven pane workflow (`split`, `move focus between panes`) with Ghostty parity.
- terminal-first UI/chrome parity with Paper designs so the app feels production-usable.

## 2) Scope

In scope for this MVP:
- Ghostty split/navigation keybinding parity for macOS defaults and user overrides.
- terminal sizing/visual cleanup:
  - reduce default terminal text size.
  - remove outer pane ID containers.
  - remove rounded corners; panes render flush with square edges.
- sidebar/topbar chrome parity from Paper `Toastty*` artboards (fonts, colors, spacing, badges, selected workspace styling).

Out of scope for this MVP:
- new diff/markdown feature behavior.
- scratchpad.
- laptop-specific layout behavior changes beyond inheriting shared chrome styles.
- layout profiles.

## 3) Design Spec Baseline (from Paper MCP)

Reference artboards:
- `Toastty` (`FJ8-0`)
- `Toastty: All Panels Open` (`HS6-0`)
- `Toastty: Laptop Sized Layout` (`HYF-0`)

Core visual tokens to implement:
- colors:
  - chrome bg: `#111111`
  - surface bg: `#0D0D0D`
  - elevated row/button bg: `#1A1A1A`
  - hairline border: `#1F1F1F`
  - primary text: `#E8E4DF`
  - muted text ramp: `#666666`, `#555555`, `#444444`, `#333333`
  - accent (active/selection): `#F5A623`
  - notification badge: `#3B82F6` (+ subtle glow)
- sidebar:
  - width desktop: `180`
  - width laptop: `148`
  - selected workspace has `2px` left accent border and dark selected fill.
- top bar:
  - height `36`
  - horizontal padding `12`
  - bottom border `1px` hairline.
- terminal pane layout:
  - split gaps `0`
  - pane separators via `1px` borders
  - no rounded corners on panes
  - terminal header height ~`25` with `5px/12px` padding
  - terminal content padding `12px/16px`
- typography direction:
  - UI labels: Geist-like sans style.
  - terminal/body monospace: Geist Mono-like style.
  - if custom fonts unavailable at runtime, use deterministic fallback stack preserving hierarchy.

## 4) Keyboard Parity Strategy

Decision:
- support Ghostty keybindings via Ghostty action callback routing (not static hardcoded shortcut maps).

Why:
- Ghostty already resolves default + user keybind overrides from config.
- routing Ghostty actions keeps behavior aligned with user Ghostty setup automatically.

MVP-required actions:
- `new_split:right`
- `new_split:down`
- `goto_split:previous`
- `goto_split:next`
- directional split focus (`goto_split:left/right/up/down`) if delivered by keybind config.

Default macOS bindings to verify (current Ghostty defaults):
- `cmd+d` -> `new_split:right`
- `cmd+shift+d` -> `new_split:down`
- `cmd+[` -> `goto_split:previous`
- `cmd+]` -> `goto_split:next`
- `cmd+alt+arrow` -> directional `goto_split:*`

Important scope line:
- we will not block MVP on implementing every Ghostty action in one pass (tabs/windows/clipboard/etc).
- we will implement all split-navigation actions first, then add high-impact extras already supported by app state.

Shortcut coverage policy:
- phase 1 (required): all Ghostty split actions (`new_split`, `goto_split`, `resize_split`, `equalize_splits`, `toggle_split_zoom`) that have a direct app analog.
- phase 2 (opportunistic): map additional Ghostty actions already supported in Toastty (`increase_font_size`, `decrease_font_size`, `reset_font_size`).
- phase 3 (deferred): actions requiring missing Toastty primitives (tabs/windows command palette parity beyond existing behavior, clipboard runtime callbacks, etc.).

## 5) Implementation Chunks

### Chunk M1: Ghostty action router + pane-focus primitives

Deliverables:
- introduce app actions for pane focus traversal/navigation (previous/next + directional fallback handling).
- wire Ghostty `action_cb` to dispatch app actions using source surface/panel resolution.
- keep non-Ghostty build shortcuts for essential actions as fallback.

Likely files:
- `Sources/App/Terminal/GhosttyRuntimeManager.swift`
- `Sources/App/Terminal/TerminalRuntimeRegistry.swift`
- `Sources/Core/AppAction.swift`
- `Sources/Core/AppReducer.swift`
- `Tests/Core/AppReducerTests.swift`

Validation:
- reducer tests for split creation and pane focus movement.
- manual Ghostty run: verify `cmd+d`, `cmd+shift+d`, `cmd+[`, `cmd+]`.
- `./scripts/automation/check.sh`
- `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh`

### Chunk M2: Pane container cleanup + terminal sizing fixups

Deliverables:
- remove pane ID wrappers from workspace UI.
- render pane surfaces edge-to-edge with square corners and zero inter-pane gaps.
- set default global terminal font to `11` (with existing min/max constraints retained unless testing says otherwise).

Likely files:
- `Sources/App/WorkspaceView.swift`
- `Sources/App/Terminal/TerminalPanelHostView.swift`
- `Sources/Core/AppState.swift`
- `Tests/Core/AppStateCodableTests.swift`
- smoke automation snapshots as needed.

Validation:
- manual run confirms no rounded pane shells and no pane-ID container chrome.
- screenshot artifact comparison against Paper structure (layout-level, not pixel-perfect).
- baseline + Ghostty smoke + check script.

### Chunk M3: Sidebar/topbar chrome parity

Deliverables:
- introduce shared UI tokens for colors/spacing/typography.
- restyle sidebar selection state, workspace row subtext, and notification badge.
- restyle top bar controls while keeping existing controls visible (`Diff`, `Markdown`, `Focus Panel`, split buttons).

Likely files:
- `Sources/App/AppRootView.swift`
- `Sources/App/SidebarView.swift`
- `Sources/App/WorkspaceView.swift`
- new style token file in `Sources/App/` (e.g. `Theme.swift`).

Validation:
- manual screenshots for the three design states.
- automation screenshot capture updated to include chrome-focused shots.
- baseline + Ghostty smoke + check script.

### Chunk M4: Daily-driver hardening

Deliverables:
- extend automation actions/assertions for split/focus keyboard workflows.
- add a short manual QA checklist for day-to-day runs.
- document Ghostty shortcut parity and known unsupported Ghostty actions.

Likely files:
- `scripts/automation/smoke-ui.sh`
- `Sources/App/Automation/AutomationSocketServer.swift`
- `AGENTS.md`
- `docs/mvp-daily-driver-plan.md` (execution log section updates)

Validation:
- smoke scripts deterministic in both baseline and Ghostty paths.
- manual app exercise for at least one real coding command flow.

## 6) Execution Loop (for each chunk)

For each chunk:
1. implement.
2. validate changed behavior (tests + smoke + live app).
3. commit with descriptive message.
4. run Claude second-opinion review.
5. accept/reject review points with rationale.
6. apply accepted fixes, re-test, commit.
7. append execution notes to this file.

## 7) Risks and Mitigations

- risk: Ghostty callback routing without source panel mapping causes wrong-pane actions.
  - mitigation: enforce surface->panel lookup in registry and no-op safely when unresolved.
- risk: style parity work regresses focus/interaction.
  - mitigation: keep behavior tests and add explicit keyboard/manual validation checklist.
- risk: custom font mismatch across machines.
  - mitigation: use ordered fallback stacks; treat exact typeface as best-effort, not blocker.

## 8) Open Decisions

Resolved:
- default terminal font target: `11`.
- keep panel headers (future drag affordance area).
- keep top-bar controls visible, restyle only.

Pending:
- none blocking for M1 start.

## 9) Execution Log

2026-02-28:
- plan created from user requirements and Paper `Toastty*` artboards.
- confirmed Ghostty macOS default split/focus keybinds locally via `ghostty +list-keybinds`.

2026-02-28 (Chunk M1: Ghostty action router + pane-focus primitives):
- implemented new core action surface:
  - `splitFocusedPaneInDirection(workspaceID:direction:)`
  - `focusPane(workspaceID:direction:)`
  - new enums: `PaneSplitDirection`, `PaneFocusDirection`
- reducer updates:
  - directional split supports `.left/.right/.up/.down` placement.
  - pane focus supports:
    - wrapped structural navigation (`previous`/`next`)
    - spatial navigation (`up/down/left/right`) via normalized pane-frame geometry derived from split ratios.
- Ghostty runtime callback wiring:
  - `GhosttyRuntimeManager` now routes `action_cb` intents to a main-actor action handler.
  - `TerminalRuntimeRegistry` now tracks `ghostty_surface_t -> panelID` mappings and resolves source workspace from app state.
  - mapped Ghostty actions:
    - `new_split:*` -> directional split
    - `goto_split:*` -> pane focus movement
    - `toggle_split_zoom` -> focused-panel mode toggle (closest existing analog)
- non-Ghostty fallback:
  - added `Pane` command menu shortcuts when GhosttyKit is not linked:
    - `cmd+d` split right
    - `cmd+shift+d` split down
    - `cmd+[`/`cmd+]` focus previous/next pane
- automation command surface additions for deterministic testing:
  - `workspace.split.{right,down,left,up}`
  - `workspace.focus-pane.{previous,next,left,right,up,down}`
- validation:
  - `./scripts/automation/check.sh` (pass, 70 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - manual Ghostty shortcut exercise in running app (automation-launched app + System Events key chords):
    - key sequence: `cmd+d`, `cmd+shift+d`, `cmd+]`, `cmd+[`
    - terminal panel count observed from state dump changed from `1` -> `3`
    - focused panel ID changed after pane navigation
    - screenshot artifact:
      - `artifacts/manual/ui/manual-shortcuts-20260227-185331/single-workspace/ghostty-shortcuts-manual.png`

2026-02-28 (Chunk M1 follow-up: reviewer hardening fixes):
- accepted and implemented second-opinion review points:
  - runtime action callback now executes on main thread even when invoked from a non-main Ghostty callback thread (sync handoff), instead of returning unhandled.
  - Ghostty action handler registration moved to `TerminalRuntimeRegistry.bind(store:)` (single assignment) rather than repeated per-surface setup.
  - Ghostty action routing now validates `action.tag` and direction payload before mutating focus state, avoiding side effects for unsupported tags.
- validation:
  - `./scripts/automation/check.sh` (pass, 70 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - note: `TOASTTY_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` is not reliable for Tuist-generate flows; use `TUIST_ENABLE_GHOSTTY=1`.

2026-02-28 (Chunk M1 follow-up: deadlock-safe callback routing):
- replaced synchronous cross-thread handoff in `ghosttyActionCallback` with a deadlock-safe queued main-actor dispatch path.
- introduced typed `GhosttyRuntimeAction` payload:
  - callback now parses supported actions and source surface handle eagerly, returns `false` for unsupported tags.
  - known actions are enqueued on the main actor and routed through the registry handler.
- moved Ghostty tag/direction parsing from `TerminalRuntimeRegistry` into runtime manager callback parsing.
- added defensive single-store bind guard in `TerminalRuntimeRegistry.bind(store:)` to prevent accidental rebinding to a different store instance.
- validation:
  - `./scripts/automation/check.sh` (pass, 70 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)

2026-02-28 (Chunk M1 follow-up: callback return semantics hardening):
- revised callback dispatch model after follow-up review:
  - Ghostty action callback now handles only on main thread and returns the actual handled result.
  - off-main callback invocations return unhandled (no async fire-and-forget), avoiding incorrect `true` acknowledgements.
- rebinding contract tightened:
  - `TerminalRuntimeRegistry.bind(store:)` now uses a hard `precondition` to prevent rebinding to a different `AppStore`.
  - Ghostty action handler registration remains in `bind(store:)` after the store is available.

2026-02-28 (Chunk M2: pane container cleanup + terminal sizing):
- removed pane-ID wrapper chrome from workspace pane rendering:
  - deleted `Pane XXXXX` labels and outer rounded pane shells.
  - leaf panes now render only the selected tab panel surface (no stacked tab panel list).
- made pane layout flush and square:
  - split stacks now use `spacing: 0` with explicit `1px` separators.
  - panel shells and terminal hosts now render with square borders (no rounded clipping).
  - workspace content no longer applies outer padding around pane tree.
- reduced default terminal sizing:
  - `AppState.defaultTerminalFontPoints` updated from `13` to `11`.
  - automation fixtures now consume `AppState.defaultTerminalFontPoints` to keep smoke state representative of default app behavior.
- test coverage:
  - added `bootstrapUsesDefaultTerminalFontSize()` in `Tests/Core/AppStateCodableTests.swift`.
- validation:
  - `./scripts/automation/check.sh` (pass, 71 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - updated smoke artifacts:
    - `artifacts/automation/ui/smoke-20260227-191037/split-workspace/aux-column-smoke.png`
    - `artifacts/automation/ui/smoke-20260227-191102/split-workspace/terminal-viewport-smoke.png`

2026-02-28 (Chunk M2 follow-up: reviewer fixes):
- accepted points:
  - added assertion-backed recovery for out-of-range `selectedIndex` in `PaneNodeView` (fallback to first tab panel with debug assertion).
  - switched panel border overlay from `stroke` to `strokeBorder` for cleaner square edge rendering.
  - removed dead `expanded` branching from `PanelCardView` and simplified to always fill pane bounds.
- rejected point:
  - kept explicit `#expect(AppState.defaultTerminalFontPoints == 11)` assertion to enforce MVP-required default, not just relative bootstrap behavior.
- re-validation:
  - `./scripts/automation/check.sh` (pass, 71 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)

2026-02-28 (Chunk M3: sidebar/topbar chrome parity):
- added shared theme tokens in `Sources/App/Theme.swift`:
  - Paper-aligned base colors (`#111111`, `#0D0D0D`, `#1A1A1A`, `#1F1F1F`, `#E8E4DF`, `#666666`, `#555555`, `#F5A623`, `#3B82F6`).
  - shared typography presets and shell constants (`sidebarWidth=180`, `topBarHeight=36`).
- restyled app chrome:
  - `AppRootView`: themed root background, 1px hairline divider between sidebar/workspace, themed font HUD.
  - `SidebarView`: selected workspace row styling with accent-leading border, subtext/shortcut tone, unread notification badge (blue capsule + glow), restyled new workspace action.
  - `WorkspaceView` top bar: fixed-height chrome bar, themed control pills for `Diff`, `Markdown`, `Focus Panel`, `Split Horizontal`, `Split Vertical` (controls remain visible).
- panel surfaces updated to consume shared theme tokens for headers/borders/separators to keep visual consistency with restyled chrome.
- validation:
  - `./scripts/automation/check.sh` (pass, 71 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - artifact references:
    - `artifacts/automation/ui/smoke-20260227-191623/split-workspace/aux-column-smoke.png`
    - `artifacts/automation/ui/smoke-20260227-191640/split-workspace/terminal-viewport-smoke.png`

2026-02-28 (Chunk M3 follow-up: reviewer fixes):
- accepted points:
  - moved top-bar `.buttonStyle(.plain)` earlier in modifier chain for clearer styling semantics.
  - improved selected workspace row styling so accent bar remains visible and not clipped/overdrawn by rounded clipping/border order.
  - added `lineLimit(1)` + truncation for workspace titles at `180px` sidebar width.
  - introduced `ToastyTheme.paneDivider` (`#333333`) for pane split separators to preserve visibility on dark surfaces.
  - restored adaptive material background for `FontHUD` and explicitly enforced `.preferredColorScheme(.dark)` for the dark MVP chrome.
  - removed badge shadow and switched badge text color to themed primary text.
- rejected points:
  - no model change required for `workspace.unreadNotificationCount`; property already exists in `WorkspaceState`.
- re-validation:
  - `./scripts/automation/check.sh` (pass, 71 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)

2026-02-28 (Chunk M4: daily-driver hardening):
- automation runtime surface:
  - added `automation.workspace_snapshot` command in `AutomationSocketServer` returning:
    - `workspaceID`
    - `paneCount`
    - `panelCount`
    - `focusedPanelID`
    - `leafPaneIDs`
    - `leafPanelIDs`
- smoke assertions extended for split/focus workflow:
  - baseline snapshot capture after fixture load.
  - assert `workspace.focus-pane.next` changes focused panel.
  - assert `workspace.focus-pane.previous` returns focus to baseline panel.
  - assert `workspace.split.right` increases pane count.
- docs/process hardening:
  - updated `AGENTS.md` with:
    - new smoke assertion behavior
    - daily-driver QA checklist
    - Ghostty shortcut parity snapshot + deferred gaps
  - updated `docs/ghostty-integration.md` with current mapped actions and deferred action list.
- validation:
  - `./scripts/automation/check.sh` (pass, 71 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - new smoke artifacts with workflow assertions:
    - `artifacts/automation/ui/smoke-20260227-192246/split-workspace/aux-column-smoke.png`
    - `artifacts/automation/ui/smoke-20260227-192304/split-workspace/terminal-viewport-smoke.png`

2026-02-28 (Chunk M4 follow-up: reviewer fixes):
- accepted point:
  - made focus-next/focus-previous smoke assertions conditional on `paneCount > 1` so fixture overrides with single-pane layouts do not fail spuriously.
- rejected points (with rationale):
  - `automation.workspace_snapshot` without explicit `workspaceID` is valid by design because `resolveWorkspaceID` falls back to selected workspace.
  - `cmd+shift+f` QA checklist entry is valid; shortcut is wired in `WorkspaceView.focusedPanelToggle`.
  - `leafPanelIDs` duplication concern is non-issue for current pane model (each panel belongs to a single leaf).
- re-validation:
  - `./scripts/automation/check.sh` (pass, 71 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)

2026-02-28 (MVP closeout):
- all planned chunks (`M1` through `M4`) completed and validated.
- implementation remains intentionally scoped:
  - deferred Ghostty parity items remain tracked in `AGENTS.md` and `docs/ghostty-integration.md`.

2026-02-28 (Post-MVP continuation: split resize/equalize parity):
- added new core actions for split resizing and equalization:
  - `resizeFocusedPaneSplit(workspaceID:direction:amount:)`
  - `equalizePaneSplits(workspaceID:)`
  - new direction enum: `PaneResizeDirection` (`up/down/left/right`)
- reducer behavior:
  - resize updates the nearest focused-pane ancestor split matching axis (`horizontal` for left/right, `vertical` for up/down).
  - ratio deltas apply bounded steps (`0.02 * amount`, clamped) with ratio clamped to `0.1...0.9`.
  - equalize recursively normalizes all split ratios to `0.5`.
  - both actions are blocked while focused-panel mode is active (same policy as split/aux layout mutations).
- Ghostty routing parity:
  - mapped `resize_split:{up,down,left,right}` and `equalize_splits` runtime callbacks into the new core actions.
- automation command surface additions:
  - `workspace.resize-split.{left,right,up,down}` (`args.amount` optional int)
  - `workspace.equalize-splits`
  - `automation.workspace_snapshot` now includes `rootSplitRatio` for deterministic ratio assertions.
- smoke updates:
  - validates resize/equalize actions by asserting root split ratio increase + normalization.
  - Ghostty terminal viewport assertion is currently best-effort in automation:
    - if terminal surfaces remain unavailable (`available:false`), smoke logs a note and continues.
- test coverage:
  - added reducer tests:
    - `resizeFocusedPaneSplitAdjustsNearestMatchingRatio`
    - `resizeFocusedPaneSplitReturnsFalseWhenNoMatchingSplitOrientationExists`
    - `equalizePaneSplitsNormalizesNestedRatios`
- validation:
  - `./scripts/automation/check.sh` (pass, 74 tests)
  - `./scripts/automation/smoke-ui.sh` (pass; Ghostty viewport step currently skipped when surface unavailable)
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)

2026-02-28 (Post-MVP continuation follow-up: Ghostty dispatch completion):
- completed Ghostty runtime dispatch wiring in `TerminalRuntimeRegistry` for:
  - `resize_split` -> `.resizeFocusedPaneSplit(...)`
  - `equalize_splits` -> `.equalizePaneSplits(...)`
- re-validation:
  - `./scripts/automation/check.sh` (pass, 74 tests)
  - `./scripts/automation/smoke-ui.sh` (pass; Ghostty viewport step still best-effort when surface unavailable)
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)

2026-02-28 (Post-MVP continuation reviewer follow-up: reducer + tests hardening):
- accepted and implemented:
  - simplified resize amount clamping to a single clamp site (`splitResizeDelta`) to avoid duplicated clamp logic.
  - optimized equalize traversal to return the original node when no subtree ratio changes are required.
  - added explicit off-main-thread callback diagnostics in `ghosttyActionCallback` (assert + stderr warning) to avoid silent drops.
  - added coverage for:
    - nearest matching ancestor resize behavior in nested split trees.
    - split ratio upper-bound clamp behavior.
    - resize/equalize mutation blocking while focused-panel mode is active.
- rejected (with rationale):
  - changing off-main callback semantics to return handled (`true`) was rejected for now because prior work intentionally avoids async-ack and sync-cross-thread deadlock risk; current behavior now emits explicit diagnostics if invariant breaks.
  - floating-point epsilon compare for equalize mutation detection was rejected because equalize writes canonical `0.5` ratios directly; repeated equalize is already covered and returns `false`.
  - removing pre-action focus sync in runtime registry was rejected because Ghostty actions should target the invoking surface’s panel and current `focusPanel` reducer path is a guarded single-field mutation.
- re-validation:
  - `./scripts/automation/check.sh` (pass, 77 tests)
  - `./scripts/automation/smoke-ui.sh` (pass; Ghostty viewport screenshot captured)
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)

2026-02-28 (Post-MVP continuation: Ghostty runtime action + font propagation fixes):
- addressed user-reported regressions:
  - Ghostty split resize / equalize shortcuts no-op while Ghostty runtime is enabled.
  - terminal font HUD updates without visible font-size changes in Ghostty terminal surfaces.
- runtime callback dispatch:
  - `ghosttyActionCallback` now synchronously routes actions onto the main queue when invoked off-main, preserving callback handled semantics instead of dropping actions.
- font propagation:
  - added `TerminalRuntimeRegistry.applyGlobalFontChange(from:to:)` and per-surface binding dispatch in `TerminalSurfaceController` using:
    - `increase_font_size:<n>`
    - `decrease_font_size:<n>`
    - `reset_font_size`
  - hooked app-level `globalTerminalFontPoints` state changes in `AppRootView` to apply Ghostty binding actions to all live terminal surfaces.
- validation:
  - `./scripts/automation/check.sh` (pass, 77 tests)
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/smoke-ui.sh` (pass; viewport step remains best-effort when surface unavailable in automation)

2026-02-28 (Post-MVP continuation reviewer follow-up: callback deadlock hardening):
- accepted point:
  - replaced blocking `DispatchQueue.main.sync` handoff in `ghosttyActionCallback` with:
    - main-queue async dispatch
    - bounded wait (`250ms`) for handled result
    - explicit timeout warning log on failure
  - rationale: avoids potential callback-thread deadlock while still preserving synchronous handled semantics where possible.
- rejected points (with rationale):
  - pointer `userdata -> UInt -> pointer` round-trip is retained to satisfy strict sendability constraints across dispatch hops and keep callback helper patterns consistent.
  - font propagation drift concern is not applicable for current model (`terminalFontStepPoints == 1`, integer-point state transitions, and reset path uses explicit `reset_font_size` action).
  - “new controller misses current font state” is not applicable because new Ghostty surfaces are initialized from current `globalFontPoints` in `ensureGhosttySurface(...)`.
- re-validation:
  - `./scripts/automation/check.sh` (pass, 77 tests)
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/smoke-ui.sh` (pass; viewport step remains best-effort when surface unavailable in automation)

2026-02-28 (Post-MVP continuation: Ghostty app-target action routing + smaller font floor):
- addressed follow-up regressions reported during manual validation:
  - Ghostty resize/equalize shortcuts still no-op for some key paths.
  - minimum font size (`9`) remained visually too large for dense side-by-side layouts.
- runtime action routing fix:
  - expanded `makeGhosttyRuntimeAction(...)` to accept both:
    - `GHOSTTY_TARGET_SURFACE` (surface-local actions)
    - `GHOSTTY_TARGET_APP` (app-scoped actions)
  - for app-scoped runtime actions, `TerminalRuntimeRegistry.handleGhosttyRuntimeAction(...)` now resolves context from:
    - selected workspace
    - focused panel fallback
  - rationale: some Ghostty bindings are emitted against app target rather than a specific surface target.
- font floor adjustment:
  - lowered `AppState.minTerminalFontPoints` from `9` to `6` to support denser pane layouts on laptop screens.
- testing gap note:
  - existing smoke automation validates state mutations via `automation.perform_action` and does not yet synthesize physical keyboard events through Ghostty key handling; manual keypress verification remains required for shortcut parity.
- validation:
  - `./scripts/automation/check.sh` (pass, 77 tests)
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `TOASTTY_ENABLE_GHOSTTY=1 tuist generate` (pass; compile conditions include `TOASTTY_HAS_GHOSTTY_KIT`)

2026-02-28 (Post-MVP continuation reviewer follow-up: deterministic app-target panel resolution):
- reviewer source: Claude second-opinion on commit `0d97aed`.
- accepted:
  - removed nondeterministic app-target fallback (`workspace.panels.keys.first`).
  - added deterministic action panel resolution from pane-tree leaf order (`resolvedActionPanelID(in:)`), preferring:
    - valid focused panel
    - selected tab in first valid leaf
    - first valid tab in that leaf
  - captured `store.state` once per action dispatch in `handleGhosttyRuntimeAction(...)` to avoid mixed-state reads.
- rejected (with rationale):
  - removing pre-intent `focusPanel` sync was rejected; routing intent should still originate from the invoking panel context (surface-target) or resolved focused panel context (app-target) before split/resize/focus/equalize.
  - adding AppState font decode migration/clamp logic was deferred; current issue scope was shortcut routing + minimum floor adjustment and no regression evidence from persisted state loading.
- re-validation:
  - `./scripts/automation/check.sh` (pass, 77 tests)
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `TOASTTY_ENABLE_GHOSTTY=1 tuist generate` + `xcodebuild -showBuildSettings` (pass; `TOASTTY_HAS_GHOSTTY_KIT` present)

2026-02-28 (Post-MVP continuation: default terminal font set to 7):
- updated `AppState.defaultTerminalFontPoints` from `11` to `7` per product direction for denser default terminal layout.
- updated codable/bootstrap assertion in `Tests/Core/AppStateCodableTests.swift` to enforce the new default.
- validation:
  - `./scripts/automation/check.sh` (pass, 77 tests)

2026-02-28 (Post-MVP continuation: app-wide logging foundation + shortcut-path instrumentation):
- added reusable logging system in `Core`:
  - `Sources/Core/Diagnostics/ToasttyLog.swift`
  - category/level logging (`debug|info|warning|error`) with structured JSON line output.
  - default file sink at `/tmp/toastty.log` with size rotation (`/tmp/toastty.previous.log`).
  - env controls:
    - `TOASTTY_LOG_LEVEL`
    - `TOASTTY_LOG_FILE` (set `none` to disable file sink)
    - `TOASTTY_LOG_STDERR`
    - `TOASTTY_LOG_DISABLE`
- instrumented critical runtime paths:
  - bootstrap + startup path (`AppBootstrap`)
  - app action dispatch/rejection (`AppStore`)
  - Ghostty callback routing (`GhosttyRuntimeManager`)
  - Ghostty runtime action resolution + reducer handoff (`TerminalRuntimeRegistry`)
  - terminal key-event forwarding to Ghostty (`TerminalHostView`)
  - reducer rejection/apply reasons for resize/equalize (`AppReducer`)
- added config tests:
  - `Tests/Core/ToasttyLogConfigurationTests.swift`
- operator usage:
  - live monitor: `tail -f /tmp/toastty.log`
  - pretty output: `tail -f /tmp/toastty.log | jq`
- validation:
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/smoke-ui.sh` (pass)

2026-02-28 (Post-MVP continuation reviewer follow-up: logging-path hardening):
- reviewer source: Claude second-opinion on pending logging/instrumentation change set.
- accepted:
  - made log message + metadata evaluation lazy in `ToasttyLog` (guard level before constructing metadata payload).
  - restored direct stderr write for automation fixture bootstrap failures so startup errors still surface when logging is disabled.
  - redacted key event payload from raw text to `text_length` only.
  - reduced duplicate warning noise by downgrading registry-level reducer rejection to debug (store retains warning).
  - normalized minor logging metadata quality (`selected_window_id` now `<none>` when absent).
- rejected (with rationale):
  - replacing exhaustive `AppAction.logName` switch with string-reflection parsing was rejected to preserve compile-time exhaustiveness and stable naming.
  - removing callback-layer Ghostty handled logs was rejected; both callback and registry layers are useful to isolate whether a drop happened before or after action routing.
- re-validation:
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `TOASTTY_ENABLE_GHOSTTY=1 tuist generate` + `xcodebuild -showBuildSettings` (pass; `TOASTTY_HAS_GHOSTTY_KIT` present)

2026-02-28 (Post-MVP continuation: real-key shortcut trace automation):
- closed the previously-documented shortcut testing gap by adding `scripts/automation/shortcut-trace.sh`.
- script behavior:
  - launches app in automation mode with `TOASTTY_LOG_LEVEL=debug`.
  - focuses terminal surface via AppKit scripting (`System Events` click).
  - sends real key chords:
    - `cmd+ctrl+right` (Ghostty `resize_split:right,10`)
    - `cmd+ctrl+=` (Ghostty `equalize_splits`)
  - validates behavior through state snapshots:
    - resize increases `rootSplitRatio`
    - equalize normalizes `rootSplitRatio` to `0.5`
  - validates observability:
    - Ghostty action-intent logs present (`resize_split.right`, `equalize_splits`)
    - input key-event forwarding logs present (`key_code` 124 and 24)
- docs/process updates:
  - `AGENTS.md` now includes shortcut-trace usage and prerequisites.
- validation:
  - `./scripts/automation/shortcut-trace.sh` (pass)
  - `./scripts/automation/check.sh` (pass, 80 tests)

2026-02-28 (Post-MVP continuation reviewer follow-up: shortcut-trace hardening):
- reviewer source: Claude second-opinion on `shortcut-trace` change set.
- accepted and implemented:
  - key chord helpers now honor configurable key codes:
    - `RESIZE_KEY_CODE`
    - `EQUALIZE_KEY_CODE`
  - added request-id dependency guard (`uuidgen`) and request timeout (`nc -w 2`) to avoid indefinite socket hangs.
  - improved numeric JSON extraction:
    - uses `jq` when available with fallback regex parser.
  - hardened startup liveness check:
    - retries `kill -0` after a short delay before treating startup as failed.
  - replaced fixed post-key sleeps with bounded snapshot polling for resize/equalize assertions.
  - screenshot capture now fails loudly when path is missing/unresolved.
  - default focus click now derives from app window bounds and targets a left-pane-biased point; explicit `CLICK_X`/`CLICK_Y` overrides remain supported.
- rejected/deferred:
  - force-killing prior `ToasttyApp` processes was rejected to avoid interrupting active manual app sessions.
  - changing documented dates was rejected as out of scope; entries intentionally reflect current log chronology.
- re-validation:
  - `./scripts/automation/shortcut-trace.sh` (pass)
  - `./scripts/automation/check.sh` (pass, 80 tests)

2026-02-28 (Post-MVP continuation: real-key split/focus trace expansion):
- expanded `scripts/automation/shortcut-trace.sh` coverage beyond resize/equalize:
  - verifies split/focus key chords with real input events:
    - `cmd+d` (`split.right`)
    - `cmd+shift+d` (`split.down`)
    - `cmd+]` (`focus.next`)
    - `cmd+[` (`focus.previous`)
  - asserts state mutations via `automation.workspace_snapshot`:
    - pane count increases after split-right and split-down
    - focus changes after focus-next and restores after focus-previous
  - verifies matching Ghostty intent logs + forwarded key-event logs for all traced shortcuts.
- script ergonomics:
  - added shortcut key-code env overrides:
    - `SPLIT_KEY_CODE`, `FOCUS_NEXT_KEY_CODE`, `FOCUS_PREVIOUS_KEY_CODE`, `RESIZE_KEY_CODE`, `EQUALIZE_KEY_CODE`
  - retained coordinate override path for focus targeting:
    - defaults `CLICK_X=760`, `CLICK_Y=420` with override support for display/layout differences.
- validation:
  - `./scripts/automation/shortcut-trace.sh` (pass)
  - `./scripts/automation/check.sh` (pass, 80 tests)

2026-02-28 (Post-MVP continuation reviewer follow-up: split/focus trace expansion):
- reviewer source: Claude second-opinion on split/focus shortcut-trace expansion.
- accepted and implemented:
  - removed dead/unreachable focus fallback branch in `focus_app_terminal` (explicit coordinate path only).
  - added bounded polling after split-workflow fixture reload before reading baseline pane/focus fields.
- rejected (with rationale):
  - concern about `focus-previous` assertion validity was rejected; the check intentionally validates an immediate `next -> previous` round-trip and is independent of total pane count.
  - substring false-positive concern for key-code log matching was rejected; patterns include closing quotes (for example `"key_code":"2"`) so `"20"`/`"21"` lines do not match.
  - splitting key-code override into separate right/down env vars was rejected for now; both actions intentionally share the same physical key with modifier variation (`cmd` vs `cmd+shift`).
- re-validation:
  - `./scripts/automation/shortcut-trace.sh` (pass)
  - `./scripts/automation/check.sh` (pass, 80 tests)

2026-02-28 (Post-MVP continuation: deterministic Ghostty viewport assertion in smoke):
- removed best-effort behavior for Ghostty viewport validation in `scripts/automation/smoke-ui.sh` when Ghostty integration is enabled.
- smoke now resolves terminal send-text target from a candidate set:
  - `SPLIT_RIGHT_FOCUSED_PANEL_ID`
  - `BASELINE_FOCUSED_PANEL_ID`
  - `NEXT_FOCUSED_PANEL_ID`
  - `PREVIOUS_FOCUSED_PANEL_ID`
- smoke now fails fast when:
  - no candidate terminal surface reports `available:true` for `automation.terminal_send_text`
  - marker text is not observed in `automation.terminal_visible_text`
  - terminal viewport screenshot path is missing/unresolved.
- fallback (Ghostty-disabled) path remains unchanged and reports viewport screenshot as skipped.
- validation:
  - `./scripts/automation/smoke-ui.sh` (pass, Ghostty-enabled path)
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass, fallback path)
  - `./scripts/automation/check.sh` (pass, 80 tests)

2026-02-28 (Post-MVP continuation reviewer follow-up: deterministic viewport smoke):
- reviewer source: Claude second-opinion on deterministic viewport smoke change.
- accepted and implemented:
  - avoided repeated command execution during readiness polling:
    - smoke now probes availability with `automation.terminal_send_text` using `text=""` + `submit=false`
    - sends the heavy terminal command once after a surface is confirmed available.
  - added split-right response guard for missing `focusedPanelID`.
  - added explicit JSON-string escaping helper for terminal command payload text.
  - enabled empty-string probes in automation command handler:
    - `automation.terminal_send_text` now requires `text` key presence but no longer rejects empty string values.
- rejected (with rationale):
  - suggestion that `NEXT_FOCUSED_PANEL_ID` / `PREVIOUS_FOCUSED_PANEL_ID` are never populated was rejected; they are intentionally initialized and conditionally populated when multi-pane focus assertions run.
- re-validation:
  - `./scripts/automation/smoke-ui.sh` (pass, Ghostty-enabled path)
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass, fallback path)
  - `./scripts/automation/check.sh` (pass, 80 tests)

2026-02-28 (Post-MVP continuation: split-ratio rendering fix for resize visibility):
- root-cause debug from live logs:
  - Ghostty resize shortcuts were routed and reducer mutations were applied, but pane widths/heights appeared unchanged.
  - cause: `PaneNodeView` split rendering used equal-size `HStack`/`VStack` branches and ignored model split `ratio`.
- implemented UI fix in `Sources/App/WorkspaceView.swift`:
  - split nodes now render through `GeometryReader` and explicit first/second dimensions derived from clamped split `ratio`.
  - horizontal split:
    - first width = `(availableWidth * ratio)`
    - second width = `(availableWidth - first width)`
  - vertical split uses the same approach for heights.
  - divider thickness is preserved at `1px`.
- validation:
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - `./scripts/automation/smoke-ui.sh` (pass, Ghostty-enabled path)
  - manual shortcut repro with debug logs:
    - `resize_split.left` and `resize_split.right` both routed/handled and now visibly change pane size.

2026-02-28 (Post-MVP continuation reviewer follow-up: split-ratio rendering fix):
- reviewer source: Claude second-opinion on `WorkspaceView` ratio-rendering patch.
- accepted:
  - no blocking defects; ratio math/path validated.
- rejected (with rationale):
  - `GeometryReader` zero-size caveat was considered non-blocking in current layout hierarchy because pane tree is always rendered inside workspace content with explicit max-size constraints.
  - toolchain compatibility caveat (`let` bindings in `ViewBuilder`) is non-blocking; current repo toolchain compiles/tests pass on target environment.

2026-02-28 (Post-MVP continuation: resize step-size tuning):
- adjusted pane-resize sensitivity in `AppReducer.splitResizeDelta(...)`:
  - reduced per-amount magnitude from `0.02` to `0.005` for finer keyboard-driven resizing.
  - increased amount clamp upper bound from `20` to `60` to preserve upper-bound clamp behavior for very large amount inputs.
- resolved a precision edge case in resize clamping:
  - added epsilon-based split-ratio change detection so `0.8999999999999999 -> 0.9` is treated as no-op at clamp bounds.
  - updated clamp assertion to tolerance-based expectation in `resizeFocusedPaneSplitClampsAtUpperBound`.
- updated reducer tests for new delta expectations:
  - `resizeFocusedPaneSplitAdjustsNearestMatchingRatio`
  - `resizeFocusedPaneSplitUsesNearestMatchingAncestor`
- validation:
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)

2026-02-28 (Post-MVP continuation reviewer follow-up: resize step-size tuning):
- reviewer source: Claude second-opinion on resize-step + clamp-precision patch.
- accepted:
  - add rationale comments for epsilon tolerance and the `amount` clamp upper bound in `splitResizeDelta`.
- rejected (with rationale):
  - remove new `AGENTS.md` reminder line about `/tmp/toastty.log`:
    - rejected because user explicitly requested that reminder be added.
  - tighten clamp test assertions beyond tolerance-based check:
    - rejected as non-actionable for current fixture because `amount: Int.max` still overshoots to upper bound after clamp and no-op-on-second-resize behavior remains covered.

2026-02-28 (Post-MVP continuation: Ghostty high-DPI terminal clarity fix):
- issue:
  - Ghostty terminal content rendered blurrier than surrounding app chrome on Retina displays.
- root cause:
  - surface size updates were passed in logical points and, in some runtime paths, Ghostty reported pixel dimensions equal to logical dimensions (effectively 1x rendering).
  - backing-scale updates were not guaranteed to reflow on window/display moves.
- implemented:
  - `TerminalPanelHostView`:
    - improved backing-scale resolution (`window.screen`, `window`, then `NSScreen.main`).
    - trigger layout/update on `viewDidMoveToWindow` and `viewDidChangeBackingProperties`.
  - `TerminalHostView`:
    - sync `CALayer.contentsScale` on init and on window/backing-change events.
  - `TerminalSurfaceController`:
    - added guarded adaptive sizing:
      - first set logical size as before.
      - if reported `ghostty_surface_size.width_px/height_px` indicates low-DPI sizing on scale>1, switch to backing-pixel sizing for that surface lifetime.
    - added debug render-metric logs (`viewport`, `scale`, `width_px`, `height_px`, `cell_*`, `pixel_sizing`) to verify behavior.
  - `GhosttyRuntimeManager`:
    - improved initial `surfaceConfig.scale_factor` resolution to use window/screen scale when available.
- validation:
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - `TOASTTY_LOG_LEVEL=debug ./scripts/automation/smoke-ui.sh` (pass)
  - debug log confirmation:
    - fallback path detected low-DPI report (`reported_width_px == logical_width` at scale 2.0)
    - adaptive switch enabled (`pixel_sizing:true`)
    - post-switch reports `width_px/height_px` aligned to backing-pixel dimensions.

2026-02-28 (Post-MVP continuation reviewer follow-up: Ghostty high-DPI clarity fix):
- reviewer source: Claude second-opinion on Ghostty DPI patch.
- accepted and implemented:
  - sizing-mode detection now resolves once per surface lifecycle (instead of probing each update).
  - improved sizing heuristic from absolute pixel tolerance to ratio-based detection relative to backing scale.
  - reduced repeated FFI `ghostty_surface_size` calls by threading measured size into render-metric logging when already available.
  - removed `syncLayerContentsScale()` from `layout()` to avoid per-layout overhead.
  - guarded `viewDidMoveToWindow` scale/layout callbacks so they only run when `window != nil`.
  - downgraded adaptive-switch announcement from `info` to `debug` to reduce normal logging noise.
- rejected (with rationale):
  - concern about stale `usesBackingPixelSurfaceSizing` state on surface replacement was rejected after verifying state reset happens before assigning each newly created surface.
  - suggestion to change `TerminalPanelHostView` helper to `static`/free function was rejected as style-only and non-functional.

2026-02-28 (Post-MVP continuation: default font size + focused-panel chrome tweak):
- updated default terminal font baseline:
  - `AppState.defaultTerminalFontPoints` changed from `7` to `12`.
  - updated bootstrap codable test expectation in `AppStateCodableTests`.
- updated focused panel visual treatment in `PanelCardView`:
  - removed full-panel accent border for focused panel.
  - focused state now appears as an accent underline at the bottom of the panel header only.
  - non-focused headers retain a subtle hairline separator.
- validation:
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)

2026-02-28 (Post-MVP continuation reviewer follow-up: default font + focused header indicator):
- reviewer source: Claude second-opinion on default-font + panel-focus styling patch.
- accepted and implemented:
  - moved header focus indicator from in-header overlay to a dedicated separator row to avoid drawing over header content.
- rejected (with rationale):
  - concern about focused-state information loss in panel border was rejected because this was an explicit design change request to remove full-panel accent border.
  - suggestion to remove explicit constant assertion in `AppStateCodableTests` was rejected; we keep it intentionally to lock desired default at `12`.

2026-02-28 (Post-MVP continuation: prevent Xcode focus-steal during automation runs):
- updated automation scripts to generate workspace without auto-opening Xcode:
  - `scripts/automation/check.sh`
  - `scripts/automation/smoke-ui.sh`
  - `scripts/automation/shortcut-trace.sh`
  - change: `tuist generate` -> `tuist generate --no-open`
- validation:
  - `bash -n scripts/automation/check.sh scripts/automation/smoke-ui.sh scripts/automation/shortcut-trace.sh` (pass)
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)

2026-02-28 (Post-MVP continuation reviewer follow-up: automation no-open generation):
- reviewer source: Claude second-opinion on `tuist generate --no-open` script patch.
- accepted:
  - added explicit smoke validation to confirm `--no-open` works in runtime automation path, not only `check.sh`.
- rejected (with rationale):
  - concern that `smoke-ui.sh` and `shortcut-trace.sh` do not check generate exit status was rejected because both scripts run with `set -e`, so `tuist generate --no-open` failure is already fatal.

2026-02-28 (Post-MVP continuation: workspace keyboard shortcuts):
- added global workspace command bindings in `ToasttyApp`:
  - `cmd+shift+n` -> create/select new workspace
  - `cmd+1...cmd+9` -> select workspace index in selected window (up to first 9)
- added helper handlers in `ToasttyApp` to route command actions through existing reducer actions:
  - `.createWorkspace(windowID:title:)`
  - `.selectWorkspace(windowID:workspaceID:)`
- ghostty-enabled build follow-up:
  - fixed `SidebarView` missing `CoreState` import that blocked ghostty-enabled app builds.
- validation:
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - manual shortcut exercise under automation via `osascript` key chords:
    - `cmd+2` switched selected workspace from fixture workspace 1 -> workspace 2
    - `cmd+1` switched back to workspace 1
    - `cmd+shift+n` increased workspace count (`2` -> `3`) and selected the new workspace

2026-02-28 (Post-MVP continuation reviewer follow-up: workspace keyboard shortcuts):
- reviewer source: Claude second-opinion on workspace shortcut patch.
- accepted and implemented:
  - replaced dynamic `Character(String(index + 1))` shortcut creation with explicit `KeyEquivalent` map (`1...9`) to avoid latent runtime traps if bounds change.
  - switched workspace-selection shortcut routing to index-based resolution at execution time (`selectWorkspaceFromShortcutIndex`) so actions always target the currently selected window/workspace ordering.
  - disabled `New Workspace` command when no window is selected.
  - preserved contiguous shortcut slots even if workspace lookup fails by rendering a disabled fallback menu item (`Missing Workspace N`).
- rejected (with rationale):
  - suggestion to drop `cmd+shift+n` due system shortcut conflict:
    - rejected because user explicitly requested this shortcut.
  - concern about menu-order differences across Ghostty/non-Ghostty builds:
    - rejected as non-blocking; `Workspace` menu is intended to exist in both builds while `Pane` fallback remains non-Ghostty-only.
- re-validation:
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - `/tmp/workspace-shortcuts-check.sh` (pass):
    - verified `cmd+2`, `cmd+1`, `cmd+shift+n` with runtime state assertions.

2026-02-28 (Post-MVP continuation: focused-panel mode terminal render regression fix):
- issue observed:
  - toggling `Focus Panel` (aka focused-panel mode) maximized the panel frame but Ghostty content went blank/black.
- root cause:
  - focused mode previously switched UI rendering from full `PaneNodeView` tree to a standalone `PanelCardView`.
  - that structural swap re-mounted terminal host views in a way that broke Ghostty rendering continuity.
- implemented:
  - removed the focused-mode standalone branch from `workspaceContent`.
  - always render the pane tree (`PaneNodeView`) and, when focused mode is active, collapse split ratios toward the branch containing `focusedPanelID`.
  - in focused mode, leaf tab selection now prefers `focusedPanelID` when it exists in the leaf.
  - when a split is collapsed, hide non-visible branch rendering (`opacity` + hit-testing off) and remove divider thickness to avoid stray 1px artifacts.
- validation:
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - focused-mode targeted repro script (`/tmp/focus-mode-check.sh`) confirms:
    - terminal text remains visible after `topbar.toggle.focused-panel`.
    - screenshot after focus no longer shows blank terminal content.

2026-02-28 (Post-MVP continuation reviewer follow-up: focused-panel mode rendering):
- reviewer source: Claude second-opinion on focused-panel rendering patch.
- accepted and implemented:
  - added an assertion guard for impossible split-state duplication where a focused panel appears in both branches.
  - tightened branch visibility logic so branch hiding only occurs when a split is truly collapsed (instead of tiny-size threshold heuristics).
- rejected (with rationale):
  - stale `focusedPanelID` concerns were not adopted as a code change here because reducer invariants already maintain focused-panel validity during toggle/close flows; fallback remains non-fatal.
  - extra focused-mode unit tests were deferred; existing reducer tests already cover state invariants and this fix is primarily view-hosting/render behavior validated via automation screenshots.
- re-validation:
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - `/tmp/focus-mode-check.sh` (pass, focused screenshot shows terminal content and no edge artifact strip).

2026-02-28 (Post-MVP continuation: header focus-indicator layout stability):
- issue observed:
  - focus indicator line sat below header bounds and changed panel content Y-position when focus moved between panes.
- implemented:
  - moved the focus indicator into the header background as a bottom overlay in `PanelCardView` (instead of a separate row below the header).
  - preserved existing header padding and removed separate underline row so terminal content no longer reflows on focus changes.
- reviewer follow-up (Claude):
  - accepted:
    - avoid fixed header height to prevent potential text clipping; keep natural header sizing with overlay-only underline.
  - rejected:
    - no additional reducer tests were added because this is a view-layout-only change; behavior verified with UI automation snapshots.
- validation:
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - `/tmp/focus-mode-check.sh` (pass):
    - before/after screenshots confirm the focus toggle no longer shifts terminal content vertically.

2026-02-28 (Post-MVP continuation: global Focus Panel shortcut):
- implemented:
  - added app-level `cmd+shift+f` command in `ToasttyApp` Workspace menu to toggle focused-panel mode from the currently selected workspace.
  - removed the view-local `keyboardShortcut` binding from `WorkspaceView.focusedPanelToggle` to avoid duplicate shortcut routing.
  - command label follows current state (`Focus Panel` / `Restore Layout`) and is disabled when no workspace is selected.
- validation:
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - runtime key-event verification with app debug logs:
    - sent two `cmd+shift+f` key chords via System Events.
    - observed two reducer cycles for `toggleFocusedPanelMode` (dispatch + applied pairs in `/tmp/toastty-focus-shortcut.log`), confirming shortcut routing executes the intended action.

2026-02-28 (Post-MVP continuation: focused-panel mode transition animation):
- implemented:
  - added explicit split-node animation in `PaneNodeView` so focus-mode enter/exit visibly animates split collapse/restore.
  - animation is bound to `effectiveRatio`, limiting animation to split-size transitions rather than the entire workspace view tree.
  - uses `.easeInOut(duration: 0.2)`; automation runs with `--disable-animations` remain deterministic via existing root transaction disabling.
- validation:
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)

2026-02-28 (Post-MVP continuation reviewer follow-up: focus transition animation scope):
- reviewer source: Claude second-opinion on staged diff for focus-transition animation.
- accepted and implemented:
  - narrowed animation scope from workspace-level animation hooks to split-node ratio changes (`effectiveRatio`) to reduce unrelated animation side effects.
- rejected/deferred:
  - no new automated UI assertion for animation smoothness yet; current smoke run is deterministic with `--disable-animations`, so animation behavior remains manual-visual validation territory for now.
- re-validation:
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)

2026-02-28 (Post-MVP continuation: embedded Ghostty config path support):
- implemented:
  - updated `GhosttyRuntimeManager` startup config loading to support explicit Ghostty config resolution in this order:
    - `TOASTTY_GHOSTTY_CONFIG_PATH` (when set and file exists)
    - `XDG_CONFIG_HOME/ghostty/config` (when set and file exists)
    - `~/.config/ghostty/config` (when present)
    - Ghostty default search paths (`ghostty_config_load_default_files`)
  - enabled recursive config include loading via `ghostty_config_load_recursive_files`.
  - added startup logging for config source and config diagnostics count/messages.
  - switched Ghostty CLI arg parsing to explicit opt-in (`TOASTTY_GHOSTTY_PARSE_CLI_ARGS=1`) so Toastty app arguments are not misinterpreted as Ghostty config fields by default.
  - env-path hardening:
    - `TOASTTY_GHOSTTY_CONFIG_PATH` must resolve to an absolute regular file path (directory paths and relative paths are rejected with fallback logging).
- validation:
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - `/tmp/toastty.log` verification:
    - `Loaded Ghostty config from user path` with `path=/Users/vishal/.config/ghostty/config`
    - `Ghostty config load complete` with `diagnostic_count=0`

2026-02-28 (Post-MVP continuation reviewer follow-up: Ghostty config loading hardening):
- reviewer source: Claude second-opinion on Ghostty config-loading diff.
- accepted and implemented:
  - restricted recursive include loading to explicit file-load branches (env/user path) and left default-search branch to Ghostty default loader behavior.
  - added regular-file validation for configured paths (reject directories).
  - switched `TOASTTY_GHOSTTY_CONFIG_PATH` normalization to absolute-only semantics (no cwd-relative fallback).
  - added `XDG_CONFIG_HOME`-aware user config fallback before `~/.config/ghostty/config`.
  - added opt-in Ghostty CLI arg parsing (`TOASTTY_GHOSTTY_PARSE_CLI_ARGS=1`) to preserve override capability without default diagnostic noise.
- rejected/deferred:
  - no additional sandbox-specific home-directory behavior change now; current target is unsandboxed and default-search fallback remains in place.
  - diagnostic severity mapping was not implemented because Ghostty diagnostics exposed by current embedded header only provide message text (`ghostty_diagnostic_s.message`).
- re-validation:
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - `/tmp/toastty.log` confirms:
    - user config source path logged
    - diagnostic count remains `0` for current `~/.config/ghostty/config`.

2026-02-28 (Post-MVP continuation: apply Ghostty unfocused split styling keys in host UI):
- implemented:
  - added host-side style store (`GhosttyHostStyleStore`) to bridge Ghostty config values into SwiftUI pane rendering.
  - `GhosttyRuntimeManager` now reads these finalized config values via typed `ghostty_config_get`:
    - `unfocused-split-opacity` (mapped to overlay alpha `1 - value`)
    - `unfocused-split-fill` (fallback to `background` when unset)
  - applied style to unfocused terminal panes in `PanelCardView` as a non-interactive fill overlay.
  - added Ghostty startup log entry:
    - `Applied Ghostty unfocused split style` with overlay alpha and RGB payload.
- validation:
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - `/tmp/toastty.log` shows expected loaded values for current config:
    - `overlay_opacity=0.300` from `unfocused-split-opacity=0.7`
    - `fill_rgb=0.118,0.118,0.180` from `unfocused-split-fill=#1e1e2e`

2026-02-28 (Post-MVP continuation reviewer follow-up: unfocused split styling hardening):
- reviewer source: Claude second-opinion on unfocused split styling patch.
- accepted and implemented:
  - added explicit `ghostty_config_get` failure handling/logging for `unfocused-split-opacity`.
  - added explicit fallback failure logging when both `unfocused-split-fill` and `background` lookups fail.
  - added warning log when computed overlay opacity requires clamp.
  - guarded unfocused overlay rendering behind `focusedPanelID != nil` to avoid accidental dimming when focus is unresolved.
- rejected/deferred:
  - runtime live-reload propagation for these host-side style keys is deferred; current host-style application remains startup-time.
  - exact compositor parity with Ghostty’s internal dimming pipeline is deferred; current implementation intentionally uses a SwiftUI overlay approximation.
- re-validation:
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/check.sh` (pass, 80 tests)
  - `/tmp/toastty.log` confirms style application log remains:
    - `overlay_opacity=0.300`
    - `fill_rgb=0.118,0.118,0.180`

2026-02-28 (Post-MVP continuation: app-menu configuration reload command):
- implemented:
  - added `Toastty -> Reload Configuration` app-menu command via SwiftUI `CommandGroup(after: .appInfo)`.
  - wired command to `GhosttyRuntimeManager.reloadConfiguration()` (Ghostty builds only):
    - allocates/reloads/finalizes a new Ghostty config
    - logs source + diagnostics
    - applies via `ghostty_app_update_config`
    - re-applies host-side unfocused split style and schedules tick
  - command is disabled in non-Ghostty builds.
- validation:
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/check.sh` (pass, 80 tests)

2026-02-28 (Post-MVP continuation reviewer follow-up: reload command ownership/threading):
- reviewer source: Claude second-opinion on reload-command patch.
- accepted and implemented:
  - documented config ownership semantics inline at `ghostty_app_update_config` callsite to make lifetime assumptions explicit for future maintenance.
- rejected (with rationale):
  - thread-safety concern rejected: `GhosttyRuntimeManager` is `@MainActor` and reload flow is main-actor isolated.
  - immediate previous-config free rejected as unsafe concern after source verification:
    - Ghostty `App.updateConfig` documents caller-owned config memory and allows freeing once the call returns.
    - embedded runtime clones app-level config during `.config_change`, so runtime does not retain caller buffer ownership.
- re-validation:
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/check.sh` (pass, 80 tests)

2026-02-28 (Post-MVP continuation: reload menu icon polish):
- implemented:
  - added AppKit-backed menu icon installation for `Toastty -> Reload Configuration`:
    - new `ReloadConfigurationMenuIconInstaller` (`NSApplicationDelegate`) scans the app menu and applies `arrow.clockwise` to that menu item.
    - installer runs at app launch plus next-runloop scheduling, with activation fallback, to handle command-menu initialization timing.
    - once applied, icon setup short-circuits on future activations (`iconWasApplied`), avoiding repeated menu-tree traversal.
  - kept `CommandGroup` menu entry text-only in SwiftUI and left existing enable/disable behavior for non-Ghostty builds unchanged.
- reviewer follow-up:
  - accepted:
    - SwiftUI `Label(..., systemImage: ...)` inside `CommandGroup` can fail to render a visible icon in AppKit menus, so direct `NSMenuItem.image` assignment is used for reliable icon display.
    - replaced `Task.yield()` timing with explicit next-runloop scheduling (`DispatchQueue.main.async`) from launch callback.
    - added `iconWasApplied` short-circuit so activation fallback does not keep traversing the full menu tree once the icon is set.
  - rejected:
    - delegate adaptor conflict concern was not actionable in this repo because there is no existing `NSApplicationDelegateAdaptor` usage to conflict with.
- validation:
  - `./scripts/automation/check.sh` (pass, 80 tests)

2026-02-28 (Post-MVP continuation reviewer follow-up: Ghostty font baseline + persisted override semantics):
- reviewer source: Claude second-opinion on Ghostty `font-size` + Toastty override patch.
- accepted and implemented:
  - removed reducer heuristic that tried to infer whether global font was "following baseline" from floating-point comparisons.
  - made configured baseline updates explicit:
    - `.setConfiguredTerminalFont` now updates only configured baseline state.
    - startup/reload paths apply/reset global font explicitly when no Toastty override is present.
  - made persisted override behavior explicit:
    - `Increase/Decrease` and explicit `setGlobal` persist override even when value equals Ghostty baseline.
    - only `Reset Terminal Font` clears `~/.config/toastty/config`.
  - moved Ghostty config reads (`font-size`, host-style keys, diagnostics) before `ghostty_config_finalize` in init/reload flows.
  - added shared terminal-font epsilon constant in `AppState` to avoid duplicated magic thresholds.
  - added reducer tests for:
    - configured baseline update + reset behavior
    - clearing configured baseline (`nil`) and resetting to default fallback.
- rejected/deferred (with rationale):
  - integration-level AppStore/ToasttyApp tests were deferred in this chunk because current unit test target is CoreState-focused; reducer coverage was expanded immediately and runtime behavior was validated via smoke/manual paths.
  - stale `AppState` decode concern for configured baseline was deferred because app-state persistence is not currently used for production startup (automation fixtures only).
- re-validation:
  - `./scripts/automation/check.sh` (pass, 83 tests)
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/smoke-ui.sh` (pass)

2026-02-28 (Post-MVP continuation: `cmd+w` closes focused panel):
- implemented:
  - added `Close Panel` workspace command.
  - installed a local key interceptor for `cmd+w` that closes the focused panel and suppresses AppKit default window-close behavior.
  - behavior now prefers panel-close semantics over full-window close when shortcut is pressed.
- validation:
  - targeted automation run with synthetic `cmd+w`:
    - baseline `panelCount=2`
    - after shortcut `panelCount=1`
    - app process remained running.
  - `./scripts/automation/check.sh` (pass, 83 tests)
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - `./scripts/automation/smoke-ui.sh` (pass)

2026-02-28 (Post-MVP continuation: focused-panel animation polish):
- implemented:
  - kept focus mode’s ratio-driven layout expansion (focused branch still grows to fill).
  - changed split visibility heuristics so non-focused branches are hidden immediately when focus mode is active, preventing the previous “shrink to zero” visual artifact.
  - suppressed branch opacity animation for those immediate hides to avoid visible panel-collapse movement.
  - when one branch is hidden in focus mode, divider thickness is now zero so no 1px gutter is reserved.
- reviewer follow-up:
  - accepted:
    - divider-space reservation fix when hidden branches remove the visual separator.
  - rejected (with rationale):
    - suggestion to preserve opacity fade was rejected for this iteration because the user requested the non-focused-pane shrink animation be removed; immediate hide is intentional.
    - stale-focused assertions on branch visibility were deferred; existing focus recovery/state validation paths already guard stale IDs and this pass is UI-polish scoped.
- validation:
  - `./scripts/automation/check.sh` (pass, 83 tests)
  - `./scripts/automation/smoke-ui.sh` (pass)
  - focused state screenshot: `artifacts/automation/ui/smoke-20260228-231629/split-workspace/focused-panel-smoke.png`

2026-03-01 (Post-MVP continuation: Ghostty render corruption after workspace switching):
- issue observed:
  - after switching workspaces repeatedly, Ghostty terminal content could appear visually corrupted/distorted in Toastty.
- implemented:
  - added host-view Ghostty visibility lifecycle synchronization in `TerminalHostView`:
    - track occlusion state across host view attach/detach transitions.
    - call `ghostty_surface_set_occlusion(...)` when effective visibility changes.
    - call `ghostty_surface_set_focus(..., false)` when the host view becomes occluded.
    - force `ghostty_surface_refresh(...)` when becoming visible again to avoid stale frame artifacts.
  - wired synchronization on:
    - `viewDidMoveToWindow` (with attach/detach handling),
    - `viewDidMoveToSuperview` (window-attached only),
    - `viewDidChangeBackingProperties`,
    - initial surface assignment via `setGhosttySurface(...)`.
- reviewer follow-up:
  - accepted:
    - avoid high-frequency lifecycle churn by removing layout-driven sync and relying on visibility transition callbacks.
    - avoid premature refresh on superview transitions unless attached to a window.
  - rejected (with rationale):
    - focus-restore warning was rejected for this patch because focus is re-applied in existing controller update flow (`ghostty_surface_set_focus(focused)`), and this change only ensures hidden surfaces do not retain focus.
    - thread-safety warning was rejected as non-actionable in current architecture: host view lifecycle and controller update paths are AppKit-main-thread driven.
- validation:
  - `./scripts/automation/check.sh` (pass, 83 tests)
  - `TOASTTY_LOG_LEVEL=debug ./scripts/automation/smoke-ui.sh` (pass)
  - debug logs show occlusion transitions and refresh path activation during visibility changes (`Updated Ghostty surface occlusion`).

2026-03-01 (Post-MVP continuation: split-close blank terminal regression hardening):
- issue observed:
  - after splitting then closing the focused/right pane (`cmd+w`), the remaining pane could render as header-only with no visible Ghostty content.
- implemented:
  - added source-container validation for `TerminalSurfaceController.update(...)` so stale `onLayout` callbacks from replaced SwiftUI container views cannot mutate an already reattached Ghostty host view.
  - plumbed `sourceContainer` from `TerminalPanelHostView` into controller updates.
  - updated focus application to respect current occlusion state (`ghostty_surface_set_focus(..., focused && !isOccluded)`), so detached/hidden surfaces do not retain focus during close transitions.
  - expanded occlusion check to include hidden ancestors (while still avoiding alpha-based occlusion checks that previously caused false positives during transitions).
  - added automation action `workspace.close-focused-panel` for deterministic split-close validation flows.
- reviewer follow-up (Claude second-opinion):
  - accepted:
    - restore ancestor hidden-state checks in occlusion computation to avoid treating hidden host trees as visible.
  - rejected (with rationale):
    - concern that source-container guard would permanently drop updates: rejected because `attach(into:)` runs before each update path and stale callbacks are intentionally ignored.
    - concern about workspace scoping for automation close action: reducer/store paths are main-actor serialized and action resolves focused panel from the requested workspace snapshot before dispatch.
- validation:
  - `sv exec -- xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath Derived build` (pass)
  - `sv exec -- ./scripts/automation/smoke-ui.sh` (pass)
  - `sv exec -- ./scripts/automation/check.sh` (pass, 83 tests)
  - targeted split-close repro (`single-workspace` fixture, `1 -> split.right -> close-focused -> 1`) confirms:
    - pane counts transition as expected,
    - focused panel remains valid after close,
    - terminal surface accepts input and visible-text marker probe after close.

2026-03-01 (Post-MVP continuation: focus-mode animation glyph-compression artifact):
- issue observed:
  - during focused-panel mode animation, non-focused pane text (commonly top-left) could visibly compress into narrow columns before being covered.
- implemented:
  - refactored split-branch rendering in `PaneNodeView`:
    - added shared `splitBranch(...)` helper to centralize branch visibility behavior.
    - replaced opacity-only hiding with a visibility modifier that applies `.hidden()` to non-visible branches while preserving layout footprint.
    - retained branch geometry animation at split level while preventing hidden branch content from drawing during transition.
  - added explicit `allowsHitTesting(show)` per branch to preserve input behavior expectations when a branch is hidden.
- reviewer follow-up (Claude second-opinion):
  - accepted:
    - avoid conditional branch removal (`if show { PaneNodeView } else { Color.clear }`) because subtree teardown could churn hosted terminal views and risk lifecycle regressions.
  - rejected (with rationale):
    - terminal-state reset/focus-loss concerns after adopting `.hidden()` path were not reproducible in existing automation flows; runtime registry keeps panel controllers keyed by panel identity and reattach behavior unchanged.
- validation:
  - `sv exec -- xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath Derived build` (pass)
  - `sv exec -- ./scripts/automation/check.sh` (pass, 83 tests)
  - `sv exec -- ./scripts/automation/smoke-ui.sh` (pass)

2026-03-01 (Post-MVP continuation: Ghostty font-size baseline parity when no Toastty override):
- issue observed:
  - with `~/.config/ghostty/config` set to `font-size = 13`, Toastty resolved Ghostty baseline as `12.00` in startup logs when running without Toastty override application.
- root cause:
  - `ghostty_config_get` for `font-size` writes a 32-bit float value, but Toastty was reading into a Swift `Double` buffer.
  - this left stale high bytes from the default `Double` initializer and produced an incorrect near-default decoded value.
- implemented:
  - changed Ghostty `font-size` config read buffer to `Float` in `resolveConfiguredTerminalFontPoints(...)`.
  - converted to `Double` only after read, then applied existing clamping/logging behavior.
  - kept `unfocused-split-opacity` read path as `Double` after validating that forcing `Float` there triggers Ghostty alignment panic (indicating different expected ABI type for that key).
- reviewer follow-up (Claude second-opinion):
  - accepted:
    - add explicit documentation comment for the `font-size` ABI expectation at the callsite.
  - rejected (with rationale):
    - request for additional type-discovery indirection was deferred; current fix directly addresses the reproduced mismatch and is validated against live Ghostty config read behavior.
- validation:
  - `TOASTTY_LOG_LEVEL=debug sv exec -- ./scripts/automation/smoke-ui.sh` (pass)
  - `sv exec -- ./scripts/automation/check.sh` (pass, 83 tests)
  - `/tmp/toastty.log` now consistently shows:
    - `Loaded Ghostty config from user path ... ~/.config/ghostty/config`
    - `Resolved Ghostty configured terminal font size ... points=13.00`

2026-03-01 (Post-MVP continuation: non-interactive terminal regression during layout churn):
- issue observed:
  - occasional launch/split states rendered as near-empty Ghostty panes (cursor-like artifact, no usable prompt/input), matching a transient 1x1 viewport lock-in path.
- implemented:
  - in `TerminalSurfaceController.update(...)`, added a tiny-viewport guard (`<=16px` logical width/height) that skips `ghostty_surface_set_size(...)` until viewport is usable.
  - retained occlusion/focus synchronization in that tiny-viewport branch so hidden/visible and responder state still converge while waiting for stable geometry.
  - when host view is detached (`superview == nil`), reattach to current source container before update.
  - tightened stale-callback protection to require direct superview identity (`hostedView.superview === sourceContainer`) before mutating Ghostty state.
- reviewer follow-up (Claude second-opinion):
  - accepted:
    - direct-parent identity check is safer than ancestor-based `isDescendant(of:)` for rejecting stale container callbacks.
  - rejected (with rationale):
    - suggestion that attach flow is async/TOCTOU was rejected for this path; `attach(into:)` performs synchronous AppKit reparenting on main-thread update flow.
    - suggestion to add pixel underflow guards was rejected because pixel dimensions are already clamped to `>=1` before conversion.
- validation:
  - `sv exec -- ./scripts/automation/check.sh` (pass, 83 tests)
  - `TOASTTY_LOG_LEVEL=debug sv exec -- ./scripts/automation/smoke-ui.sh` (pass)
  - `TOASTTY_LOG_LEVEL=debug sv exec -- ./scripts/automation/shortcut-trace.sh` (pass)
  - clean-log verification (`rm -f /tmp/toastty.log` before smoke) shows no `viewport_width=1`/`viewport_height=1` render-metrics entries in current run.

2026-03-01 (Post-MVP continuation: stale container callback robustness follow-up):
- issue observed:
  - panel callback routing still depended on host-view/superview shape, which could be brittle during SwiftUI/AppKit container replacement churn.
- implemented:
  - added explicit source-container identity tracking in `TerminalSurfaceController`:
    - store both weak `activeSourceContainer` and `activeSourceContainerID`.
    - reject `update(...)` callbacks unless both active references match the callback `sourceContainer`.
  - preserved detached-view recovery (`hostedView.superview == nil -> attach(into:)`) but stopped reattaching when the host is attached to a different live container.
  - clear active container tracking on controller invalidation.
- reviewer follow-up (Claude second-opinion):
  - accepted:
    - pair `ObjectIdentifier` with weak container reference to avoid pointer-reuse false positives.
    - avoid broad reattach behavior that can yank views between containers during transitions.
  - rejected (with rationale):
    - thread-barrier warnings were rejected as non-actionable in this path because controller lifecycle/update methods are `@MainActor` isolated.
- validation:
  - `sv exec -- ./scripts/automation/check.sh` (pass, 83 tests)
  - `TOASTTY_LOG_LEVEL=debug sv exec -- ./scripts/automation/smoke-ui.sh` (pass)
  - `TOASTTY_LOG_LEVEL=debug sv exec -- ./scripts/automation/shortcut-trace.sh` (pass)
  - targeted real-keystroke probe in automation mode (`System Events` typing + `automation.terminal_visible_text contains`) confirms input reaches focused terminal surface (`marker_found=true`).
