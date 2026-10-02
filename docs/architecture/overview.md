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

## Related docs

- [State Invariants](../state-invariants.md)
- [Socket Protocol](../socket-protocol.md)
- [Ghostty Integration](../ghostty-integration.md)
- [Remote Access WebSocket](remote-access-websocket.md)
