# toastty web panels

Date: 2026-04-02

This is the current spec for browser integration and extensible panels in Toastty. It supersedes older exploratory panel-architecture ideas in `extensibility-architecture.md` and `scratchpad.md` wherever they conflict.

## summary

1. Toastty should have two renderer-level panel kinds: `terminal` and `web`.
2. Browser, markdown, scratchpad, and future extensible panels should all use the same `web` panel substrate.
3. The auxiliary-panel paradigm should be removed entirely. There is no permanent right-column panel class.
4. The command palette should be for panel creation actions, not panel navigation.
5. Default placement should be predictable and low-disruption:
   - explicit placement override wins
   - user config override for a definition wins next
   - definition default placement wins next
   - platform fallback is a new tab in the current workspace
6. Panel reuse should be internal behavior based on a resolved `instanceKey`, not a separate global `Open` vs `New` UX concept.
7. Launch data should distinguish between:
   - `creationArguments`: what content/resource the panel should open
   - `launchContext`: where the launch came from and what agent/session/repo context was active
8. Feedback routing is an app concern, not an extension concern.
9. V1 should harden built-in web panels first. Generic third-party manifest features should be extracted from real built-in needs afterward.

## goals

- Add a browser panel without painting the app into a corner.
- Support future built-in web panels such as markdown review and scratchpad.
- Support installable web-panel definitions later without introducing a second runtime path.
- Keep terminal creation and terminal-first workflows fast.
- Preserve existing panel mobility expectations:
  - move between splits
  - move between tabs/workspaces/windows
  - persist and restore cleanly
- Keep agent-to-panel and panel-to-agent communication as an app-owned capability.

## non-goals

- Designing a package registry or marketplace in v1.
- Finalizing a broad public extension manifest schema in v1.
- Giving arbitrary installed panels a generic unrestricted command bridge in v1.
- Requiring every split action to show a panel-type picker.

## panel model

Toastty should converge on one content-panel substrate.

```swift
enum PanelKind: String, Codable, CaseIterable, Hashable, Sendable {
    case terminal
    case web
}

enum PanelState: Equatable, Sendable {
    case terminal(TerminalPanelState)
    case web(WebPanelState)
}

struct WebPanelState: Codable, Equatable, Sendable {
    let panelID: UUID
    var definitionID: String
    var instanceKey: String?
    var title: String
    var creationArguments: [String: JSONValue]
    var persistedState: Data?
    var launchContext: LaunchContext?
}

struct LaunchContext: Codable, Equatable, Sendable {
    var sourcePanelID: UUID?
    var sessionID: String?
    var cwd: String?
    var repoRoot: String?
}
```

`definitionID` identifies the panel definition:

- built-in examples:
  - `toastty.browser`
  - `toastty.markdown`
  - `toastty.scratchpad`
  - `toastty.diff`
- installed examples:
  - `ext.ci-status`
  - `ext.notes`

`instanceKey` is an optional dedupe key resolved at launch time:

- markdown file: `file:/abs/path/README.md`
- scratchpad for a session: `session:<session-id>`
- diff for a repo: `repo:/abs/path/to/repo`
- browser: `nil`

If `instanceKey` is present and the definition allows keyed reuse, Toastty may focus an existing matching instance instead of creating a duplicate. This is internal launch behavior, not a separate user-facing mode.

## remove auxiliary panels

The current auxiliary-panel behavior should be deleted as a product concept.

What goes away:

- dedicated right-column insertion logic
- aux visibility state
- aux toggle semantics for markdown, scratchpad, and diff
- the assumption that some panels are second-class layout citizens

What remains valid:

- creation-time placement heuristics can still choose a right-side split when appropriate
- a right rail can still exist later as launcher/library/inspector chrome

The right rail, if it exists, is UI chrome. It is not where web panels permanently live.

## built-in definitions

Built-in panels should use the same host/runtime path as installed panels. The difference is trust level and shipping source, not runtime architecture.

### browser

- `definitionID`: `toastty.browser`
- default placement: `newTab`
- default `instanceKey`: none
- primary creation arguments:
  - `url`
- common actions:
  - `New Browser Tab`
  - `New Browser Beside Current`

### markdown

- `definitionID`: `toastty.markdown`
- default placement: `newTab`
- default `instanceKey`: file path when opening a specific file
- primary creation arguments:
  - `filePath`
  - optional inline or agent-provided content in future
- common actions:
  - `Open Markdown File...`
  - `Open Markdown Beside Current`

### scratchpad

- `definitionID`: `toastty.scratchpad`
- default placement:
  - `splitBesideSource` when launched with a source terminal/session
  - otherwise `newTab`
- default `instanceKey`: session ID when session-linked
- primary creation arguments:
  - none required for the empty state
  - optional mode/settings later
- common actions:
  - `Show Scratchpad For Current Session`
  - `New Scratchpad Tab`

### diff

- `definitionID`: `toastty.diff`
- default placement: `newTab`
- default `instanceKey`: repo root
- primary creation arguments:
  - repository binding, if not inferable from launch context

## placement model

Placement should be resolved by precedence:

1. explicit invocation override
2. user config override for the target definition
3. definition default placement
4. platform fallback: foreground new tab in the current workspace

Examples of explicit overrides:

- command palette action variant such as `New Browser Beside Current`
- menu command variant
- socket/CLI request with a placement field
- agent-initiated creation that specifies `background: true`

### default placements

The platform should support a small placement vocabulary:

- `newTab`
- `backgroundNewTab`
- `splitRight`
- `splitDown`
- `splitBesideSource`

`splitBesideSource` means:

- if `launchContext.sourcePanelID` resolves to a visible panel, split beside that panel
- otherwise fall back through the normal placement precedence

The fallback default is intentionally `newTab` because it is predictable and does not mutate the user's current split layout unless they or the invoking agent explicitly ask for that.

## creation ux

The command palette should expose concrete creation actions, not a generic panel-type chooser that leaves placement unresolved.

Examples:

- `New Browser Tab`
- `New Browser Beside Current`
- `Open Markdown File...`
- `Open Markdown Beside Current`
- `Show Scratchpad For Current Session`

Rules:

- The command palette is for creation.
- Panel navigation remains the job of normal tab/panel navigation, keyboard shortcuts, and pointer interactions.
- Split shortcuts should continue to serve the terminal fast path. They should not require a mandatory type picker.
- Built-ins may also expose direct shortcuts if they prove useful, but they should map to the same placement rules as palette and socket creation.

### definition-specific follow-up ui

Some panel definitions need additional input at creation time.

Examples:

- browser needs a URL or can open empty
- markdown usually needs a file path
- scratchpad may want a source session

In v1, built-in definitions should own these follow-up flows directly instead of forcing a generic manifest-driven UI schema too early.

Examples:

- browser can show an optional URL field or open a blank/start page
- markdown can show:
  - file picker
  - recent files
  - files derived from current launch context
- scratchpad can show:
  - current session-linked option when available
  - empty scratchpad option otherwise

Third-party manifest extraction should happen after built-in create flows stabilize.

## launch context

`LaunchContext` is app-owned metadata captured at creation time.

It exists to answer:

- what panel or session launched this panel
- what repo/cwd/session was active
- where feedback should route when the panel is agent-linked

It does not replace `creationArguments`.

Examples:

- markdown plan review:
  - `creationArguments["filePath"] = "/Users/vishal/GiantThings/repos/toastty/docs/plans/foo.md"`
  - `launchContext.sessionID = "<agent-session>"`
  - `launchContext.repoRoot = "/Users/vishal/GiantThings/repos/toastty"`
- browser:
  - `creationArguments["url"] = "https://example.com"`
  - `launchContext` may be empty

### v1 launch-context resolution

For v1, keep the resolution chain simple:

1. explicit invocation data
2. focused terminal context
3. none

If there is no resolved launch context, the panel should still be creatable. The definition handles the empty state.

## keyed instance reuse

Keyed reuse is definition-driven internal behavior.

Rules:

- if launch resolves no `instanceKey`, create a new panel instance
- if launch resolves an `instanceKey`, the host may search for an existing matching instance
- matching requires:
  - same `definitionID`
  - same `instanceKey`

V1 reuse scope:

- current workspace

If a matching keyed instance is found in another tab of the current workspace, Toastty may focus that tab instead of creating a duplicate. This is acceptable even though the command palette is primarily for creation, because the user intent is still "show me this exact keyed resource."

The host should not dedupe browser panels by URL in v1.

## configuration and definition overrides

Panel definitions should declare defaults. User config should be able to override a definition's defaults without requiring code changes.

Defaults worth exposing:

- default placement
- default foreground/background behavior
- whether keyed instances should reuse existing matches when possible

The exact storage format can be decided later. The important part is the precedence model:

- invocation override
- user override
- definition default
- platform fallback

## runtime architecture

Toastty should have one app-owned web-panel runtime path.

Required native pieces:

- `WebPanelRuntime` that owns `WKWebView` lifecycle for a panel instance
- `WebPanelRuntimeRegistry` or equivalent host that keeps runtimes stable across view remounts and panel moves
- shared `WKProcessPool` strategy
- app-owned `WKWebViewConfiguration` selection by capability tier
- JS bridge implementation

Rules:

- runtime ownership stays native and explicit
- `WebPanelState` remains serializable and resource-free
- panel moves must preserve `panelID`
- runtime reattachment must be deterministic after moves, restores, and tab switches

## bridge and capabilities

The bridge should be minimal, typed, and capability-gated.

V1 principles:

- no generic unrestricted `toastty.command(...)`
- no unrestricted `eval_js`
- extension/panel code should not own agent routing logic
- app routes feedback using launch context and session data

V1 bridge surface should focus on:

- bootstrap payload delivery
- title updates
- state persistence
- typed feedback submission

Future capabilities can include:

- outbound network
- file read
- file write
- session read
- session write

Built-ins can ship with trusted capabilities. Installed panels should be designed so capabilities can be approved explicitly later.

## feedback routing

Feedback routing is an app-level concern.

The panel only needs to emit a typed feedback event such as:

- comment submitted
- annotation submitted
- button action requested

Toastty then decides how to route it:

- inject into a running linked session when possible
- otherwise invoke a new or resumed agent session using stored context

This keeps panel definitions simple and keeps the agent-feedback system reusable across markdown, scratchpad, and future panels.

## sequencing

Recommended order:

### phase 1: substrate

- add `PanelState.web(WebPanelState)`
- remove aux-panel machinery
- create stable `WKWebView` host/runtime
- prove mobility, focus, persistence, and restore with a minimal browser panel

### phase 2: creation and placement

- implement definition registry for built-ins
- implement placement precedence and user overrides
- implement concrete creation flows for browser, markdown, and scratchpad
- add `creationArguments` and `launchContext`

### phase 3: bridge and feedback

- add minimal typed bridge
- add agent-linked markdown review flow
- add app-level feedback routing
- add session-linked scratchpad flow

### phase 4: installed panels

- support installed definitions under the same runtime path
- extract shared built-in creation/config concepts into a real manifest/config schema
- add development and hot-reload workflow only after the core lifecycle is stable

## migration

When this work starts, Toastty should migrate from:

- `terminal`
- `diff`
- `markdown`
- `scratchpad`

to:

- `terminal`
- `web`

Old non-terminal persisted states should be migrated into `WebPanelState` with built-in `definitionID` values.

## open questions

These are still real product questions, but they should not block the core substrate work:

- How much native chrome should browser own versus what lives inside the page?
- Should browser creation default to a blank page, home page, or recent page?
- How should installed panels advertise shortcuts, if at all?
- What exact user-facing config surface should override placement defaults?
- When a keyed instance already exists, should Toastty always focus it or allow per-definition override for duplicate creation?
