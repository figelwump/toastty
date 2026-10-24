# Architecture Overview

This page is a short map of Toastty's macOS source tree and how app state flows through it. The other documents in `docs/architecture/` cover individual subsystems, such as Remote Access and the iOS client, in more depth.

## Source layout

```
Sources/
├── Core/          # CoreState framework: pure Swift state management (no UI dependencies)
│   ├── AppState, AppReducer, AppAction    # Redux-like state machine
│   ├── WorkspaceSplitTree, LayoutNode     # Binary tree layout engine
│   ├── Sessions/                          # Managed agent session records and registry
│   └── Diagnostics/                       # JSON logging and diagnostics reports
├── App/           # SwiftUI application layer (ToasttyApp target)
│   ├── AppStore                           # Single store that runs AppReducer
│   ├── Terminal/   # Ghostty surface hosting, runtime management
│   ├── Commands/   # Menu and keyboard shortcut routing
│   ├── Automation/ # Unix socket server
│   └── Preferences/
├── CLI/, CLIKit/  # Bundled `toastty` command-line tool and its command implementations
├── AgentShim/     # toastty-agent-shim, the PATH wrapper for typed agent commands
├── CodexReconciliation/  # Codex hook, notify, and rollout status reconciliation
└── RemoteProtocol/       # Remote Access protocol models, shared with the iOS client
```

The `CoreState` framework contains all business logic and state transitions, with no UI dependencies. The `App` layer handles SwiftUI views, Ghostty surface hosting, and system integration.

State flows through a single `AppStore` using a reducer pattern: views dispatch `AppAction`, the `AppReducer` produces new `AppState`, and SwiftUI re-renders.

## Conversation state and input

`Sources/App/RemoteAccess/ConversationService.swift` owns one conversation
projection, transcript tracker, input gate, and send queue on the main actor.
Native conversation surfaces and Remote Access use this same service. The
application creates one instance and injects it into `RemoteAccessService`, or
uses that facade's exposed `conversationService`. Views must not create another
engine. `RemoteAccessService` owns the gateway, pairing, device permissions,
remote write settings, previews, and push delivery.

Local surfaces register their panel IDs with `setLocalPanelIDs`. The application
supplies the union across windows. Remote Access requests all supported panels
while its listener is enabled. Turning remote access off or losing the listener
does not stop local conversations. Closing a local surface stops new local input
for that panel, but accepted local queued messages keep tracking until they
finish or are cancelled. Pending delivery confirmations from either surface
also keep tracking until they settle. Disabling remote access cancels queued
remote messages. Queue delivery still checks
the exact runtime binding and current prompt. Stop pauses the queue as before.

Local subscribers use `changes()` as a coalesced invalidation signal, then read
snapshots and cursor-based event pages. Each subscriber gets its own stream,
which survives tracking restarts. Remote event pages and resnapshot messages
use a synchronous callback to preserve their order. Local and remote requests
share duplicate detection and input epochs. Only actual terminal typing sets a
terminal draft lock; editing a separate native composer does not. Attachment
staging can suspend, so the service checks caller permission and input state
again before it delivers the message.

## Related docs

- [State Invariants](../state-invariants.md)
- [Socket Protocol](../socket-protocol.md)
- [Ghostty Integration](../ghostty-integration.md)
- [Remote Access WebSocket](remote-access-websocket.md)
