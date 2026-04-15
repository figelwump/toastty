# toastty markdown editing on localDocument

Date: 2026-04-15

This document is the detailed implementation plan for the next `localDocument`
step: adding markdown editing on top of the landed persistence refactor.

It assumes `main` already contains the step 1 `localDocument` state migration.
The higher-level sequence still lives in `docs/plans/local-document-panel.md`.

## goals

- Add markdown editing without reopening the `localDocument` persistence model.
- Keep markdown as the only editable local-document format in this patch.
- Preserve current preview behavior when the panel is in preview mode.
- Add bounded save, revert, dirty-state, and external-modification handling.
- Make close and quit flows safe for dirty markdown panels.

## non-goals

- YAML or TOML support.
- Renaming `Markdown*` files or resources in the same patch unless necessary.
- Reworking browser state into typed payloads.
- Building a generic document-provider system.
- Persisting full unsaved draft content into app restore state.
- Save As, autosave, undo-manager integration, or crash-recovery drafts.

## current baseline

Relevant code today:

- [WebPanelState.swift](/Users/vishal/GiantThings/repos/toastty-local-document-editing-plan/Sources/Core/WebPanels/WebPanelState.swift)
- [MarkdownPanelRuntime.swift](/Users/vishal/GiantThings/repos/toastty-local-document-editing-plan/Sources/App/WebPanels/MarkdownPanelRuntime.swift)
- [MarkdownPanelBootstrap.swift](/Users/vishal/GiantThings/repos/toastty-local-document-editing-plan/Sources/App/WebPanels/MarkdownPanelBootstrap.swift)
- [MarkdownPanelView.swift](/Users/vishal/GiantThings/repos/toastty-local-document-editing-plan/Sources/App/WebPanels/MarkdownPanelView.swift)
- [WebPanelRuntimeRegistry.swift](/Users/vishal/GiantThings/repos/toastty-local-document-editing-plan/Sources/App/WebPanels/WebPanelRuntimeRegistry.swift)
- [FocusedPanelCommandController.swift](/Users/vishal/GiantThings/repos/toastty-local-document-editing-plan/Sources/App/Commands/FocusedPanelCommandController.swift)
- [AppQuitConfirmation.swift](/Users/vishal/GiantThings/repos/toastty-local-document-editing-plan/Sources/App/AppQuitConfirmation.swift)
- [WorkspaceTabCloseConfirmation.swift](/Users/vishal/GiantThings/repos/toastty-local-document-editing-plan/Sources/App/WorkspaceTabCloseConfirmation.swift)
- [MarkdownPanelApp.tsx](/Users/vishal/GiantThings/repos/toastty-local-document-editing-plan/WebPanels/MarkdownApp/src/MarkdownPanelApp.tsx)
- [bootstrap.ts](/Users/vishal/GiantThings/repos/toastty-local-document-editing-plan/WebPanels/MarkdownApp/src/bootstrap.ts)

Behavior today:

- persisted state knows `localDocument(filePath, format)` only
- runtime is preview-only and owns file reload behavior
- JS receives one-way bootstrap payloads
- there is no JS to Swift message bridge
- close and quit confirmation only reason about terminals

## design decisions

### 1. Persist mode only

Step 2 should extend persisted state with document mode and stop there.

```swift
public enum LocalDocumentMode: String, Codable, Equatable, Sendable {
    case preview
    case edit
    case split
}

public struct LocalDocumentState: Codable, Equatable, Sendable {
    public var filePath: String?
    public var format: LocalDocumentFormat
    public var mode: LocalDocumentMode
}
```

Rules:

- legacy `definition: "markdown"` payloads default to `mode: .preview`
- `mode` persists across restore and reopen
- dirty draft content does not persist in `AppState`

This keeps step 2 aligned with the earlier simplification: persist panel mode,
not a general draft-recovery system.

### 2. Runtime owns draft and conflict state

Dirty editing state should stay runtime-owned inside `MarkdownPanelRuntime`.
The app already keeps one runtime per live panel ID in
`WebPanelRuntimeRegistry`, which is enough for live editing and close/quit
queries without persisting full draft bodies.

Use a runtime-only session model roughly like:

```swift
struct MarkdownDocumentSession {
    var loadedContent: String
    var draftContent: String
    var diskRevision: MarkdownDiskRevision?
    var hasExternalConflict: Bool
    var contentRevision: UInt64
    var isSaving: Bool
    var lastSaveError: String?
}

struct MarkdownDiskRevision: Equatable {
    var fileNumber: UInt64?
    var modificationDate: Date?
    var size: UInt64?
}
```

Rules:

- `draftContent == loadedContent` means clean
- `contentRevision` only increments when the host intentionally replaces the
  editor buffer:
  - initial load
  - clean file reload
  - revert
  - successful save
  - explicit conflict overwrite
- mode or theme changes alone do not increment `contentRevision`

Crash or force-quit can still lose unsaved edits. That is acceptable for this
patch as long as close and quit confirmation are implemented correctly.

### 3. Store owns mode; runtime mirrors it

Persisted mode needs a narrow reducer action:

```swift
case setLocalDocumentMode(panelID: UUID, mode: LocalDocumentMode)
```

Ownership rules:

- `AppState` is the source of truth for persisted mode
- `MarkdownPanelRuntime` mirrors the currently applied mode from `WebPanelState`
- file reloads must not silently bounce the panel back to preview

This keeps mode restore simple and avoids broad generic web-panel mutations.

### 4. Add a typed JS bridge, but keep it small

Editing requires JS to send draft updates and user intents back to Swift.

Proposed JS-to-host messages:

```ts
type MarkdownPanelHostEvent =
  | { type: "draftDidChange"; baseContentRevision: number; content: string }
  | { type: "setMode"; mode: "preview" | "edit" | "split" }
  | { type: "save" }
  | { type: "revert" }
  | { type: "overwriteAfterConflict" };
```

Validation requirements on the Swift side:

- reject malformed payloads
- reject invalid enum values
- ignore stale `draftDidChange` messages whose `baseContentRevision` does not
  match the current runtime session
- no-op repeated payloads when content is unchanged
- keep all message handling on the main actor

The bridge should use a dedicated `WKScriptMessageHandler` name rather than
stringly scattering `evaluateJavaScript` snippets throughout the runtime.

### 5. Keep the editor in the web app

Do not introduce a native SwiftUI `TextEditor` in this step.

Reasons:

- preview rendering already lives in the React app
- split mode is simpler when editor and preview share one DOM/UI shell
- markdown-specific chrome already exists in the web panel resources

The web app should keep immediate text-editing state locally, but mirror it to
the runtime through debounced `draftDidChange` events.

## contract update

Update the bootstrap contract instead of inventing multiple native-to-JS
payload types in the first pass.

```swift
struct MarkdownPanelBootstrap: Codable, Equatable, Sendable {
    let contractVersion: Int
    let mode: MarkdownPanelMode
    let filePath: String
    let displayName: String
    let content: String
    let theme: MarkdownPanelTheme
    let isDirty: Bool
    let hasExternalConflict: Bool
    let contentRevision: UInt64
    let saveErrorMessage: String?
}
```

Rules:

- bump `contractVersion`
- JS replaces its local editor state only when `contentRevision` changes
- JS treats `saveErrorMessage` as transient UI copy, not persisted state

## save and conflict behavior

### clean panel

- file observer changes auto-reload from disk
- runtime refreshes `loadedContent`, `draftContent`, `diskRevision`
- runtime clears conflict and save-error state

### dirty panel

- file observer changes do not clobber `draftContent`
- runtime sets `hasExternalConflict = true`
- runtime keeps the editor buffer intact

### save

- save writes `draftContent` to disk
- successful save promotes `draftContent` into `loadedContent`
- successful save refreshes `diskRevision`
- successful save clears `hasExternalConflict`

### revert

- discard `draftContent`
- reload from disk
- clear conflict and save-error state

### overwrite after conflict

- ordinary save should not silently overwrite when the disk revision no longer
  matches the loaded revision
- conflict UI should expose an explicit overwrite action
- overwrite is still a normal save path, but gated on a user action and a
  conflict state check

### own-write suppression

This is the subtle part that needs to be designed upfront.

`FilePathObserver` already tolerates atomic-save churn. Step 2 should add an
explicit runtime mechanism for suppressing self-triggered conflict/reload
handling during the app's own save writes, for example:

- mark a save as in-flight before writing
- after a successful write, refresh `diskRevision` immediately from disk
- ignore the first observer callback that matches the just-written revision

Do not rely on a bare inode or mtime comparison without an explicit
own-save-suppression path. Atomic writes will make that brittle.

### save failures

Save errors must be explicit:

- keep the session dirty
- do not update `loadedContent` or `diskRevision`
- surface the error in panel UI
- leave the editor buffer untouched

## close, tab-close, and quit safety

Dirty markdown panels need explicit confirmation just like running terminals.

Add a runtime-facing assessment:

```swift
struct LocalDocumentCloseConfirmationAssessment: Equatable, Sendable {
    let requiresConfirmation: Bool
    let filePath: String?
    let displayName: String
}
```

`WebPanelRuntimeRegistry` should expose a synchronous main-actor query for live
local-document panels. Because draft state is runtime-owned, this API needs to
work even when the host view is detached; the runtime object must not treat
host attachment as the lifetime of the edit session.

Extend:

- `FocusedPanelCommandController` for single-panel close
- `WorkspaceTabCloseConfirmation` for tab close
- `AppQuitConfirmation` for app quit

Workspace close already always prompts, so step 2 can keep that flow simple.
Refining its message to mention unsaved markdown edits is optional.

## command routing

Do not rely only on WKWebView-local keyboard handling for save.

Step 2 should provide:

- in-panel save / revert / mode buttons
- app-owned `Cmd+S` routing for the focused local-document panel

The concrete target/action wiring can live in the existing command-menu layer,
but the important requirement is that save still works when the editor has web
view focus.

If responder-chain wiring turns out to be the highest-risk part of the patch,
keep the app-owned `Cmd+S` route and treat DOM hotkeys as optional sugar.

## UI scope

The editing patch should stage the UI in this order:

1. preview mode remains unchanged
2. edit mode with textarea/editor shell
3. save / revert / conflict banner
4. split mode last

Split mode is part of the intended step 2 scope, but it should be the final UI
slice in the patch. If save/revert/conflict behavior is still unstable, cut
split mode before cutting close/quit safety.

Open questions that should stay out of the first patch:

- persisted split ratio
- multi-pane synchronized scrolling
- merge or diff-based conflict resolution
- save-as flow
- autosave

## implementation slices

### slice 1: core persisted mode

Files:

- `Sources/Core/WebPanels/WebPanelState.swift`
- `Sources/Core/AppAction.swift`
- `Sources/Core/AppReducer.swift`
- core codable and restore tests

Work:

- add `LocalDocumentMode`
- persist it in `LocalDocumentState`
- default legacy markdown payloads to `.preview`
- add `setLocalDocumentMode`

### slice 2: runtime session and bridge plumbing

Files:

- `Sources/App/WebPanels/MarkdownPanelRuntime.swift`
- `Sources/App/WebPanels/MarkdownPanelBootstrap.swift`
- `Sources/App/WebPanels/WebPanelRuntimeRegistry.swift`
- markdown runtime tests

Work:

- add runtime-owned session state
- add typed script-message handling
- add own-save suppression
- add save/revert/conflict transitions
- expose dirty/conflict assessment through the registry

### slice 3: web editor UI

Files:

- `WebPanels/MarkdownApp/src/MarkdownPanelApp.tsx`
- `WebPanels/MarkdownApp/src/bootstrap.ts`
- `WebPanels/MarkdownApp/src/styles.css`
- bundled markdown-panel resources

Work:

- add edit UI
- add preview/edit/split mode controls
- add debounced `draftDidChange`
- add conflict and save-error UI
- keep preview rendering path intact

### slice 4: commands and confirmations

Files:

- `Sources/App/Commands/ToasttyCommandMenus.swift`
- `Sources/App/Commands/FocusedPanelCommandController.swift`
- `Sources/App/AppQuitConfirmation.swift`
- `Sources/App/WorkspaceTabCloseConfirmation.swift`
- related app tests

Work:

- wire app-owned save/revert commands
- add dirty markdown close confirmation
- extend quit and tab-close confirmation logic

### slice 5: automation and cleanup

Files:

- `Sources/App/Automation/AutomationSocketServer.swift`
- automation/runtime tests

Work:

- expose markdown mode / dirty / conflict state in automation snapshots
- keep current markdown preview automation working
- add smoke coverage for edit/save/revert/conflict

## validation

Required tests:

- `LocalDocumentState` codable with and without `mode`
- legacy `definition: "markdown"` decode defaults to `.preview`
- runtime mode propagation
- save success
- save failure
- revert after dirty edits
- clean file reload
- dirty file conflict instead of auto-reload
- explicit overwrite after conflict
- stale debounced `draftDidChange` after revert is ignored
- close confirmation for dirty markdown panel
- workspace-tab quit/close confirmation when dirty markdown panels exist

Required local validation:

- open markdown panel
- switch preview -> edit -> preview
- edit and save
- edit and revert
- edit, modify file externally, verify conflict banner
- quit with dirty markdown panel and confirm prompt behavior

## fallback plan

If one slice proves unstable, cut in this order:

1. split mode
2. fancy conflict UI wording
3. DOM-level hotkeys beyond app-owned save routing

Do not cut:

- persisted mode
- save / revert behavior
- own-save conflict suppression
- dirty-panel close and quit confirmation
