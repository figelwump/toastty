# Worktree Handoff

## Goal

Support local file links with trailing `:<line>` so supported local-document files still open in Toastty, and the local-document webview scrolls to and temporarily highlight the target line.

## User Constraints

- Keep the first slice narrow.
- Support supported local-document files only.
- One-based line numbers only.
- Do not add column support in v1.
- Do not persist transient reveal state in workspace snapshots.
- Preserve existing file-open dedupe by normalized file path.
- Do not break legitimate filenames containing `:`.

## Current Status

- Fresh worktree created and bootstrapped on branch `codex/file-links-line-numbers`.
- No code changes made yet in this worktree.
- There is no durable plan file in the repo yet; this handoff is the source of truth for the implementation plan.

## Agreed Design

1. Add a transient local-document open shape with `filePath + optional lineNumber`.
2. Parse trailing `:digits` only after checking exact-path priority:
   - exact supported local-document path wins first
   - only if exact path is not a supported local document, try stripping `:digits`
   - only accept stripped form when the base path resolves to an existing supported local document and `digits > 0`
3. Keep line reveal transient and runtime-owned, not persisted in `WebPanelState`.
4. Dedupe remains keyed only by normalized file path.
5. Existing read-only panel may reveal after focus; existing editing panel should focus only and skip reveal in v1.
6. Use a one-shot JS reveal command, not a bootstrap field and not an ack/retry protocol.
7. Use a temporary highlight overlay in the local-document code view; do not split syntax-highlighted code into per-line wrappers.
8. Clamp positive out-of-range line numbers to EOF at reveal time.

## Likely Files

- `Sources/App/AppStore.swift`
- `Sources/App/Terminal/TerminalCommandClickTargetResolver.swift`
- `Sources/App/Terminal/TerminalRuntimeRegistry.swift`
- `Sources/App/WebPanels/WebPanelRuntimeRegistry.swift`
- `Sources/App/WebPanels/LocalDocumentPanelRuntime.swift`
- `WebPanels/LocalDocumentApp/src/bootstrap.ts`
- `WebPanels/LocalDocumentApp/src/LocalDocumentPanelApp.tsx`
- `WebPanels/LocalDocumentApp/src/styles.css`
- `Tests/App/TerminalCommandClickTargetResolverTests.swift`
- `Tests/App/AppStoreWindowSelectionTests.swift`
- `Tests/App/LocalDocumentPanelRuntimeTests.swift`
- `WebPanels/LocalDocumentApp/test/local-document-panel.test.mjs`
- Optional if needed for smoke and docs:
  - `Sources/App/Automation/AutomationSocketServer.swift`
  - `Sources/App/AppControl/AppControlExecutor.swift`
  - `docs/socket-protocol.md`
  - `docs/cli-reference.md`
  - `README.md`
  - `docs/configuration.md`

## Next Actions

1. Inspect the existing local-document open flow and add a typed request/outcome path for `lineNumber` without changing persisted `WebPanelState`.
2. Implement the resolver/parser pipeline in `TerminalCommandClickTargetResolver` with explicit transform order and tests for:
   - exact colon-in-filename priority
   - `file.md:42`
   - `file.md:42.`
   - relative paths
   - unsupported files
3. Add runtime-owned pending reveal handling in `WebPanelRuntimeRegistry` and `LocalDocumentPanelRuntime`.
4. Add the web app reveal command plus scroll/highlight overlay in the local-document code view.
5. Run JS tests, targeted Swift tests, then broader validation and docs updates if the public automation surface changes.

## Risks And Notes

- The current code view has a separate gutter and scrolling code pane. Keep reveal/highlight aligned with that model rather than reworking syntax-highlight DOM.
- Do not introduce a reliability handshake for reveal in v1 unless the simpler fire-on-ready approach proves insufficient.
- If exposing `lineNumber` through automation or CLI is necessary for smoke coverage, update docs in the same change.

## Validation

- `cd WebPanels/LocalDocumentApp && npm test`
- Targeted Swift tests around resolver, store selection, and local-document runtime
- `./scripts/automation/check.sh`
- Extend `./scripts/automation/smoke-ui.sh` or comparable local-document validation only if needed to prove reveal behavior beyond unit tests
