# Removing the Tasks view, 2026-10-25

Captured on the remote toastty-mini host by the remote checks, through
`sv exec -- scripts/remote/validate.sh --require-remote --scope working-tree --validation-command 'python3 scripts/automation/<check>.py'`.
Each check runs a disposable app instance in automation mode with a fake
coordinator agent. Images are scaled to half size.

- `coordinator-chat.png` (remote-task-stages-check.py): `window.tasks.show`,
  the Tasks view's old action, opens the coordinator chat. The sidebar has the
  Coordinator row, Needs you and Projects; there is no Tasks view.
- `coordinator-chat-typing.png`: keys typed while the chat shows do not reach
  the coordinator's terminal under it.
- `coordinator-terminal.png`: after `toastty coordinator show-terminal`,
  typing reaches the terminal.
- `coordinator-chat-from-shortcut.png`: Cmd+Shift+T opens the chat again.
- `projects-show-more.png` (remote-sidebar-to-ship-check.py): Show 2 more
  lists all five To ship tasks in the sidebar.
- `projects-row-opens-chat.png`: a To ship row opens its task's card in the
  chat.
- `remote-task-merge-1-confirm-merge.png` (remote-task-merge-check.py, with a
  real Codex task agent): Merge on the task's Needs you row asks first; the
  merge then runs through the agent.
- `remote-task-merge-2-to-ship.png`: the merged task is To ship in the
  sidebar.
- `remote-task-merge-4-waiting-for-checks.png`: Merge Without Checks from the
  row's menu waits for a pending check; Cancel Merge from the task space row's
  menu ends the wait.
