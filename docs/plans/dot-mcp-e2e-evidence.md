# Local MCP adapter end-to-end evidence

Run on 2026-10-03 with `scripts/remote/validate.sh --require-remote --scope working-tree --run-label mcp-adapter-e2e-all-tools --validation-command 'python3 scripts/automation/mcp-adapter-e2e.py'`.

The remote wrapper reported `executionTarget: remote` and `status: pass` (21:06:36–21:07:17 UTC). The fixture launched a second Toastty app with a separate runtime home and socket, a fake Claude executable, and the actual Node stdio MCP adapter. The HTTP Remote Access gateway remained disabled. No production conversation or provider account was used.

Sanitized tool trace from `artifacts/remote-gui/mcp-adapter-e2e-all-tools/remote/artifacts/mcp-e2e.json`:

```json
{
  "status": "passed",
  "mcp": { "protocol": "2025-03-26", "toolCount": 6 },
  "gatewayEnabled": false,
  "controlSequenceRejected": true,
  "start": {
    "status": "delivered_to_terminal",
    "agentReceivedFirstPrompt": true,
    "duplicateReturnedSame": true
  },
  "read": { "assistantSeen": true, "eventCount": 7 },
  "send": {
    "status": "accepted",
    "repeated": "duplicate",
    "transcriptConfirmed": true,
    "eventCount": 12
  },
  "skill": { "status": "accepted", "transcriptConfirmed": true },
  "merge": {
    "status": "accepted",
    "transcriptConfirmed": true,
    "githubMergeInvoked": false
  }
}
```

The skill and merge tools sent text to the owning fixture agent. The merge tool did not call GitHub. This test verifies delivery and transcript confirmation, not that a real agent acted on those requests. Start idempotency is currently in memory for the adapter process lifetime.
