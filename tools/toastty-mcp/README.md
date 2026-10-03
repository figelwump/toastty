# Toastty local MCP adapter

This stdio MCP server gives an assistant a small, portable set of Toastty tools:
list sessions, read bounded conversation events, send a message to an exact open
prompt, start a managed agent in a new background tab, ask an agent to use a
skill, and ask an agent to prepare a merge handoff. Merge requests send text to
the owning session; they never call GitHub merge.

Run the adapter on the **same Mac and user account** as Toastty. Set
`TOASTTY_SOCKET_PATH` to the `socketPath` in that instance's `instance.json`,
then configure an MCP client to execute:

```text
node /path/to/toastty/tools/toastty-mcp/server.mjs
```

For a private MCP client or tunnel that launches stdio servers, the equivalent
server entry is:

```json
{
  "command": "node",
  "args": ["/path/to/toastty/tools/toastty-mcp/server.mjs"],
  "env": { "TOASTTY_SOCKET_PATH": "<resolved socketPath from the target instance>" }
}
```

For a runtime-isolated Toastty instance, read `socketPath` from its
`$TOASTTY_RUNTIME_HOME/instance.json`; do not reconstruct it from the runtime
home because a live instance can fall back to a per-process socket. The client
or tunnel must run as the same macOS user. This entry only defines the local
process; connecting a cloud dot to a private tunnel is a separate setup step.

The adapter uses Toastty's mode-0600 Unix socket. It does not use iOS device
credentials, require Tailscale, start the Remote Access HTTP listener, or open a
network port. Cloud assistants need a separately authorized transport to this
stdio server; a private MCP tunnel is one possible transport. The adapter
itself grants no cloud access.

`toastty_send_message` requires the `conversationID` and `inputAvailability`
`open_prompt` epoch returned by `toastty_list_sessions`. The result is one of
`accepted`, `rejected`, `uncertain`, or `duplicate`. Only a subsequent
`user_message` event bearing the same `clientRequestID` confirms delivery.
For `uncertain`, inspect the conversation before taking another action.

`toastty_start_session` requires a client-generated `clientRequestID`. The
adapter remembers start results for its process lifetime and returns the same
result for an exact retry. It does not yet provide durable idempotency across
adapter or app restarts; after an interrupted start, inspect the target
workspace before using a new request ID. A failed launch can leave the new tab
in place, and returns its IDs with `status: uncertain` for inspection.

The conversation projection is shared with Toastty Mobile, but local MCP
tracking can start without enabling Remote Access. Socket access remains a
same-user local authority. Do not expose the socket through a generic relay or
run an unrestricted adapter for untrusted clients.

For an isolated, disposable live check on Toastty's remote validation host:

```bash
sv exec -- scripts/remote/validate.sh --require-remote --scope working-tree \
  --run-label mcp-adapter-e2e \
  --validation-command 'python3 scripts/automation/mcp-adapter-e2e.py'
```

That check launches a second runtime-isolated Toastty process, a fake Claude
CLI in a throwaway home, and the actual MCP stdio server. It leaves the user's
production app and real sessions untouched.

Run the socket-framing and malformed-request regressions with
`node --test tools/toastty-mcp/server.test.mjs`.
