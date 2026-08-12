# Remote Access WebSocket Lifecycle

Status: accepted and implemented for the browser remote-access client.

## Decision

Toastty uses a same-origin WebSocket at `/api/subscribe` for live session-list
and conversation-event updates. The connection is authenticated by the paired
device's HttpOnly cookie and is accepted only when its `Origin` exactly matches
the origin configured in Toastty.

The browser client reconnects after 1 second and doubles the delay up to 15
seconds. Each attempt first refreshes `/api/sessions`; an unpaired response
returns the UI to pairing instead of retrying indefinitely. Returning the page
to the foreground also reconnects when the socket is not open.

The server responds to client ping frames with matching pong payloads, but does
not originate heartbeat frames. The 10-second request-header timeout protects
only connections that have not completed their HTTP request or upgrade. After
a successful upgrade, Toastty has no application-level idle timeout; normal
TCP, browser, Tailscale, or operating-system connection loss drives reconnect.

WebSocket frames are limited to 256 KiB and fragmentation is rejected. Each
client may have at most 32 incomplete server sends; attempting to enqueue above
that bound drops the slow client so one receiver cannot create unbounded host
memory pressure. The client then resynchronizes through REST and reconnects.

## Rationale and implications

This keeps the host small and predictable while Tailscale Serve owns remote TLS
and reachability. A client must treat the stream as a notification channel, not
the durable source of truth: sequence gaps, reconnects, and
`resnapshot_required` all require paging the REST event endpoint again.

The absence of a server heartbeat avoids background traffic, but means dead
peers may be detected only by the surrounding network stack or a later send.
Clients that need quicker detection may send standard WebSocket ping frames;
Toastty already answers them. Increasing frame or pending-send bounds requires
an explicit resource review rather than being inferred from client behavior.
