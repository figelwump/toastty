# Back and forward across Toastty

Status: proposal; implementation is not authorized yet.

## User behavior

Back returns to the last visited terminal or panel, selecting its workspace and
tab and restoring keyboard focus. Forward retraces the same visits. Mouse side
buttons and two titlebar chevrons invoke the same commands.

Proposed scope is one history across the app, including separate Toastty windows.
This matches “Toastty as a whole”; the user can choose per-window history before
implementation. Every window shows the same availability. A cross-window return
activates the destination window, potentially on another display or Space.

- Record deliberate workspace/tab/panel selection, keyboard or palette navigation,
  opening a panel in the foreground, and explicit foreground app-control navigation.
- An explicit `panel.focus` request counts as navigation regardless of caller.
  Background creation, browser-state queries, metadata changes, redraws, automatic
  focus restoration, and window key/app activation notifications add nothing. An
  actual click selecting a panel in another window does count; do not treat the
  resulting window notification as a second visit.
- A visit after going back discards the forward path. Visiting the current panel
  again is a no-op. Returning to an older panel later is a real visit.
- Skip closed destinations; never reopen a closed terminal. Follow a moved panel
  to its current workspace/tab/window. Resolve tooltip names from current state.
- Keep history only for this app session, capped at 100 visits. No persisted
  settings/schema change, history menu, breadcrumbs, or new settings screen.
- Track panel identity, not terminal scroll position, shell directory, document
  cursor, browser URL, or layout. Browser panels retain their own page history.
  Scratchpad and local-document panels participate through the same panel IDs.
  Revealing an auxiliary panel or adjusting focus mode is not undone as a layout
  snapshot on Forward.
- Empty windows with no panel are not destinations. Workspace tabs already have
  layout panels; a missing focus falls back to their resolved focused panel.

Mouse side buttons are reserved for Toastty navigation on all panel types, even
at a history endpoint. This deliberately stops forwarding those buttons to
terminal applications and web content. Middle click and other buttons keep their
existing behavior. No conditional switch to browser-page history at endpoints.

## Existing capabilities and reuse

`Sources/App/AppStore.swift` already resolves a panel's live owner and can select
its workspace, focus it, and activate another window. `Sources/Core/AppReducer.swift`
selects the containing main/auxiliary tab, reveals the right panel, and adjusts
focus-mode presentation. Reuse those paths rather than rebuilding selection.

Focus recording needs stronger intent: `FocusAwareWKWebView` currently calls the
same callback for mouse interaction and `becomeFirstResponder`; terminal runtime
activation and `TerminalActionRouter` also dispatch focus actions. Watching every
state change would record restoration and intermediate hops. `AppActionSource`
is currently audit metadata with many unknown callers; do not infer intent from
its free-form strings.

## History and recording design

Add a small, pure history value with stable panel IDs, a cursor, and operations
for recording a visit, choosing the previous/next live destination, and clearing.
Keep it as transient app-store state, outside Codable `AppState`. A bounded linear
scan is sufficient; no indexing, observer graph, or caching layer is needed.

One synchronous app-store navigation command resolves its before/after destination
using the same main/auxiliary focus resolver as selection fallback; equality is by
panel ID. It applies workspace selection and panel focus as one operation, then
records one visit. Low-level selection helpers never record independently. Pass
typed intent for normal navigation, history traversal, and focus maintenance; do
not hold a nesting guard across asynchronous work or use timers to merge events.
Failed/no-op selection records nothing. IDs must survive moves and never be reused
for a different panel.

For automatic close/fallback changes, retain the cursor's position even if its
entry becomes invalid. Back/Forward scan strictly before/after it, skipping dead
entries and the currently displayed panel. Thus closing C in A → B → C → D while
backed up at C, with fallback B, leaves Back → A and Forward → D. On a subsequent
explicit visit, truncate the forward path, preserve the live origin if it differs
from the cursor entry, then append the destination. Skip invalid entries lazily during traversal; no
eager pruning pass is needed for 100 entries. Avoid adjacent duplicate appends.
Trim oldest visits and adjust the cursor to respect the cap. Replace-state/session
restore clears history and any pending focus target.

History traversal resolves the live destination and commits its cursor after
successful synchronous store selection. Each repeated press uses that new cursor;
no navigation queue is needed. Reuse existing native focus restoration. Input
callers, including keyboard focus changes, supply explicit intent; programmatic
responder callbacks must not record or truncate history. If a pending cross-window
focus target is needed, it suppresses recording only for that target and never
blocks traversal. Clear it on matching completion, target closure, app deactivation,
state replacement, or a new navigation request. Failed native activation must not
leave a global suppression flag or stop later visits. Verify actual first responder
in runtime tests, separately from successful store selection.

Derive Back/Forward availability and destination help text from history plus live
store state on each normal store publication, including closure in another window.
An empty window can invoke the shared history but is never appended as a destination.

Audit and cover these navigation entry points during implementation:

| Entry points | Planned integration |
| --- | --- |
| `Sources/App/SidebarView.swift`, `Sources/App/WorkspaceView.swift` | Workspace/tab clicks, main/aux panel selection and foreground creation |
| `Sources/App/Commands/DisplayShortcutInterceptor.swift`, command palette handlers, app commands | Keyboard/palette navigation through the same recording boundary |
| `Sources/App/Terminal/TerminalRuntimeRegistry.swift`, `Sources/App/Terminal/Runtime/TerminalActionRouter.swift` | Distinguish user terminal navigation from automatic surface activation |
| `Sources/App/WebPanels/WebPanelContainerView.swift`, `Sources/App/WebPanels/WebPanelRuntimeRegistry.swift` | Distinguish input-driven focus from responder restoration |
| `Sources/App/AppWindowSceneView.swift`, `Sources/App/AppStore.swift`, `Sources/App/AppControl/AppControlExecutor.swift` | Window changes, history restoration, explicit foreground automation; background work never records |

Avoid a broad rewrite of all actions. Add typed intent at the navigation boundary
and the specific native focus callbacks that need it. Keep reducer selection and
existing terminal/browser behavior intact. Remove superseded direct recording
hooks if any are introduced during development; there is no legacy history to migrate.

## Mouse input and titlebar

Add one app-local mouse event interceptor, installed alongside the existing
shortcut interceptor in `Sources/App/ToasttyApp.swift`. Handle side-button down
before the terminal/web view focuses itself. Validate physical button mapping
(AppKit numbers 3/4 are the expected candidates; current terminal code forwards
them as Ghostty eight/nine). Vendor drivers that emit keyboard shortcuts need a
separate compatibility check; do not silently steal unrelated shortcuts.

Only handle events for the active Toastty content window, with no modal dialog,
sheet, or blocking transient UI. Keep one consumed-button set so matching up and
drag events remain consumed after a cross-window jump. An up without a consumed
down passes through. Clear stale pairing state on application deactivation.
Use an app-local monitor; no global event tap or Accessibility permission.

Place Back/Forward beside the existing sidebar toggle in `Sources/App/AppWindowView.swift`.
Use disabled endpoints and destination help text such as “Back to Toastty / Code /
editor”, plus accessible labels. Update `Sources/App/Theme.swift` and `Sources/App/WorkspaceView.swift`
leading-space reservations from a single shared width so hidden/minimum-width
sidebars do not cause overlap. Preserve titlebar drag regions and full-screen layout.
Keep the existing minimum window width and tab overflow behavior. Expose named
menu/palette commands without a new default shortcut in the first slice.
`Cmd+[` / `Cmd+]` already select panes, and Shift/Control variants select tabs;
reassigning them is outside this request.

## Implementation order and verification

1. Pure history model and meaningful tests for cursor movement, branching,
   duplicates, closure/fallback followed by branching, moved panels, capacity/cursor
   adjustment, stable identity, and all-dead history.
2. App-store recording/restore boundary: first sidebar/tab/palette, then terminal,
   web, window and app-control entry points. Test one
   record for multi-action navigation, no entries from background work, and delayed
   responder callbacks preserving Forward. Include primary/aux tabs, focus mode,
   explicit automation, failed selection/activation, target closure during restore,
   state replacement, repeated Back presses, and window activation.
3. Verify hardware button mapping, then add chevrons, commands and the side-button interceptor. Test event pairing across
   window switches, disabled endpoints, middle click, modal/sheet exclusion, and
   window identity, teardown/deactivation, and unmatched up events. Restore real
   keyboard input to the selected terminal/web panel.
4. Update `docs/keyboard-shortcuts.md` and relevant app-control documentation for
   app history versus browser-page history and foreground navigation semantics.

After implementation, use the repository verification skill to regenerate/build
and run focused tests through `sv exec -- scripts/remote/test.sh --scope working-tree`.
This mutates only a disposable remote checkout/test app. Start runtime validation
with `sv exec -- scripts/remote/validate.sh --scope working-tree --smoke-test smoke-ui`;
report any local fallback. Then use remote Computer Use for workspace/tab/split,
auxiliary panel, multi-window, focus-mode, hidden-sidebar, narrow titlebar,
full-screen and window-drag scenarios. Include keyboard input after traversal.
Physical side-button validation is still necessary; synthetic events cannot prove
vendor-driver mapping. Do not drive the user's local app without explicit request.

The preserved Scratchpad shows the chevron placement and an interactive visit
history. It is a concept, not evidence of native focus or mouse support.

## Decisions before implementation

The main tradeoff is side-button ownership: terminal applications and embedded
web content lose those buttons, including at history endpoints. This proposal
matches the requested app-wide navigation; it does not add an unrequested modifier
bypass or settings mode. Confirm this contract when authorizing implementation.

App-wide history includes separate windows as the proposed default. Per-window
history is simpler and sufficient for the example involving workspaces; it avoids
cross-window focus restoration and Space changes. The app-wide option better
matches “Toastty as a whole” and reuses existing cross-window panel focus.

Explicit app-control `panel.focus` branches history because it changes the user
location; read-only inspection must use the existing panel-targeted queries. No
new automation opt-out flag is proposed. Storage remains transient, with no data
migration. The independent design review informed the recording, closure, native
focus, availability and validation rules above; its suggested per-window default
and modifier bypass remain alternatives, not silently adopted behavior.
