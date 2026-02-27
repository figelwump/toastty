# toastty scratchpad canvas (V2)

Date: 2026-02-26

This document captures the V2 scratchpad canvas design. It is intentionally separated from the main implementation plan because scratchpad is out of V1 scope and the design will likely evolve significantly before implementation begins. Revisit and pressure-test this spec before starting V2 work.

## goal

- interactive HTML/CSS/JS canvas for agent-human communication
- machine-readable + machine-writable

## initial API

- `canvas.set_html(panelID, html)`
- `canvas.get_html(panelID)`
- `canvas.eval_js(panelID, script)`
- `canvas.snapshot(panelID)`

## behavior

- follows focused terminal — each terminal session can have associated scratchpad content
- Edit/Preview toggle in panel header
- default no outbound network from scratchpad runtime
- if local dev-server bridging is needed, only allow loopback (`127.0.0.1` / `localhost`) and block remote hosts

## state

```swift
struct ScratchpadPanelState: Codable {
    let panelID: UUID
    var sourcePanelID: UUID?
    var activeSessionID: String?
    var contentBySessionID: [String: String] // sessionID -> html string
}
```

## implementation path

- build panel host in toastty
- keep canvas runtime as separable package boundary so it can move to dedicated repo later
- run a dedicated scratchpad threat-model review before enabling `canvas.eval_js` in stable builds

## security considerations

- `canvas.eval_js` must be gated by explicit security review before production enablement
- sandboxed webview with no external network access by default
- loopback-only if local dev-server bridging is needed
- review attack surface for cross-origin and data exfiltration before V2 ships

## open questions

- Should scratchpad content persist across sessions or be ephemeral?
- How does scratchpad interact with undo/redo?
- Should there be a shared scratchpad mode (not session-scoped)?
- What happens to scratchpad content when the source terminal/session is closed?
