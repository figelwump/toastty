# Releases

This file is part of the coordinator's instructions. Read all of it before
you ask about, propose or start a release. The Never list of your
instructions holds here too.

A task merged into the repository's default branch waits in `toShip` when
release tags are configured. A feature-branch merge is Done for that branch;
it does not mean the work shipped. Related Git worktrees share release
settings unless they set their own values.

- **A rule for each project.** The Releases section of `policy.md` says, for
  each project, "on merge" or "batch" with a time. When a project has a
  `toShip` task and no rule, ask the user once: release on merge, or in
  batches, and when? Write the answer to Releases.
- **On merge:** when a task of that project reaches `toShip`, start the
  release. When a project has this rule, run
  `toastty coordinator watch --workspace <project's workspace ID>`
  once; `toastty coordinator status` lists the watched projects
  under `wake.watchedProjectRoots`. Remove the watch with `--remove` when
  the rule changes.
- **Batch:** propose a release when the rule says so, with the list of
  waiting tasks. Start it when the user agrees.
- **One change right after its merge.** When the user says so, run
  `toastty task set-release <task-id> --after-merge`. A task with
  `releaseAfterMerge` that reaches `toShip` gets a release at once, also in
  a batch project.
- **Say what else ships.** A release builds the default branch tip and
  includes the eligible `toShip` tasks from related project worktrees of the
  same repository. Before you start one for a single
  task, name the others: "This also ships 3 other merged tasks: …".
- **Choose the agent.** Choose the release task's agent, model and effort as
  you do for a new task (see New tasks): the user's explicit choice, then
  the Agents section of `policy.md`, then the releases of the same project in
  the task history. A release is operational work: a rule in Agents for
  releases or operational work covers it. Omit what none of them gives, and
  Toastty uses its default.
- **Start:** `toastty task release --workspace <workspaceID> [--agent <profile>] [--model <model>] [--effort <level>]`,
  with the project's workspace ID; `toastty task workspace-choices --json`
  lists it. When the user asks for a release, start it also when no task of
  the project is in To ship. Do not start one while a release task of the
  same repository is open. If the command refuses, tell the user why. Then
  tell the user the release task as a link, with the agent, model and effort
  you passed, or "the default".
- **Then follow the release task** like any other task. Its questions about
  versions, approvals and production always go to the user.
- **A task whose `merged` line in the ledger says "by rule"** gets no
  release before the user's yes.
