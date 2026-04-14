# toastty scratchpad

Date: 2026-04-02

This document is scratchpad-specific product guidance. Shared panel/runtime architecture lives in `docs/plans/web-panels.md`.

## summary

1. Scratchpad is a `web` panel definition, not its own renderer-level panel kind.
2. Scratchpad exists to support agent-human collaboration around visual or structured intermediate work.
3. The primary scratchpad mode is session-linked: one scratchpad instance is associated with one agent session or source terminal context.
4. Scratchpad should default to opening beside its source terminal/session when that context exists.
5. Scratchpad should be safe by default:
   - no outbound network
   - no generic JS eval surface
   - feedback routing handled by the app
6. Scratchpad should support both agent-authored and user-authored updates.

## purpose

Scratchpad is for work that does not fit well in terminal text alone:

- visual plans
- HTML/CSS mockups
- structured review surfaces
- canvases that an agent can populate and a user can comment on
- temporary collaborative artifacts that stay close to the terminal session that produced them

Scratchpad is not a general browser and is not primarily a file viewer.

## primary mode: session-linked scratchpad

The main scratchpad experience should be tied to a session or source terminal context.

Expected behavior:

- user or agent invokes `Show Scratchpad For Current Session`
- Toastty resolves the current source terminal/session
- if a scratchpad keyed to that session already exists, Toastty focuses it
- otherwise Toastty creates a new scratchpad beside the source terminal

Suggested keying:

- `instanceKey = session:<session-id>` when session-linked
- if there is no session ID but a source terminal exists, a fallback source-panel key may be acceptable in development, but session ID is preferred

This model makes scratchpad feel like a companion workspace for an active agent, not an orphaned document.

## secondary mode: standalone scratchpad

Scratchpad should also support an empty standalone mode for cases where there is no live session link.

Examples:

- user wants a temporary whiteboard-like area
- agent creates a scratchpad before session telemetry is available
- user wants to sketch or collect notes without tying them to one agent run

In standalone mode:

- default placement should be `newTab`
- `instanceKey` can be `nil`
- the UI should make it clear that the panel is not currently linked to a live session

## user experience

### entry points

Common actions:

- `Show Scratchpad For Current Session`
- `New Scratchpad Tab`

Possible later actions:

- `Relink Scratchpad To Current Session`
- `Detach Scratchpad From Session`

### placement

Placement should follow the shared precedence rules from `web-panels.md`, with scratchpad-specific defaults:

- if launched for a source session or source panel, default to `splitBesideSource`
- otherwise default to `newTab`

### panel chrome

Scratchpad-specific controls may include:

- linked-session indicator
- relink/detach control
- clear/reset action
- edit/view mode if that distinction proves useful

Do not assume all scratchpad interaction happens through native panel chrome. The primary interaction surface should live inside the scratchpad content itself.

## collaboration model

Scratchpad should support three collaboration patterns.

### 1. agent writes, user reads

The agent pushes HTML or structured content into the scratchpad. The user reviews it.

Examples:

- plan mockup
- generated diagram
- structured review sheet

### 2. agent writes, user responds

The user comments, annotates, or otherwise responds inside the scratchpad. Toastty routes that feedback back to the linked session when possible.

Examples:

- comment on a plan
- mark up a visual draft
- approve/reject a proposed direction

### 3. user edits, agent observes later

The user changes the scratchpad state, then the agent reads the updated state or a snapshot on a later turn.

Examples:

- tweak a layout
- add notes to a draft
- sketch a structure for the agent to continue from

## state model

Scratchpad-specific meaning should live on top of shared `WebPanelState`.

Suggested `creationArguments` and persisted state patterns:

- no required `creationArguments` for standalone mode
- optional `creationArguments["mode"] = "session"` for explicit session-linked launch
- optional `creationArguments["template"]` later if scratchpad supports starter templates

Scratchpad content should be stored as scratchpad-owned state, not inferred from panel title or launch context.

Useful scratchpad state concepts:

- current document/content payload
- annotation/comment data
- viewport state if needed
- tool mode if scratchpad grows richer editing affordances

`launchContext` should be used for routing and provenance, not as the durable content store.

## persistence

Initial persistence direction:

- session-linked scratchpad should persist across app restart
- the link to the source session should persist even if the session is no longer running
- the content should still be viewable after the source session ends

When a linked session is no longer active:

- scratchpad becomes a historical artifact with stale-link UI
- new feedback should either:
  - relaunch/resume an agent using stored context, or
  - be stored until the user explicitly sends it

Do not make scratchpad purely ephemeral by default. The work is often exactly the kind of artifact a user will want to revisit.

## security model

Scratchpad is the highest-risk built-in web panel because it is explicitly designed for generated content and user interaction.

V1 security requirements:

- no outbound network by default
- no unrestricted remote asset loading
- no generic `eval_js` bridge
- no direct extension-owned control over agent routing
- typed feedback events only

If local development bridging is needed, it should be a separate explicit mode with loopback-only restrictions and should not be the default stable behavior.

## bridge needs

Scratchpad likely needs more than a simple viewer but should still stay within a minimal typed bridge.

Reasonable scratchpad bridge capabilities:

- bootstrap initial scratchpad payload
- update title
- persist/load structured state
- submit feedback/annotation events
- request a host-generated snapshot or export later, if needed

Deferred until proven necessary:

- arbitrary host command dispatch
- generic script execution
- unrestricted filesystem access

## unresolved product questions

- What is the first concrete scratchpad use case worth shipping?
- Does scratchpad need freeform drawing in v1, or is HTML/CSS/structured interaction enough?
- Should comments/annotations be embedded into the scratchpad document model or stored as separate app-owned metadata?
- How should undo/redo work if both user edits and agent updates are possible?
- When a linked session is closed, should the scratchpad remain linked to the historical session, or should the user be prompted to relink it?
- Should one terminal session ever have multiple scratchpads, or should keyed reuse stay strict for the session-linked mode?

## sequencing

Scratchpad should not be the first web panel shipped.

Recommended order:

1. prove the shared web-panel host/runtime with browser
2. refactor file-backed markdown into a broader `localDocument` built-in panel
   that is ready for upcoming editing work
3. prove creation arguments, launch context, and feedback routing with
   local-document review/edit flows if they arrive before scratchpad
4. build scratchpad once the collaboration and bridge model are already working

That sequencing keeps scratchpad focused on the genuinely unique product problems instead of forcing it to carry all substrate risk too early.
