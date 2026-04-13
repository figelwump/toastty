# toastty web panels

Date: 2026-04-13

This document describes the current shared web-panel architecture in Toastty and
the next steps after browser and markdown v1. It is the source of truth for
near-term web-panel work in this worktree.

## summary

1. Toastty already has two renderer-level panel kinds: `terminal` and `web`.
2. Browser is the shipped proof of the shared `web` substrate.
3. Markdown v1 is now implemented in this worktree as the first non-browser web
   panel.
4. Scratchpad should follow markdown, not precede it.
5. Built-in panels should stay typed and app-owned in v1. Generic
   manifest-style abstractions should wait until real built-in or third-party
   needs force them.
6. Feedback routing remains an app concern, not a panel-owned concern.
7. Installed third-party panels are deferred until the built-in lifecycle is
   stable across browser and markdown.

## current baseline

The following are already true in the repo:

- `PanelKind` already has `terminal` and `web`.
- `PanelState` already has `.terminal` and `.web`.
- Browser already ships as a real `web` panel with:
  - stable `WKWebView` ownership
  - runtime registry ownership across view remounts
  - split, tab, close, reopen, and restore behavior
  - command/menu creation flows
  - URL routing integration
  - automation and reducer coverage
- This worktree also includes markdown v1 with:
  - explicit `filePath` state in `WebPanelState`
  - definition-aware runtime registry support
  - host-owned file selection and workspace-local dedupe
  - split and tab placement support
  - restore and reopen coverage
  - a bundled local web app rendered inside `WKWebView`
- The old auxiliary-panel product concept is already gone. There is no remaining
  permanent right-column panel class to migrate away from.

This means Toastty is no longer in a speculative "phase 1 substrate" state. The
browser panel is the substrate proof, and markdown is now the second proof that
the same substrate can host non-browser content cleanly. The next work is no
longer "build markdown," but rather harden markdown and use it as the reference
shape for future built-in and third-party web panels.

## goals

- Keep a single `web` substrate for browser, markdown, scratchpad, diff, and
  future built-in panels.
- Preserve the mobility guarantees browser already proved:
  - move between splits
  - move between tabs, workspaces, and windows
  - persist and restore cleanly
- Establish markdown as the reference non-browser built-in panel shape.
- Keep terminal-first workflows fast and predictable.
- Keep panel creation and placement rules concrete and understandable.
- Keep agent-to-panel and panel-to-agent communication app-owned.

## non-goals

- Designing a public package registry or marketplace in v1.
- Finalizing a generic installed-panel manifest schema in v1.
- Replacing typed built-in state with `String` identifiers and untyped payload
  dictionaries before a real need exists.
- Requiring every split action to prompt for a panel type.
- Giving arbitrary installed panels a generic unrestricted command bridge in v1.

## current model

Toastty should continue to treat `web` as the only non-terminal renderer-level
panel kind.

```swift
enum PanelKind: String, Codable, CaseIterable, Hashable, Sendable {
    case terminal
    case web
}

enum PanelState: Equatable, Sendable {
    case terminal(TerminalPanelState)
    case web(WebPanelState)
}

enum WebPanelDefinition: String, Codable, CaseIterable, Hashable, Sendable {
    case browser
    case markdown
    case scratchpad
    case diff
}
```

That high-level shape is correct and should stay.

The current `WebPanelState` is still intentionally flat because browser shipped
first and markdown v1 chose the smallest stable state change:

- browser keeps `initialURL` and `currentURL`
- markdown adds explicit `filePath`

That is acceptable as the current as-built state, but it should be revisited
before edit/comment mode or more non-browser panel types land.

## near-term architecture direction

### keep built-ins typed

For built-in panels, keep `WebPanelDefinition` as a Swift enum in v1.

Do not switch to:

- `definitionID: String`
- `creationArguments: [String: JSONValue]`
- generic manifest lookup for built-ins

Those abstractions become useful only when installed third-party panels are real
product scope. Before that, they remove type safety and introduce migration
surface without solving a current problem.

### evolve `WebPanelState` toward typed per-definition payload

The next state evolution should be typed and definition-aware.

Requirements:

- panel identity remains external to `WebPanelState`
  - do not add `panelID` into the payload struct
- browser-specific data should stay browser-specific
- markdown-specific data should be modeled explicitly
- restore should remain Codable and stable

Acceptable v1 directions:

1. a definition-specific associated payload model
2. a flat but still typed struct with explicit browser and markdown fields

Preferred direction:

- use a typed per-definition payload if it stays reasonably small

Current implementation choice in this worktree:

- add explicit markdown fields to `WebPanelState` and keep the struct flat for
  one more iteration

What should be avoided:

- replacing typed fields with a generic key-value bag before a second concrete
  built-in panel exists

### keep reuse as host behavior, not user-facing mode

The product direction from the previous plan still stands: reuse should be host
behavior, not a global "Open vs New" UX concept.

For the next phase:

- browser continues to create a new instance by default
- markdown should reuse an existing instance within the current workspace when
  opening the same normalized file path
- reuse can be resolved from typed state
  - do not add a generic persisted `instanceKey` field yet unless a concrete
    implementation truly needs it

### runtime registry must become definition-aware

The real missing substrate work is not "create a registry." Toastty already has
one. The missing work is to make it support more than browser.

Required direction:

- keep one app-owned `WebPanelRuntimeRegistry`
- let that registry vend definition-specific runtimes
- keep runtime ownership native and explicit
- preserve deterministic reattachment after moves, restores, and tab switches

The current implementation in this worktree uses:

- existing `BrowserPanelRuntime`
- new `MarkdownPanelRuntime`
- separate typed runtime stores inside the same registry

That is the right near-term choice. A shared runtime protocol can wait until a
third runtime makes the duplication worth addressing.

## web profiles

Toastty needs a small set of app-owned web profiles that bundle runtime policy
with `WKWebViewConfiguration`.

Required near-term profiles:

- browser profile
  - outbound network allowed
  - browser-like storage behavior as appropriate
- local-only profile
  - outbound network denied
  - isolated storage/data-store behavior

Markdown should use the local-only profile.

The current codebase now makes that contract explicit on
`WebPanelDefinition.capabilityProfile` instead of leaving it as runtime-only
convention. The current mapping is `browser -> networkAllowed` and
`markdown -> localOnly`. Placeholder built-ins that do not have a concrete
runtime yet default to `localOnly` until a real product need justifies broader
access.

The profile boundary matters more than the exact implementation class layout.
The key product rule is that a file-backed markdown panel should not silently
behave like a general browser.

Current implementation status:

- explicit capability profile on each `WebPanelDefinition`
- non-persistent `WKWebsiteDataStore`
- file-only navigation policy in the runtime
- remote links blocked in the bundled markdown app
- remote images blocked in the bundled markdown app

This is enough for markdown v1, but it is not the final word on enforcement.
If stronger no-network guarantees are needed later, they should be added as
explicit runtime policy rather than assumed from the current setup.

## placement model

The broad placement idea remains right, but it should be grounded in current
behavior rather than a more general future system.

### current shipped placement behavior

Browser already has concrete placement behavior:

- `New Browser` uses `rootRight`
- `New Browser Tab` uses `newTab`
- `New Browser Split` uses `splitRight`
- internal URL opens default to `newTab`
- alternate URL opens default to `rootRight`

### near-term rule

For the next phase, placement precedence should stay simple:

1. explicit invocation override
2. definition default
3. platform fallback

Do not add a definition-override user config layer yet unless a concrete second
panel needs it.

### supported vocabulary

Current useful placement vocabulary:

- `rootRight`
- `newTab`
- `splitRight`

Future values such as `splitDown`, `backgroundNewTab`, or
`splitBesideSource` can be added later when a built-in panel genuinely needs
them.

## markdown v1 status

Markdown was the right next built-in web panel because it validates the parts of
the substrate browser did not need to prove:

- a non-browser content model
- a local-only web profile
- file-backed panel state
- workspace-local instance reuse
- host-driven content loading into a web view

Markdown remains narrower than scratchpad and should continue to act as the
reference built-in non-browser panel.

### markdown v1 scope

Markdown v1 in this worktree focuses on file-backed rendering and lifecycle
correctness.

Implemented behavior:

- open a markdown file into a `web` panel
- restore that panel from persisted state
- reopen the panel after close
- reuse an existing markdown panel in the current workspace when opening the
  same file
- live reload the panel when the backing file changes on disk
- allow both `newTab` and explicit split placement variants
- keep the panel local-only

Implemented creation actions:

- `Open Markdown File...`
- `Open Markdown File in Tab...`
- `Open Markdown File in Split...`

### markdown v1 content loading

Markdown v1 does not use Swift-side HTML rendering.

Current implementation direction:

- bundle a local markdown web app under `WebPanels/MarkdownApp/`
- copy built assets into `Sources/App/Resources/WebPanels/markdown-panel/`
- load that bundled app inside `WKWebView`
- have the host read markdown source in Swift
- inject a typed bootstrap payload into the page
- render the source inside the page with `react-markdown`,
  `remark-gfm`, and `rehype-sanitize`

This better matches the intended third-party extension shape than a one-off
Swift-side HTML renderer would.

### markdown v1 bridge stance

Do not block markdown on a generic typed bridge.

What markdown v1 currently uses is simpler:

- host prepares bootstrap data
- host injects bootstrap data into the bundled page
- the page owns rendering from that source

A richer host-to-panel or panel-to-host bridge can arrive later when markdown
review or scratchpad feedback needs it.

Current bootstrap fields are intentionally narrow:

- contract version
- mode
- file path
- display name
- raw markdown content

### markdown v1 file watching

Markdown file watching is now part of the implemented v1 hardening work.

Current implementation direction:

- keep runtime-owned watching inside `MarkdownPanelRuntime`
- watch the persisted file path and its parent directory so atomic-save
  rename/recreate flows still recover
- debounce reload requests in the runtime instead of persisting watcher state
- keep missing-file rendering path-based rather than mutating `WebPanelState`

This keeps the implementation markdown-specific while still leaving room for a
small internal watcher helper to be reused later by another file-backed panel.

## scratchpad follows markdown

Scratchpad remains a `web` panel, but it should not be the next panel built.

Scratchpad adds higher-risk concerns that markdown does not require:

- richer host-to-panel updates
- panel-to-host feedback events
- session-linked routing
- more complicated durable state
- more complicated security and collaboration semantics

The correct order remains:

1. browser proves the substrate
2. markdown proves non-browser content, local-only policy, and typed state
3. scratchpad proves collaboration and feedback routing

## feedback routing

The previous plan was right that feedback routing should be app-owned.

That remains true, but it should be introduced only when a concrete panel needs
it.

Near-term rule:

- browser does not need feedback routing
- markdown v1 does not need feedback routing
- scratchpad and richer markdown review flows likely will

This means a formal `LaunchContext` type should be deferred until there is a
real consumer for it.

## sequencing

Recommended order from the current baseline:

### step 1: generalize the existing runtime path

Completed in this worktree:

- keep the shipped browser path working
- make `WebPanelRuntimeRegistry` definition-aware
- add the local-only web profile
- evolve `WebPanelState` toward typed non-browser payload support

### step 2: ship markdown v1

Completed in this worktree:

- add markdown creation flows
- implement markdown runtime and bundled web-app rendering
- add markdown reuse within the current workspace by file path
- validate close, reopen, move, and restore behavior
- package the bundled markdown assets under `WebPanels/markdown-panel/` in the
  app bundle

### step 3: expand markdown only if the first cut proves sound

- optional richer review affordances
- optional app-owned feedback routing for markdown-specific review flows
- decide whether the flat `WebPanelState` shape should be replaced before edit
  or comment mode

### step 4: build scratchpad

- add session-linked behavior
- add richer content updates
- add typed feedback events and routing

### step 5: revisit generic extensibility

- extract built-in lessons into a real manifest/config schema
- decide whether string identifiers and generic payload models are worth the
  cost
- add installed-panel workflows only after browser and markdown have stabilized

## migration and validation

The primary migration risk is existing browser state, not legacy non-terminal
panel kinds.

Requirements:

- existing persisted browser panels must continue to restore
- browser reopen behavior must continue to work
- browser placement and menu behavior must not regress while making the runtime
  registry definition-aware

If `WebPanelState` changes shape:

- add an explicit compatibility path for existing browser payloads, or
- consciously choose a restore reset and document it as a product decision

Do not rely on an accidental hard cutover.

Validation for markdown work should include:

- reducer tests for creation, placement, reuse, close, and reopen
- restore/snapshot tests for persisted markdown state
- runtime tests for bundled asset lookup, live reload, delete/recreate recovery,
  and retargeting behavior
- automation coverage or an equivalent smoke path for opening and rendering a
  markdown file

## open questions

- Is the current flat `WebPanelState` still acceptable for markdown edit/comment
  mode, or should that be the forcing function for typed per-definition payloads?
- What is the right enforcement mechanism for the local-only web profile?
- Does markdown review/comment mode need a richer typed bridge, or does
  scratchpad remain the first real consumer?
- Once two non-browser panels exist, is a generic `instanceKey` field still
  justified, or is computed host-side reuse enough?
