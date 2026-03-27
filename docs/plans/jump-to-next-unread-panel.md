# Historical Plan: Jump to Next Unread Panel

> Superseded in the shipped implementation. Toastty now uses `Cmd+Shift+A` for `Jump to Next Unread or Active`, which preserves the same traversal precedence for unread panels and falls back to active managed-session panels (`working`, `needs approval`, `error`) when no unread target exists. The remaining contents below are retained as historical planning notes for the original unread-only design.

## Context

When multiple terminal panels produce output across tabs, workspaces, and windows, there's no quick way to navigate to the next panel with unread notifications. The user must visually scan badges and manually click through the hierarchy. This shortcut provides a single-key way to cycle through all unread panels in a deterministic order.

## Precedence Order

Starting from the currently focused panel, search for the next unread panel in this order:

1. **Current tab** — remaining panels in layout-tree display order (after focused panel, wrapping)
2. **Other tabs in current workspace** — left-to-right starting from the tab after the selected one, wrapping
3. **Other workspaces in current window** — top-to-bottom starting from the workspace after the selected one, wrapping
4. **Other windows** — cycle through `state.windows` starting after the current window, wrapping; for each window follow the same workspace→tab→panel order

If no unread panel is found anywhere, no-op.

## Architecture

### 1. Core search function on `AppState` (`Sources/Core/AppState.swift`)

Add a pure function that finds the next unread panel given the current position:

```swift
public struct UnreadPanelTarget: Equatable, Sendable {
    public let windowID: UUID
    public let workspaceID: UUID
    public let tabID: UUID
    public let panelID: UUID
}

extension AppState {
    public func nextUnreadPanel(
        fromWindowID: UUID,
        workspaceID: UUID,
        tabID: UUID,
        focusedPanelID: UUID?
    ) -> UnreadPanelTarget?
}
```

This keeps the search logic in the pure `Core` layer, testable without AppKit or runtime dependencies.

**Algorithm sketch:**

```
func nextUnreadPanel(...) -> UnreadPanelTarget?:
    // Build a flat ordered list of (windowID, workspaceID, tabID) tuples
    // starting from current position, wrapping around all windows

    for each (windowID, workspaceID, tab) in order:
        let panelOrder = tab.layoutTree.allSlotInfos.map(\.panelID)

        // If this is the starting tab, begin search AFTER focused panel
        let startOffset = (isStartingTab && focusedPanelID != nil)
            ? index after focusedPanelID in panelOrder
            : 0

        for panelID in rotated panelOrder from startOffset:
            if tab.unreadPanelIDs.contains(panelID):
                return UnreadPanelTarget(windowID, workspaceID, tab.id, panelID)

    return nil
```

The key insight: build a single flat iteration that starts at the current position and wraps through tabs→workspaces→windows, checking each tab's `unreadPanelIDs` directly. This avoids the `workspace.unreadPanelIDs` convenience property which only sees the selected tab.

### 2. New `AppAction` case (`Sources/Core/AppAction.swift`)

```swift
case focusNextUnreadPanel(windowID: UUID)
```

The action carries the window context where the shortcut was pressed. The reducer uses `nextUnreadPanel(...)` to find the target, then applies the necessary state changes (select workspace, select tab, focus panel, clear unread).

### 3. Reducer handling (`Sources/Core/AppReducer.swift`)

```swift
case .focusNextUnreadPanel(let windowID):
    guard let currentWorkspaceID = state.selectedWorkspaceID(in: windowID),
          let workspace = state.workspacesByID[currentWorkspaceID],
          let selectedTabID = workspace.resolvedSelectedTabID else {
        return false
    }

    guard let target = state.nextUnreadPanel(
        fromWindowID: windowID,
        workspaceID: currentWorkspaceID,
        tabID: selectedTabID,
        focusedPanelID: workspace.focusedPanelID
    ) else {
        return false  // No unread panels anywhere
    }

    // Select window if different
    if target.windowID != windowID {
        state.selectedWindowID = target.windowID
    }

    // Select workspace if different
    if target.windowID != windowID || target.workspaceID != currentWorkspaceID {
        // Find window index and update selectedWorkspaceID
        if let idx = state.windows.firstIndex(where: { $0.id == target.windowID }) {
            state.windows[idx].selectedWorkspaceID = target.workspaceID
        }
    }

    // Select tab if different
    if var targetWorkspace = state.workspacesByID[target.workspaceID] {
        targetWorkspace.selectedTabID = target.tabID
        targetWorkspace.focusedPanelID = target.panelID
        // Clear unread for focused panel (matches existing focusPanel behavior)
        _ = targetWorkspace.updateTab(id: target.tabID) { tab in
            _ = tab.unreadPanelIDs.remove(target.panelID)
        }
        targetWorkspace.unreadWorkspaceNotificationCount = 0
        state.workspacesByID[target.workspaceID] = targetWorkspace
    }

    return true
```

### 4. AppStore command method (`Sources/App/AppStore.swift`)

```swift
@discardableResult
func focusNextUnreadPanelFromCommand(preferredWindowID: UUID?) -> Bool {
    guard let selection = commandSelection(preferredWindowID: preferredWindowID) else {
        return false
    }
    return send(.focusNextUnreadPanel(windowID: selection.windowID))
}
```

Use `commandSelection(preferredWindowID:)`, not `commandWindowID(preferredWindowID:)`, so the command is disabled when the focused SwiftUI scene is tearing down instead of silently falling back to some other selected window.

**Cross-window activation:** When the target is in a different window, the command/interceptor layer should bring that window to front after the reducer succeeds. The reducer owns state changes; the App layer owns `NSWindow` activation. Callers can compare `state.selectedWindowID` before and after dispatch to decide whether to activate a different window.

### 5. Shortcut interceptor changes (`Sources/App/ToasttyApp.swift`)

Add to `ShortcutAction` enum:
```swift
case focusNextUnreadPanel
```

Add detection in `shortcutAction(for:)`:
```swift
if Self.isFocusNextUnreadShortcut(event),
   appOwnedShortcutWindowID() != nil {
    return .focusNextUnreadPanel
}
```

Keep both layers:

- The Workspace menu advertises the command and key equivalent for discoverability and normal command validation.
- The local event monitor owns the actual shortcut handling so the embedded terminal cannot swallow `⌘⇧U` before the command path runs.

Add static detection method:
```swift
static func isFocusNextUnreadShortcut(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown,
          event.isARepeat == false,
          event.charactersIgnoringModifiers?.lowercased() == "u" else {
        return false
    }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return modifiers == [.command, .shift]
}
```

Add handler:
```swift
case .focusNextUnreadPanel:
    focusNextUnreadPanel()
```

The handler method dispatches the shared AppStore command and handles window activation:
```swift
private func focusNextUnreadPanel() -> Bool {
    guard let store else { return false }
    guard let preferredWindowID = appOwnedShortcutWindowID() else { return false }
    guard store.commandSelection(preferredWindowID: preferredWindowID) != nil else {
        return false
    }

    let previousSelectedWindowID = store.state.selectedWindowID
    let didNavigate = store.focusNextUnreadPanelFromCommand(
        preferredWindowID: preferredWindowID
    )

    if didNavigate,
       store.state.selectedWindowID != previousSelectedWindowID,
       let targetWindowID = store.state.selectedWindowID {
        activateWindow(id: targetWindowID)
    }

    // Cmd+Shift+U is app-owned in a normal Toastty workspace window.
    // If there is no unread target, consume the shortcut anyway so the
    // app-owned no-op does not leak through to the terminal/default responder.
    return true
}
```

The important distinction is:

- If the key press does not belong to a normal app-owned workspace window, return `false` so AppKit/default handling can continue.
- If Toastty does own the shortcut for that window, return `true` even when there is no unread target, so `⌘⇧U` remains a Toastty no-op rather than falling through to the terminal.

### 6. Keyboard shortcut constant (`Sources/App/ToasttyKeyboardShortcut.swift`)

```swift
static let focusNextUnreadPanel = ToasttyKeyboardShortcut(
    "u",
    modifiers: [.command, .shift]
)
```

### 7. Workspace menu item (`Sources/App/Commands/ToasttyCommandMenus.swift`)

Add "Jump to Next Unread" to the `CommandMenu("Workspace")` block, near the existing tab navigation items:

```swift
Button("Jump to Next Unread") {
    let previousSelectedWindowID = store.state.selectedWindowID
    guard store.focusNextUnreadPanelFromCommand(preferredWindowID: focusedWindowID) else {
        return
    }

    if store.state.selectedWindowID != previousSelectedWindowID,
       let targetWindowID = store.state.selectedWindowID {
        activateWindow(id: targetWindowID)
    }
}
.keyboardShortcut(
    ToasttyKeyboardShortcuts.focusNextUnreadPanel.key,
    modifiers: ToasttyKeyboardShortcuts.focusNextUnreadPanel.modifiers
)
```

Do not add this to `WindowCommandController.swift`; that file manages AppKit bridge items in File/Window, while the actual Workspace menu is declared in `ToasttyCommandMenus.swift`.

Disable the menu item when either:

- `commandSelection(preferredWindowID:)` cannot resolve the focused Toastty window, or
- there are no unread panels anywhere to jump to.

### 8. Window activation helper

The interceptor (or AppStore) needs a way to activate a specific NSWindow by its UUID identifier. Check if there's an existing pattern for this — if not, add a small helper:

```swift
private func activateWindow(id windowID: UUID) {
    for window in NSApp.windows {
        if window.identifier?.rawValue == windowID.uuidString {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}
```

## Files to modify

| File | Change |
|------|--------|
| `Sources/Core/AppState.swift` | Add `UnreadPanelTarget` struct, `nextUnreadPanel(...)` method |
| `Sources/Core/AppAction.swift` | Add `.focusNextUnreadPanel(windowID:)` case + `logName` |
| `Sources/Core/AppReducer.swift` | Handle `.focusNextUnreadPanel` case |
| `Sources/App/ToasttyApp.swift` | Add to `ShortcutAction`, detection, handler, window activation |
| `Sources/App/ToasttyKeyboardShortcut.swift` | Add `focusNextUnreadPanel` constant |
| `Sources/App/AppStore.swift` | Optional: command method if menu item needs it |
| `Sources/App/Commands/ToasttyCommandMenus.swift` | Add Workspace menu item + shortcut |
| `Tests/Core/AppReducerTests.swift` | Test `focusNextUnreadPanel` action |
| `Tests/Core/AppStateTests.swift` | Test `nextUnreadPanel(...)` search logic |
| `Tests/App/DisplayShortcutInterceptorTests.swift` | Test shortcut detection |

## Test strategy

### Unit tests for `nextUnreadPanel` (pure Core logic)
- No unread panels anywhere → returns nil
- Single unread panel in current tab, after focused → returns it
- Single unread panel in current tab, before focused (wrap) → returns it
- Unread panel in a different tab of same workspace → returns it with correct tabID
- Unread panel in a different workspace of same window → returns it
- Unread panel in a different window → returns it
- Multiple unread panels → returns the nearest one per precedence
- Focused panel is itself unread → skips it, finds next

### Reducer tests
- Action correctly updates selectedWorkspaceID, selectedTabID, focusedPanelID
- Clears unread state for the focused panel
- Returns false when no unread panels exist
- Cross-workspace navigation selects the right workspace
- Cross-tab navigation selects the right tab

### Interceptor tests
- Cmd+Shift+U detected as `focusNextUnreadPanel`
- Other Cmd+Shift combinations not detected (Cmd+Shift+[, etc.)

### Smoke test
- Extend `smoke-ui.sh` or add a dedicated automation test that:
  1. Creates multiple panels
  2. Triggers a desktop notification in a background panel
  3. Invokes the shortcut
  4. Verifies the correct panel is now focused and unread badge is cleared

## Cross-window complexity assessment

Cross-window support adds moderate complexity:
- The search function iterates `state.windows` which is already an ordered array
- The reducer already has patterns for cross-window state updates (e.g., `selectWindow`)
- The main new piece is AppKit window activation after the action, which is ~5 lines

This is straightforward to implement inline rather than deferring to a follow-up.
