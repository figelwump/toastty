# Coordinator

Open **Coordinator** in the sidebar, or press `Cmd+Shift+T`. The home shows
one shared agent conversation beside a native review queue. **All tasks**
opens the existing task list and actions. Selecting a workspace returns to
its terminals.

**New Task** and `Option+Shift+T` still open quick entry directly. Choose a
project, agent and attachments there. Task creation does not wait for the
Coordinator to start or answer.

## Conversation

**Start Coordinator** starts a managed Claude or Codex session. All windows
share that session and its composer. Settings choose the profile, model and
reasoning effort for the next session. **Terminal** opens the backing terminal
for inspection or for interactions the chat cannot answer.

The chat uses the same Markdown, selectable text, tool rows and structured
interaction cards as the iPhone app. Input uses Toastty's local conversation
service. Remote Access can remain off; opening Coordinator does not enable a
network listener or pair a device.

Send at an open prompt, queue a message while the agent works, or use **Send
now** when the provider permits it. **Stop** interrupts the current turn and
holds queued messages until you resume them. Files use the existing conversation
attachment limits. If terminal typing holds input, inspect the terminal before
releasing its draft hold. Chat typing does not mark a terminal draft.

A delivery warning means the message may have reached the agent. Toastty does
not replay that message automatically. Inspect the terminal before sending it
again. An unchanged retry retains its request identity to prevent duplicate
delivery. If the session changes while you compose, the draft remains available
for copying; clear it before writing to the new session.

## Inspect a task without leaving Coordinator

Use **Peek session** in a review, or follow a `toastty://task/…` or
`toastty://session/…` chat link. Peek temporarily occupies the right-hand area.
It shows the task conversation and lets you message its agent through the same
input service. **Back to review** restores the queue. **Open task space** opens
the terminal workspace. The Coordinator chat, draft and selected review stay
in place while Peek is open.

Each window retains the scroll position for recently viewed conversations,
including the position inside a long message. Switching tasks or closing and
reopening Peek preserves that position even when the draft is empty. New
messages follow the view while it is at the bottom. Reading earlier text keeps
the view in place.

Each window owns its Peek selection. Toastty tracks the union of those panels
and the Coordinator panel. Closing Peek releases viewing demand. An unfinished
draft, attachment or send keeps conversation observation active until it is
cleared or completes. This preserves the input binding across navigation and
still detects session changes and input in the backing terminal. A hidden Peek
cannot start new input. Accepted queued input remains owned by the conversation
service.

## Review queue

The queue comes from task records and saved reviews. It remains available when
the Coordinator is busy, stopped or unavailable. Tasks needing attention appear
even before a brief exists. Urgent issues and work that blocks other tasks come
first. A review's priority menu can override its automatic priority.

A brief identifies the task, PR, exact commit and destination branch. It explains the behavior
change, decision needed, verification, remaining gaps, recommendation and
evidence. Open the linked task, PR or evidence before deciding when needed.
Evidence copies and review records live outside task worktrees, so cleanup does
not remove the review record.

**Approve & Merge** records your approval for that exact PR head and destination. Toastty sends
the request to the task's agent in its checkout. The agent follows that
repository's merge instructions and reports the result. A changed head or destination needs a
new review. The global Coordinator cannot create approval through its agent API.

**Request changes** saves your feedback and sends it to the task's agent. The
queue distinguishes saved decisions, delivery, uncertain delivery, agent
reports, and observed PR results. An agent saying it merged is not confirmation:
Toastty marks a merge confirmed only after observing the PR result.

**Retry delivery** creates a new request after failed or uncertain delivery, or
after the task agent reports a blocked or failed request. Toastty keeps prior
attempts with the review. The app's delivery reason and the task agent's report
are shown separately. Restart does not replay an uncertain request.

Reviews, decisions and feedback survive restart. Failed review-store loading is
shown as an error; it is not treated as an empty queue. A restored Coordinator
uses the native managed-session restore path. An uncertain launch is left for
inspection instead of starting a duplicate session.

## Automatic preparation

When enabled in Coordinator settings, meaningful task outcomes can prompt the
Coordinator to prepare or refresh briefs. Toastty coalesces these updates and
waits for an idle prompt. User drafts, pending interactions and queued messages
take priority. Pausing automatic preparation does not interrupt a running turn.
Automatic preparation never approves or merges work.

The bundled `toastty-coordinator` skill reads current task and review records.
It uses the structured `coordinator.review.*` app-control commands to publish
briefs and inspect decisions. The existing `window.tasks.show` and
`window.tasks.hide` automation IDs remain stable and now show or hide this home.
