# Local MCP adapter end-to-end evidence

Run on 2026-10-03 with `scripts/remote/validate.sh --require-remote --scope working-tree --run-label mcp-adapter-e2e-final-head --validation-command 'python3 scripts/automation/mcp-adapter-e2e.py'`.

The remote wrapper reported `executionTarget: remote` and `status: pass` (21:15:30–21:16:11 UTC). The fixture launched a second Toastty app with a separate runtime home and socket, a fake Claude executable, and the actual Node stdio MCP adapter. Its Python JSON-RPC client called the adapter, which called the isolated app's Unix socket; the app launched the fake provider in a PTY and projected its transcript. The fixture did not request HTTP Remote Access gateway enablement, but did not independently measure listener state. No production conversation or real provider account was used.

Sanitized tool trace from `artifacts/remote-gui/mcp-adapter-e2e-final-head/remote/artifacts/mcp-e2e.json`:

```json
{
  "status": "passed",
  "mcp": {
    "protocol": "2025-03-26",
    "transport": "JSON-RPC stdio to Unix socket",
    "toolNames": [
      "toastty_list_sessions", "toastty_read_progress",
      "toastty_send_message", "toastty_start_session",
      "toastty_request_skill", "toastty_request_merge"
    ]
  },
  "gatewayEnablementRequested": false,
  "controlSequenceRejected": true,
  "offlineSocketRejected": true,
  "wrongConversationRejected": true,
  "start": {
    "status": "delivered_to_terminal",
    "agentReceivedFirstPrompt": true,
    "duplicateReturnedSame": true
  },
  "read": { "assistantSeen": true, "eventCount": 8 },
  "send": {
    "status": "accepted",
    "repeated": "duplicate",
    "transcriptConfirmed": true,
    "eventCount": 12
  },
  "skill": { "status": "accepted", "transcriptConfirmed": true },
  "merge": { "status": "accepted", "transcriptConfirmed": true }
}
```

The skill and merge tools sent text to the owning fixture agent. The merge tool's implementation does not call GitHub. This test verifies delivery and transcript confirmation, not that a real agent acted on those requests. Start idempotency is currently in memory for the adapter process lifetime. A separate local Node test passed two regressions: split UTF-8 response framing and a `null` JSON-RPC request followed by a successful ping.
