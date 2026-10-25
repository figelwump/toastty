# Coordinator final end-to-end pass, 2026-10-25

Captured by `scripts/automation/remote-coordinator-final-e2e-check.py` on the
remote toastty-mini host, through
`sv exec -- scripts/remote/validate.sh --require-remote --scope working-tree --validation-command 'python3 scripts/automation/remote-coordinator-final-e2e-check.py'`.
The build was `feat/coordinator` at 3de0a20 plus this branch's fixes. The app
ran a disposable instance in automation mode with a real Claude Code
(2.1.310) coordinator and task agents on the host's subscription. Both
projects had a local bare origin and a fake `gh`, so nothing on GitHub
changed. Images are scaled to half size. Every step passed.

| Step | Capture | What it shows |
| --- | --- | --- |
| 1 | `01-sidebar-opens-chat.png` | The sidebar's Coordinator row opens the chat. Cmd+Shift+T from the project workspace opens it too. |
| 2 | `02-coordinator-creates-task.png` | A request typed in the composer: the coordinator created and started task A. |
| 3 | `03-sidebar-needs-you.png`, `03-sidebar-row-menu.png`, `03-sidebar-opens-packet.png` | A's packet puts it in Needs you with its action and ▾ menu; the row opens the packet card in the chat. |
| 4 | `04-full-report.png`, `04-reply-leaves-needs-you.png`, `04-packet-v2.png` | Full report in the right panel; a reply takes A out of Needs you; v2 adds a card and v1 collapses. |
| 5 | `05-open-pr.png`, `05-sidebar-merge-question.png`, `05-sidebar-merged.png` | Open PR in the right panel; Merge from the sidebar row asks first, then merges at A's commit; A is Done. |
| 6 | `06-card-merge-question.png`, `06-card-merged.png` | Task B merges from its card in the chat. |
| 7 | `07-cmd-shift-t.png` | Cmd+Shift+T from the project workspace, after the merges. |
| 8 | `08-all-tasks.png`, `08-all-tasks-done-open.png`, `08-all-tasks-filtered.png`, `08-all-tasks-selection.png`, `08-return-opens-card.png` | Option+Cmd+T shows All tasks; Done opens; the docs-site filter; Down Arrow; Return opens A's card. |
| 9 | (no capture) | The window has no Tasks view element, and `window.tasks.show` opens the chat. |
| 10 | `10-relaunch-keeps-cards.png` | After the app is killed and relaunched, the chat shows the same cards. |
| 11 | `11-routing.png` | routing.md in the right panel. |

The relaunch kills the app with SIGKILL. The docs-site workspace, opened a
few minutes before, did not come back, so its task shows as closed. The
coordinator's workspace came back with a new ID, and the chat's transcript
starts with the new coordinator session. The cards stay.
