# Native iOS runtime reuse boundary

Date: 2026-08-11

This note records the Phase 1 reuse decision before Toastty's native network and domain runtimes are implemented. EmptyOS is useful prior art for small concurrency and testing patterns, but its SSE transport, scalar cursor, refresh-token behavior, and content-based send matching do not implement Toastty's protocol.

## Copy structurally

- Copy the narrow HTTP transport seam, request-builder shape, status/error boundary, and actor-backed queued mock pattern from EmptyOS. Do not copy its large API client.
- Copy the raw JSON-value discriminator pattern as the front door of Toastty's compatibility decoder. Do not copy SSE frame or parser types.
- Copy the actor-owned reducer shape, generation checks on callbacks, immediate-yield state stream, cancellable stream task, and current-state accessor. Toastty state delivery uses `.bufferingNewest(1)`.
- Copy the bounded, cancellation-aware request-handshake test pattern: a request becomes observable only after its continuation is installed. Tests must not coordinate with sleeps or count polling.

## Adapt

- `EventStreamClient` uses `URLSessionWebSocketTask`, HTTPS-to-WSS URL conversion, the host-required authorization and Origin headers, text-frame receipt, and `GatewayCompatibilityDecoder`.
- One `ConnectionCoordinator` owns credentials, connection generation, retry/backoff, scene lifecycle, subscription handshakes, and rejection of stale REST/socket work. Individual session and conversation runtimes do not run independent retry loops.
- Session startup is REST seed, WebSocket subscribe, then a fresh full `session_list` snapshot before the connection is live. Session lists have no transcript cursor.
- Conversation startup subscribes before REST paging and buffers matching live pages across the handoff. The cursor is the full `(projectionRunID, projectionGeneration, afterSequence)` tuple. Pages drain contiguously; gaps trigger REST recovery; run/generation mismatch, retention loss, overflow, or explicit `resnapshot_required` triggers a resnapshot.
- `RemoteSessionState` and `RemoteInputAvailability` remain independent. Only an exact `.openPrompt` epoch can enable send. Unknown display/input variants are read-only, not a reason to discard the snapshot.
- Scene and UI controllers may use narrow capability protocols and generation-owned refresh, but lifecycle/retry policy remains below SwiftUI.

The live-page handoff buffer starts at the host web oracle's bound of 32 pages. Changing that bound requires recorded workload evidence rather than silent growth.

## Rewrite

- Send reconciliation is keyed only by `clientRequestID`. `accepted` and `duplicate` remain pending until the exact `user_message` echo arrives. `rejected` is terminal. An uncertain request is not blindly retried. When a projection changes, or a completed resnapshot reaches its latest sequence without the echo, the row becomes a dismissible `deliveryUnconfirmed` receipt. Text, timestamps, and `origin: unknown` are never matching heuristics.
- The shared strict host Codable models remain the known-case wire contract. Native compatibility decoding screens top-level message, event, display/input, send-result, and error discriminators before constructing domain state. Unknown top-level messages and events are ignored narrowly while cursor progress survives; unknown display/input becomes read-only; an unknown send result or error fails only that operation.
- Native credentials have no refresh protocol. `401` stops reconnect and requires pairing; `403` keeps the credential and reports authorization/scope. Protocol mismatch does not retry. Only network failures and eligible 5xx responses use jittered backoff from one to thirty seconds, with a reconnecting banner after two failures.

## Planned layout

- `ios/Sources/ToasttyMobileDomain/Networking/`: HTTP transport, gateway client, event stream, compatibility decoder, gateway errors.
- `ios/Sources/ToasttyMobileDomain/Runtime/`: connection coordinator/policy, session and conversation runtimes/reducers, send reconciliation, state stream.
- `ios/Sources/ToasttyMobileDomain/Support/`: injectable clock and randomness.
- Matching tests under `ios/Tests/ToasttyMobileDomainTests/`, with scripted transports/streams, explicit request handshakes, test clock/jitter, client-authored compatibility fixtures, and the canonical host baseline referenced in place.

Both repositories currently use Foundation-only native domain targets and no third-party iOS dependencies. Because a clear root license/notice was not found during the survey, substantial verbatim source copying is out of scope; implementation should port the small patterns above and preserve provenance in commit context. The shared `RemoteProtocol` source directory first undergoes the dual-Tuist-graph stop/go gate. If cross-root source ownership is unreliable, use the planned local Swift package before runtime code is added; never duplicate protocol sources into `ios/`.
