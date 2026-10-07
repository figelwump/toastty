# Remote Access

Toastty Mobile connects to a private gateway running on your Mac. Tailscale
Serve provides the tailnet HTTPS address; Toastty itself listens only on
`127.0.0.1` and does not expose a LAN or public listener.

## Set up access

1. Install Tailscale on the Mac and phone, sign both into the same tailnet, and
   confirm they can reach each other.
2. In Toastty, open **Toastty > Remote Access…**, or use the command palette's
   **Open Remote Access** action, and turn on **Enable Remote Access**. Toastty
   starts its local gateway, then sets up private Tailscale Serve HTTPS access
   to it. The default local address is `http://127.0.0.1:42871`.
3. If Toastty shows **Open Tailscale Setup**, open that page and complete the
   HTTPS approval steps. Your tailnet administrator may need to approve them.
   Return to Toastty and choose **Retry Setup**. Toastty does not wait for
   browser approval or retry a configuration change in the background.
4. Wait for **Tailscale Serve is configured**. Toastty fills an empty **Tailnet
   origin** field with this Mac's address. It does not replace a different
   saved address. If that address is stale, choose **Detect** or edit it, then
   choose **Retry Setup**. Native pairing accepts only an HTTPS MagicDNS
   hostname ending in `.ts.net`, with no path, query, user information, or
   custom port, such as `https://your-mac.example-tailnet.ts.net`.
5. Choose **Show Pairing QR**, then scan it from Toastty Mobile. If scanning is
   unavailable, enter the fallback code shown beside the QR. Both proofs belong
   to the same single-use offer, expire after two minutes, and are invalidated
   together when either succeeds or you cancel or reissue the offer.

The configured status verifies the private HTTPS mapping on this Mac. The
phone checks the real HTTPS connection during pairing. Tailnet ACLs, DNS,
certificate setup, or the phone's Tailscale connection can still prevent
access.

Toastty reuses a correct existing mapping, including a manual mapping to
`localhost`. It preserves unrelated paths on that mapping. It does not replace
another service on HTTPS port 443 or enable Funnel. If HTTPS port 443 already
has another setup, resolve that conflict in Tailscale before retrying. Avoid
editing Serve configuration from another app or terminal while Toastty is
setting it up. The Tailscale command cannot atomically prevent concurrent
external changes.

Setup also blocks pairing if an existing Funnel mapping exposes HTTPS port 443
or forwards another public HTTPS port to Toastty's local gateway. Resolve that
Funnel configuration before retrying.

When Toastty restores enabled Remote Access at app startup, it starts only the
local gateway. Opening settings can verify an existing mapping without changing
it. **Enable Remote Access**, **Set Up Tailscale**, and **Retry Setup** are the
actions that can configure Tailscale.

### Manual setup and recovery

If Toastty cannot find or inspect Tailscale, a working manual setup can still
pair a phone. The status says that Tailscale Serve is not verified. Configure
the mapping in a terminal and enter its exact HTTPS origin in Toastty:

```bash
tailscale serve status
tailscale serve --bg --https=443 http://127.0.0.1:42871
tailscale serve status
```

The status command reads your Mac's existing Tailscale configuration. The
`--bg` command changes it. Inspect the current mapping first and do not replace
another service. If Tailscale prints an HTTPS approval URL, complete its steps
before trying again. Toastty hides pairing while setup is running or when it
finds a missing mapping, a different target or origin, or Funnel access.

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
Pi, and Cursor conversations and send replies to their active sessions. Codex and
Claude Code can replay history from their local provider transcript files.
OpenCode, MiMo Code, and Pi publish a bounded launch-scoped conversation feed
through Toastty's injected instrumentation; that history remains available
only while the current Toastty app process retains it and is rebuilt from the
provider when a managed launch or resume exposes a snapshot.

Cursor publishes prompt and final response text from the current managed launch
through its hooks. It does not replay older chats or publish tool results. A
matching completed local turn enables replies; startup, interrupted turns, and
Cursor Cloud handoffs do not. Clearing the Cursor chat starts a new history.
Prompts are limited to 64 KiB and responses to 48 KiB, with a visible marker when
text is truncated. A chat keeps at most 20,000 observations and 20,000 turn
identities. When the turn limit is reached, remote input stays closed until a
new chat starts. Relaunch Cursor through Toastty after updating the app.

Cursor CLI `2026.10.01-e373342` can skip `afterAgentResponse` and `stop` hooks
provided only by a plugin. On that version, those events also need user or
project hook registrations for Cursor to dispatch them. Toastty does not edit
Cursor's global hook settings. If completion hooks do not arrive, the phone
keeps the conversation read-only. Validation used an installation with existing
user hooks; a clean plugin-only installation is not verified.

A temporary workaround for that Cursor version is to merge these no-op
registrations into the project's `.cursor/hooks.json`, preserving any existing
hooks. They let Cursor dispatch the corresponding Toastty plugin hooks without
forwarding events twice. Remove this workaround when Cursor fixes plugin-only
dispatch. See [Cursor's hook configuration](https://cursor.com/docs/hooks).

```json
{
  "version": 1,
  "hooks": {
    "afterAgentResponse": [{ "command": "true" }],
    "stop": [{ "command": "true" }]
  }
}
```

Toastty Mobile shows the session's reported model and reasoning above the
message field. Codex reports these in structured turn metadata; Claude Code
reports its model in assistant message metadata, without a reasoning value.
Cursor reports an explicit model from its prompt hook when available, without
a reasoning value. Other providers currently omit these fields. Unreported values stay hidden;
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

The iOS app icon badge counts sessions with an unread completion, a pending
approval, or an error. Each session counts once. Quiet unread sessions in a
subspace marked done do not count, matching the conversation screen's **Next**
action. Reading a completion or resolving an approval or error updates the
badge when the Mac sends the new state. Opening the app alone does not clear it.
Reading an error does not dismiss it; it counts until the session leaves its
error state or is removed on the Mac.

Toastty asks for badge permission when attention first appears while the app is
active. It requests badges only. You can change this permission in iOS Settings.
The badge keeps its last count during a connection loss or while the app is
suspended. This version has no push delivery, so new activity cannot update the
badge until the app reconnects. Unpairing, losing access, or a pairing that
needs repair because it is corrupt or incompatible clears the badge.

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

Use the **Attach** paperclip inside the message field to choose **Photo Library**,
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
first. Once the hook receives a phone answer, Toastty allows up to five minutes
for Claude to confirm it before closing the mobile response channel.

Question answers require a native paired device with send access and remote
replies enabled for that session. A question can be answered remotely for up to
24 hours while its launch hook remains connected. The phone can disconnect and
return later during that window. The Mac must remain awake with Toastty and the
Claude session running: a lost hook connection, including a long sleep or host
restart, closes mobile input without answering Claude's question. If the
connection ends, the window expires, or the provider's form is unsupported,
continue on the Mac. Other tool permission requests remain read-only on the
phone. Existing Claude sessions must be relaunched or resumed through the
updated Toastty to install the hook with the longer answer window.

Session rows follow the desktop sidebar: a status mark, the session name, and
its latest summary. Touch and hold a row to see its path, last update, model,
workspace, desktop tab, and agent, or to copy its path. In a conversation, the
**Next** button beside the Scratchpad button opens another session that needs
you: approvals first, then errors, then unread results. Touch and hold it to
choose from the list. It is hidden when no other session needs you.

Swipe a session row left for **Info**, which opens the same card as a sheet,
and **Flag**, which sets or clears the desktop's Flag for Later mark on the
session. The violet flag shows under the row's status mark, and **Undo**
appears for a few seconds. The change reaches the Mac's sidebar and every other
device; the Mac still clears the flag itself when the session starts new work.
Flag needs a Mac that advertises it and a device with send access, and is
hidden otherwise.

While a session is working, its row shows the running turn's time, ticking,
in place of its age. Touch and hold the row for the elapsed time and the
length of its last turn.

### Subspaces

Subspaces, the workspaces an agent spawned from another workspace, appear
under their parent in a collapsible **Subspaces** group, on Home and on the
parent's workspace screen. Rows sort as in the desktop sidebar: unread results
first, then approvals, errors, working, idle, and done. Each row shows the
subspace's status, its primary annotation or pull request chip, and the
summary of the session that sets the status. Tap a row to open the subspace,
which names its parent above its sessions. Touch and hold a row for its
annotations, sessions, path, and spawner.

A session that spawned subspaces shows a ⑂ chip with their count. Tap it to
show only that session's subspaces in the group, and again to show them all.
The filter gives way while it would hide a subspace that needs approval or has
an error. A collapsed group stays open under the same condition.

While a subspace is idle, has an unread result, or is done, its status box is a
checkbox. Tap it, swipe the row right, or choose **Mark as Done** from the
row's menu, to mark the subspace done without opening it; **Undo** appears for a few seconds. The
change applies on the Mac through the same rule as the sidebar checkbox and
reaches every connected device. When an agent in the subspace starts new work,
the Mac clears the mark. The Mac also refuses to mark a subspace done while
one of its sessions is working, waiting on approval, or failed, so a request
delayed past the start of new work cannot restore the mark. The checkbox is
read-only while the phone is disconnected.

**Active** leaves out idle and done subspaces. A workspace whose only activity
is in a subspace still appears under Active, listing that subspace.

Subspaces, the done mark, the flag and turn times need updates on both sides.
The host sends optional `parentWorkspaceID`, `spawningConversationID`,
`primaryAnnotationKey`, and `doneAt` fields on each workspace summary, and
optional `isFlaggedForLater`, `turnStartedAt`, and `lastTurnDuration` fields on
each conversation summary. It advertises the `workspace_done` capability for
`POST /api/workspace.done.set` and `conversation_flag` for
`POST /api/conversation.flag.set`. An older Mac
omits them, so the phone lists every workspace at the top level and shows no
checkbox. An older phone ignores them and keeps its flat list.

### Starting a session

Tap **+** on the Home screen or on a workspace screen to start a new agent
session. Choose the workspace, the agent, optionally a model and an effort
level, and write the first message or attach photos or files. Use **Attach** in
the first-message field to choose **Photo Library**, **Take Photo**, or
**Choose File**. Review or remove the selected files, then tap **Start**.
Message text is optional when files are attached. The same file types and
limits described in [Photos and files from iOS](#photos-and-files-from-ios) apply.
Selection alone does not upload anything.

The Mac saves private copies and includes their local paths in the agent's
first message. Files stay in the form after a refused or unanswered start,
including when you change workspaces. **Cancel** discards this unsent draft.
The draft is held in memory and is lost if the sheet closes or the app exits.
The first message, including the Mac's saved file paths, must fit within 64 KiB.
If a long message is refused, shorten it and try again. Accepted or uncertain
starts keep the same seven-day file retention and storage quota as replies.

The Mac opens a new tab in that workspace with a plain terminal, starts the
agent there with your message, and leaves the tab you are looking at and your
keyboard focus where they were. The session then appears in the phone's list
and opens. If it has not appeared after 10 seconds, the sheet closes with a
notice, and you open the session from the list when it arrives.

- **Workspace.** The menu lists every top-level workspace in Home order. From
  a workspace screen it starts on that workspace, and a subspace stays in the
  list under its parent. From Home it starts on the workspace of the last
  session started from this phone, or on Home's first workspace when the Mac no
  longer lists that one. Changing the workspace keeps your message and reloads
  the agents and directory for the new workspace.
- **Directory.** The session starts in the directory of the workspace's first
  terminal, which the sheet shows. The phone never sends a path, a command, or
  environment values. A workspace with no terminal directory cannot start a
  session from the phone.
- **Agents.** The sheet lists the profiles from `~/.toastty/agents.toml` whose
  sessions the phone can show: Codex, Claude Code, OpenCode, MiMo Code, Pi, and Cursor.
  A profile whose command is not installed, or that cannot take a first message
  on its command line, is listed struck through and cannot be chosen. Tap it
  to see the reason.
- **Model.** "Profile default" sends no model. The other choices are models
  your sessions of that agent report now, models you chose before on this
  phone, and **Other…** for typing a model ID. The agent's own CLI decides
  whether the model is valid.
- **Effort.** The Mac supplies the values each agent accepts. The picker is
  hidden for agents with no effort setting.
- **Permission.** Each native device has a **Start sessions** switch under
  **Paired Devices** in Remote Access settings. It is on by default, also for
  devices paired before this feature. Starting also needs send access, because
  the first message is a send.
- **Retries.** If the phone does not get an answer, **Start** sends the same
  request again, and the Mac returns the session it already started instead of
  starting another. The Mac remembers a started request for 10 minutes and
  until Toastty quits. Changing the workspace, message, attachments, agent, model, or
  effort makes a new request. You cannot cancel the sheet while the Mac is
  starting a session.

Starting needs updates on both sides. The Mac advertises the `session_start`
capability for `POST /api/session.start.options` and `POST /api/session.start`.
Start options also report `supportsAttachments`. When it is true, the phone
uses the native-only `POST /api/session.start-with-attachments` route. Older
Macs still accept text-only starts and show an update hint for attachments.
The upload requires send access, the **Start sessions** permission, and a
`Content-Length` header. The encoded request is limited to 12 MiB.
An older Mac does not, so the phone hides **+**. If you turn **Start sessions**
off and then run an older Toastty build on the Mac, that build does not know
the switch: it rewrites the device record without it, and the switch is on
again when you return to a newer build.

Toastty Mobile reconnects automatically after transient network loss and
reloads from Toastty's current snapshots when it detects an event gap. Keep
Toastty running and Remote Access enabled; Tailscale Serve alone cannot reach a
stopped local gateway.

## Workspace panels and file previews

Open a workspace in Toastty Mobile to see its sessions first, followed by
**Subspaces** when present, then **Open Panels**.
The list includes the right-side panels from every desktop tab in that
workspace, including tabs that are not selected and panels in a hidden
sidebar. Each row identifies its owning desktop tab. Panels are ordered by
their latest known opening or update time, with a relative age beside the
title. The list initially shows four panels; use **Show more** to see the rest
and **Show less** to collapse it. Under **All**, workspaces containing open
panels remain available even when they have no sessions. **Active** lists only
workspaces with a working, ready, needs-approval, or error session, and ends
with a count of the idle sessions it hides. Closed panels are not a document
history.

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
- Marking a subspace done or flagging a session needs a native paired device
  with send access. Each changes only that one mark, and each change is
  recorded in the audit log with the device that made it.
- Starting a session needs a native paired device with send access and the
  **Start sessions** switch on. The device chooses only an existing workspace,
  a configured agent profile, a model, an effort level, and the first message
  or attached files. The Mac chooses the saved file paths.
  The Mac checks the permission again immediately before it sends the command
  to the terminal. Accepted and refused starts are recorded in the audit log
  with the device, without the message text.
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
for the next time you enable it. The Tailscale Serve mapping remains configured;
it cannot reach Toastty while the local gateway is stopped.
When you no longer need the tailnet URL, remove only its root HTTPS mapping
on your Mac so other Serve paths remain intact:

```bash
tailscale serve --https=443 --set-path=/ off
```

See [Toastty Privacy and Local Data](privacy-and-local-data.md) for the local
files associated with Remote Access.
