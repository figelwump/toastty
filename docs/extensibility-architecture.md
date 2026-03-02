# toastty extensibility architecture

Date: 2026-03-02

This document describes the architecture for making Toastty a fully controllable, extensible application — controllable by agents, extensible by users, and capable of serving as a coordination layer between agents and humans.

## goals

1. **Full external control.** Everything the app can do — splits, focus, typing, panel creation, workspace management — is available through a CLI.
2. **WebView extension panels.** Users (and agents) can create custom panel types as HTML/CSS/JS bundles, loaded at runtime without recompiling the app.
3. **Agent feedback loop.** Users can comment on agent-produced content (feed items, markdown annotations), and feedback routes back to the agent — either injected into a running terminal session or by invoking a new agent session.
4. **Extensible CLI.** When an extension is installed, it can register CLI subcommands that route through to the extension.

## architecture overview

```
┌─────────────┐     ┌─────────────┐     ┌──────────────┐
│  toastty CLI │     │ Claude Code │     │ custom script │
│  (socket)    │     │ (socket)    │     │ (socket)      │
└──────┬───────┘     └──────┬──────┘     └──────┬────────┘
       │ JSON                │ JSON               │ JSON
       ▼                    ▼                    ▼
┌──────────────────────────────────────────────────────────┐
│                      Toastty App                         │
│                                                          │
│  ┌───────────────┐  ┌────────────────┐  ┌─────────────┐ │
│  │ Socket Server │  │ Extension Host │  │ Agent        │ │
│  │ (always-on)   │  │ (WebView mgr)  │  │ Invocation   │ │
│  └───────┬───────┘  └───────┬────────┘  └──────┬──────┘ │
│          │                  │                   │        │
│          ▼                  ▼                   ▼        │
│  ┌──────────────────────────────────────────────────┐   │
│  │          AppAction / AppReducer / AppStore        │   │
│  └──────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
```

Three entry points, one dispatch layer. The socket server accepts commands from the CLI, agents, and scripts. The extension host manages WebView panel lifecycles. The agent invocation system spawns agent sessions in response to user feedback. All three funnel into the existing `AppAction`/`AppReducer`.

## 1) CLI

### overview

The `toastty` CLI is a standalone binary that communicates with the running app over the existing Unix domain socket. It handles socket discovery, JSON serialization, and provides a human-friendly command interface.

The CLI is sugar over the socket protocol. Anything the CLI can do, a raw socket client can also do. The CLI exists for ergonomics — tab completion, `--help`, structured output.

### socket discovery

Same resolution order as the existing protocol:

1. `TOASTTY_SOCKET_PATH` if set
2. `$TMPDIR/toastty-$UID/events-v1.sock`
3. `/tmp/toastty-$UID/events-v1.sock`

The CLI connects, sends one JSON request, reads one JSON response, and exits. No persistent connections — the one-shot model is sufficient for CLI use.

### always-on socket

The socket server runs unconditionally, not gated behind `--automation`. Automation-specific commands (`automation.reset`, `automation.load_fixture`, `automation.capture_screenshot`, `automation.dump_state`) remain gated behind `--automation` mode. All other commands are available to any connected client.

This means the existing automation scripts continue to work as before, while the CLI and agents can control the app in normal operation.

### built-in commands

Commands map directly to existing `AppAction` cases and socket protocol commands. The CLI translates human-friendly syntax into socket requests.

**workspace commands:**

```bash
toastty workspace list
toastty workspace new [--title "name"]
toastty workspace select <name-or-id>
toastty workspace rename <name-or-id> "new name"
toastty workspace close <name-or-id>
```

**panel / pane commands:**

```bash
toastty split right|down|left|up
toastty focus previous|next|left|right|up|down
toastty resize left|right|up|down [--amount 5]
toastty equalize

toastty panel close [--panel <id>]
toastty panel reopen
toastty panel focus <id>
toastty panel create terminal [--workspace <id>]
toastty panel create extension <extension-id> [--workspace <id>]

toastty zoom toggle
```

**terminal I/O:**

```bash
toastty send "ls -la" [--panel <id>] [--submit]
toastty read [--panel <id>] [--contains "pattern"]
```

**aux panel toggles:**

```bash
toastty toggle diff|markdown|scratchpad
```

**font:**

```bash
toastty font increase
toastty font decrease
toastty font reset
toastty font set 14
```

**state inspection:**

```bash
toastty status                  # workspace snapshot (pane count, focused panel, etc.)
toastty state [--json]          # full state dump
```

**notifications (existing `toastty notify`):**

```bash
toastty notify "title" "body" [--workspace <id>]
```

**feed (see section 4):**

```bash
toastty feed post "markdown content" [--context session.json]
toastty feed list [--limit 20]
toastty feed inject <content-id> "feedback text"    # simulate user comment
```

### output format

By default, commands print human-readable output. Pass `--json` for structured JSON (the raw socket response). Scripts and agents should use `--json`.

```bash
$ toastty status
Workspace: main (3 panes, focused: terminal-abc)

$ toastty status --json
{"workspaceID":"...","paneCount":3,"focusedPanelID":"...","rootSplitRatio":0.5,...}
```

### CLI extensibility

When the CLI receives an unrecognized top-level command, it checks for installed extensions that declare CLI commands. Extension commands are routed through the socket as `extension.command` requests.

```bash
# built-in command — handled directly
toastty split right

# extension command — routed to extension
toastty ci-status refresh
toastty ci-status get-pipeline --id 123
```

Resolution order for a command like `toastty ci-status refresh`:

1. Is `ci-status` a built-in command group? No.
2. Is `ci-status` an installed extension with declared commands? Check `~/.config/toastty/extensions/ci-status/manifest.json`.
3. If yes, send to socket: `{"command": "extension.command", "payload": {"extensionID": "ci-status", "command": "refresh", "args": {"id": "123"}}}`.
4. The app routes it to the extension's WebView via the JS bridge.
5. The extension processes it and returns a result.

Extensions declare their CLI commands in the manifest (see section 2). The CLI reads manifests from disk to build help text and tab completions — it does not need the app to be running for `--help` to work.

### implementation notes

The CLI should be a lightweight Swift executable in the repo (e.g. `Sources/CLI/`). It links against a shared protocol module for JSON envelope types but has no dependency on the app target or any UI framework.

## 2) WebView extension panels

### overview

Extensions are directories containing a manifest, an HTML entry point, and optional assets. Toastty loads them into `WKWebView` instances and communicates via a JS bridge. Extensions can render arbitrary UI, receive events from the app, and send commands back.

### extension directory layout

```
~/.config/toastty/extensions/
  ci-status/
    manifest.json
    index.html
    panel.js          # optional, or inline in HTML
    styles.css         # optional
    icon.svg           # optional, shown in panel tab and sidebar
  my-feed-viewer/
    manifest.json
    index.html
```

### manifest format

```json
{
  "id": "ci-status",
  "name": "CI Status",
  "version": "1.0.0",
  "description": "Live CI pipeline status dashboard",
  "entryPoint": "index.html",
  "icon": "icon.svg",

  "panel": {
    "defaultTitle": "CI Status",
    "minWidth": 300,
    "minHeight": 200
  },

  "commands": {
    "refresh": {
      "description": "Refresh pipeline status"
    },
    "get-pipeline": {
      "description": "Get details for a specific pipeline",
      "args": {
        "id": { "type": "string", "required": true, "description": "Pipeline ID" }
      }
    }
  },

  "sidebar": {
    "title": "CI",
    "icon": "icon.svg",
    "position": "below-workspaces"
  },

  "permissions": []
}
```

Fields:

- `id`: unique identifier, matches directory name. Used as the CLI subcommand namespace.
- `name`: human-readable display name.
- `version`: semver string.
- `entryPoint`: path to HTML file relative to extension directory.
- `icon`: optional SVG/PNG icon for panel tabs and sidebar.
- `panel`: sizing hints for the panel host.
- `commands`: CLI commands this extension handles (see CLI extensibility above).
- `sidebar`: optional sidebar section registration (see section 5).
- `permissions`: reserved for future permission model. Empty array for now.

### panel lifecycle

1. User (or agent via CLI/socket) creates an extension panel: `toastty panel create extension ci-status`.
2. App adds `PanelState.extension(ExtensionPanelState)` to the workspace.
3. App creates a `WKWebView`, loads `~/.config/toastty/extensions/ci-status/index.html`.
4. App injects the `toastty` JS bridge object before the page loads.
5. The extension renders its UI and communicates via the bridge.
6. On panel close, the WebView is torn down. The extension can persist its own state via the bridge.

Extension panels participate in all standard panel operations: focus, move between panes, move between workspaces, move between windows, detach to new window. The WebView moves with the panel — no teardown/recreate cycle on moves.

### JS bridge API

The app injects a global `toastty` object into every extension WebView.

**Extension -> App:**

```js
// Send a command to the app (returns a promise)
const result = await toastty.command("workspace.split", { direction: "right" });

// Update this panel's title
toastty.setTitle("CI: 3 failing");

// Persist extension state (survives app restart)
toastty.saveState({ selectedPipeline: "main", scrollPos: 120 });

// Read persisted state
const state = await toastty.loadState();

// Post to the feed (see section 4)
toastty.postToFeed({
  content: "## Pipeline failed\n`main` has 3 failing jobs.",
  feedbackEnabled: true
});

// Log (routed to Toastty's structured logging)
toastty.log("info", "Refreshed pipeline data");
```

**App -> Extension:**

```js
// Register event handlers
toastty.on("panel.focused", () => { /* refresh data */ });
toastty.on("panel.unfocused", () => { /* pause polling */ });
toastty.on("panel.resized", ({ width, height }) => { /* adapt layout */ });
toastty.on("command", ({ command, args }) => {
  // Handle CLI commands routed to this extension
  if (command === "refresh") {
    refreshPipelines();
  }
});
toastty.on("message", ({ from, data }) => {
  // Messages from other extensions or the feed
});
```

**Implementation:** `toastty.command()` and `toastty.postToFeed()` use `WKScriptMessageHandler` (extension -> app). Event delivery uses `evaluateJavaScript` (app -> extension). State persistence uses a JSON file at `~/.config/toastty/extensions/<id>/state.json`.

### hot reload

When files in an extension directory change, the app reloads the WebView. During development, this provides a fast iteration loop. Detection is via `DispatchSource.makeFileSystemObjectSource` on the extension directory.

### state model

```swift
struct ExtensionPanelState: Codable {
    let panelID: UUID
    let extensionID: String
    var title: String
    // opaque state blob, persisted/restored by the extension via JS bridge
    var extensionState: Data?
}

// PanelKind gains a new case:
enum PanelKind: String, Codable {
    case terminal
    case diff
    case markdown
    case scratchpad
    case `extension`
}

// PanelState gains a new case:
enum PanelState: Codable {
    case terminal(TerminalPanelState)
    case diff(DiffPanelState)
    case markdown(MarkdownPanelState)
    case scratchpad(ScratchpadPanelState)
    case `extension`(ExtensionPanelState)
}
```

Extension panel state is persisted with the workspace layout. On restore, the app reloads the WebView and calls `toastty.loadState()` to let the extension restore its internal state.

## 3) agent feedback loop

### the problem

An agent posts content (feed item, markdown annotation). The user reads it and wants to respond. The response needs to reach the agent. But agents like Claude Code and Codex are ephemeral — they run, do work, and exit. They don't hold open connections waiting for feedback.

### two cases

**Case 1: Agent is currently running in a terminal pane.**

Toastty injects the feedback as terminal input. The agent sees it as user-typed text and responds normally. The app formats the context and sends it via the existing `terminal_send_text` mechanism.

Example: user comments on a markdown annotation. Toastty identifies which terminal pane the originating agent session is in (via `sessionID` -> `panelID` mapping from `session.start`). Toastty sends:

```
[Feedback from markdown panel: README.md, line 42]
This section is outdated, the API changed last week.
```

The agent receives this as regular user input and responds.

**Case 2: Agent session has ended.**

Toastty invokes a new agent session with the feedback as prompt context. The new session opens in a terminal pane and the agent picks up the conversation.

Agent invocation is configured per agent type:

```toml
# ~/.config/toastty/agents.toml

[claude-code]
invoke = "claude --resume {sessionID} --print '{message}'"
fallback = "claude -p '{message}' --cwd '{cwd}'"

[codex]
invoke = "codex --message '{message}' --cwd '{cwd}'"
```

Template variables available:

- `{sessionID}`: the original agent session ID
- `{message}`: the user's feedback text
- `{cwd}`: working directory from the original session
- `{repoRoot}`: repo root from the original session
- `{contentID}`: ID of the feed item or annotation being commented on

When feedback arrives for a dead session:

1. Look up the session's agent type and context from the feed item metadata.
2. Resolve the invocation template from `agents.toml`.
3. Open a new terminal pane in the same workspace.
4. Run the invocation command in that terminal.
5. The new agent session starts, reads the context, and responds.

### context storage

Every feed item and annotation stores the metadata needed to restart the conversation:

```json
{
  "contentID": "feed-abc-123",
  "sessionID": "sess_xyz",
  "agent": "claude-code",
  "cwd": "/Users/vishal/repos/toastty",
  "repoRoot": "/Users/vishal/repos/toastty",
  "timestamp": "2026-03-02T14:30:00Z",
  "content": "Refactored auth module. 3 files changed.",
  "feedbackEnabled": true
}
```

This metadata is persisted with the feed state. It survives app restarts.

## 4) feed panel

### overview

The feed is a built-in panel type (not an extension) that serves as a shared communication channel between agents and users. Agents post content, users read and comment, comments route back to agents.

The feed is global — all connected agents can post to it, and all posts are visible to everyone. This makes it a natural coordination layer: one agent posts a summary, another sees it and responds if relevant, the user watches and intervenes when needed.

### feed item model

```swift
struct FeedItem: Codable, Identifiable {
    let id: UUID
    let sessionID: String?
    let agent: String?
    let timestamp: Date
    let content: FeedContent
    let feedbackEnabled: Bool
    var comments: [FeedComment]

    // context for agent invocation on feedback
    var agentContext: AgentInvocationContext?
}

struct FeedContent: Codable {
    let type: FeedContentType  // .markdown, .text, .status
    let body: String
}

struct FeedComment: Codable, Identifiable {
    let id: UUID
    let author: FeedCommentAuthor  // .user or .agent(sessionID)
    let timestamp: Date
    let body: String
}

struct AgentInvocationContext: Codable {
    let agent: String
    let sessionID: String
    let cwd: String?
    let repoRoot: String?
}
```

### posting to the feed

Via CLI:

```bash
toastty feed post "## Refactored auth\n3 files changed." --agent claude-code --session sess_xyz
```

Via socket:

```json
{
  "command": "feed.post",
  "payload": {
    "content": { "type": "markdown", "body": "## Refactored auth\n3 files changed." },
    "feedbackEnabled": true,
    "agentContext": {
      "agent": "claude-code",
      "sessionID": "sess_xyz",
      "cwd": "/Users/vishal/repos/toastty"
    }
  }
}
```

Via extension JS bridge:

```js
toastty.postToFeed({
  content: "## Pipeline failed\n`main` has 3 failing jobs.",
  feedbackEnabled: true
});
```

### user commenting

The feed panel renders an inline comment input on each feedback-enabled item. When the user submits a comment:

1. The comment is appended to `FeedItem.comments`.
2. If the originating agent's terminal session is still running (session is in `SessionRegistry`), inject the comment as terminal input (case 1 from section 3).
3. If the session has ended, invoke a new agent session with the comment as context (case 2 from section 3).

### feed as coordination layer

Because the feed is visible to all connected agents, it can serve as a broadcast channel:

- Agent A posts: "Refactored auth module, 3 files changed"
- Agent B (monitoring the feed via socket events) sees it: "I depend on auth — re-running my tests"
- User comments: "Hold off on deploying until B confirms"
- Both agents see the user's comment

For agents that want to monitor the feed programmatically, the socket protocol adds a `feed.new_item` event type that is sent to all connected clients when a new item is posted.

## 5) sidebar extensibility

Extensions can register sidebar sections via the `sidebar` field in their manifest. The sidebar stays native SwiftUI — extensions contribute data, not views.

A sidebar section declared by an extension shows:

- An icon and title
- A list of items (provided by the extension via the JS bridge)
- Click actions that route to the extension

```json
{
  "sidebar": {
    "title": "CI",
    "icon": "icon.svg",
    "position": "below-workspaces"
  }
}
```

The extension provides sidebar content via the bridge:

```js
toastty.setSidebarItems([
  { id: "pipeline-main", label: "main", subtitle: "3 failing", status: "error" },
  { id: "pipeline-dev", label: "dev", subtitle: "passing", status: "ok" }
]);
```

Clicking a sidebar item sends an event to the extension: `toastty.on("sidebar.itemClicked", ({ itemId }) => { ... })`.

The sidebar renders built-in sections first (workspaces), then extension-contributed sections in manifest-declared order.

## 6) phased implementation

### phase 1: always-on socket + CLI

**Goal:** The full current automation surface area is available via CLI in normal (non-automation) operation.

- Remove automation gate for non-destructive commands (splits, focus, font, terminal I/O, state inspection, notifications).
- Keep `automation.reset`, `automation.load_fixture`, `automation.capture_screenshot`, `automation.dump_state` gated behind `--automation`.
- Build `toastty` CLI binary (`Sources/CLI/`) that wraps socket communication.
- Implement command groups: `workspace`, `split`, `focus`, `resize`, `equalize`, `panel`, `send`, `read`, `toggle`, `font`, `status`, `notify`.
- JSON output mode (`--json`) for programmatic use.
- Socket discovery, error handling, timeout.

### phase 2: extension panel system

**Goal:** A user can create a WebView panel extension and open it in Toastty.

- Add `PanelKind.extension` and `ExtensionPanelState`.
- Build extension host: `WKWebView` management, JS bridge injection, lifecycle.
- Manifest parsing from `~/.config/toastty/extensions/*/manifest.json`.
- Extension panel creation via CLI and socket (`panel.create.extension`).
- Extension state persistence (`saveState`/`loadState`).
- Hot reload on file changes.
- Extension panel participates in all panel mobility operations.
- CLI extensibility: unrecognized commands route to extensions.

### phase 3: feed panel + agent feedback

**Goal:** Agents can post to a feed, users can comment, comments route back to agents.

- Add `PanelKind.feed` (built-in, not an extension — needs deep app integration).
- Feed data model: `FeedItem`, `FeedComment`, `AgentInvocationContext`.
- Socket commands: `feed.post`, `feed.list`, `feed.comment`.
- CLI commands: `toastty feed post`, `toastty feed list`, `toastty feed inject`.
- Terminal injection for running-agent feedback (case 1).
- Agent invocation for exited-agent feedback (case 2): `agents.toml` config, template resolution, terminal pane creation.
- Feed UI: feed panel with markdown rendering, inline comment input.

### phase 4: sidebar extensibility + polish

**Goal:** Extensions can contribute sidebar sections. Extension development workflow is smooth.

- Data-driven sidebar with built-in + extension-contributed sections.
- `setSidebarItems` JS bridge API.
- Sidebar click routing to extensions.
- Extension scaffolding command: `toastty extension create <name>` generates manifest + boilerplate HTML.
- Extension listing: `toastty extension list`, `toastty extension info <id>`.
- Documentation and examples for extension authors.

## 7) open questions and future considerations

### permissions model

Trust-by-installation for now. All installed extensions have full access to the JS bridge API. A future permissions model could restrict capabilities per extension (e.g., "this extension cannot read terminal output" or "this extension cannot post to the feed"). The `permissions` field in the manifest is reserved for this.

### native Swift extensions

WebView panels cover the common case, but some extensions may need native performance or deep platform access. A `Bundle`-based native extension system (load compiled `.bundle` at runtime, instantiate a `PanelExtensionProvider` protocol conformance) is architecturally feasible but deferred. It introduces ABI coupling, architecture-specific builds, and crash isolation concerns that are worth solving only when a concrete use case demands it.

### MCP

MCP could be added as an alternative interface to the same dispatch layer. The socket server and CLI cover the practical needs for current agents (Claude Code, Codex). If MCP becomes the standard way agents discover and use tools, adding an MCP server that exposes the same commands as MCP tools would be straightforward — it's a protocol adapter over the existing `AppAction` dispatch, not a new architecture.

### extension-authored extensions

An agent running in a terminal pane can create an extension at runtime: write files to `~/.config/toastty/extensions/<name>/`, then `toastty panel create extension <name>`. The hot-reload system picks up the new extension automatically. No special "self-modification" mechanism needed — the file system and the CLI are the interface.

### cross-extension communication

Extensions may want to communicate with each other. The feed serves as a broadcast channel. For direct messaging, a `toastty.sendMessage(extensionID, data)` bridge API could allow point-to-point communication. Deferred until there's a concrete need.
