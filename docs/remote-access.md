# Remote Access

Toastty Mobile connects to a private gateway running on your Mac. Tailscale
Serve provides the tailnet HTTPS address; Toastty itself listens only on
`127.0.0.1` and does not expose a LAN or public listener.

## Set up access

1. Install Tailscale on the Mac and phone, sign both into the same tailnet, and
   confirm they can reach each other.
2. In Toastty, open **Toastty > Remote Access…**, or use the command palette's
   **Open Remote Access** action, and turn on **Enable Remote Access**. The
   default local address is `http://127.0.0.1:42871`.
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
   Native pairing accepts only a canonical HTTPS MagicDNS hostname ending in
   `.ts.net`, with no path, query, user information, or custom port.
5. Choose **Show Pairing QR**, then scan it from Toastty Mobile. If scanning is
   unavailable, enter the fallback code shown beside the QR. Both proofs belong
   to the same single-use offer, expire after two minutes, and are invalidated
   together when either succeeds or you cancel or reissue the offer.

The QR is a non-HTTP payload and contains a short-lived secret, not the
long-lived device credential. Avoid screenshots or copying the fallback code
into messages.

The exchange returns an opaque Bearer credential to the native app once.
Toastty binds it to the exact `Tailscale-User-Login` identity supplied by
Tailscale Serve and requires that identity on later native REST requests and
WebSocket upgrades. A native app can inspect its own device metadata and
best-effort revoke itself through the gateway. `401` means it must pair again;
`403` means the credential remains valid but a scope or action is denied, so it
must retain the credential.

The current Remote Access window issues pairing offers only for Toastty Mobile.
Browser profiles paired by earlier Toastty builds may continue to connect and
appear in the paired-device list, but the current UI does not issue new browser
pairing codes.

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
panel, provider, and provider-native session before it enables replies. To stop
remote access, revoke one device, revoke all devices, or disable the gateway
immediately.

Remote input is fail-closed. A send succeeds only while Toastty can prove that
the root prompt shown to the phone is still open and untouched. Local typing,
a newer prompt, a modal interaction, an offline session, or an unavailable
terminal rejects the send. An accepted send means Toastty handed it to the
terminal; the transcript event carrying the same request ID is the later
confirmation.

Toastty Mobile reconnects automatically after transient network loss and
reloads from Toastty's current snapshots when it detects an event gap. Keep
Toastty running and Remote Access enabled; Tailscale Serve alone cannot reach a
stopped local gateway.

## Workspace panels and file previews

Open a workspace in Toastty Mobile to see **Open Panels** above its sessions.
The list includes the right-side panels from every desktop tab in that
workspace, including tabs that are not selected and panels in a hidden
sidebar. Each row identifies its owning desktop tab. Panels are ordered by
their latest known opening or update time, with a relative age beside the
title. The list initially shows four panels; use **Show more** to see the rest
and **Show less** to collapse it. Workspaces containing
open panels remain available even when they have no sessions or the session
filter hides all their sessions. Closed panels are not a document history.

Tap a panel to open a full page, then use Back to return to the workspace.
Local file links in conversations open preview sheets. Explicit line references reveal the
requested line. Previews use the saved file on the Mac; unsaved edits in a
desktop document editor are not transferred. The source viewer supports the
same text, Markdown source, code, and configuration formats as the desktop
viewer. Local HTML opens as a rendered browser preview with its permitted
supporting assets.

Scratchpads initially fit the screen width and start at the top. Scroll down
through tall content, pinch to zoom, pan to explore, and use **Fit** to return
to the width-fitted view at the top. Existing buttons and
other interactions inside a Scratchpad remain usable. Viewing a panel on the
phone does not focus or close its desktop panel, and the phone's zoom and
scroll position are independent. Leave and reopen a preview to load current
content from the Mac.

Recency combines the desktop's recent panel activity with saved file
modification times. The desktop retains a limited history, so older panels
may have no known time; those appear after dated panels without an age label.
Panels showing the same file or website can share its activity time.

Local-file panels whose files are confirmed missing are omitted from the
mobile list. This does not close their desktop tabs or retarget them to a
different file. Permission errors and inconclusive checks do not hide panels.

File previews require a native paired device with read access. A conversation
link is resolved using the conversation's recorded working directory on the
Mac. Access is limited to its containing Git repository, or that recorded
directory when it is not in a repository, plus files already open in panels
of the same workspace. A missing working directory does not fall back to the
Mac's current directory or home directory, and the filesystem root and home
directory cannot become broad preview roots.
Recorded working directories and open-panel paths must refer directly to
their files or directories. Custom symlink paths do not grant remote preview
access; open the resolved path on the Mac instead. Standard macOS path aliases
such as `/tmp` remain supported.

An open HTML file also permits supported web assets within its containing
directory. This includes local stylesheets, scripts, images, fonts, and media;
it does not grant access to arbitrary neighboring documents or hidden files.
Paths that escape the allowed directory, including through symlinks, are
rejected. Local HTML runs separately from the gateway credentials, with
network connections, forms, and embedded frames blocked. This can prevent a
local page that depends on external services from working completely.

A regular website panel opens its URL in an independent mobile browser
session; desktop cookies and page state are not copied. A development server
address such as `localhost` belongs to the Mac and cannot be opened as the
phone's `localhost`.

The Mac must remain connected while loading previews. Missing content,
unsupported previews, and files exceeding the preview size limits show an
unavailable message. Hosts without the preview capabilities continue to
support conversations; update Toastty on the Mac to enable previews.

## Privacy and security

- Remote Access is tailnet-private only when your Tailscale Serve and tailnet
  ACL configuration keep it private. Do not publish the loopback gateway
  through Funnel, a public reverse proxy, port forwarding, or another ingress.
- Tailscale terminates HTTPS. The hop from Tailscale Serve to Toastty is plain
  HTTP confined to loopback.
- Toastty stores only a SHA-256 hash of each browser or native credential,
  never the credential itself. Browser profiles paired by earlier builds hold
  their credential in an HttpOnly cookie; the native app receives its Bearer
  credential only in the successful pairing response. Neither kind belongs in
  URLs.
- The phone receives normalized conversation metadata and events, including
  message text, concise tool activity, state, workspace/panel placement, and
  working directories when present. It does not receive raw provider JSONL or
  raw terminal frames.
- Workspace snapshots also include open-panel titles, tab placement, and
  file or URL metadata. A native client fetches document contents, Scratchpad
  HTML, and permitted local HTML assets only when needed for a preview. These
  content endpoints do not accept legacy browser-cookie credentials.
- Toastty keeps a bounded local audit log of remote-security actions. Entries
  may include timestamps, device IDs or names, and rejection reasons, but not
  message text, prompts, or credential values.
- Pairing failures and invalid credentials are rate-limited. Presented origins
  outside the exact allowlist are rejected on every route.

If a phone is lost or a previously paired browser profile may be compromised,
revoke that device from the Mac. Revocation is persisted before Toastty closes
every active stream for that device; revoke-all covers browser and native
devices. Disabling Remote Access closes the listener and all active
subscriptions and cancels a native offer, but retains paired-device credentials
for the next time you enable it.
When you no longer need the tailnet URL, remove only the default
HTTPS mapping created above so other Serve configuration remains intact:

```bash
tailscale serve --https=443 off
```

See [Toastty Privacy and Local Data](privacy-and-local-data.md) for the local
files associated with Remote Access.
