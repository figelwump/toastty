# Coordinator chat

Status: implemented. Third of five coordinator PRs into `feat/coordinator`.

## Goal

Replace "talk to the coordinator in its terminal" with a chat. The chat shows
the coordinator's conversation with the cards it posts, opens packets in place,
and acts on them: a reply to the task, a question to the coordinator, Merge,
the task space, the pull request, and the packet report.

## Behavior

- The chat covers the coordinator workspace's terminal in the main area, as an
  overlay, so the terminal stays attached. The right panel stays beside it.
  `WindowState.showsCoordinatorTerminal` (not saved) switches one window to the
  raw terminal; `coordinator show-terminal` sets it, `coordinator.chat.show`
  clears it.
- `coordinator.chat.show [taskID]` and `toastty coordinator show [--task]` open
  the chat; with a task, the page opens and scrolls to that task's newest packet
  card. PR 4's sidebar calls this action. The command palette has **Show
  Coordinator Chat**.
- Cards come from `events.jsonl`; each shows its task's live state from the
  task board. `CoordinatorChatTimeline` gives a packet card the version that
  was newest when it was posted, adds a card for a newer version at its publish
  time, marked new, and collapses the task's older packet cards.
- A reply to the task is `task send` with `Review note on packet vN: <text>`.
  It clears `readyForReviewAt`, so the task leaves Needs you until its next
  packet. Ask sends the coordinator a message that names the task.
- Merge asks first, with the policy from `tasks.toml` (`merge`, `merge_skill`,
  `merge_prompt`, `release_tags`), then calls `TaskCoordinator.requestMerge`,
  as the Merge button does.
- PR links, the report and routing.md open in the coordinator workspace's right
  panel. The report is `toastty://coordinator/report/<task>/<version>` in an
  ordinary browser panel, so annotation mode works there.

## Data flow

- `CoordinatorChatController` (one per app) follows the coordinator's
  conversation through the shared `ConversationService` (`changes()`, then
  event pages after a cursor), the task board's changes, and card posts. It
  builds one `CoordinatorChatPayload` and pushes it to each open page.
- `CoordinatorChatView` hosts `WebPanels/CoordinatorApp` at
  `toastty://coordinator/` in a `WKWebView`. The page sends actions through the
  `toasttyCoordinatorChat` message handler; `CoordinatorChatPageEvent` checks
  each one before it runs.
- `ToasttyPageSchemeHandler` serves the bundle and, through the controller,
  `packet-data/<task>/<version>` JSON and `packet-files/<task>/v<N>/<file>`,
  only for files a stored packet names.
- The composer sends with `sendLocal`: into the open prompt, or queued for the
  end of the turn when the agent is busy.

## Supporting changes

- `automation.capture_screenshot` draws each visible web view's own snapshot
  over its frame. `cacheDisplay` alone leaves WebKit content blank, so smoke
  captures of web panels now show their pages.
- `scripts/automation/task-stages-ui-helper.swift` matches `title:<prefix>`
  against an element's title, label or placeholder, for web content, which
  has no Accessibility identifiers, and gains `focus`.

## Out of scope

- The sidebar Coordinator row and Needs you items (PR 4). PR 4's
  `openCoordinatorChat` closure calls `coordinator.chat.show`.
- Removing the Tasks view (PR 5), Today and All tasks pages, cards on the
  iPhone.

## Validation

- Swift: `Tests/Core/CoordinatorChatTimelineTests.swift`,
  `Tests/App/CoordinatorChatTests.swift`, CLI parsing in
  `Tests/CLI/ToasttyCLITaskTests.swift`.
- Web: `WebPanels/CoordinatorApp/test/render.test.mjs` and the bundle sync
  check.
- Live: `scripts/automation/remote-coordinator-chat-check.py` through
  `sv exec -- scripts/remote/validate.sh --require-remote`; captures are in
  `docs/plans/evidence/coordinator-chat-2026-10-24.md`.
