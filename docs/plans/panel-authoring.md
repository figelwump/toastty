# toastty panel authoring checklist

Date: 2026-02-26

This checklist still applies to native panel kinds. For web-backed built-ins and extensible panels, follow `docs/plans/web-panels.md` first and treat this document as secondary guidance where it still fits.

Use this checklist whenever adding a new panel kind (e.g. browser, notepad, whiteboard).

## 1) define the panel kind and state

1. Add a new `PanelKind` case.
2. Add a new typed state payload (`XPanelState`).
3. Add a new `PanelState` enum case.
4. Add migration defaults for old snapshots.

## 2) implement runtime and view

1. Create `XPanelRuntime` conforming to `PanelRuntime`.
2. Create `XPanelView` for rendering.
3. Keep runtime ownership explicit:
- runtime owns native resources/lifecycles
- state remains serializable and resource-free

## 3) register the panel

1. Register panel runtime factory in `PanelRuntimeRegistry`.
2. Wire panel renderer routing in workspace panel host.

## 4) mobility compatibility (required)

Every panel must work with all mobility actions:
1. reorder within pane
2. move to another pane
3. move to another workspace (vertical tab target)
4. move to another window
5. drag-out to new window

Rules:
- preserve `panelID` on move
- do not silently recreate panel state on move
- runtime reattach must be deterministic

## 5) focus and input contract

1. Implement `focus()` and `unfocus()` safely.
2. Ensure focus survives pane/workspace/window moves.
3. Ensure background panels cannot steal first responder.

## 6) persistence contract

1. State must encode/decode cleanly with schema versioning.
2. Persist panel-specific settings/content.
3. Restore should succeed even if optional runtime dependencies are unavailable.

## 7) commands and automation (optional but recommended)

1. Add minimal create/focus/close commands for the panel.
2. Add panel-specific commands only if high-value.
3. Keep command surface typed and versioned.

## 8) tests (required)

## unit
1. state encode/decode + migration
2. reducer actions for create/move/focus/close

## integration
1. panel move matrix (pane/workspace/window/new-window)
2. focus correctness after move/split/close
3. persistence roundtrip

## ui
1. create panel from command palette/menu
2. drag to another workspace tab
3. drag out to new window

## 9) performance and safety checks

1. no leaked runtime resources after close/move cycles
2. no main-thread stalls during frequent updates
3. large-workspace behavior remains responsive

## 10) done criteria

A panel type is "done" when:
1. it can be created, focused, moved, persisted, and restored
2. it passes the mobility + focus + persistence test set
3. it has basic automation hooks (or explicit rationale if not)

## reference template

```swift
enum PanelKind: String, Codable {
    case terminal
    case diff
    case markdown
    case scratchpad
    case xpanel
}

struct XPanelState: Codable {
    let panelID: UUID
    var title: String
    var payload: String
}

enum PanelState: Codable {
    case terminal(TerminalPanelState)
    case diff(DiffPanelState)
    case markdown(MarkdownPanelState)
    case scratchpad(ScratchpadPanelState)
    case xpanel(XPanelState)
}

final class XPanelRuntime: PanelRuntime {
    let panelID: UUID
    let kind: PanelKind = .xpanel

    init(state: XPanelState, context: PanelRuntimeContext) {
        self.panelID = state.panelID
    }

    func focus() {}
    func unfocus() {}
    func close() {}
}
```
