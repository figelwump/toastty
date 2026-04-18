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

Step 4 is complete in the `codex/local-document-step3` worktree:

- centralized local-document classification under `Sources/Core/WebPanels/`
- shared extension mapping across app open flow, terminal link-open, and the
  open panel
- preserved markdown-only entry points while the runtime was still
  markdown-only
- preserved normalized-path dedupe and legacy automation compatibility

Step 5 is complete in the `codex/local-document-step3` worktree:

- extended `LocalDocumentFormat` and the shared classifier to admit YAML and
  TOML
- added `format` and native `shouldHighlight` metadata to the bootstrap
  contract
- preserved markdown preview behavior while adding direct YAML/TOML code views
  with line numbers
- broadened menus, the open panel, and terminal link-open flow to all
  supported local-document formats
- added `panel.create.localDocument` and
  `automation.local_document_panel_state` while keeping the markdown-named
  automation aliases working
- kept the large-file highlight threshold provisional and left editing behavior
  unchanged when highlighting is disabled

This document is now the follow-on plan, not a proposal for the already-landed
state-model change. The planned implementation sequence in this document is now
complete in this worktree.

## summary

1. The markdown viewer was the right proof of a file-backed, local-only web
   panel, but its persisted naming and state shape were too markdown-specific.
2. That persistence work should land before editing, and it now has.
3. Markdown editing has now landed on top of the new `localDocument` state.
4. The runtime and implementation surface now use `localDocument` naming.
5. YAML and TOML rendering plus broader local-file entry points are now landed
   on top of the shared local-document classification plumbing.

## goals

- Keep the persisted `localDocument` model stable while building on it.
- Add markdown, YAML, and TOML behavior without reworking persistence again.
- Preserve all current browser behavior and restore compatibility.
- Preserve current markdown mobility guarantees:
  - split, tab, move, close, reopen, restore
- Keep local documents on the local-only web profile.

## non-goals

- Reworking browser state into typed payloads in the next patch.
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
    case yaml
    case toml
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
- `LocalDocumentState` now supports `.markdown`, `.yaml`, and `.toml`.
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

### step 4 complete: shared classification plumbing

Landed scope:

- centralized local-document classification and extension source-of-truth under
  `Sources/Core/WebPanels/`
- added one shared extension mapping:
  - `md`, `markdown`, `mdown`, `mkd` -> markdown
  - `yaml`, `yml` -> yaml
  - `toml` -> toml
- kept unsupported and extension-less files returning `nil`
- kept content sniffing out of scope
- reused existing normalized file-path helpers instead of duplicating path
  logic
- preserved markdown-only picker/menu/terminal entry points until code mode
  existed

Implemented validation:

- classification tests for lowercase and uppercase extensions
- spaces in file paths
- terminal link-open routing
- workspace-local dedupe by normalized file path
- open-panel type parity with the shared supported-extension list

### step 5 complete: YAML and TOML rendering plus open-flow broadening

Landed scope:

- extended `LocalDocumentFormat` and the shared classifier to admit YAML and
  TOML
- added explicit `format` metadata and native `shouldHighlight` to the
  bootstrap contract
- preserved markdown preview behavior for markdown files
- added direct YAML/TOML code views with line numbers
- suppressed markdown-only UI in code mode
- broadened the open panel, menu commands, and terminal link-open flow once
  code mode existed
- added `panel.create.localDocument` and
  `automation.local_document_panel_state` while keeping the markdown-named
  automation aliases working

Requirements carried into the implementation:

- no synthetic fenced-markdown fallback for YAML or TOML
- no TOC, frontmatter summary, heading IDs, or markdown scroll-target helpers
  in code mode
- the initial syntax-highlight threshold remains provisional, not measured
- the provisional threshold currently applies to YAML/TOML code views and does
  not change markdown preview behavior
- large-file editing behavior stays unchanged even when highlighting is
  disabled
- the YAML/TOML missing-file placeholder body is plain text, not markdown and
  not comment syntax:
  - `Toastty could not load this document.`
  - blank line
  - `Path:`
  - path line when available
  - blank line
  - `Reason:`
  - reason text
- `UTType(filenameExtension:conformingTo: .plainText)` resolves on the current
  supported development runtime for `yaml`, `yml`, and `toml`

Implemented validation:

- persistence and decode-compat tests for missing `format` defaulting to
  `.markdown`
- runtime/bootstrap tests for markdown vs code documents
- runtime/bootstrap tests for the new automation aliases and bootstrap fields
- missing-file behavior for YAML and TOML
- local smoke validation for one markdown file, one YAML file, and one TOML
  file
- performance sanity checks for small, medium, and large files, including the
  provisional no-highlight threshold

## handoff expectation

Steps 1 through 5 are complete in this worktree. Follow-up work, if needed,
should build on the landed `localDocument` runtime rather than reopening the
compatibility or markdown-only steps.
