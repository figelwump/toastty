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

This document is now the follow-on plan, not a proposal for the already-landed
state-model change.

## summary

1. The markdown viewer was the right proof of a file-backed, local-only web
   panel, but its persisted naming and state shape were too markdown-specific.
2. That persistence work should land before editing, and it now has.
3. Markdown editing should come next on top of the new `localDocument` state.
4. YAML and TOML should wait until editing is settled and the runtime/UI
   surface is no longer markdown-specific.

## goals

- Keep the persisted `localDocument` model stable while building on it.
- Add markdown edit/preview/split behavior without reworking persistence again.
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

### step 2: markdown editing on top of localDocument

Detailed plan:

- `docs/plans/local-document-markdown-editing.md`

Goal:

- add markdown editing without changing the panel identity or persistence model
  again

Likely files:

- `Sources/Core/WebPanels/WebPanelState.swift`
- `Sources/App/WebPanels/MarkdownPanelRuntime.swift`
- `Sources/App/WebPanels/MarkdownPanelBootstrap.swift`
- `Sources/App/WebPanels/MarkdownPanelView.swift`
- `Sources/App/Resources/WebPanels/markdown-panel/`
- `WebPanels/MarkdownApp/src/`
- related runtime, restore, and interaction tests

Work:

- extend `LocalDocumentState` with the minimum additional persisted state
  needed for editing, most likely `LocalDocumentMode`
- keep markdown as the only supported format in this patch
- add preview, edit, and split modes for markdown documents
- add save and revert flows
- add dirty-state tracking
- handle external file modification with a bounded conflict strategy
- keep the web runtime on the local-only profile

Guardrails:

- do not add YAML or TOML in the same patch
- do not mix runtime/file renames with editing behavior unless the diff stays
  obviously reviewable
- keep unsaved-buffer handling scoped to markdown editing rather than designing
  a fully generic document-provider system

Validation:

- state roundtrip tests for any new persisted markdown mode
- runtime/bootstrap tests for edit and split mode metadata
- save/revert/dirty tests
- missing-file and external-modification tests
- local smoke validation for preview, edit, save, and restore

### step 3: rename markdown runtime and UI surface to localDocument

Goal:

- remove markdown-specific type and file naming before broadening beyond
  markdown

Likely files:

- `Sources/App/WebPanels/*Markdown*`
- `WebPanels/MarkdownApp/`
- `Sources/App/Resources/WebPanels/markdown-panel/`
- menu and open-panel copy that still says "Markdown"

Work:

- rename implementation-local types and files to `LocalDocument*`
- rename menu and UI copy to document-oriented wording
- keep the compatibility layer from step 1 unchanged

This step is mostly about naming clarity and reducing the chance that YAML/TOML
support gets wedged into markdown-specific types.

### step 4: classification and open-flow broadening

Goal:

- centralize local-document classification before adding more formats

Likely files:

- new Core helper under `Sources/Core/WebPanels/`
- `Sources/App/AppStore.swift`
- `Sources/App/Terminal/TerminalCommandClickTargetResolver.swift`
- file-picker and open-panel code

Initial mappings:

- `md`, `markdown`, `mdown`, `mkd` -> markdown
- `yaml`, `yml` -> yaml code document
- `toml` -> toml code document

Rules:

- unsupported or extension-less files return `nil`
- do not inspect file contents to guess type
- use existing normalized file-path helpers instead of duplicating path logic

Validation:

- classification tests for lowercase and uppercase extensions
- spaces in file paths
- terminal link-open routing
- workspace-local dedupe by normalized file path

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

The next implementation work should start at step 2, not reopen step 1.

Recommended order:

1. markdown editing
2. runtime and UI rename to local-document
3. classification and open-flow broadening
4. YAML and TOML rendering

Do not start with YAML or TOML. The point of step 1 was to stop building new
behavior on top of markdown-specific persistence. The next step should cash in
that refactor by shipping editing on the new model before broadening format
support again.
