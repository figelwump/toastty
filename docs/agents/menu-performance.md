# Toastty Menu Performance And Shortcut Gotchas

Read this before touching menu rebuilds, hidden system menu items, workspace shortcuts, terminal jank that may involve AppKit, or `Cmd+W` behavior.

## Menu Mutation Risk

A March 2026 regression came from `HiddenSystemMenuItemsBridge` observing `NSMenu.didAddItem`, `didChangeItem`, `didRemoveItem`, and `didBeginTracking`, then recursively refreshing the whole menu tree and reinstalling dynamic bridges. That main-thread AppKit work caused visible terminal scroll, cursor, and TUI stutter. Do not recreate that pattern.

Treat `NSMenu` mutation notifications as high-risk. Do not synchronously perform whole-tree refreshes plus dynamic bridge reinsertion from those observers. If a notification path is needed, keep it bounded, coalesced, and idempotent.

Keep hidden-item refresh separate from dynamic menu bridge reinstall. Mutation notifications may refresh delegate/visibility state, but dynamic bridge reinsertion should stay on explicit user-driven boundaries such as top-level menu open, not every menu mutation.

If a menu refresh path mutates menu items, assume it can trigger more menu notifications. Guard against recursive feedback loops and avoid wiring refresh callbacks that immediately re-mutate the same tree.

If hidden system menu items regress after a programmatic menu rebuild, do not revive the global observer pattern from `04ee174`. Prefer a bounded fix scoped to the opened menu or another non-observer path, even if the narrower fix needs separate follow-up work.

Preserve targeted tests for menu rebuild behavior when touching this area: hidden system items stay hidden after rebuild, and dynamic bridges still reattach where needed without restoring a global recursive refresh loop.

## Terminal Jank Profiling

For stubborn terminal scroll jitter, cursor jitter, or TUI animation stutter, profile a settled `Release` process with Time Profiler before assuming the hot path is in Ghostty or terminal view code. In March 2026, the real culprit was AppKit menu churn on the main thread, not terminal rendering.

When reading Time Profiler for terminal jank, inspect menu/AppKit stacks too. Hot frames in `HiddenSystemMenuItemsBridge`, dynamic menu bridges, `NSMenu`, `NSMenuItem`, `ICUCatalog`, or other menu validation/rendering paths can starve terminal redraws and input handling.

## Workspace Shortcuts

Menu-advertised `Option+digit` workspace shortcuts are not sufficient by themselves. The embedded terminal's key handling can consume those events before the menu-based workspace switch path runs reliably, so keep app-level interception for workspace switching even when the menu also shows the shortcut.

## Close Commands

Do not retarget the native File > Close / Close All slots in place. AppKit can bypass or rebuild those standard menu items in ways that diverge from Toastty's panel/workspace close behavior. Prefer Toastty-owned File menu items wired directly to the same command paths as `Cmd+W` and workspace close.

A retargeted File > Close Panel menu item is not sufficient by itself to own `Cmd+W`. AppKit can bypass that menu item and invoke native window close directly, so `Cmd+W` should stay app-owned in the local shortcut interceptor rather than depending on the menu item's key equivalent.

The app-owned `Cmd+W` path must stay conservative. Do not reclaim it from modal windows, sheet-backed windows, or active text-input responders. If those guards regress, AppKit starts stealing closes in some paths and Toastty starts stealing them in others.
