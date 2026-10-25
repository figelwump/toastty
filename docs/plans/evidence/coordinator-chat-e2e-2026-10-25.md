# Coordinator chat end to end, 2026-10-25

Captured by `scripts/automation/remote-coordinator-chat-e2e-check.py` on the
remote toastty-mini host, through
`sv exec -- scripts/remote/validate.sh --require-remote --scope working-tree --validation-command 'python3 scripts/automation/remote-coordinator-chat-e2e-check.py'`.
The app ran a disposable instance in automation mode. A real Claude Code
(2.1.310) coordinator and task agent used the host's subscription. The
project was a throwaway repository with `merge = "direct"`, a local bare
origin, and a fake `gh` that merges by pushing to that origin. Nothing on
GitHub changed. Images are scaled to half size. The run passed every step.

- `e2e-1-chat-ready.png`: the chat over the running coordinator.
- `e2e-1-task-created.png`: after a request typed into the composer, the
  coordinator created and started a task.
- `e2e-2-packet-open.png`: the task published packet v1 with the toastty-task-verify
  skill; its card open.
- `e2e-2-report.png`: Full report in the right panel, before and after at 390.
- `e2e-3-replied.png`: a reply to the task. The task agent got
  "Review note on packet v1: …", and the task left Needs you.
- `e2e-4-packet-v2.png`: packet v2 added a card marked new; v1 collapsed.
- `e2e-5-open-pr.png`: Open PR opened the pull request link in the right
  panel (a 404, since the repository does not exist).
- `e2e-5-merge-confirm.png`: Merge asks first, naming the direct policy.
- `e2e-5-merged.png`: after Merge, the pull request merged at the task's
  commit, the task space and worktree were cleaned up, and the task is Done.
