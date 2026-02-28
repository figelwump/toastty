# Toastty Daily-Driver MVP Plan

Date: 2026-02-28
Status: active plan
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
