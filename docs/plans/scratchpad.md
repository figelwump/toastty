# toastty scratchpad

Date: 2026-04-24

This document is the v1 implementation plan for Scratchpad. Shared panel/runtime
architecture lives in `docs/plans/web-panels.md`.

## summary

1. Scratchpad is a typed built-in `web` panel definition, not a new renderer-level
   panel kind and not a generic extension/plugin system.
2. V1 is agent initiated and session linked: an agent writes content for its
   current managed session, and Toastty creates or updates one scratchpad for
   that session.
3. V1 uses whole-document replacement through `panel.scratchpad.set-content`.
   Patch, append, streaming, comments, and user-to-agent feedback are deferred.
4. Agent-authored JavaScript is allowed, but only inside a sandboxed generated
   content surface with no direct native bridge access.
5. Scratchpad content persists outside workspace layout snapshots. The layout
   snapshot stores a small typed reference and session-link metadata.
6. Auto-created scratchpads use existing `rootRight` placement in v1 and restore
   focus to the source terminal after creation.

## purpose

Scratchpad is for work that does not fit well in terminal text alone:

- architecture diagrams
- UI mockups
- visual plans
- structured comparison surfaces
- temporary visual artifacts that should stay near the agent session that
  produced them

Scratchpad is not a general browser, not a file viewer, and not a replacement
for normal terminal prose or code snippets.

## current baseline

The current codebase already has the substrate this feature should build on:

- `PanelKind` has `terminal` and `web`.
- `PanelState` has `.terminal` and `.web`.
- `WebPanelDefinition` already includes `scratchpad`.
- `WebPanelDefinition.scratchpad.capabilityProfile` is `localOnly`.
- `WebPanelRuntimeRegistry` already vends typed browser and local-document
  runtimes by panel ID.
- `WorkspaceView` already switches web panel rendering by definition and shows a
  placeholder for unwired definitions.
- Agents launched by Toastty receive `TOASTTY_SESSION_ID`,
  `TOASTTY_PANEL_ID`, `TOASTTY_SOCKET_PATH`, and `TOASTTY_CLI_PATH`.
- The app-control CLI already sends request/response JSON envelopes over the
  local Toastty socket.

This means Scratchpad should be another concrete built-in web panel. Do not
introduce manifest-style panel extensibility, third-party panel loading, or
stringly typed payloads for v1.

## v1 scope

Build:

- typed `ScratchpadState` under `WebPanelState`
- `ScratchpadPanelRuntime`
- `ScratchpadPanelView`
- `ScratchpadPanelHostView`
- bundled `WebPanels/ScratchpadApp/`
- app-control action `panel.scratchpad.set-content`
- session-linked create-or-update behavior
- sandboxed generated HTML/CSS/JS rendering
- persisted scratchpad document storage outside layout snapshots
- unread/updated indication when an unfocused scratchpad changes

Do not build in v1:

- `New Scratchpad Tab`
- standalone scratchpads
- workspace-shared scratchpads
- relink or detach
- user comments or annotations
- scratchpad-to-agent feedback queues
- terminal injection
- MCP server support
- append, patch, or DOM-fragment update APIs
- true `splitBesideSource` placement
- background tab placement
- freeform native drawing tools

## user experience

### primary path: agent initiated

The main experience is that an agent asks Toastty to render visual content while
responding in the terminal.

Expected behavior when an agent calls `panel.scratchpad.set-content` with the
current `TOASTTY_SESSION_ID`:

- Toastty resolves the active session.
- Toastty resolves the session's source terminal panel and workspace.
- If a scratchpad is already linked to that session, Toastty updates it in
  place.
- If no scratchpad is linked to that session, Toastty creates one in the same
  workspace using `rootRight` placement.
- Auto-create does not leave focus in the scratchpad. If creation focuses the
  new panel internally, Toastty restores focus to the source terminal.
- If the scratchpad is not focused when updated, Toastty marks it updated using
  the same quiet unread/updated visual language used for panels that need
  attention.
- The agent should mention the scratchpad only after the app-control action
  succeeds. This is agent guidance, not app policy.

The agent should reuse the same session-linked scratchpad rather than creating a
new one per turn.

### backup entry point

V1 should include one user-facing backup action:

- `Show Scratchpad For Current Session`

Expose this action from the Workspace menu and the command palette. Do not add a
standalone `New Scratchpad` action in v1.

Behavior:

- if a scratchpad is open for the current session, focus it
- if a scratchpad for the current session is recently closed and can be reopened,
  reopen/focus it
- otherwise create an empty scratchpad linked to the current session and focus it

Unlike agent auto-create, explicit user invocation may focus the scratchpad.

Standalone `New Scratchpad Tab` is deferred until standalone scratchpads have a
clear product role.

## placement

Use existing placement primitives in v1.

Default v1 behavior:

- agent-created scratchpad: `rootRight`, then restore focus to the source
  terminal
- user `Show Scratchpad For Current Session`: focus existing/reopened scratchpad
  or create with `rootRight`

If the source session or source terminal panel cannot be resolved for an
agent-initiated `set-content`, fail the command with a clear error. Do not
silently create an orphan scratchpad in v1.

Do not take over another panel's content. Do not silently decline to create the
scratchpad after a successful command. True source-aware placement such as
`splitBesideSource` can be reconsidered after the v1 workflow is proven.

## agent command contract

Agents interact with Scratchpad through the existing app-control channel:

```text
agent process
  -> Toastty CLI
  -> local Toastty socket
  -> AppControlExecutor
  -> Scratchpad document store/runtime
  -> Scratchpad web app
```

V1 action:

```text
panel.scratchpad.set-content
```

Inputs:

- `sessionID`: required for the v1 agent path
- `filePath` or stdin content: required content source
- `title`: optional display title
- `expectedRevision`: optional guard against overwriting newer scratchpad
  content

Behavior:

- resolve the active session by `sessionID`
- create or locate the session-linked scratchpad
- read content from `filePath` or stdin
- enforce payload limits before committing
- serialize mutations per scratchpad document
- if `expectedRevision` is provided and stale, reject the write with a conflict
- assign the next revision in Toastty, not in the agent
- persist the document snapshot
- push the new revision to the running web view if loaded

Response:

- `windowID`
- `workspaceID`
- `panelID`
- `documentID`
- `revision`
- `created`

Agents should prefer `filePath` for non-trivial HTML so shell quoting does not
become part of the protocol.

Do not add `stream-start`, `stream-chunk`, or `stream-finish` in v1. Agents do
not naturally stream tool calls. If a live-feeling sequence is useful, agents
can make repeated `set-content` calls with successive complete snapshots.

## agent guidance

Agent guidance should be supplied through a skill or prompt convention.

Use Scratchpad for:

- architecture diagrams
- UI mockups
- spatial workflows
- visual plans
- comparisons where layout improves comprehension

Do not use Scratchpad for:

- ordinary prose explanations
- bullet lists
- command output
- code snippets
- content that is better opened as a local document

Agents should update the current session's scratchpad in place unless the user
explicitly asks for a separate artifact or the topic clearly changes.

## state model

Scratchpad-specific persisted layout state should be small and typed.

Suggested shape:

```swift
public struct ScratchpadState: Codable, Equatable, Sendable {
    public var documentID: UUID
    public var sessionLink: ScratchpadSessionLink?
    public var revision: Int
}

public struct ScratchpadSessionLink: Codable, Equatable, Sendable {
    public var sessionID: String
    public var agent: AgentKind
    public var sourcePanelID: UUID
    public var sourceWorkspaceID: UUID
    public var repoRoot: String?
    public var cwd: String?
    public var displayTitle: String?
    public var startedAt: Date?
}
```

`WebPanelState.title` remains the panel title used by layout and chrome.
Scratchpad should not introduce a second independently editable title source in
the runtime. If the agent passes a title, update the panel title through the same
app-owned metadata path used by other web panels.

The session link is a historical/provenance snapshot. It should not require the
runtime `SessionRegistry` to still contain the session after app restart.

## document storage

Do not store large HTML content directly in the workspace layout snapshot.

Store Scratchpad documents in a scratchpad-owned store under Toastty's
runtime/config paths. The store should be keyed by `documentID` and persist:

- document ID
- current revision
- title/display metadata
- content type
- HTML/CSS/JS payload or packaged document payload
- creation and update timestamps
- optional session-link snapshot

If a layout restores a scratchpad whose `documentID` is missing from the
document store, show a recoverable missing-document state inside the panel rather
than crashing or silently removing the panel.

Retention can stay simple in v1:

- one linked scratchpad per session
- session end does not delete the scratchpad
- explicit panel close follows normal recently closed panel behavior
- no archive/library UI

Add cleanup and retention policy only when Scratchpad usage creates real
accumulation pressure.

## security model

Scratchpad allows agent-authored JavaScript in v1. Treat it as higher risk than
local-document rendering.

V1 requirements:

- no outbound network by default
- no unrestricted remote asset loading
- no direct native bridge access from generated content
- no generic host command dispatch
- no generic native `eval_js` bridge for agents
- no filesystem access from generated content
- nonpersistent web data store
- explicit payload size limit before content is committed or injected

The Scratchpad web app should have two layers:

1. a trusted bundled shell loaded by Toastty
2. an isolated generated-content surface for agent HTML/CSS/JS

The trusted shell owns the native bridge. Generated content must not have direct
access to `window.webkit.messageHandlers` or any Toastty app-control surface.

Sanitization and sandboxing are not interchangeable:

- if agent JavaScript is allowed, sanitizing away scripts defeats the product
  goal
- generated JavaScript should run only in the isolated content surface
- the isolated content surface should communicate with the trusted shell only
  through a narrow, typed, allowlisted channel if needed

The exact isolation mechanism should be chosen during implementation, but the
boundary is non-negotiable: generated content cannot call native APIs directly.

## bridge model

Use a typed bridge modeled after the local-document bridge, but keep it
scratchpad-specific.

Host-to-shell capabilities:

- bootstrap current document revision
- replace rendered content with a committed revision
- update theme
- update title/display metadata if needed
- report missing-document or load-error states

Shell-to-host events in v1:

- bridge ready
- render ready
- JavaScript diagnostic events from the trusted shell
- generated-content load/render diagnostics if safely available

Do not add shell-to-agent feedback in v1. Scratchpad comments, annotations,
approval buttons, or "send to agent" actions require a separate product pass
covering delivery semantics. Markdown review/commenting may be the better first
consumer for that feedback architecture.

## persistence and lifecycle

Scratchpad panels and document content should persist across app restart.

When the linked agent session ends:

- the scratchpad remains open if its panel is open
- the document remains viewable
- the session link becomes historical metadata
- future writes require a currently active session unless a later relink flow is
  built

When the user closes a scratchpad panel:

- the closed panel enters normal recently closed panel history
- reopening should restore the same `documentID` when possible

When a session-linked scratchpad already exists:

- `panel.scratchpad.set-content` updates it in place, even if the user moved it
  elsewhere in the workspace/window
- lookup is by session link/document binding, not by layout position

## validation plan

Reducer/app-state tests:

- `WebPanelDefinition.scratchpad` remains local-only
- `WebPanelState` encodes/decodes `ScratchpadState`
- creating a scratchpad stores typed scratchpad state
- updating existing session-linked scratchpad reuses the panel
- agent auto-create uses `rootRight`
- agent auto-create restores focus to the source terminal
- stale `expectedRevision` rejects the write
- missing session fails with a clear error

Runtime tests:

- bundled Scratchpad app asset lookup
- bootstrap current document into web view
- push committed revision into an already loaded web view
- restore from persisted document store
- missing document renders a recoverable placeholder
- generated content cannot call native bridge handlers directly
- non-file/network navigation is blocked
- oversized payload is rejected before injection

App-control tests:

- `panel.scratchpad.set-content` accepts `filePath`
- `panel.scratchpad.set-content` accepts stdin or equivalent socket payload
- response includes `windowID`, `workspaceID`, `panelID`, `documentID`,
  `revision`, and `created`
- repeated calls for the same session update in place
- concurrent calls serialize per scratchpad document

Smoke validation:

- launch a managed agent session
- call the CLI to set scratchpad content from a file
- verify a Scratchpad panel appears with focus still in the terminal
- call the CLI again and verify the existing panel updates
- restart the app/runtime and verify the scratchpad document restores

## sequencing

Recommended implementation order:

1. add typed `ScratchpadState` and layout snapshot compatibility tests
2. add scratchpad document store with payload limits and missing-document state
3. add `ScratchpadPanelRuntime` and bundled `ScratchpadApp`
4. wire `WorkspaceView` and `WebPanelRuntimeRegistry`
5. add `panel.scratchpad.set-content` app-control action
6. add session-linked create-or-update behavior and focus restoration
7. add unread/updated indicator behavior
8. add agent skill/prompt guidance for when to use Scratchpad

After v1 is proven, revisit:

- true `splitBesideSource`
- standalone scratchpads
- append or patch APIs
- comments and feedback routing
- Markdown-to-agent review feedback
- MCP wrapper over the existing app-control socket
- broader installed web-panel extensibility
