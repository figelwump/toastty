# toastty local document markdown editing

Date: 2026-04-15

This document narrows the next patch after the `localDocument` persistence
refactor. The goal is markdown editing, not a general document editor and not
an edit-mode matrix.

## summary

The next patch should ship a simple markdown editing loop:

1. A local markdown panel opens in rendered preview.
2. The user explicitly enters edit mode.
3. Edit mode replaces the preview instead of adding a second pane.
4. Save writes to disk and returns the panel to rendered preview.
5. Cancel or revert abandons the in-memory draft and returns the panel to
   rendered preview.

That is enough to prove markdown editing on top of `localDocument` without
persisting transient editor state or widening the UI surface.

## goals

- Add markdown editing for `localDocument` panels.
- Keep `localDocument` identity and restore semantics unchanged.
- Keep edit state transient and runtime-owned.
- Preserve dirty-save-close safety.
- Handle external file changes without silently discarding the user's draft.

## non-goals

- Split or dual-pane edit/preview UI.
- Persisting edit mode in `WebPanelState`.
- Persisting unsaved draft buffers across app relaunch.
- YAML or TOML rendering or editing.
- New-document creation, Save As, or untitled buffers.
- Refactoring browser payloads or broadening local-document classification.

## design simplification

The old plan assumed persisted `preview | edit | split` state. That is
unnecessary for the feature the user actually wants.

For this patch:

- `WebPanelState` stays as-is from the `localDocument` refactor.
- `LocalDocumentState` does not gain a persisted `mode`.
- Panels always restore into rendered markdown preview.
- Entering edit mode is a runtime action, not a persisted panel property.
- Save returns to rendered preview.
- Cancel or revert also returns to rendered preview.

This keeps app restore stable and avoids awkward questions like "should a dirty
editor restore back into edit mode after relaunch?" The answer for this patch
is simply no, because edit sessions are transient.

## architecture

### persisted state

No persistence-model changes are needed for this patch.

The existing model remains:

```swift
public struct LocalDocumentState: Codable, Equatable, Sendable {
    public var filePath: String?
    public var format: LocalDocumentFormat
}
```

That is intentional. The editor session belongs in runtime state.

### runtime session

`MarkdownPanelRuntime` should own a dedicated edit session model for the active
panel instance.

Suggested shape:

```swift
struct MarkdownEditingSession: Sendable, Equatable {
    var isEditing: Bool
    var loadedContent: String
    var draftContent: String
    var contentRevision: Int
    var diskRevision: DocumentDiskRevision?
    var hasExternalConflict: Bool
    var isSaving: Bool
    var saveErrorMessage: String?
}
```

Notes:

- `isEditing` drives whether the web panel renders preview or the source editor.
- `loadedContent` is the last clean content accepted from disk or a successful
  save.
- `draftContent` is only authoritative while editing.
- `contentRevision` increments only when native intentionally replaces the
  editor buffer:
  - initial load
  - clean reload from disk
  - successful save
  - explicit revert/cancel
  - explicit overwrite after conflict
- `contentRevision` must not change for theme changes, transient UI updates, or
  same-content rebootstrap.
- `hasExternalConflict`, `isSaving`, and `saveErrorMessage` are runtime state
  and should not be persisted in app restore.

### bootstrap contract

The bootstrap payload can stay as the only native-to-JS channel in this patch,
but the contract needs to be explicit because draft preservation depends on it.

Suggested payload fields:

```ts
type MarkdownPanelBootstrap = {
  filePath: string | null;
  content: string;
  contentRevision: number;
  isEditing: boolean;
  isDirty: boolean;
  hasExternalConflict: boolean;
  isSaving: boolean;
  saveErrorMessage: string | null;
};
```

Rules:

- JS replaces its editor buffer only when `contentRevision` changes.
- Rebootstrap with the same `contentRevision` while dirty must preserve the
  in-browser draft.
- Preview mode renders the clean `content` value because preview is the
  non-editing state in this design.
- While editing, the editor owns the visible buffer and preview is not shown.

If bootstrap churn becomes awkward later, a transient event channel can be
added. It is not required for the first patch.

### JS to native bridge

The bridge should stay narrow and editing-specific:

```ts
type MarkdownPanelEvent =
  | { type: "enterEdit" }
  | { type: "draftDidChange"; content: string; baseContentRevision: number }
  | { type: "save"; baseContentRevision: number }
  | { type: "cancelEdit"; baseContentRevision: number }
  | { type: "overwriteAfterConflict"; baseContentRevision: number };
```

Notes:

- There is no generic `setMode`.
- `draftDidChange` should be debounced at an initial `250ms`.
- `baseContentRevision` lets native ignore stale messages that were emitted
  before a reload, revert, or save completed.

### UI behavior

The patch should support exactly two visible states:

- rendered preview
- full-panel source editor

User flow:

1. Preview shows rendered markdown plus an `Edit` affordance.
2. `Edit` swaps the panel into source editing.
3. While editing, the panel shows:
   - source editor
   - `Save`
   - `Cancel` or `Revert`
   - dirty/conflict/save-error UI as needed
4. `Save` writes the file, clears dirty state, and returns to rendered preview.
5. `Cancel` or `Revert` discards the draft and returns to rendered preview.

This intentionally avoids a free preview/edit toggle while dirty.

## file and disk behavior

### save strategy

Use atomic save semantics and treat post-save disk content as the new clean
baseline.

The runtime should not implement own-save suppression as "ignore the next file
event." That is too brittle. Instead:

1. Begin save and mark `isSaving = true`.
2. Write atomically.
3. Reload or restat the file and compute the fresh clean disk revision.
4. Accept the resulting content as the new clean baseline.

That makes save behavior defensible whether the file monitor sees one event or
several.

### missing file and nil path

This patch only supports editing existing file-backed documents.

Rules:

- If `filePath == nil`, editing is disabled.
- If the backing file disappears while clean, show a missing-file error in
  preview.
- If the backing file disappears while dirty, retain the draft in memory and
  surface a missing-file conflict state.
- An explicit save may recreate the original file path if the parent directory
  still exists.
- If the parent path is gone or unwritable, keep the draft, keep the panel in
  edit mode, and show a save error.

External rename does not need special tracking in this patch. If the original
path no longer resolves, treat it as a missing-file case.

### external modification

When the file changes on disk:

- if the panel is clean, reload from disk, update `loadedContent`, increment
  `contentRevision`, and stay in preview
- if the panel is dirty, keep the draft, set `hasExternalConflict = true`, and
  require explicit user action

Conflict resolution for the first patch:

- `Cancel` drops the draft and reloads disk content
- `Overwrite` writes the current draft to disk and returns to preview

No three-way merge UI is needed.

### in-flight save

`isSaving` should make behavior explicit:

- disable `Save`, `Cancel`, and `Overwrite` buttons while save is in flight
- ignore duplicate save requests instead of queueing them
- if the host detaches and reattaches during save, the runtime session should
  survive and eventually publish the settled result

## app integration

### native commands

The app-owned command layer should grow only what this patch needs:

- `Edit Markdown` when preview is active
- `Save` routed to the active markdown editor when editing
- close / tab-close / quit dirty checks for markdown panels with active drafts

`Cmd+S` should remain app-owned rather than relying on the embedded web view to
own the shortcut globally.

### lifecycle and hosting

The runtime editing session must survive view detach/reattach for the same
panel instance. A temporary web-view rebuild must not implicitly discard the
draft.

That means the source of truth for draft, dirty, conflict, and save state stays
native-side in `MarkdownPanelRuntime`, with the web app acting as a view over
that session.

## affected files

Primary implementation files:

- `Sources/App/WebPanels/MarkdownPanelRuntime.swift`
- `Sources/App/WebPanels/MarkdownPanelBootstrap.swift`
- `Sources/App/WebPanels/MarkdownPanelView.swift`
- `Sources/App/AppStore.swift`
- `Sources/App/Runtime/` files that coordinate panel lifecycle and close
  confirmation
- `Sources/App/Resources/WebPanels/markdown-panel/`
- `WebPanels/MarkdownApp/src/`

Not expected to change materially in this patch:

- `Sources/Core/WebPanels/WebPanelState.swift`
- local-document classification/open-flow files

## implementation slices

### slice 1: runtime edit session and bootstrap contract

- add the native runtime session model
- load clean file content into runtime state
- thread `isEditing`, `isDirty`, `isSaving`, conflict, and error metadata
  through bootstrap
- teach JS to preserve its draft when `contentRevision` is unchanged

### slice 2: editor UI and entry/exit flow

- add preview `Edit` affordance
- add full-panel source editing view
- wire `enterEdit`, debounced `draftDidChange`, `cancelEdit`, and `save`
- return to preview after successful save or explicit cancel/revert

### slice 3: save, conflict, and close safety

- atomic save
- own-save suppression via refreshed disk revision, not "ignore next event"
- missing-file handling
- external-modification conflict handling
- dirty close / tab-close / quit confirmation

### slice 4: validation and automation

- add focused unit and integration coverage
- run the relevant local test targets
- run local smoke validation for preview, enter edit, save back to preview, and
  restore behavior

## tests

Required coverage:

- bootstrap roundtrip for clean preview and active edit session metadata
- rebootstrap while dirty with unchanged `contentRevision` preserves the draft
- save success clears dirty state and returns to preview
- cancel/revert drops the draft and returns to preview
- duplicate save requests while `isSaving` do not trigger a second write
- external modification while clean reloads content
- external modification while dirty preserves the draft and raises conflict
- external file deletion while dirty preserves the draft and reports missing-file
  state
- host detach/reattach during save preserves the session and settles correctly
- dirty close / quit confirmation for active markdown edit sessions

Validation beyond tests:

- local smoke pass opening a markdown file
- enter edit
- modify content
- save and verify the panel returns to rendered preview
- reopen or restore and confirm the panel comes back in preview mode

## fallback cut list

If the patch grows too large, cut in this order:

1. conflict-copy polish
2. extra editor affordances beyond edit/save/cancel
3. non-essential command/menu polish

Do not cut:

- full-panel editing
- save returning to rendered preview
- dirty close safety
- external-change conflict protection
