# broader local-document code support

Date: 2026-04-20

## goal

Broaden Toastty's local-document support to cover common programming-language
files used in agent workflows, while keeping the persisted state model coarse
and adding a clear escape hatch to open the backing file in the system default
app outside Toastty.

Primary user-facing outcomes:

- `.swift`, `.js`, `.mjs`, `.cjs`, `.jsx`, `.ts`, `.mts`, `.cts`, `.tsx`,
  `.py`, `.go`, and `.rs` files can open as local-document panels.
- Those files reuse the existing code-view surface with line numbers and
  syntax highlighting when supported.
- Local-document panels gain an `Open in Default App` header action for backed
  files.
- Markdown fenced code highlighting picks up the newly supported languages
  where the bundled markdown highlighter can do so, with Swift included in the
  first slice.

## constraints and settled decisions

- Do not add one persisted `LocalDocumentFormat` case per programming language.
- Keep `WebPanelState` / `LocalDocumentState` persisted shape coarse-grained.
- Markdown stays the only special preview mode.
- Do not turn this into a broader editor project. Reuse the existing minimal
  edit mode, but do not add language-specific editing features.
- Add an `Open in Default App` escape hatch rather than trying to make the
  local-document editor competitive with dedicated editors.
- Keep the first slice extension-based. Basename-only files such as
  `Dockerfile`, `Makefile`, `.env`, and `Justfile` are a follow-up, not part of
  the first patch.
- Build on the current `highlightState` model instead of reverting to the old
  `shouldHighlight`-only framing.

## recommended model

The persisted model should grow by at most one coarse case:

```swift
public enum LocalDocumentFormat: String, Codable, Equatable, Sendable {
    case markdown
    case yaml
    case toml
    case json
    case jsonl
    case config
    case csv
    case tsv
    case xml
    case shell
    case code
}
```

Do not persist per-language syntax metadata in `WebPanelState`.

Instead, introduce runtime-only classification metadata derived from the file
path:

```swift
public enum LocalDocumentSyntaxLanguage: String, Codable, Equatable, Sendable {
    case swift
    case javascript
    case typescript
    case python
    case go
    case rust
}

public struct LocalDocumentClassification: Equatable, Sendable {
    public let format: LocalDocumentFormat
    public let syntaxLanguage: LocalDocumentSyntaxLanguage?
    public let formatLabel: String
}
```

This classification should remain the single source of truth for:

- which local files Toastty supports
- which coarse persisted format gets stored
- which runtime syntax language the code view should ask the highlighter for
- which user-facing format label the header shows

## file layout and implementation plan

### 1. extend shared classification without exploding persistence

Target files:

- `Sources/Core/WebPanels/LocalDocumentClassification.swift`
- `Sources/Core/WebPanels/WebPanelState.swift`
- `Tests/Core/LocalDocumentClassifierTests.swift`

Plan:

- Add `LocalDocumentFormat.code`.
- Replace the current extension-to-format dictionary with a richer internal
  table that can answer:
  - supported extension
  - coarse persisted format
  - runtime syntax language
  - runtime header label
- Keep `supportedFilenameExtensions` as the picker / command-entry allowlist.
- Preserve compatibility helpers such as `format(forPathExtension:)` and
  `format(forFilePath:)`, but implement them on top of the richer classifier.
- Add new first-slice source-code mappings:
  - `swift -> .code / swift / "Swift"`
  - `js`, `mjs`, `cjs`, `jsx -> .code / javascript / "JavaScript"`
  - `ts`, `mts`, `cts`, `tsx -> .code / typescript / "TypeScript"`
  - `py -> .code / python / "Python"`
  - `go -> .code / go / "Go"`
  - `rs -> .code / rust / "Rust"`

Notes:

- Keep YAML / TOML / JSON / shell in their current coarse families.
- Do not broaden to basename-only files in this patch because the current open
  panel allowlist is extension-driven.

### 2. pass runtime syntax metadata through the local-document bootstrap

Target files:

- `Sources/App/WebPanels/LocalDocumentPanelBootstrap.swift`
- `Sources/App/WebPanels/LocalDocumentPanelRuntime.swift`
- `WebPanels/LocalDocumentApp/src/bootstrap.ts`
- `Tests/App/LocalDocumentPanelRuntimeTests.swift`

Plan:

- Bump the local-document bootstrap contract version.
- Add runtime-only fields to the bootstrap:
  - `syntaxLanguage: LocalDocumentSyntaxLanguage?`
  - `formatLabel: String`
- Derive those fields from the classifier when the runtime resolves the current
  document.
- Keep `WebPanelState.localDocument.format` persisted as the coarse value.
- Continue using `highlightState` to distinguish:
  - large-file disable
  - unsupported language/format
  - unavailable runtime state

Notes:

- This avoids duplicating extension classification logic in both Swift and the
  web app.
- `highlightState == .unsupportedFormat` should cover any `.code` file whose
  registered syntax language is absent from the web bundle, even though the
  first slice intends to wire all listed languages through.

### 3. extend the web app highlighter and header actions

Target files:

- `WebPanels/LocalDocumentApp/src/LocalDocumentPanelApp.tsx`
- `WebPanels/LocalDocumentApp/src/bootstrap.ts`
- `WebPanels/LocalDocumentApp/src/nativeBridge.ts`
- `WebPanels/LocalDocumentApp/src/styles.css`
- `WebPanels/LocalDocumentApp/test/local-document-panel.test.mjs`

Plan:

- Replace `syntaxLanguage(format, filePath)` and `formatLabel(format, filePath)`
  with bootstrap-driven data.
- Register highlight.js grammars for the new runtime syntax languages.
- Use `bootstrap.syntaxLanguage` for code highlighting, not file extension
  parsing inside the web app.
- Add a new native-bridge event for opening the backing file externally.
- Add an `Open in Default App` secondary header action when a backing file
  exists.
- Keep the header layout intentional:
  - read mode: `Open in Default App`, `Edit`
  - edit mode: current save / cancel controls only

Reason for hiding it during edit mode:

- the external app opens on-disk content, not Toastty's unsaved draft
- showing it during edit mode implies a stronger draft handoff than exists

### 4. handle the external-open action in the native runtime

Target files:

- `Sources/App/WebPanels/LocalDocumentPanelRuntime.swift`
- possibly a small helper near `Sources/App/Routing/AppURLRouter.swift` if the
  logic wants to be shared
- `Tests/App/LocalDocumentPanelRuntimeTests.swift`

Plan:

- Extend the script-message event enum to include an external-open request.
- Resolve the backing file URL from the current editing session / document
  snapshot.
- Open it via `NSWorkspace.shared.open(URL(filePath: ...))`.
- Fail quietly when the panel has no file path; do not surface noisy alerts for
  this first slice.

Notes:

- Keep this action local to local-document panels. Do not generalize it into a
  cross-panel header command in this patch.
- If a shared helper becomes obvious, extract it after the behavior is proven,
  not before.

### 5. broaden all local-file entry points consistently

Target files:

- `Sources/App/AppStore.swift`
- `Sources/App/WebPanels/LocalDocumentOpenPanel.swift`
- `Sources/App/Terminal/TerminalCommandClickTargetResolver.swift`
- relevant command/menu tests if coverage exists
- `Tests/App/TerminalCommandClickTargetResolverTests.swift`
- `Tests/App/LocalDocumentOpenPanelTests.swift`

Plan:

- Make sure the new source-code extensions flow through every existing
  local-document entry path:
  - open panel
  - built-in commands / menu items
  - command-palette file-open mode via shared classifier
  - terminal cmd-click link open
- Preserve normalized-path dedupe behavior. Opening the same source file twice
  in the same workspace should still focus the existing panel.

### 6. improve markdown fenced highlighting for the new languages

Target files:

- `WebPanels/LocalDocumentApp/src/markdownSourceHighlighter.mjs`
- `WebPanels/LocalDocumentApp/test/markdown-source-highlighter.test.mjs`

Plan:

- Add Starry Night grammars for the new fenced-code languages that the package
  supports in the first slice, with Swift mandatory because that gap prompted
  the work.
- Add tests that verify a Swift fence gets real tokenization rather than only
  markdown fence highlighting.

Notes:

- Keep the markdown grammar list curated, not exhaustive.
- The fenced-code improvement is additive to markdown rendering and should not
  block local-file support if one of the non-Swift grammars turns out not to be
  available under the expected import name.

### 7. update user-facing docs

Target files:

- `README.md`
- `docs/configuration.md`
- `docs/cli-reference.md` if examples mention supported local-document types
- `docs/socket-protocol.md` only if API behavior or examples need adjustment

Plan:

- Update the supported local-file extension lists anywhere user-facing docs
  enumerate them.
- Mention the new `Open in Default App` action in the local-document surface
  docs if there is a natural home for it.
- Keep the docs honest about scope: supported common source files, not all
  local text/code files.

## validation plan

Minimum automated validation for the implementation session:

1. `Tests/Core/LocalDocumentClassifierTests.swift`
   - new code extension mappings
   - persisted format remains `.code`
   - unsupported extension still returns `nil`
2. `Tests/App/LocalDocumentPanelRuntimeTests.swift`
   - bootstrap carries `syntaxLanguage` and `formatLabel`
   - `highlightState` behavior for `.code` matches expectations
   - external-open bridge event only fires for backed files
3. `Tests/App/TerminalCommandClickTargetResolverTests.swift`
   - cmd-click on a newly supported source file resolves to local-document open
4. `Tests/App/LocalDocumentOpenPanelTests.swift`
   - open panel allowlist includes the new extensions
5. `WebPanels/LocalDocumentApp/test/local-document-panel.test.mjs`
   - header shows the external-open control in read mode
   - code highlighting keys off bootstrap syntax language
6. `WebPanels/LocalDocumentApp/test/markdown-source-highlighter.test.mjs`
   - Swift fenced block tokenizes as Swift

Suggested implementation-session runtime validation after code lands:

- `./scripts/automation/smoke-ui.sh`
- a targeted manual or automation-backed open of:
  - one Swift file
  - one TypeScript or JavaScript file
  - one Python or Go file
- verify the panel header action opens the system default app for a backed file

## sequencing

Recommended order:

1. classifier + coarse model update
2. runtime bootstrap contract update
3. web app runtime/highlighter changes
4. external-open bridge handling
5. entry-point broadening and docs
6. tests and smoke validation

This order keeps state-shape decisions stable before touching UI behavior and
ensures the web app consumes runtime metadata instead of re-deriving it late in
the patch.

## follow-up, not in this slice

- basename-only support such as `Dockerfile`, `Makefile`, `.env`, `Justfile`
- any richer editor behaviors for code files
- broader language pack expansion beyond the first slice
- generic cross-panel “open externally” affordances
- syntax-aware search, symbol navigation, folding, linting, or formatting
