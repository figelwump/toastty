# Toastty Pane Re-Architecture Plan

## Status
- Drafted: 2026-03-05
- Updated: 2026-03-05 after removing in-slot tabbing
- Scope owner: Codex + Vishal
- Execution model: new git worktree branch, direct cutover

## Terminology
- This document uses:
  - `layout tree` = the split topology inside a workspace
  - `slot` = one visible leaf position in that layout
  - `panel` = the content/runtime hosted in a slot
- Current code still uses `pane` names. In implementation terms today:
  - `layout tree` maps to `paneTree`
  - `slot` maps to `PaneNode.leaf` / `paneID`
- Recommendation:
  - do not start with the terminology rename
  - land the behavior/identity/lifecycle rearchitecture first
  - do the `pane` -> `slot` / `paneTree` -> `layoutTree` rename as a follow-up mechanical pass once the new behavior is stable

## Constraints (Explicit Decisions)
- Do the work in a new worktree branch.
- No feature flags.
- No compatibility migration layer.
- No legacy-path preservation for replaced layout/render lifecycle code.
- No in-slot tabbing. One visible slot hosts exactly one panel.
- No whole-window tabbing or multi-window redesign in this pass.
- No staged migration across panel types for behavior correctness, but the lifecycle seam introduced here must be panel-generic.

## Problem Summary
Split close flows, especially repeated `Cmd+W` in mixed split trees, have produced intermittent blank pane rendering due to lifecycle and identity races between:
- SwiftUI subtree reuse after layout topology mutation.
- Native host view reattachment/update timing.
- Focus restoration timing after close.

The immediate bug is terminal-visible, but the architecture risk is broader:
- current host lifecycle handling is too terminal-specific
- rendering identity is not expressed clearly enough for deterministic remounting
- automation coverage is too action-centric and not strong enough on close-path equivalence

If we leave those seams vague, future work such as custom panels, user extension panels, full UI automation, and panel-to-panel interaction will accumulate more special cases instead of getting simpler.

Panel-to-panel interaction is not implemented in this pass, but the layout/lifecycle boundaries introduced here must not preclude a future coordination seam between panels.

## Current Baseline
- Single-panel slots are already in place.
- In-slot panel tabbing has been removed from the state model and reducer behavior.
- `PaneNode.leaf` now represents one slot containing one panel.

This plan starts from that baseline.

## Architecture Target
Rebuild slot management around four strict boundaries:

### 1) Topology-first layout tree model
- Layout is modeled as immutable topology plus stable slot identity.
- Each slot contains exactly one panel.
- Structural identity is **derived projection metadata**, not persisted app state.
- Structural identity changes only when topology changes, not when split ratios change.
- Split ratio changes must not force subtree remount.

### 2) Projection-only workspace rendering
- `WorkspaceView` renders a projection of layout state.
- Split subtrees are keyed by derived structural identity.
- Slot containers are keyed by stable slot identity.
- Panel host/runtime identity is keyed by stable `panelID`.

The keying contract must be explicit:
- split subtree key = derived structural identity
- slot container key = stable slot ID
- panel runtime key = stable panel ID

### 3) Panel-generic host lifecycle ownership
- Native/runtime host controllers own resources and attach/detach explicitly.
- The lifecycle seam must be generic enough for:
  - terminal panels
  - markdown/diff/scratchpad panels
  - future custom or extension-backed panels
- Terminal remains the first concrete implementation, but the architectural boundary must not hard-code terminal-only assumptions into workspace composition.

### 4) Automation-friendly state and command equivalence
- Automation must expose a panel-agnostic snapshot of the layout projection.
- Action-path close, menu close, and `Cmd+W` must be proven equivalent.
- Repeated close/split/focus loops over mixed trees must be automatable and deterministic.

## Non-Goals
- No extension framework implementation in this pass.
- No WebView extension runtime work in this pass.
- No whole-window tabbing implementation.
- No multi-window architecture redesign beyond preserving current behavior.
- No broad redesign of unrelated app state, sidebar flows, or workspace management.
- No migration of previously persisted multi-tab leaf state.
- No dedicated panel-to-panel interaction bus in this pass.

## Required Chunk Order
- Chunk 1 must land first.
- Chunk 2 must land before any structural-identity-based keying work.
- The host lifecycle seam must land before or with the workspace projection refactor.
- Close/focus path unification depends on the layout identity contract and the host lifecycle seam being in place.
- The terminology rename stays out of this sequence and happens later as a mechanical cleanup pass.

## Implementation Chunks (Commit-Oriented)

### Chunk 1: Guardrails + Close-Path Equivalence Baseline
**Intent**
- Freeze expected behavior before refactoring identity and lifecycle code.

**Changes**
- Expand automation coverage for:
  - action-path close
  - menu close
  - `Cmd+W`
- Add panel-agnostic snapshot fields that expose:
  - slot count
  - slot IDs
  - slot-to-panel mapping
  - focused panel
  - root split ratio
- Add deterministic repeated-close loop coverage over mixed trees.

**Likely files**
- `scripts/automation/smoke-ui.sh`
- `scripts/automation/shortcut-trace.sh`
- `Sources/App/Automation/AutomationSocketServer.swift`

**Acceptance**
- Baseline smoke passes both fallback and Ghostty paths.
- Shortcut trace fails deterministically if any close path leaves a non-renderable slot.
  - For this plan, "non-renderable slot" means any of:
    - a slot with no panel mapping in the automation snapshot
    - a slot whose host is present in the layout snapshot but reported as unattached/non-renderable by runtime diagnostics
    - a visible blank region where a slot exists in the layout snapshot but no panel host is rendered
- Automation can compare action/menu/shortcut close outcomes structurally.

---

### Chunk 2: Layout Identity Contract
**Intent**
- Introduce derived structural identity and codify the rendering key contract.

**Changes**
- Add derived structural identity helpers on the layout tree.
- Ensure identity:
  - changes on topology change
  - stays stable on ratio-only change
  - is localized to affected branches where possible
- Add tests for slot ID, panel ID, and structural identity behavior.

**Likely files**
- `Sources/Core/PaneNode.swift` or extracted `Sources/Core/Layout/*`
- `Tests/Core/PaneNodeMutationTests.swift`
- new dedicated structural-identity tests if needed

**Acceptance**
- Unit tests verify:
  - topology change => structural identity change
  - ratio-only change => structural identity stable
  - branch-local mutation changes only the affected branch identity
  - mutating branch A leaves sibling branch B identity unchanged
- Structural identity is explicitly non-persisted.

---

### Chunk 3: Panel-Generic Host Lifecycle Seam
**Intent**
- Replace heuristic attach arbitration with explicit lifecycle ownership that is usable beyond terminals.

**Changes**
- Introduce a minimal panel-generic host lifecycle contract.
- Move terminal-specific attach/detach behavior behind that seam.
- Remove epoch/attach-ignore heuristics that only existed to compensate for ambiguous identity/reuse.
- Expose the lifecycle completion or readiness point that later close/focus orchestration can sequence against.
- Keep terminal as the first concrete adopter.

**Likely files**
- `Sources/App/Terminal/TerminalPanelHostView.swift`
- `Sources/App/Terminal/TerminalRuntimeRegistry.swift`
- any new host-lifecycle abstraction under `Sources/App/PanelHost/*` if extraction is warranted

**Acceptance**
- No host/source-container mismatch after repeated close/focus/split operations.
- The seam is usable by a second non-terminal panel host later without reworking workspace layout logic.
- Focus orchestration has a concrete lifecycle point it can wait on instead of racing async host attach.

---

### Chunk 4: Workspace Projection Refactor
**Intent**
- Make split rendering deterministic across topology changes.

**Changes**
- Key split subtree boundaries by structural identity.
- Keep slot containers keyed by stable slot ID.
- Keep panel hosts keyed by stable panel ID.
- Remove whole-workspace invalidation or remount hacks that exist only to paper over topology reuse ambiguity.
- Update automation snapshot shape here if the projection contract changes from the Chunk 1 baseline.

**Likely files**
- `Sources/App/WorkspaceView.swift`
- `Sources/App/Automation/AutomationSocketServer.swift` if projection snapshot fields need to be revised

**Acceptance**
- Repeated split/close stress, including repeated `Cmd+W`, does not produce blank slots.
- Ratio changes and equalize operations do not cause unnecessary remount churn.
- Structural-identity keying does not break expected topology-change behavior even if SwiftUI remounts affected subtrees.

---

### Chunk 5: Close/Focus Command Path Unification
**Intent**
- Ensure all close entry points use identical orchestration.

**Changes**
- Centralize close-focused-panel logic in one app-layer command path.
- Keep reducer close semantics as the source of truth.
- Make app-layer focus restore scheduling explicit and equivalent across:
  - menu close
  - keyboard shortcut close
  - automation-triggered close
- Ensure focus restore is sequenced against the host lifecycle readiness point introduced in Chunk 3.

**Likely files**
- `Sources/App/ToasttyApp.swift`
- minor reducer wiring if needed

**Acceptance**
- Menu close, `Cmd+W`, and automation close produce equivalent slot/focus outcomes.
- Equivalence is verified by automation, not only manual checking.

---

### Chunk 6: Cleanup + Final Validation
**Intent**
- Delete superseded code and prove the architecture is stable enough to build on.

**Changes**
- Remove replaced dead paths and old heuristics.
- Run full automation and manual stress checks.
- Capture any manual artifacts in `artifacts/manual/`.

**Acceptance**
- Required scripted validation passes:
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh`
  - `./scripts/automation/smoke-ui.sh`
  - `./scripts/automation/check.sh`
- Manual verification:
  - repeated `Cmd+W` in mixed split trees
  - no blank slots
  - prompt/surface alignment remains correct
  - aux and non-terminal panels remain isolated from terminal host lifecycle issues

## Validation Strategy
- Treat split-pane close behavior as release-gating.
- Validate both fallback and Ghostty-enabled paths.
- Validate both pure-terminal trees and mixed trees with aux panels.
- Inspect screenshot and render-attachment artifacts after each identity/lifecycle chunk.
- Prefer automated state-equivalence checks over ad hoc manual assertions when possible.

## Risks + Mitigations
- **Risk:** Structural identity over-invalidates and hurts UI smoothness.
  - **Mitigation:** Keep split ratio out of structural identity and validate resize/equalize behavior during Chunk 4.
- **Risk:** SwiftUI `.id()`-driven remounting conflicts with expected topology-change animations.
  - **Mitigation:** treat deterministic correctness as primary; explicitly verify resize/equalize smoothness and disable or narrow topology-change animations if continuity assumptions are incorrect.
- **Risk:** A generic lifecycle seam becomes over-engineered.
  - **Mitigation:** keep the protocol minimal and only generalize the ownership boundary, not every panel behavior.
- **Risk:** Close-path equivalence drifts over time.
  - **Mitigation:** add explicit automation assertions for action/menu/shortcut equivalence in Chunk 1 and keep them release-gating.
- **Risk:** Future custom/extension panels inherit terminal-specific assumptions.
  - **Mitigation:** make the lifecycle seam panel-generic in Chunk 3 even though terminal remains the first implementation.

## Commit Cadence
- One commit per chunk, unless a chunk needs to be split for reviewability.
- Each commit must be runnable and validated on its own.
- Keep commit messages behavior-focused.

## Exit Criteria
- Repro no longer occurs under repeated close/split operations.
- Both smoke paths and the full check gate pass.
- `Cmd+W`, menu close, and action close have deterministic automated equivalence coverage.
- Structural identity is derived, not persisted.
- The host lifecycle boundary is panel-generic, not terminal-only.
