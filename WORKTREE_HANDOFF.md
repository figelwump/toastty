# Worktree Handoff

## Goal

Support local file links with trailing `:<line>` so supported local-document files still open in Toastty, and the local-document webview scrolls to and temporarily highlights the target line.

This is specifically for Toastty-owned local-document surfaces. The first slice should be narrow and should not expand into a general editor-navigation feature.

## Branch And Status

- Branch: `codex/file-links-line-numbers`
- Worktree: `/Users/vishal/GiantThings/repos/toastty-file-links-line-numbers`
- Current status:
  - fresh worktree created and bootstrapped
  - no feature code changes started yet
  - this handoff file is the source of truth for the implementation plan from the parent thread

## User Constraints

- Keep the first slice narrow.
- Supported local-document files only.
- One-based line numbers only.
- Do not add column support in v1.
- Do not persist transient reveal state in workspace snapshots.
- Preserve existing file-open dedupe by normalized file path.
- Do not break legitimate filenames containing `:`.
- Optimize for the simpler correct implementation, not speculative extensibility.

## Current Code Facts

- Local-document open requests currently carry only `filePath`, `placementOverride`, and `formatOverride` in `Sources/App/AppStore.swift`.
- Existing local-document panel dedupe is keyed only by normalized file path in `AppStore.createLocalDocumentPanel(...)`.
- Persisted panel state only carries `filePath` and `format` in `Sources/Core/WebPanels/WebPanelState.swift`.
- Local-document runtime currently does not expose any reveal-line concept.
- The local-document web app renders a separate line-number gutter and scrolling code pane.
- The local-document code view currently uses a monolithic highlighted `<code>` block, which should stay intact in v1.
- The worktree-create helper script is not responsible for handoff detail loss; it only opens the handoff file that was written before launch.

## Root Design Decisions

These were already pressure-tested in the parent thread and should be treated as decided unless implementation evidence forces a revisit.

1. Use a transient local-document open shape with `filePath + optional lineNumber`.
   - Do not persist `lineNumber` in `WebPanelState` or workspace snapshots.

2. Exact-path priority must beat `:line` parsing.
   - If the exact path is an existing supported local-document file, open that exact file.
   - Only if the exact path is not a supported local-document file should a trailing `:digits` be interpreted as a line suffix.

3. Use a one-shot reveal command from runtime to web app.
   - Do not put reveal line into bootstrap state.
   - Do not build an ack/retry protocol for v1.

4. Runtime owns pending reveal delivery, not the store.
   - The store decides which panel to open or focus.
   - The runtime layer decides when the webview is ready enough to consume a reveal command.

5. Use a temporary highlight overlay in the code pane.
   - Do not split highlighted code into per-line wrappers.
   - Preserve the monolithic syntax-highlight DOM to avoid breaking multi-line tokenization.

6. Editing mode should not auto-reveal in v1.
   - If a file is already open in edit mode, focus it and skip reveal to avoid moving the user's editing context.

7. Positive out-of-range line numbers clamp to EOF.
   - `:0`, negative, or non-numeric suffixes do not produce a line target.

## Detailed Implementation Plan

### 1. Introduce a transient file-location shape at the open boundary

Add `lineNumber: Int?` to the local-document open request path in `Sources/App/AppStore.swift`, and add an internal open outcome that returns whether the panel was newly created or an existing panel was focused.

Suggested shape:

```swift
struct LocalDocumentPanelCreateRequest: Equatable, Sendable {
    var filePath: String
    var lineNumber: Int?
    var placementOverride: WebPanelPlacement?
    var formatOverride: LocalDocumentFormat?
}

enum LocalDocumentPanelOpenOutcome: Equatable {
    case opened(panelID: UUID)
    case focusedExisting(panelID: UUID)
}
```

Keep existing bool-returning APIs as compatibility wrappers where needed so the change stays incremental.

### 2. Add shared `path[:line]` parsing with exact-path priority

Implement the parser in a shared place used by the terminal local-file click resolver, or keep it local to that resolver if that is the only current caller. Either way, define the rules explicitly:

- First try the full candidate path as an exact supported local-document path.
- If exact path succeeds, open it as-is and do not interpret `:digits`.
- Otherwise try parsing a trailing `:digits`.
- Only accept parsed form when:
  - digits are numeric
  - digits are greater than 0
  - the base path resolves to an existing supported local-document file
- If parsed form fails, keep the whole string as a plain path candidate.

This rule is critical for filenames containing colons.

### 3. Make the terminal resolver pipeline explicit

In `Sources/App/Terminal/TerminalCommandClickTargetResolver.swift`, the transform order must be explicit and tested:

1. derive raw path from URL
2. resolve relative path against `cwd`
3. generate punctuation/prose-recovery candidates
4. for each candidate:
   - exact supported local-document match
   - then `:line` parsing against that candidate
5. if no local-document match, try local directory handling
6. otherwise passthrough

Important cases to cover:

- `file.md:42`
- `file.md:42.`
- `docs/plan.md:17`
- `docs/plan.md#headings`
- exact filename with colon that exists
- unsupported files with `:42`
- malformed prose-appended paths

### 4. Extend AppStore open flow without changing dedupe semantics

In `Sources/App/AppStore.swift`:

- preserve dedupe strictly on normalized file path
- if matching panel already exists:
  - focus that panel
  - return the existing panel ID
- if no panel exists:
  - create panel normally
  - return the created panel ID

Do not let `lineNumber` affect dedupe identity.

### 5. Move transient reveal ownership into the runtime registry

In `Sources/App/WebPanels/WebPanelRuntimeRegistry.swift`:

- add runtime-facing API to request a reveal for a `panelID`
- if runtime exists and is ready, dispatch immediately
- if runtime exists but app is not ready, store one pending reveal per `panelID`
- if runtime is created later, deliver the pending reveal when possible
- clear pending reveal after delivery
- if the panel disappears, drop the reveal

Do not store this in `AppStore` state or persisted panel state.

### 6. Add one-shot reveal support in LocalDocumentPanelRuntime

In `Sources/App/WebPanels/LocalDocumentPanelRuntime.swift`:

- add a transient pending reveal line field or equivalent queue with one-slot semantics
- flush reveal when:
  - the webview finishes loading
  - the runtime already has a loaded app and receives a reveal request
  - the panel is reloaded and a pending reveal still exists
- do not build an ack protocol
- do not require reveal to survive crashes or long-lived app restarts

If a reveal request arrives while the panel is in editing mode, either skip it at the runtime boundary or have the web app ignore it based on bootstrap state. V1 decision from the parent thread: focus only, skip reveal for editing panels.

### 7. Extend the local-document web app with a reveal command

In `WebPanels/LocalDocumentApp/src/bootstrap.ts`:

- expose a one-shot `revealLine(lineNumber: number)` API on `window.ToasttyLocalDocumentPanel`

In `WebPanels/LocalDocumentApp/src/LocalDocumentPanelApp.tsx`:

- add state/effect handling for transient reveal requests
- compute line count from existing content
- clamp target line into `[1, lineCount]`
- scroll the code pane so the line is visible, preferably centered or slightly top-biased
- show a temporary highlight overlay for the line

In `WebPanels/LocalDocumentApp/src/styles.css`:

- add overlay/highlight styling
- use a duration around 1.5-2s
- respect `prefers-reduced-motion`
- keep the highlight visually distinct in both light and dark themes

### 8. Keep the DOM strategy conservative

Do **not** rewrite code rendering into per-line wrappers for v1.

Reason:

- highlight.js and markdown-as-code highlighting assume a contiguous token stream
- per-line wrappers risk corrupting multi-line strings, block comments, template literals, or markdown token spans
- the overlay approach is simpler and lower risk

The current code view already has the layout primitives needed for an overlay:

- gutter and code pane are already visually aligned
- line height is already explicit in CSS
- code pane already owns scroll

### 9. Decide public automation/CLI exposure only if needed for validation

Optional scope:

- `Sources/App/Automation/AutomationSocketServer.swift`
- `Sources/App/AppControl/AppControlExecutor.swift`
- `docs/socket-protocol.md`
- `docs/cli-reference.md`

Only expose `lineNumber` through automation if it materially improves validation or smoke coverage for this feature. Do not expand the API surface just because it is available.

If added, document it in the same change.

## Affected Files

Primary implementation files:

- `Sources/App/AppStore.swift`
- `Sources/Core/WebPanels/WebPanelState.swift` only if needed for helper types or comments; avoid persisted-state changes
- `Sources/App/Terminal/TerminalCommandClickTargetResolver.swift`
- `Sources/App/Terminal/TerminalRuntimeRegistry.swift`
- `Sources/App/WebPanels/WebPanelRuntimeRegistry.swift`
- `Sources/App/WebPanels/LocalDocumentPanelRuntime.swift`
- `WebPanels/LocalDocumentApp/src/bootstrap.ts`
- `WebPanels/LocalDocumentApp/src/LocalDocumentPanelApp.tsx`
- `WebPanels/LocalDocumentApp/src/styles.css`

Tests:

- `Tests/App/TerminalCommandClickTargetResolverTests.swift`
- `Tests/App/AppStoreWindowSelectionTests.swift`
- `Tests/App/LocalDocumentPanelRuntimeTests.swift`
- `WebPanels/LocalDocumentApp/test/local-document-panel.test.mjs`

Docs and optional automation surface:

- `Sources/App/Automation/AutomationSocketServer.swift`
- `Sources/App/AppControl/AppControlExecutor.swift`
- `docs/socket-protocol.md`
- `docs/cli-reference.md`
- `README.md`
- `docs/configuration.md`

## Required Test Coverage

### Swift tests

Add or update tests for:

- exact colon-in-filename priority
- `file.md:42`
- `file.md:42.`
- relative path + `cwd`
- unsupported files with numeric suffix
- `:0` ignored
- malformed prose-appended paths with numeric suffixes
- existing-panel focus path with `lineNumber`
- newly-created-panel open path with `lineNumber`
- runtime pending reveal when webview is not yet ready
- runtime reveal after reload when pending reveal still exists
- editing-mode skip behavior if implemented at runtime/store boundary

### JS tests

Add or update tests for:

- reveal command registration on the bootstrap bridge
- line clamping behavior
- temporary highlight state lifecycle
- reduced-motion compatibility if the implementation exposes a deterministic seam

### Validation commands

- `cd WebPanels/LocalDocumentApp && npm test`
- targeted Swift tests for resolver/runtime/store paths
- `./scripts/automation/check.sh`

### Runtime/UI validation

If unit tests are not enough, extend a local-document validation path so the feature can be exercised against a fixture file with a target line.

Preferred approach:

- add smoke coverage only if needed
- if automation surface is extended with `lineNumber`, use that to open a known fixture and assert/snapshot the result
- otherwise rely on targeted local validation with captured artifacts

## Known Edge Cases

- Existing supported file named with a literal colon must win over `:line` stripping.
- Existing editing panel should not auto-scroll in v1.
- Positive out-of-range line numbers clamp to EOF.
- Empty files should behave as though line 1 is the only revealable line.
- Unsupported file extensions should keep current behavior.
- Directory paths with `:digits` should not accidentally route into local-document reveal.
- Fragment-only links like `file.md#heading` should preserve current routing behavior unless explicitly changed.

## Non-Goals For V1

- column support
- heading anchors
- generalized browser/editor deep links
- persisted cursor or reveal state
- reveal retry or acknowledgment protocol
- per-line syntax-highlight DOM rewrite
- edit-mode cursor positioning

## Review Reconciliation From Parent Thread

The parent thread ran a plan-review pass and accepted these corrections:

- exact-path-vs-`:line` priority must be explicit
- transform order in the terminal resolver must be fixed before coding
- reveal should be a one-shot command, not a bootstrap-field hybrid
- no ack/retry protocol in v1
- overlay highlight is the preferred approach over per-line DOM wrappers
- “supported local document” must come from a single canonical predicate already used by routing

Treat those as settled unless implementation evidence proves otherwise.

## Suggested First 5 Actions

1. Inspect `AppStore` and `TerminalCommandClickTargetResolver` together, then introduce `lineNumber` plumbing without touching persisted panel state.
2. Implement the explicit resolver pipeline and add tests for exact-path priority, punctuation ordering, and unsupported-file behavior.
3. Add the runtime registry + local-document runtime transient reveal path.
4. Add the web app reveal command and overlay highlight in the code pane.
5. Run JS tests, targeted Swift tests, then broaden to `./scripts/automation/check.sh` and docs only if surface area changed.
