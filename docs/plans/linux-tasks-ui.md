# Linux: tasks and coordinator UI

Goal: the Linux GTK app reaches parity with macOS for tasks, the Tasks view,
quick entry, and the coordinator (chat, dock, full view). Tasks and the
coordinator are the UI Toastty is moving to. The user-facing contract is
`docs/tasks.md`.

## Approach

- Native GTK/libadwaita for every surface, including the chat transcript.
  The Mac and iPhone transcripts are native too. GTK widgets are testable
  through the Broadway automation script (`Gtk.setName` ids), and native
  widgets avoid WebKitGTK's NVIDIA rendering cost
  (see `docs/linux.md`).
- Share logic and rewrite views. Pure logic that lives inside macOS view
  files moves to its own shared file, so Linux compiles the same code.
  Linux keeps only GTK views and a thin facade in `ToasttyAppLogic`. Each
  split is a move with no behaviour change and is listed in
  `docs/linux.md`. The macOS and iOS graphs need `tuist generate` and a
  build on toastty-mini after each split; a Linux host cannot run them.
- The GTK layer cannot see `Sources/App` types (module-internal). The
  facade in `linux/Sources/ToasttyAppLogic` exposes public render models
  and action methods, as `LinuxAppLogic+Frontend.swift` does for sessions.
  `ConversationUI`'s pure model files compile on Linux as their own
  module, so their public types reach the GTK layer directly.

## Phases

0. **Backend.** `LinuxAppLogic` builds the task stack as
   `ToasttyApp.init` does. That stack is `TaskRecordStore`,
   `RecentWorkspacesStore`, `TaskCoordinator`, `PullRequestStateCache`,
   `TaskBoardStore`, `TaskWebhookService`, `LiveTaskSessions` and
   `CoordinatorController`, plus `SessionCloseController` and
   `SessionExitController`. Pass them to the automation socket and Remote
   Access. Result: `toastty task …` and `toastty coordinator …` work, and
   the phone sees the task board.
1. **Shared splits.** Logic moves out of the view files:
   - Quick entry: `QuickEntryController`, `QuickEntryModel`, the shortcut
     answer.
   - Coordinator: `CoordinatorChatModel`, mentions, chat links, notices,
     the composer delivery mode, `SidebarCoordinatorPresentation`.
   - Tasks: the webhook approval texts, `TaskSetupCard`'s statics,
     `WhatsNewFacts`.
   - `ConversationUI`: the model halves of the mixed files.
2. **Sidebar.**
   - The Tasks row with ＋, and the All | Needs you switcher with its
     counts.
   - The coordinator row.
   - Task space marks, task record rows, the To ship and Done lines, the
     folded merged children, and the Needs you segment.
   - Task context menus.
3. **Tasks view.**
   - The list, the detail pane, the setup card, and the webhook banner and
     sheet.
   - Arrow keys and Esc.
   - Show Tasks, the palette's Task: actions, and Merge on the current
     task.
4. **Quick entry.**
   - A small window with the Workspace and Agent pickers, attachments
     (drop, paste, Attach), and Create or Send.
   - New Task from Selection in the terminal menu.
   - A global shortcut through the XDG GlobalShortcuts portal, with the
     in-app accelerator and `toastty` CLI as fallbacks.
5. **Coordinator.**
   - Chat over the coordinator's terminal, with Terminal/Chat, Dock and
     the … menu.
   - The dock column, its toggle and Ctrl+Shift+K.
   - The transcript renderer: turns, work strips, tool batches, markdown,
     tables, interaction cards, the New line, Jump to latest and load
     older.
   - The composer: steer, queue and stop, replies, mentions, attachments,
     notices and text scale.
6. **First run.** The What's new sheet and the start offer. The Agent menu
   gets Open and Restart Coordinator.
7. **Docs and tests.** `docs/linux.md`, `docs/tasks.md` Linux notes,
   Broadway tests per surface, and the full Linux gate.

## Linux differences

- Shortcuts follow `LinuxCommandTable`: Ctrl replaces Cmd unless a terminal
  key needs it.
- The quick entry panel cannot float above other apps' full-screen windows
  under Wayland. It is a normal small window.
- PhotosPicker has no Linux equivalent; Files… covers images.
