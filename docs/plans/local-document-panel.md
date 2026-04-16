# toastty local document panel

Date: 2026-04-15

This document tracks the remaining implementation sequence after the initial
`localDocument` persistence refactor landed. Shared web-panel architecture
still lives in `docs/plans/web-panels.md`.

## status

Step 1 is complete in the `codex/local-document-step1` worktree:

- persisted `WebPanelDefinition.localDocument`
- added typed `LocalDocumentState`
- added compatibility decode for legacy persisted `definition: "markdown"`
- preserved browser restore behavior
- preserved workspace-local markdown dedupe by normalized file path

Step 2 is complete in the current worktree:

- added transient full-panel markdown editing on top of `localDocument`
- kept `WebPanelState` and `LocalDocumentState` unchanged
- added save, cancel/revert, dirty-state, and conflict handling
- returned saved and reverted panels to rendered preview
- added close and quit safeguards for dirty drafts and in-flight saves

Step 3 is complete in the `codex/local-document-step3` worktree:

- renamed implementation-local markdown runtime, host, bootstrap, and view
  types/files to `LocalDocument*`
- renamed the bundled web app and shipped asset path to the local-document
  naming surface
- renamed app integration APIs and runtime registry seams to `localDocument*`
- kept user-facing open/menu wording on "Markdown File" until broader format
  support lands
- kept the step 1 compatibility layer and automation command strings unchanged

This document is now the follow-on plan, not a proposal for the already-landed
state-model change. The next remaining step is step 4.

## summary

1. The markdown viewer was the right proof of a file-backed, local-only web
   panel, but its persisted naming and state shape were too markdown-specific.
2. That persistence work should land before editing, and it now has.
3. Markdown editing has now landed on top of the new `localDocument` state.
4. The runtime and implementation surface now use `localDocument` naming.
5. The next step is to centralize local-document classification plumbing before
   broadening the open flow and adding YAML and TOML rendering.

## goals

- Keep the persisted `localDocument` model stable while building on it.
- Add markdown editing behavior without reworking persistence again.
- Preserve all current browser behavior and restore compatibility.
- Preserve current markdown mobility guarantees:
  - split, tab, move, close, reopen, restore
- Keep local documents on the local-only web profile.

## non-goals

- Reworking browser state into typed payloads in the next patch.
- Adding YAML or TOML support in the next patch.
- Building a generic installed-panel or manifest system.
- Supporting every local text or code format immediately.
- Building live log tailing in this sequence.
- Reintroducing a generic stringly-typed payload bag to `WebPanelState`.

## current persisted model

The landed state model is intentionally narrow:

```swift
public enum WebPanelDefinition: String, Codable, CaseIterable, Hashable, Sendable {
    case browser
    case localDocument
    case scratchpad
    case diff
}

public enum LocalDocumentFormat: String, Codable, Equatable, Sendable {
    case markdown
}

public struct LocalDocumentState: Codable, Equatable, Sendable {
    public var filePath: String?
    public var format: LocalDocumentFormat
}

public struct WebPanelState: Codable, Equatable, Sendable {
    public var definition: WebPanelDefinition
    public var title: String
    public var initialURL: String?
    public var currentURL: String?
    public var localDocument: LocalDocumentState?
}
```

Notes on the landed shape:

- `WebPanelState.filePath` remains as a read-only compatibility shim for
  call sites that have not migrated yet.
- Browser state still uses the existing flat `initialURL` and `currentURL`
  fields. That is intentional for now.
- `LocalDocumentState` currently only supports `.markdown`.
- The next change that needs more document metadata should extend
  `LocalDocumentState` directly instead of adding new top-level fields back to
  `WebPanelState`.

## compatibility guarantees

The current compatibility contract is:

- persisted browser panels continue to restore
- persisted markdown panels continue to restore
- reopened markdown panels continue to reuse their original normalized file path
- current workspace-local reuse by normalized file path remains intact

Decode rules:

- legacy `definition: "markdown"` decodes as `.localDocument`
- legacy top-level markdown `filePath` decodes into `localDocument.filePath`
- legacy markdown payloads default to `format: .markdown`
- browser payloads continue to decode through the existing flat URL fields

Encode rules:

- new local document payloads encode as `definition: "localDocument"`
- new local document payloads write nested `localDocument` state
- new payloads do not emit the legacy top-level markdown `filePath`

Downgrade compatibility to pre-refactor builds is not a goal. The supported
direction is old persisted markdown state into new builds, not the reverse.

## remaining sequence

### step 2 complete: markdown editing on top of localDocument

Landed scope:

- kept markdown as the only supported local-document format in this step
- kept `WebPanelState` and `LocalDocumentState` unchanged
- added transient full-panel edit mode for markdown documents
- added save and revert flows
- added dirty-state tracking
- added external-modification conflict handling
- returned panels to rendered markdown preview after save and revert
- kept the runtime on the local-only profile

Implemented validation:

- runtime/bootstrap tests for transient edit-session metadata
- save/revert/dirty tests
- missing-file and external-modification tests
- close / quit confirmation coverage for dirty drafts and saves in progress

### step 3 complete: rename markdown runtime and UI surface to localDocument

Goal:

- remove markdown-specific type and file naming before broadening beyond
  markdown

Likely files:

- `Sources/App/WebPanels/*Markdown*`
- `WebPanels/MarkdownApp/`
- `Sources/App/Resources/WebPanels/markdown-panel/`
- menu and open-panel copy that still says "Markdown"

Landed scope:

- renamed implementation-local types and files to `LocalDocument*`
- renamed the bundled web app and shipped asset directory to local-document
  naming
- renamed app integration APIs to `localDocument*`
- kept user-facing file-picker/menu wording on markdown-specific copy for now
- kept the compatibility layer from step 1 unchanged
- kept automation command strings stable for now

This step is mostly about naming clarity and reducing the chance that YAML/TOML
support gets wedged into markdown-specific types.

Implemented validation:

- runtime/bootstrap tests for the renamed asset locator and JS bridge global
- app-layer tests for the renamed runtime and creation APIs
- local smoke automation through the renamed bundled assets

### step 4: shared classification plumbing

Goal:

- centralize local-document classification and extension source-of-truth before
  broadening beyond markdown

Likely files:

- new Core helper under `Sources/Core/WebPanels/`
- `Sources/App/AppStore.swift`
- `Sources/App/Terminal/TerminalCommandClickTargetResolver.swift`
- file-picker and open-panel code

This step should stay intentionally narrow:

- keep user-facing entry points markdown-only in this step
- do not persist YAML or TOML formats until the runtime has a non-markdown
  rendering path
- use one shared source of truth for supported markdown extensions and format
  detection

Future mappings once code mode lands:

- `md`, `markdown`, `mdown`, `mkd` -> markdown
- `yaml`, `yml` -> yaml code document
- `toml` -> toml code document

Rules:

- unsupported or extension-less files return `nil`
- do not inspect file contents to guess type
- use existing normalized file-path helpers instead of duplicating path logic
- do not expose YAML or TOML through picker, menu, or terminal open flows in
  this step

Validation:

- classification tests for lowercase and uppercase extensions
- spaces in file paths
- terminal link-open routing
- workspace-local dedupe by normalized file path
- open-panel type parity with the previous markdown-only filter

### step 5: YAML and TOML rendering

Goal:

- add direct code-view support for YAML and TOML without routing those files
  back through markdown rendering

Likely files:

- `WebPanels/LocalDocumentApp/src/`
- app-bundled local-document resources
- local-document runtime/bootstrap contract

Work:

- add explicit format and syntax metadata to the bootstrap contract
- preserve markdown preview behavior for markdown files
- add direct code-view rendering for YAML and TOML
- add line numbers
- suppress markdown-only UI in code mode

Requirements:

- no synthetic fenced-markdown fallback for YAML or TOML
- no TOC, frontmatter summary, heading IDs, or markdown scroll-target helpers
  in code mode
- keep a bounded large-file fallback if syntax highlighting becomes too slow

Validation:

- runtime/bootstrap tests for markdown vs code documents
- missing-file behavior for YAML and TOML
- local smoke validation for one markdown file, one YAML file, and one TOML
  file
- performance sanity checks for small, medium, and large files

## handoff expectation

The next implementation work should start at step 4, not reopen steps 1, 2,
or 3.

Recommended order:

1. shared classification plumbing
2. YAML and TOML rendering plus open-flow broadening

Do not start with YAML or TOML. The point of step 1 was to stop building new
behavior on top of markdown-specific persistence. The next step should cash in
that refactor by broadening the naming and classification surface only after
editing and the runtime rename landed on the new model.
