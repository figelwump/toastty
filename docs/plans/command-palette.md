# toastty command palette

Date: 2026-04-13

This document describes the design and implementation plan for a command palette
in Toastty. It covers presentation, command sourcing, search and ranking,
window/panel targeting, `@` file-open mode, and future extensibility.

## summary

1. The command palette is a single, keyboard-driven overlay for discovering and
   executing commands in the app.
2. It opens with `Cmd+Shift+P`, intercepted in the existing local event monitor
   before the terminal can consume it.
3. The palette is anchored to the window it was opened from. Commands execute
   against live state in that origin window, even if the palette becomes key.
4. Focused-panel commands target the origin workspace's current
   `focusedPanelID` state at execution time. We do not snapshot a panel ID on
   open.
5. The palette does not introduce a second command system. It is a thin
   projection over existing command helpers, command controllers, menu titles,
   and shortcut definitions.
6. Default mode shows commands. `@` is a file-open mode in v1, routing markdown
   files to markdown panels and HTML files to browser panels.
7. Search uses fuzzy scoring with contiguity and word-boundary bonuses, boosted
   by persisted usage frequency.
8. A `PaletteProvider` protocol keeps modes pluggable. `#` is intentionally
   reserved for future heading/symbol-style queries rather than file search.

## current baseline

- User-facing actions already flow through app-owned command helpers and
  controllers such as:
  - `AppStore.createWorkspaceFromCommand(...)`
  - `AppStore.createWorkspaceTabFromCommand(...)`
  - `AppStore.createBrowserPanelFromCommand(...)`
  - `AppStore.renameSelectedWorkspaceFromCommand(...)`
  - `AppStore.renameSelectedWorkspaceTabFromCommand(...)`
  - `AppStore.closeSelectedWorkspaceFromCommand(...)`
- Keyboard shortcuts are intercepted in `ToasttyApp` via
  `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` and routed through
  `DisplayShortcutInterceptor.ShortcutAction`.
- `ToasttyKeyboardShortcuts` already defines the built-in shortcut constants and
  the symbol labels used in menus and help text.
- `ToasttyCommandMenus` and the command controllers are the current source of
  truth for many command titles, enablement rules, and side effects.
- There is no existing command palette, fuzzy search, or provider abstraction.
  Discoverability depends on menus and keyboard shortcuts.
- The local-document implementation is now the reference shape for file-backed
  editable documents. That work includes:
  - `LocalDocumentPanelCreateRequest`
  - path normalization and same-workspace reuse by file path
  - `Open Local File…`, `Open Local File in Tab…`, and `Open Local File in Split…`
- The command palette plan should align with that local-document shape rather
  than inventing a parallel file-open path.

## goals

- Give users a fast way to discover and execute app commands without memorizing
  shortcuts or navigating menus.
- Keep command execution scoped to the window the palette came from so palette
  actions feel local and predictable.
- Make panel-local actions behave intuitively: split, close, detach, and
  similar actions should apply to the origin workspace's current focused-panel
  state.
- Provide a contextual file-open mode in v1 for markdown and HTML files.
- Rank results by relevance and usage frequency so the palette gets faster the
  more it is used.
- Keep the palette keyboard-native: open, type, navigate with arrows or
  `Ctrl+N` / `Ctrl+P`, then execute or dismiss without needing the mouse.
- Design the provider interface so future sources such as headings, symbols,
  screenshots, slash commands, or richer file types can plug in without
  changing the core palette shell.

## non-goals

- Building a general file finder or Spotlight replacement in v1.
- Replacing the existing command helpers, menu layer, or shortcut system.
- Adding a two-step flow in v1 for commands that require a second target
  selection.
- Building a generic extension/plugin API for third-party palette providers in
  v1.
- Turning `@` into an everything-search mode in v1. It is a contextual file-open
  mode first.

## chosen design: minimal spotlight

Three design directions were explored in Paper (artboards "Command Palette —
Option A/B/C"). Option A remains the selected visual direction.

### design rationale

Option A is a centered floating panel over a dimmed background with a flat
result list and no category headers.

This remains the right starting point because it is:

- the least visually noisy
- the easiest to scan quickly from the keyboard
- the least coupled to existing toolbar or window-chrome layout
- compatible with mixed result types later if the file-open mode grows

### visual spec

- **Panel width:** 580px, centered horizontally, offset about 20% from the top
  of the origin window.
- **Background:** `#2e2722`, 12px corner radius, 1px border
  `rgba(255,255,255,0.10)`, heavy shadow
  `0 32px 80px rgba(0,0,0,0.8)`.
- **Search field:** 14-16px padding, magnifying glass icon, 15px Inter,
  separated from results by a 1px divider.
- **Result rows:** 8px vertical padding, 16px horizontal. Icon on the left,
  title centered, shortcut badge right-aligned.
- **Selected row:** amber tint background with a left accent border.
- **Footer:** result count on the left, mode hints on the right.
- **Empty state:** muted centered text.

### color tokens

```text
palette.background:      #2e2722
palette.border:          rgba(255,255,255,0.10)
palette.divider:         rgba(255,255,255,0.07)
palette.shadow:          0 32px 80px rgba(0,0,0,0.8)

search.text:             #ece4db
search.icon:             #7a7066
search.placeholder:      #6b6058

row.icon.default:        #6b6058
row.icon.selected:       #d4a853
row.title.default:       #a89d93
row.title.selected:      #f0e8de
row.background.selected: rgba(212,168,83,0.13)
row.accent.selected:     #d4a853

badge.text.default:      #6b6058
badge.text.selected:     #a09488
badge.bg.default:        rgba(255,255,255,0.04)
badge.bg.selected:       rgba(255,255,255,0.07)

footer.text:             #5c5349
footer.hint:             #4a4038
```

## execution scope model

The palette needs a clear targeting model before any UI work starts.

### origin window

When the user opens the palette, it captures the current app-owned window ID as
`originWindowID`. That ID is the routing anchor for the entire palette session.

This is required because the palette itself becomes key while typing, so
default "current key window" routing is no longer trustworthy once the panel is
open. In v1, the palette is intentionally ephemeral: click-away dismisses it
rather than keeping it alive across window switches.

### live command resolution

Commands execute against live state in the origin window at execution time.

That means:

- we do not snapshot a workspace ID beyond what `originWindowID` already
  implies
- we do not snapshot a focused panel ID on palette open
- focused-panel commands resolve the origin workspace's current
  `focusedPanelID` state when the user executes the result

This is the right UX for panel-local commands because the user expectation is
"act on the panel I am working in", not "act on whatever panel happened to be
last focused when I opened the overlay." Once the palette is key, AppKit focus
is no longer on the workspace window, so the implementation should be explicit
that it is using persisted workspace focus state, not the current first
responder.

### command scopes

- **App-global:** not tied to a workspace or panel
  - Example: `Reload Configuration`
- **Window-scoped:** target the origin window
  - Example: `Toggle Sidebar`
- **Workspace-scoped:** target the selected workspace in the origin window
  - Example: `Rename Workspace`
- **Focused-panel scoped:** target the origin workspace's current
  `focusedPanelID` inside the selected workspace
  - Example: `Close Panel`, `Split Horizontal`, `Detach Panel to New Window`
- **Explicit-target:** the result itself carries the target
  - Example: `Switch to Workspace 3`
- **File-open routed:** resolve a local file result, then route to the correct
  opener for that file type in the origin window
  - Example: `@README.md` -> markdown panel
  - Example: `@index.html` -> browser panel

## presentation layer

### why NSPanel + NSHostingController

The palette needs:

- reliable text focus
- raw arrow-key handling
- a floating overlay independent from the main content hierarchy
- easy dismiss-on-escape and dismiss-on-click-away behavior

A SwiftUI-only overlay inside the workspace hierarchy risks focus contention
with terminal surfaces and `WKWebView` panels.

### ownership

The palette should be owned by a dedicated `CommandPaletteController` at the app
layer, not by `DisplayShortcutInterceptor`.

Reasons:

- shortcut interception and window/panel lifecycle are separate concerns
- the palette needs its own session state (`originWindowID`, prior responder,
  query, providers, usage tracker)
- command execution will reuse the same controllers and helpers already used by
  menus and shortcut paths

`DisplayShortcutInterceptor` should do only this:

1. detect `Cmd+Shift+P`
2. resolve the current `appOwnedWindowID`
3. ask `CommandPaletteController` to toggle for that window

### panel configuration

The palette should use a small `NSPanel` subclass that can become key for text
entry. We should not depend on `.nonactivatingPanel` semantics to keep the
origin window key because command routing already uses `originWindowID`.

```swift
let panel = CommandPalettePanel(
    contentRect: NSRect(x: 0, y: 0, width: 580, height: 400),
    styleMask: [.borderless, .fullSizeContentView],
    backing: .buffered,
    defer: true
)
panel.isFloatingPanel = true
panel.level = .floating
panel.hasShadow = true
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hidesOnDeactivate = false
panel.collectionBehavior = [.moveToActiveSpace, .transient]
```

`CommandPalettePanel` should override `canBecomeKey` to return `true` so the
search field can reliably accept input.

### panel lifecycle

The controller should use explicit dismiss reasons instead of relying on a
single generic resign-key path.

```swift
enum CommandPaletteDismissReason {
    case cancelled
    case executed
    case toggled
    case clickAway
    case originWindowClosed
    case appDeactivated
}
```

- `show(relativeTo originWindow: NSWindow, originWindowID: UUID)` records the
  origin window, centers the panel on that window's screen, restores the last
  query policy for the session, and focuses the search field.
- `dismiss(reason:)` orders the panel out and handles focus restoration based on
  the reason.
- Escape, explicit toggle-close, and successful execution restore focus to the
  origin window when it is still alive.
- Click-away, app deactivation, and origin-window close dismiss silently with no
  focus restoration.
- In v1, click-away dismisses the palette. We do not keep the palette alive
  after the user activates another window.
- Panel height is dynamic up to a fixed max row count.

### SwiftUI content structure

```swift
VStack(spacing: 0) {
    PaletteSearchField
    Divider()
    PaletteResultList
    Divider()
    PaletteFooter
}
```

### keyboard interaction

| Key | Action |
|-----|--------|
| `Cmd+Shift+P` | Toggle palette |
| typing | Filter results |
| `Up` / `Down` | Move selection |
| `Ctrl+P` / `Ctrl+N` | Move selection up / down |
| `Return` | Execute selected result |
| `Escape` | Dismiss palette |

`PaletteSearchField` uses an `NSTextField` subclass so arrow keys and
`Ctrl+P` / `Ctrl+N` can move the selection instead of falling through to normal
text-field handling.

## command source of truth

### design principle

The palette is not a second command registry layered on top of `AppAction`.

Instead, it is a thin searchable surface over the command layer that already
exists in Toastty:

- `AppStore` command helpers
- command controllers
- menu titles
- `ToasttyKeyboardShortcuts`

If a command already has a helper or controller method, the palette should call
that exact path. If a title or shortcut already exists in menu code, the palette
should reuse that value instead of retyping it.

### command execution context

```swift
protocol CommandPaletteActionHandling: AnyObject {
    func canCreateWorkspace(originWindowID: UUID) -> Bool
    func createWorkspace(originWindowID: UUID) -> Bool
    // ... other command-specific adapter methods ...
}

struct CommandExecutionContext {
    let originWindowID: UUID
    let store: AppStore
    let actions: CommandPaletteActionHandling
}
```

`CommandExecutionContext` can derive:

- `commandSelection(preferredWindowID: originWindowID)`
- the selected workspace in the origin window
- the workspace's current `focusedPanelID` state

`actions` is a thin adapter over the existing command layer. It should own or be
constructed with the command controllers and helper paths the palette needs,
rather than forcing the catalog to reach into controllers ad hoc.

### command descriptor

```swift
struct CommandPaletteCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let keywords: [String]
    let shortcut: ToasttyKeyboardShortcut?
    let icon: PaletteIcon?
    let isAvailable: @MainActor (CommandExecutionContext) -> Bool
    let execute: @MainActor (CommandExecutionContext) -> Bool
}
```

This is still an explicit list, but it is not a second command system. The
closure bodies must call existing helpers/controllers rather than sending raw
`AppAction` values unless no higher-level path exists yet.

### command catalog

`CommandPaletteCatalog` should build the list of commands from shared command
metadata and existing execution paths.

Example:

```swift
CommandPaletteCommand(
    id: "workspace.create",
    title: "New Workspace",
    subtitle: nil,
    keywords: ["workspace", "create"],
    shortcut: ToasttyKeyboardShortcuts.newWorkspace,
    icon: .systemImage("square.stack.badge.plus"),
    isAvailable: { context in
        context.actions.canCreateWorkspace(originWindowID: context.originWindowID)
    },
    execute: { context in
        context.actions.createWorkspace(originWindowID: context.originWindowID)
    }
)
```

For commands handled through controllers instead of `AppStore`, the palette
should reuse those same controllers.

Examples:

- split/focus/resize commands should use the same split command controller paths
  used by shortcut/menu handling
- focused-panel close/detach should use the same focused-panel command paths
- rename commands should use the same request-producing helper paths that menus
  already use

### initial command set

The initial palette should cover the existing built-in user-facing commands,
including:

- workspace commands
- tab commands
- panel commands
- split/layout commands
- browser creation commands
- markdown open commands once the markdown APIs land from the reference worktree
- window and appearance commands

The palette should not invent titles that differ from the menu bar. If the
existing title values are not currently shareable, the implementation should
factor them into shared constants rather than duplicate strings.

That metadata extraction should happen before or alongside the catalog work, not
as an afterthought once duplicate strings already exist.

## search and ranking

### fuzzy scoring algorithm

Search uses character-by-character fuzzy matching with:

- contiguity bonus
- word-boundary bonus
- prefix bonus
- gap penalty

Search runs against `title` first, then `keywords`. Title matches rank above
keyword-only matches.

### frequency boost

```text
finalScore = fuzzyScore * (1 + ln(1 + useCount))
```

The logarithmic boost prevents a single heavily-used command from dominating
forever while still surfacing habits.

### usage persistence

Usage data should live alongside other mutable Toastty state by using
`ToasttyRuntimePaths.configDirectoryURL`, not a hardcoded `~/.toastty` path.

That means:

- ordinary runs write under `~/.toastty/`
- runtime-isolated dev/test runs write inside the active runtime home

Suggested filename:

```text
<config-directory>/command-palette-usage.json
```

Schema:

```json
{
  "workspace.create": { "count": 12, "lastUsed": "2026-04-13T10:30:00Z" },
  "layout.split.horizontal": { "count": 45, "lastUsed": "2026-04-13T11:00:00Z" }
}
```

## scoped modes

### mode model

The palette supports explicit prefix modes, but v1 keeps the set intentionally
small.

| Prefix | Mode | Data source | Placeholder |
|--------|------|-------------|-------------|
| (none) | Commands | Command catalog | "Type a command..." |
| `@` | File open | Contextual file scan + file router | "Open a file..." |

`#` is reserved for future heading/symbol/anchor-style queries once file-backed
panels and richer navigation exist.

### provider protocol

```swift
struct PaletteQueryContext {
    let originWindowID: UUID
    let store: AppStore
    let actions: CommandPaletteActionHandling
}

protocol PaletteProvider {
    var prefix: Character? { get }
    var placeholder: String { get }
    func results(for query: String, context: PaletteQueryContext) async -> [PaletteResult]
    func execute(_ result: PaletteResult, context: PaletteQueryContext) -> Bool
}

struct PaletteResult: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: PaletteIcon?
    let shortcut: ToasttyKeyboardShortcut?
    let score: Double
}
```

### command provider

The default provider wraps `CommandPaletteCatalog`.

Important behavior:

- results are recomputed from live state in the origin window on each query
  update
- availability is a display filter, not a trust boundary
- execution re-runs the underlying helper/controller path and may still fail
  gracefully if state changed after filtering

### file-open provider (`@` mode)

`@` is a file-open mode, not a markdown-only mode.

#### v1 supported file types

- Markdown:
  - `.md`
  - `.markdown`
  - `.mdown`
  - `.mkd`
- HTML:
  - `.html`
  - `.htm`

#### scan scope

The provider scans a contextual tree, not the whole machine.

Root resolution priority:

1. resolve the selected workspace in the origin window
2. if the focused panel is a terminal with a live cwd:
   - ask `RepositoryRootLocator.inferRepoRoot(from:)` for a repo root
   - use the repo root when found, otherwise use that cwd directly
3. otherwise fall back to the first terminal panel in slot order in the
   selected tab that has a live cwd:
   - again prefer inferred repo root over raw cwd
4. otherwise show an empty state because no contextual root can be resolved

This keeps `@` useful without turning it into a general-purpose file finder.

#### scanning behavior

- use `FileManager.default.enumerator` in a background `Task`
- v1 uses bounded async search and returns one batch of results per query
- cancel the in-flight task when the query changes
- cache results for the life of the palette session
- invalidate the cache on the next palette open
- skip hidden directories and common heavy build/vendor directories:
  - `.git`
  - `node_modules`
  - `build`
  - `Derived`
  - `.build`

#### routed execution

The file result carries a routed destination rather than a hardcoded panel type.

```swift
enum FileOpenDestination {
    case markdown(filePath: String)
    case browser(fileURLString: String)
}
```

Execution must go through the existing app-owned openers:

- Markdown:
  - call `createMarkdownPanelFromCommand(...)`
  - preserve the markdown implementation's path normalization and same-workspace
    reuse by file path
- HTML:
  - call `createBrowserPanelFromCommand(...)` with `initialURL` set to the local
    `file://` URL string

This is the durable abstraction for future file types. When more file types are
supported later, `@` stays the same and only the router table grows.

#### placement behavior

For v1, file-open results should use the default placement of the destination
opener:

- markdown -> `MarkdownPanelCreateRequest.defaultPlacement`
- html -> `BrowserPanelCreateRequest.defaultPlacement`

This keeps the first version simple and consistent with existing app-owned open
flows. Alternate placements can come later through modifier keys or secondary
results.

## shortcut interception

`Cmd+Shift+P` should be added to
`DisplayShortcutInterceptor.ShortcutAction` in `ToasttyApp.swift`.

Behavior:

- if a palette session is already active, `Cmd+Shift+P` should toggle it closed
  even though the palette panel is currently key and `appOwnedWindowID` for the
  workspace window is `nil`
- if no palette session is active, detect the shortcut only when
  `appOwnedWindowID` is non-`nil`
- in `handle(_:appOwnedWindowID:)`, forward the live window ID to
  `CommandPaletteController.toggle(originWindowID:)`
- add `ToasttyKeyboardShortcuts.commandPalette`
- add a menu item for discoverability

The interceptor should not own the panel itself.

## file layout

```text
Sources/
  App/
    CommandPalette/
      CommandPaletteController.swift      // app-level owner and session lifecycle
      CommandPalettePanel.swift           // NSPanel subclass and positioning
      CommandPaletteViewModel.swift       // query, selection, provider switching
      CommandPaletteView.swift            // SwiftUI root view
      PaletteSearchField.swift            // NSTextField bridge
      PaletteResultRow.swift              // result row rendering
      PaletteProvider.swift               // provider protocol + result types
      CommandPaletteActionHandler.swift   // adapter over store + controllers
      CommandPaletteCatalog.swift         // thin projection over existing commands
      CommandPaletteContext.swift         // origin-window execution/query context
      FuzzyScorer.swift                   // fuzzy matching
      UsageTracker.swift                  // frequency persistence
      FileOpenRouting.swift               // extension/UTType -> destination
    CommandPalette/Providers/
      CommandProvider.swift               // default command mode
      FileOpenProvider.swift              // @ mode
```

The palette remains an app-layer feature. It reads app state and uses existing
app-owned command paths; it does not add new reducer-owned core state.

## sequencing

### step 1: core shell, origin-window routing, and validation strategy

- add the shortcut
- add `CommandPaletteController`
- add `CommandPalettePanel`
- add `CommandPaletteActionHandler`
- capture `originWindowID` on open
- ensure execution routes through that origin window
- choose the automation strategy up front for wave 1
- implement the search field, selection movement, return/escape behavior

### step 2: command catalog projection

- introduce `CommandPaletteCatalog`
- project the existing command layer into palette results
- reuse menu titles/shortcuts and app-owned command helpers/controllers
- keep focused-panel commands live-resolved in the origin window

### step 3: usage tracking

- implement `UsageTracker`
- persist under `ToasttyRuntimePaths.configDirectoryURL`
- apply frequency boost in command ranking

### step 4: `@` file-open mode

- add `FileOpenProvider`
- scan contextual roots
- support markdown and HTML in v1
- route markdown to markdown panels and HTML to browser panels
- keep `#` reserved

### step 5: polish and validation

- smooth open/dismiss animation
- selected-row visibility
- empty-state polish
- menu integration
- docs updates
- end-to-end validation

## testing

### unit tests

- `FuzzyScorer`
  - exact match
  - prefix match
  - word-boundary bonus
  - gap penalty
  - no match
  - case insensitivity
- `CommandPaletteCatalog`
  - command projection contains expected built-ins
  - titles/shortcuts stay aligned with shared command metadata
  - availability closures call the expected helper/controller paths
- `CommandPaletteViewModel`
  - mode detection
  - selection wraparound
  - `Ctrl+N` / `Ctrl+P` navigation parity with Down / Up
  - dismissal
  - live provider refresh on query changes
- origin-window targeting
  - open from window A
  - let the palette become key
  - execute from palette
  - verify the command still targets A
- toggle behavior
  - open the palette
  - press `Cmd+Shift+P` while the palette is key
  - verify it dismisses cleanly
- dismiss reasons
  - Escape restores focus to the origin window
  - click-away dismisses without focus restoration
  - origin window closing while the palette is open dismisses safely
- focused-panel targeting
  - open from a workspace window
  - change the focused panel inside that origin window
  - execute `Close Panel` or `Split`
  - verify the workspace's current `focusedPanelID` is the target
- `UsageTracker`
  - round trip
  - missing file
  - corrupt file recovery
  - runtime-home path handling
  - config directory creation failure
- `FileOpenProvider`
  - root resolution priority
  - skip-list behavior
  - supported extension filtering
  - markdown vs HTML routing
  - file-scan cancellation on query change
  - symlink-loop safety

### integration tests

- palette open/dismiss lifecycle from the shortcut
- command execution through existing helper/controller paths
- command availability in the origin window
- `@` mode returning markdown and HTML results from a fixture tree
- markdown result executing through `createMarkdownPanelFromCommand(...)`
- HTML result executing through `createBrowserPanelFromCommand(...)`

### automation

The current automation socket does not already provide arbitrary keyboard event
injection for the palette. The plan should not assume that it does.

For end-to-end coverage, choose one of these paths explicitly:

1. add automation-only palette hooks in automation mode only
   - `commandPalette.open`
   - `commandPalette.setQuery`
   - `commandPalette.moveSelection`
   - `commandPalette.executeSelected`
2. or drive the real shortcut/typing path with a dedicated validation script,
   similar in spirit to `shortcut-trace.sh`

Path 1 is more deterministic for CI-like validation. Path 2 gives more faithful
UI coverage. Either is fine, but the implementation plan should pick one rather
than assuming the socket can already send `Cmd+Shift+P`.

This decision should be made in wave 1 because the highest-risk behavior ships
there, not deferred until later polish.

## implementation plan

### wave 1: core palette shell

Goal: `Cmd+Shift+P` opens a working palette shell that executes a small set of
high-frequency commands against the correct origin window.

**1a. Shortcut interception**

Files:

- `Sources/App/ToasttyApp.swift`
- `Sources/App/ToasttyKeyboardShortcut.swift`

Changes:

- add `case commandPalette` to `ShortcutAction`
- add `isCommandPaletteShortcut(_:)`
- in `handle(_:appOwnedWindowID:)`, forward the live `appOwnedWindowID` to the
  palette controller
- if the palette is already active, let the active session consume
  `Cmd+Shift+P` and close itself before normal `appOwnedWindowID` gating runs
- add `ToasttyKeyboardShortcuts.commandPalette`

**1b. Controller and panel**

New files:

- `Sources/App/CommandPalette/CommandPaletteController.swift`
- `Sources/App/CommandPalette/CommandPalettePanel.swift`

Changes:

- `CommandPaletteController` owns the panel and the current palette session
- `CommandPaletteActionHandler` adapts `AppStore` helpers and command
  controllers into palette-facing methods
- `toggle(originWindowID:)` resolves the `NSWindow`, creates/shows the panel,
  and records `originWindowID`
- panel becomes key for typing
- controller tracks explicit dismiss reasons and restores focus only for
  cancellation/toggle-close/success

**1c. Search field and view model**

New files:

- `Sources/App/CommandPalette/PaletteSearchField.swift`
- `Sources/App/CommandPalette/CommandPaletteViewModel.swift`

Changes:

- `PaletteSearchField` intercepts Up, Down, Return, and Escape
- `PaletteSearchField` also intercepts `Ctrl+N` and `Ctrl+P` as aliases for
  Down and Up so the palette matches terminal/readline-style navigation muscle
  memory
- `CommandPaletteViewModel` owns:
  - `query`
  - `selectedIndex`
  - `results`
  - `originWindowID`
  - active provider
- the view model no longer stores an `AppState` snapshot as the command source
  of truth
- query work must cancel cleanly when the user types again

**1d. Wave-1 command set**

Use a small initial set:

- Split Horizontal
- Split Vertical
- New Workspace
- New Tab
- Close Panel
- Toggle Sidebar
- Reload Configuration

Each command must execute through existing helpers/controllers scoped to
`originWindowID`.

**1e. Wave-1 validation**

- unit tests for `FuzzyScorer`
- unit tests for `CommandPaletteViewModel`
- integration test for origin-window targeting
- manual smoke:
  - open the palette and execute `Split Horizontal` while the palette panel is
    key, verifying the split lands in the origin window
  - press `Cmd+Shift+P` again while the palette is key and verify it dismisses
  - click outside the palette and verify it dismisses without trying to persist
    across the window switch

### wave 2: full command catalog

Goal: all built-in user-facing commands are searchable without introducing a
parallel command system or duplicating command metadata inline.

**2a. Catalog**

New file:

- `Sources/App/CommandPalette/CommandPaletteCatalog.swift`

Changes:

- extract shareable command titles and shortcut metadata before wiring the full
  catalog so menus and palette results stay in lockstep
- define the full command list as a thin projection over existing helpers and
  controllers
- factor shared titles/shortcuts into reusable constants where needed
- keep availability and execution closures rooted in the existing command layer

**2b. Result rendering**

Changes:

- render shortcut badges using `ToasttyKeyboardShortcut.symbolLabel`
- show subtitles for commands that benefit from context
- support icons per result

**2c. Wave-2 validation**

- command projection tests
- availability tests
- integration check that the empty query shows the expected built-ins and hides
  unavailable commands for the origin window

### wave 3: usage frequency

Goal: frequently-used commands rise without fighting runtime isolation.

**3a. Usage tracker**

New file:

- `Sources/App/CommandPalette/UsageTracker.swift`

Changes:

- read/write `<config-directory>/command-palette-usage.json`
- derive the config directory from `ToasttyRuntimePaths`
- record usage after successful execution

**3b. Scoring integration**

- apply the logarithmic boost to command results

**3c. Wave-3 validation**

- unit tests for persistence and runtime-aware path resolution
- manual verification that repeated commands rise for ambiguous prefixes

### wave 4: `@` file-open mode

Goal: `@` opens markdown and HTML files from a contextual tree, routing each
result to the right destination.

Prerequisite: the markdown APIs from `../toastty-markdown-panel` must be merged
before wave 4 ships with markdown support. If that merge is not available yet,
ship HTML-only routing first or hold `@` mode until the markdown command path is
present.

**4a. Provider and routing**

New files:

- `Sources/App/CommandPalette/Providers/FileOpenProvider.swift`
- `Sources/App/CommandPalette/FileOpenRouting.swift`

Changes:

- detect `@` as the active provider prefix
- scan the contextual file root
- produce routed file results
- route markdown files through `createMarkdownPanelFromCommand(...)`
- route HTML files through `createBrowserPanelFromCommand(...)`

**4b. Markdown alignment**

Do not bypass the markdown implementation details that already exist in the
reference worktree. The palette must preserve:

- path normalization
- supported markdown extensions
- same-workspace reuse by file path

That means the palette should not construct raw markdown web panels directly.

**4c. Wave-4 validation**

- provider tests for extension support and skip lists
- routing tests for markdown vs HTML
- integration test that opening the same markdown file twice reuses the same
  markdown panel in the current workspace

### wave 5: polish, docs, and end-to-end validation

Goal: smooth presentation, clear discoverability, and stable verification.

**5a. Polish**

- fade in/out animation
- selected-row autoscroll
- better empty states

**5b. Menu integration**

- add `Command Palette…` to the menu bar
- wire it to `Cmd+Shift+P`

**5c. Docs updates**

Update:

- `docs/keyboard-shortcuts.md` for `Cmd+Shift+P`
- command palette docs if one is added
- web/markdown docs when palette-driven file open ships so markdown and browser
  entry points stay documented consistently

**5d. End-to-end validation**

- adopt one explicit automation strategy from the testing section
- include a smoke path for:
  - command execution in the correct origin window
  - `@README.md` opening a markdown panel
  - `@index.html` opening a browser panel

## resolved decisions

- **Design direction:** centered minimal spotlight panel.
- **Window routing:** commands always target the window the palette was opened
  from.
- **Dismiss behavior:** click-away dismisses the palette in v1; we do not keep
  it alive across window switches.
- **Focused-panel UX:** panel-local commands act on the origin workspace's
  current `focusedPanelID` state at execution time.
- **Command sourcing:** the palette is a thin projection over existing
  command/menu/controller paths, not a second command system.
- **Default mode:** no-prefix = commands.
- **File mode:** `@` = file open.
- **Reserved prefix:** `#` stays available for future heading/symbol queries.
- **V1 file routing:** markdown files open markdown panels; HTML files open
  browser panels.
- **File-search execution model:** bounded async search in v1, not streaming
  partial results.
- **Usage storage:** runtime-aware config directory, not a hardcoded home path.

## accessibility and performance

- Provide accessibility labels and identifiers for the search field, results
  list, and selected result state before shipping.
- Respect reduced-motion preferences by making palette animations optional.
- Prefer keyboard-only interaction paths to remain complete even without arrow
  keys, including `Ctrl+N` / `Ctrl+P`.
- Initial command-mode open should feel effectively instant.
- Query updates in command mode should stay under a tight interactive budget.
- `@` mode may take longer on first uncached scan, but cached queries should
  remain responsive enough that streaming is unnecessary in v1.

## open questions

- Should a later version of `@` expose a user-visible toggle between repo-root
  scope and raw cwd scope?
- Should v1 file-open results always use the destination opener's default
  placement, or should the palette support an alternate placement modifier in
  the first release?
- Does the palette need to persist its last query during a single app session,
  or should each open start fresh?
- What is the right max visible row count before scrolling begins?
- Should a future `#` mode target markdown headings only, or broader workspace
  symbols as well?
