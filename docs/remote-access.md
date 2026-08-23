# Remote Access

Toastty supports its small web app and the native Toastty Mobile client through
the same Mac gateway. Tailscale Serve provides the private tailnet HTTPS
address; Toastty itself listens only on `127.0.0.1` and does not expose a LAN
or public listener.

## Set up access

1. Install Tailscale on the Mac and phone, sign both into the same tailnet, and
   confirm they can reach each other.
2. In Toastty, open **Toastty > Remote Access…** and turn on **Enable Remote
   Access**. The default local address is `http://127.0.0.1:42871`.
3. Configure Tailscale Serve to proxy an HTTPS tailnet URL to that loopback
   address. With current Tailscale clients, this is typically:

   ```bash
   tailscale serve --bg http://127.0.0.1:42871
   ```

   Follow the URL printed by Tailscale; your tailnet policy and HTTPS settings
   may require an administrator. `tailscale serve status` shows the active
   mapping.
4. Enter the exact HTTPS origin in Toastty's **Tailnet origin** field, without
   a trailing path—for example `https://your-mac.example-tailnet.ts.net`.
   Toastty rejects browser requests whose `Origin` does not exactly match this
   value.
5. Open that HTTPS URL on the phone. In Toastty, choose **Show Pairing Code**,
   then enter the single-use code and a device name in the phone web app. The
   code expires after five minutes.

Pairing installs an HttpOnly, same-site credential cookie in that browser. It
is specific to that browser profile: private browsing, cleared site data, or a
different browser requires pairing again. Do not put a pairing code or cookie
in a URL, message, screenshot, or command line.

### Pair the native app

Native pairing is separate from browser pairing; issuing or redeeming one kind
does not replace the other. Enter the public Tailscale Serve origin first. The
native QR accepts only a canonical HTTPS MagicDNS hostname ending in `.ts.net`
(no path, query, user information, or custom port), rather than the loopback
listener or a value learned from an incoming request.

Choose **Show Native Pairing QR**, then scan it from Toastty Mobile. If scanning
is unavailable, enter the fallback code shown beside the QR. Both proofs belong
to the same single-use offer, expire after two minutes, and are invalidated
together when either succeeds or you cancel/reissue the offer. The QR is a
non-HTTP payload and contains a short-lived secret, not the long-lived device
credential. Avoid screenshots or copying the fallback code into messages.

The exchange returns an opaque Bearer credential to the native app once.
Toastty binds it to the exact `Tailscale-User-Login` identity supplied by
Tailscale Serve and requires that identity on later native REST requests and
WebSocket upgrades. A native app can inspect its own device metadata and
best-effort revoke itself through the gateway. `401` means it must pair again;
`403` means the credential remains valid but a scope or action is denied, so it
must retain the credential.

## Reading and replying

A newly paired device can read managed Codex, Claude Code, OpenCode, MiMo Code,
and Pi conversations and send replies to their active sessions. Codex and
Claude Code can replay history from their local provider transcript files.
OpenCode, MiMo Code, and Pi publish a bounded launch-scoped conversation feed
through Toastty's injected instrumentation; that history remains available
only while the current Toastty app process retains it and is rebuilt from the
provider when a managed launch or resume exposes a snapshot.

**Ready** is an unread-completion presentation, shared with Toastty on the Mac.
When Toastty Mobile has rendered a conversation through the transcript's live
edge, it acknowledges that boundary to the Mac. The Mac clears the panel's
unread state and the remote presentation returns to **Idle**, including for a
completed session that has already stopped. Reading the same completion on the
Mac has the same effect on the phone.

Remote replies are enabled by default for active sessions. For every supported
provider, Toastty requires an exact match between the active managed session,
panel, provider, and provider-native session before it enables replies. You can
turn off **Send** for a paired device persistently, turn off replies for an
individual active session until Toastty restarts, revoke one device, revoke all
devices, or disable the gateway immediately.

Remote input is fail-closed. A send succeeds only while Toastty can prove that
the root prompt shown to the phone is still open and untouched. Local typing,
a newer prompt, a modal interaction, an offline session, or an unavailable
terminal rejects the send. An accepted send means Toastty handed it to the
terminal; the transcript event carrying the same request ID is the later
confirmation.

The browser reconnects automatically after transient network loss and reloads
from Toastty's current snapshots when it detects an event gap. Keep Toastty
running and Remote Access enabled; Tailscale Serve alone cannot reach a stopped
local gateway.

## Privacy and security

- Remote Access is tailnet-private only when your Tailscale Serve and tailnet
  ACL configuration keep it private. Do not publish the loopback gateway
  through Funnel, a public reverse proxy, port forwarding, or another ingress.
- Tailscale terminates HTTPS. The hop from Tailscale Serve to Toastty is plain
  HTTP confined to loopback.
- Toastty stores only a SHA-256 hash of each browser or native credential,
  never the credential itself. The browser receives its credential only as an
  HttpOnly cookie; the native app receives its Bearer credential only in the
  successful pairing response. Neither kind belongs in URLs.
- The phone receives normalized conversation metadata and events, including
  message text, concise tool activity, state, workspace/panel placement, and
  working directories when present. It does not receive raw provider JSONL or
  raw terminal frames.
- Toastty keeps a bounded local audit log of remote-security actions. Entries
  may include timestamps, device IDs or names, and rejection reasons, but not
  message text, prompts, or credential values.
- Pairing failures and invalid credentials are rate-limited. Presented origins
  outside the exact allowlist are rejected on every route.

If a phone is lost or a browser profile may be compromised, revoke that device
from the Mac. Revocation is persisted before Toastty closes every active stream
for that device; revoke-all covers browser and native devices. Disabling Remote
Access closes the listener and all active subscriptions and cancels a native
offer, but retains paired-device credentials for the next time you enable it.
When you no longer need the tailnet URL, remove only the default
HTTPS mapping created above so other Serve configuration remains intact:

```bash
tailscale serve --https=443 off
```

See [Toastty Privacy and Local Data](privacy-and-local-data.md) for the local
files associated with Remote Access.
