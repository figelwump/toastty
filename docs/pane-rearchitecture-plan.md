# Toastty Pane Re-Architecture Plan

## Status
- Drafted: 2026-03-05
- Scope owner: Codex + Vishal
- Execution model: new git worktree branch, direct cutover

## Constraints (Explicit Decisions)
- Do the work in a new worktree branch.
- No feature flags.
- No compatibility migration layer.
- No legacy-path preservation for replaced pane/render lifecycle code.
- No staged migration across panel types (current practical target is terminal panes).

## Problem Summary
Split-pane close flows (especially `Cmd+W`) have produced intermittent blank pane rendering due to lifecycle/identity races between:
- SwiftUI subtree reuse after pane topology mutation.
- AppKit host view reattachment/update timing.
- Focus restoration timing after close.

Current smoke checks primarily validate action-based close (`workspace.close-focused-panel`) and do not guarantee the exact keyboard shortcut path behaves identically.

## Architecture Target
Rebuild pane management around three strict boundaries:
1. **Topology-first pane tree model**
   - Pane layout is modeled as immutable topology with explicit structural identity.
   - Structural identity changes only when topology changes, not when split ratios change.
2. **Projection-only UI composition**
   - `WorkspaceView` renders a projection of pane state.
   - Split subtrees are keyed by structural identity so topology mutations force deterministic subtree remount where needed.
3. **Deterministic host lifecycle ownership**
   - Runtime host controllers own terminal surfaces and attach/detach explicitly.
   - Remove stale-attachment heuristics introduced to compensate for identity ambiguity.

## Non-Goals
- No extension framework work in this pass.
- No diff/markdown-specific architecture expansion in this pass.
- No broad redesign of unrelated app state, workspace persistence format, or sidebar flows.

## Implementation Chunks (Commit-Oriented)

### Chunk 1: Baseline + Regression Guardrails
**Intent**
- Freeze current expected behavior and ensure we can catch regressions during refactor.

**Changes**
- Add/expand shortcut-path close validation to cover `Cmd+W` pane close behavior.
- Keep existing action-path smoke checks.
- Ensure render-attachment assertions remain part of close checks.

**Likely files**
- `scripts/automation/smoke-ui.sh`
- `scripts/automation/shortcut-trace.sh`
- `Sources/App/Automation/AutomationSocketServer.swift` (only if additional telemetry fields are needed)

**Acceptance**
- Baseline smoke still passes both fallback and Ghostty paths.
- Shortcut trace can fail deterministically if close causes non-renderable panes.

---

### Chunk 2: Core Layout Topology + Structural Identity
**Intent**
- Introduce first-class structural identity in pane layout model.

**Changes**
- Extend pane tree model with `structuralIdentity`.
- Ensure identity excludes split ratio changes and includes topology/branch shape.
- Add tests proving identity semantics.

**Likely files**
- `Sources/Core/PaneNode.swift` (or a new split under `Sources/Core/Layout/*` if extracted)
- `Tests/Core/PaneNodeMutationTests.swift` (and/or new dedicated structural identity tests)

**Acceptance**
- Unit tests verify:
  - topology change => identity change
  - ratio-only change => identity stable
  - branch-local mutation changes only affected branch identity

---

### Chunk 3: Workspace Rendering Refactor (Projection + Identity Keying)
**Intent**
- Make split rendering deterministic across topology changes.

**Changes**
- Key split subtree boundaries by structural identity.
- Keep leaf identity tied to stable pane/panel IDs.
- Remove any leftover whole-workspace invalidation hacks that paper over split topology reuse.

**Likely files**
- `Sources/App/WorkspaceView.swift`

**Acceptance**
- Manual split/close stress (including repeated `Cmd+W`) does not produce blank panes.
- No regression in split resize/equalize animations.

---

### Chunk 4: Terminal Host Lifecycle Simplification
**Intent**
- Replace heuristic attach arbitration with explicit ownership flow.

**Changes**
- Simplify `NSViewRepresentable` coordination.
- Remove epoch/attach-ignore shims that are no longer needed post identity fix.
- Keep one authoritative active source container per host controller.

**Likely files**
- `Sources/App/Terminal/TerminalPanelHostView.swift`
- `Sources/App/Terminal/TerminalRuntimeRegistry.swift`

**Acceptance**
- No host/source-container mismatch after pane close operations.
- Runtime render attachment snapshots remain fully renderable after repeated close/focus actions.

---

### Chunk 5: Command Path Unification for Close/Focus
**Intent**
- Ensure menu close and `Cmd+W` use identical close/focus orchestration.

**Changes**
- Centralize close-focused-panel logic in one app-layer command path.
- Keep reducer close semantics as source of truth; app layer handles focus restore scheduling only.

**Likely files**
- `Sources/App/ToasttyApp.swift`
- Potential minor touch in reducer wiring where needed

**Acceptance**
- `Cmd+W` and menu close produce equivalent pane/focus outcomes in automation and manual use.

---

### Chunk 6: Final Validation + Cleanup
**Intent**
- Validate fully and remove superseded code.

**Changes**
- Delete replaced dead paths.
- Run full automation + manual stress checks.
- Capture artifacts for handoff in `artifacts/manual/` (gitignored).

**Acceptance**
- Required scripted validation passes:
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh`
  - `./scripts/automation/smoke-ui.sh`
  - `./scripts/automation/check.sh`
- Manual verification:
  - repeated `Cmd+W` in mixed split trees
  - no blank panes
  - prompt/surface alignment stays correct

## Validation Strategy
- Treat `Cmd+W` close in split panes as a release-gating path.
- Validate both fallback and Ghostty-enabled paths.
- Inspect screenshot and render-attachment artifacts after each relevant chunk.

## Risks + Mitigations
- **Risk:** Structural identity over-invalidates and hurts UI smoothness.
  - **Mitigation:** Keep ratio out of identity and verify animation regressions during Chunk 3.
- **Risk:** Host lifecycle simplification regresses focus handoff.
  - **Mitigation:** Keep explicit post-close focus restore assertions in automation and manual checks.
- **Risk:** Shortcut test reliability affected by macOS permissions.
  - **Mitigation:** Keep action-path smoke as baseline and continue permissioned shortcut trace for keyboard-path coverage.

## Commit Cadence
- One commit per chunk (or split a chunk if needed for reviewability).
- Each commit must be runnable/validated on its own.
- Keep commit messages behavior-focused (no phase/wave wording).

## Exit Criteria
- Repro no longer occurs under repeated close/split operations.
- Both smoke paths and check gate pass.
- `Cmd+W` path has deterministic automated regression coverage.
