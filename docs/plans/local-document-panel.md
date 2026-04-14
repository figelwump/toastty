# toastty local document panel

Date: 2026-04-14

This document is the implementation-sequence plan for evolving Toastty's
current markdown viewer into a typed `localDocument` built-in web panel.
It is intentionally narrower than a general extension system and is written
for the next implementation worktree, where editing is expected to follow
soon after the initial refactor.

Shared web-panel architecture still lives in `docs/plans/web-panels.md`.

## summary

1. The current markdown panel was the right proof of a file-backed, local-only
   `web` panel.
2. YAML and TOML support should not be added as more cases under a
   markdown-specific implementation.
3. Because editing is near-term, the next change should pay the model and
   naming cost now:
   - rename the built-in file-backed panel to `localDocument`
   - move `WebPanelState` toward typed per-definition payloads
   - add a compatibility decode path for existing persisted markdown panels
4. The initial shipped formats remain narrow:
   - markdown preview
   - YAML code view
   - TOML code view
5. The next patch should make the state model editing-ready without
   implementing full save/dirty/bridge behavior yet.

## goals

- Replace markdown-specific naming with `localDocument` naming where that does
  not force an avoidable persistence break.
- Add YAML and TOML support without routing those files through markdown parsing.
- Establish a persisted local-document model that can support editing next.
- Preserve all current browser behavior and restore compatibility.
- Preserve all current markdown mobility guarantees:
  - split, tab, move, close, reopen, restore
- Keep local documents on the local-only web profile.

## non-goals

- Building the editing bridge in this patch.
- Designing installed third-party panels or a manifest schema.
- Supporting every local text/code file type immediately.
- Building live log tailing in this patch.
- Adding generic stringly-typed payload bags to `WebPanelState`.

## target model

The current markdown panel should become one format inside a more general
file-backed panel.

```swift
public enum WebPanelDefinition: String, Codable, CaseIterable, Hashable, Sendable {
    case browser
    case localDocument
    case scratchpad
    case diff
}

public enum LocalDocumentFormat: String, Codable, Equatable, Sendable {
    case markdown
    case text
    case code
    case log
}

public enum LocalDocumentMode: String, Codable, Equatable, Sendable {
    case preview
    case edit
    case split
}

public struct LocalDocumentState: Codable, Equatable, Sendable {
    public var filePath: String?
    public var format: LocalDocumentFormat
    public var syntaxLanguage: String?
    public var mode: LocalDocumentMode
}
```

Expected near-term mappings:

- `README.md` -> `format: .markdown`, `syntaxLanguage: nil`, `mode: .preview`
- `config.yaml` -> `format: .code`, `syntaxLanguage: "yaml"`, `mode: .preview`
- `settings.toml` -> `format: .code`, `syntaxLanguage: "toml"`, `mode: .preview`

This keeps the shape broad enough for later `txt`, source code, and static log
support without forcing those formats into the first implementation wave.

## compatibility requirements

This work changes persisted panel semantics and must not rely on accidental
restore resets.

Required compatibility behavior:

- persisted browser panels continue to restore
- persisted markdown panels continue to restore
- reopened markdown panels continue to reuse their original file path
- current workspace-local reuse by normalized file path remains intact

Compatibility decode rules:

- legacy `definition: "markdown"` decodes as `.localDocument`
- legacy markdown `filePath` state becomes:
  - `format: .markdown`
  - `syntaxLanguage: nil`
  - `mode: .preview`
- legacy browser payloads decode into the new browser-specific payload shape

Do not keep a parallel persisted `documentKind` field just for YAML/TOML.
Classification should derive from the canonical file path when creating or
reloading the panel.

## classification model

Classification should be host-owned and centralized in Core.

Add a small shared type under `Sources/Core/WebPanels/` that maps extensions to
local-document state.

Initial supported mappings:

- `md`, `markdown`, `mdown`, `mkd` -> markdown
- `yaml`, `yml` -> code with `yaml`
- `toml` -> code with `toml`

Rules:

- unsupported or extension-less files return `nil`
- do not inspect content to guess markdown vs YAML
- use existing normalized file-path helpers; do not reimplement path
  normalization in the classifier

This keeps all entry points honest:

- file picker
- terminal link-open routing
- app-store create/focus logic

## runtime and web-app direction

The runtime and bundled web app should also become `localDocument` rather than
`markdown`.

Renames expected in the next implementation patch:

- `MarkdownPanelRuntime` -> `LocalDocumentPanelRuntime`
- `MarkdownPanelBootstrap` -> `LocalDocumentPanelBootstrap`
- `MarkdownOpenPanel` -> `LocalDocumentOpenPanel`
- `MarkdownPanelView` -> `LocalDocumentPanelView`
- `WebPanels/MarkdownApp/` -> `WebPanels/LocalDocumentApp/`
- app-bundle resources under `Sources/App/Resources/WebPanels/`

The runtime bootstrap should carry:

- contract version
- mode
- file path
- display name
- raw file content
- format
- syntax language
- theme

Contract-version handling should stay strict. Native and JS ship together; a
mismatch is a developer failure, not a user-facing fallback path.

## rendering direction

### markdown

Markdown stays on the current markdown-rendering path:

- `react-markdown`
- `remark-gfm`
- `rehype-sanitize`
- heading IDs
- TOC
- frontmatter summary
- markdown word count

### YAML and TOML

YAML and TOML should use a direct code-view path rather than re-entering the
markdown pipeline with synthetic fences.

Requirements:

- explicit syntax highlighting
- line numbers
- no TOC
- no frontmatter bar
- no heading-ID helpers
- no markdown scroll-target behavior

Use the underlying highlighter directly in the code path instead of creating
synthetic fenced markdown. This avoids fence-escaping bugs and keeps the code
document path narrower and easier to reason about.

## editing readiness

Editing is expected soon after this refactor, so the state model should be
ready for it even if the first implementation stays read-only.

What this patch should do now:

- persist `LocalDocumentMode`
- keep `mode: .preview` as the default for the shipped markdown, YAML, and TOML
  flows
- ensure the runtime/bootstrap shape can carry `edit` and `split` later

What this patch should defer:

- dirty-buffer persistence
- save / save as
- reload from disk vs unsaved buffer conflict handling
- typed panel-to-host save/revert commands
- external-modification conflict UI

Expected next editing wave:

- markdown edit/preview/split
- YAML/TOML text editing
- save/revert flows
- dirty state
- file-system conflict handling
- a typed local-document host bridge

## implementation sequence

### step 1: core state refactor and compatibility decode

Files:

- `Sources/Core/WebPanels/WebPanelState.swift`
- related Core/App snapshot and restore tests

Work:

- add `.localDocument` to `WebPanelDefinition`
- move `WebPanelState` toward typed per-definition payloads
- add `LocalDocumentState`
- add compatibility decode for legacy `.markdown`
- preserve browser restore compatibility

This is the highest-risk step and should land first so the rest of the patch
builds against the final persisted model instead of a temporary adapter.

### step 2: shared local-document classification

Files:

- new Core helper under `Sources/Core/WebPanels/`
- `Sources/App/AppStore.swift`
- `Sources/App/Terminal/TerminalCommandClickTargetResolver.swift`
- file-picker/open-panel code

Work:

- centralize extension-to-format/language mapping
- replace markdown-only admission checks
- keep path-based reuse logic intact

### step 3: rename runtime and UI surface to local-document

Files:

- `Sources/App/WebPanels/*Markdown*`
- `Sources/App/WebPanels/WebPanelRuntimeRegistry.swift`
- `Sources/App/WorkspaceView.swift`
- `Sources/App/ToasttyApp.swift`
- `Sources/App/Commands/ToasttyCommandMenus.swift`
- `WebPanels/MarkdownApp/`
- bundled resource paths under `Sources/App/Resources/WebPanels/`

Work:

- rename implementation-local types and files
- rename menu copy to `Open Document...`
- keep the persistence compatibility layer from step 1

### step 4: runtime/bootstrap migration

Files:

- renamed local-document runtime/bootstrap files
- the TS bootstrap contract

Work:

- include `format`, `syntaxLanguage`, and `mode`
- keep file-path-driven reload and missing-file behavior
- keep local-only `WKWebView` profile

### step 5: web-app rendering split

Files:

- `WebPanels/LocalDocumentApp/src/*`
- app-bundled resources

Work:

- preserve markdown preview path
- add direct code view for YAML/TOML
- add line numbers
- suppress markdown-only UI and helpers in code mode

### step 6: validation and performance bounds

Validation requirements:

- targeted Swift tests for state decode, routing, reuse, restore, runtime
  bootstrap, and file watching
- local smoke validation for one markdown file, one YAML file, and one TOML file
- performance sanity checks for:
  - a small config file
  - roughly 5k lines
  - roughly 50k lines

If syntax highlighting is not acceptable for very large files, the same patch
should add a bounded fallback such as plain preformatted text with line numbers
above a documented threshold.

## test plan

Add or update coverage for:

- legacy markdown restore decode into local-document state
- browser restore compatibility
- YAML/TOML admission and classification
- uppercase extensions
- spaces in file paths
- terminal link-open routing for YAML/TOML
- workspace-local dedupe by normalized file path
- runtime bootstrap metadata for markdown vs code documents
- missing-file behavior for YAML/TOML
- code-view UI suppression of markdown-only chrome

Do not add a full new JS test framework just for this patch unless the runtime
work reveals a clear gap that Swift-side coverage cannot reasonably catch.

## out of scope after this patch

Still deferred after the initial local-document refactor:

- editing bridge implementation
- scratchpad
- third-party panel manifests
- generic installed local-document providers
- live log tailing

## handoff expectation

The next worktree should implement this plan in small reviewable commits with
the following order:

1. Core state compatibility
2. classification and command/open flow changes
3. runtime/file rename and wiring
4. web app rendering split
5. validation and cleanup

Do not start with the web app. The persistence and routing model should settle
first so the UI work does not have to be rewritten around a temporary state
shape.
