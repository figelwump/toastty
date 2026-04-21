# Worktree Handoff

## task goal

Create and implement a concrete plan for broader local-document code support in
Toastty:

- support common source files in local-document panels
- keep the persisted model coarse rather than per-language
- add an `Open in Default App` header action for backed local documents

## user constraints and preferences

- The user explicitly wants a plan first.
- Push back on over-engineering rather than agreeing by default.
- Prefer fixing the root shape at the source over downstream shims.
- Keep the solution pragmatic. Do not accrete a half-built editor project.

## current status

- A fresh sibling worktree is created and bootstrapped on branch
  `codex/local-document-code-support`.
- No implementation has been started in this worktree yet.
- A durable implementation plan now exists at:
  `docs/plans/local-document-code-support.md`

## settled decisions from the parent thread

- Broaden support for common programming-language files, but not “everything”.
- Do not add one persisted `LocalDocumentFormat` case per language.
- Add at most one new coarse persisted format for source code.
- Derive per-language syntax metadata at runtime.
- Add a header-level `Open in Default App` action as the escape hatch.
- Keep markdown as the only special preview mode.
- Keep the first slice extension-based; basename-only files are follow-up.
- Build on the current `highlightState` bootstrap model.

## affected areas

- `Sources/Core/WebPanels/LocalDocumentClassification.swift`
- `Sources/Core/WebPanels/WebPanelState.swift`
- `Sources/App/AppStore.swift`
- `Sources/App/WebPanels/LocalDocumentPanelBootstrap.swift`
- `Sources/App/WebPanels/LocalDocumentPanelRuntime.swift`
- `Sources/App/WebPanels/LocalDocumentOpenPanel.swift`
- `Sources/App/Terminal/TerminalCommandClickTargetResolver.swift`
- `WebPanels/LocalDocumentApp/src/bootstrap.ts`
- `WebPanels/LocalDocumentApp/src/LocalDocumentPanelApp.tsx`
- `WebPanels/LocalDocumentApp/src/nativeBridge.ts`
- `WebPanels/LocalDocumentApp/src/markdownSourceHighlighter.mjs`
- `WebPanels/LocalDocumentApp/src/styles.css`
- relevant tests under `Tests/Core/`, `Tests/App/`, and
  `WebPanels/LocalDocumentApp/test/`
- user-facing docs that enumerate supported local-document file types

## next actions

1. Read `docs/plans/local-document-code-support.md` and treat it as the source
   of truth for implementation sequencing.
2. Implement the classifier and coarse model changes first.
3. Update the runtime bootstrap and web app together so syntax metadata stays
   single-sourced from Swift.
4. Add the external-open bridge + header action after the bootstrap contract is
   in place.
5. Run the targeted tests from the plan, then broader smoke validation if the
   change lands cleanly.

## risks and validation notes

- Do not let per-language syntax metadata leak into persisted workspace state.
- Do not broaden to basename-only files in this patch unless the plan is
  intentionally revised.
- Be careful with edit mode and the external-open button; it should not imply
  unsaved draft handoff to the outside editor.
- If Starry Night lacks one of the desired fenced-code grammars under the
  expected import name, keep Swift in the first slice and defer the rest rather
  than blocking the whole patch.
