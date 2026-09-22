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

If Toastty Mobile cannot access its saved device record, unlock the iPhone and
choose **Try again**. For an unreadable record, **Forget pairing and start again**
removes the saved pairing from the iPhone so you can pair again. It does not
revoke or remove the Mac's device entry; remove that entry separately in
**Remote Access** on the Mac.

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

Toastty Mobile shows the session's reported model and reasoning above the
message field. Codex reports these in structured turn metadata; Claude Code
reports its model in assistant message metadata, without a reasoning value.
Other providers currently omit these fields. Unreported values stay hidden;
Toastty does not infer them from message text or configured defaults. The line
shows the latest report for the conversation, not the model used for every
earlier message, and is labelled **Last reported** while connection updates
are paused. Long values wrap up to two lines, with the complete values
available to VoiceOver. The line is read-only and does not change the session's
settings.

The host sends an optional `executionProfile` object in conversation summaries,
with optional `modelIdentifier` and `reasoningEffort` strings. Either the host
or iOS app can be updated first: older hosts omit the object, and older clients
ignore it. Both updates are needed to display reported values on the phone.

The composer also shows the conversation's Mac tab name on the right of the
model/reasoning row. The name is read-only, uses one line with tail truncation,
and is available in full to VoiceOver. It remains right-aligned when no model
has been reported. Session list UI and conversation titles are unchanged.

Conversation `placement` includes optional `workspaceTabID` and
`workspaceTabTitle` fields. Older hosts omit them and older clients ignore them.
The host uses the same state-backed display title as Open panels: custom names
match the Mac, while live-only terminal title updates may differ. Renaming a tab
on the Mac updates its remote context even without new agent activity; renaming
from iOS is not supported.

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

### Photos and files from iOS

Use **Attach** below the conversation composer to choose **Photo Library**,
**Take Photo**, or **Choose File**. Review the selected thumbnails or filenames,
remove anything you do not want to send, then send with or without message text.
Camera access requires permission and a device with a camera. Selection alone
does not upload anything. Both the iOS app and paired Mac must support attachments.

A message can contain up to four files, at most 4 MiB per file and 8 MiB total.
Photos are resized to at most 2048 pixels on their longest side and re-encoded
as JPEG without the source metadata. Images chosen through Files use the same
conversion; animated images use their first frame. Files supports JPEG, PNG,
GIF, WebP, HEIC/HEIF images, PDFs, and common
UTF-8 text/source formats; directories, packages, and unsupported binary formats
are rejected. Attachment drafts stay with their conversation in memory and are
lost if the app exits or the pairing is cleared.

The authenticated send transfers bytes directly to your paired Mac. Toastty
stores private copies under its runtime configuration directory at
`remote-access/attachments/`, then asks the running agent to read those local
files in the same prompt as your message. It creates no public upload links.
The agent's tools, model, and filesystem permissions determine which contents
it can read; a tool permission request may require action on the Mac. Upload
acceptance does not mean the agent has read or understood the files.

The same prompt, permission, and duplicate checks apply to attachment sends.
A definite host rejection restores the attachment draft when it will not
replace a newer draft. Dismissing a rejected send discards any saved attachment
recovery for that send. For an uncertain delivery, inspect the conversation on
the Mac before sending again; Toastty does not automatically resend. Files from
accepted or uncertain deliveries remain available for delayed agent reads.
The Mac removes copies older than seven days when starting attachment storage
or staging another send, and refuses new uploads when its 256 MiB storage
budget is full. Removing an unsent attachment only removes its local draft.

### Structured questions

Claude Code sessions launched or resumed through Toastty can also answer
`AskUserQuestion` forms from the phone. Choose an option, select multiple options
where offered, or enter a custom answer, then submit the complete form. The
desktop question remains available. The phone waits for Claude's completion
event before showing the accepted answers, including when you answer on the Mac
first.

Question answers require a native paired device with send access and remote
replies enabled for that session. A question can be answered remotely for up to
five minutes while its launch hook remains connected. If that connection ends,
the question expires, or the provider's form is unsupported, continue on the
Mac. Other tool permission requests remain read-only on the phone. Existing
Claude sessions must be relaunched or resumed through the updated Toastty to
install the answer hook.

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
scroll position are independent. Close the sheet or return to the workspace,
then open the preview again to load current content from the Mac.

For a Scratchpad linked to a session, use the **Scratchpad** button in the
chat header to open it in a sheet. Close the sheet to return to your chat;
an unfinished message draft is preserved. If more than one open Scratchpad
is linked to that session, the button offers a menu identifying each panel.
From a Scratchpad opened through the workspace list, use **Session** to open
the linked chat. Back returns to the Scratchpad, then to the workspace.
These links follow the exact live session association on the Mac. Standalone
Scratchpads and ended sessions do not gain inferred links to other sessions.

Recency combines the desktop's recent panel activity with saved file
modification times. The desktop retains a limited history, so older panels
may have no known time; those appear after dated panels without an age label.
Panels showing the same file or website can share its activity time.

Local-file panels whose files are confirmed missing are omitted from the
mobile list. This does not close their desktop tabs or retarget them to a
different file. Permission errors and inconclusive checks do not hide panels.

File previews require a native paired device with read access. A conversation
link is resolved using the conversation's recorded working directory on the
Mac. Access covers three kinds of files: files inside the conversation's
containing Git repository, or the recorded directory when it is not in a
repository; files already open in panels of the same workspace; and files the
agent itself linked in that conversation, wherever they are, such as a sibling
worktree or a `/tmp` scratch file. The Mac decides that last kind from its own
copy of the conversation, so the phone can only open links the agent wrote.
Links in your own messages do not grant access. An agent-linked absolute path
still opens when the conversation has no recorded working directory.
A missing working directory does not fall back to the
Mac's current directory or home directory, and the filesystem root and home
directory cannot become broad preview roots.
Recorded working directories and open-panel paths must refer directly to
their files or directories. Custom symlink paths do not grant remote preview
access; open the resolved path on the Mac instead. Standard macOS path aliases
such as `/tmp` remain supported.

The source viewer also opens `.patch` and `.diff` files and extensionless
text files such as a `Makefile` as plain text. Dotfiles, `.env` files reached
only through an agent link, and binary files stay unavailable.

An open HTML file also permits supported web assets within its containing
directory. This includes local stylesheets, scripts, images, fonts, and media;
it does not grant access to arbitrary neighboring documents or hidden files.
Paths that escape the allowed directory, including through symlinks, are
rejected. An HTML file reached only through an agent link does not serve
assets when it sits directly in the home directory or the filesystem root.

When a preview fails, the Mac log records why: the failure stage, the reason,
whether the reference was absolute or relative, its extension, whether a
working directory was recorded, and which access rule applied or was tried.
File paths and contents are never logged. Local HTML runs separately from the gateway credentials, with
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
- Answerable Claude questions include their question text, options, optional
  previews, and accepted answers. The phone sends option identifiers and custom
  answer text; the Mac applies them only to the exact pending question through
  Claude's hook response. This does not grant tool permissions or change
  Claude's permission settings.
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
