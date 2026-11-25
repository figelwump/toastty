# The workspace page and workspace Scratchpads

Date: 2026-11-25. Status: on Linux (`feat/linux-tasks-ui`); the Mac app does
not have it yet. This document is the contract for the macOS implementation.

## Why

A top-level workspace, such as *Bike Fabrication* or *toastty*, holds its
own tabs and its task spaces. Before this change, clicking its card's title in
the Tasks sidebar selected the workspace's own tab. That tab is usually an
idle shell in the project folder, or in `~` for a workspace that
`workspace.create` made without a folder. The user expected to see the
workspace: what it is about, what its tasks did, and what they produced.

Scratchpads made the same problem worse. A task's Scratchpad is the best
record of what the task worked out (plans, mockups, comparisons). Its panel
lives in the task space's tab, which closes when the task merges or is
archived. The document stays on disk, but nothing leads back to it.

## The UI flow

### Opening and leaving the page

| Where | What it does |
|---|---|
| A top-level workspace card's title (Tasks sidebar, All or Needs you) | Selects the workspace and shows its **workspace page** over the workspace content. A second click on the same title returns to the workspace's own tabs. |
| **Show Workspace Page** / **Hide Workspace Page** (command palette) | The same for the selected workspace. A task space means its top-level workspace. |
| The page's **Terminal** button, or Esc | Returns to the workspace's own tabs. |
| Selecting another workspace, a task space row, a session row, another tab, or the Tasks view | Leaves the page. The page is not saved: it shows until something else is selected, and a restart opens the workspace's tabs. |

While the page shows, it covers the workspace content and the right panel, as
the Tasks view does. The tab bar and the window title stay.

### What the page shows

```
┌ Bike Fabrication ─────────────────────── [Terminal] [+ New Task] ┐┌ WORKSPACE SCRATCHPADS   2 ┐
│ ~/Code/bike · 4 tasks · 1 open · 2 Scratchpads                    ││ ▣ Frame jig plan     Live │
│ ┌ ABOUT ─────────────────────────────────────────────────────────┐││   From Order the jig plate │
│ │ Builds the steel jig that holds the swingarm for welding. …    │││ ▣ Weld sequence            │
│ │ Written by an agent · 2h                                       │││   From Plan welds · 3d     │
│ └────────────────────────────────────────────────────────────────┘│├──────────────────── ◫ 🗑 ─┤
│ ┌ RECENTLY ──────────────────────────────────────────────────────┐││ (the selected Scratchpad, │
│ │ ◌ Order the jig plate        Claude · working             now  │││  rendered read-only)      │
│ │   Placed the order with OSH Cut; plate ships Friday. …         │││                           │
│ │ ✓ Plan welds   PR #12        Done                          3d  │││                           │
│ └────────────────────────────────────────────────────────────────┘││                           │
│ ┌ TASKS ─────────────────────────────────────────────────────────┐││                           │
│ │ RUNNING 1  … rows as in the Tasks view …                       │││                           │
│ └────────────────────────────────────────────────────────────────┘││                           │
└───────────────────────────────────────────────────────────────────┘└───────────────────────────┘
```

- **Header:** the workspace's title; its folder (with `~`), the task count,
  the open count and the Scratchpad count; **Terminal** (the workspace's own
  tabs) and **New Task** (quick entry, as the Tasks view's button).
- **About:** the synopsis. An agent writes it with `workspace.synopsis.set`,
  and the caption reads *Written by an agent · <age>*. Without one, Toastty
  makes it from the tasks: *“<title> works in <folder>. It has had N tasks:
  a open and b finished. Latest: “t1”, “t2”, “t3”.”*, with the caption *Made
  from the tasks. Ask an agent to describe this workspace and it writes one
  here.*
- **Recently:** the five tasks with the latest activity, newest first. Each
  row has the task's mark, title, PR tag and status line (as in the Tasks
  view), and what the task did. That is the agent's latest reply as plain
  text, cut to about 360 characters and three lines. Without a reply, it is
  the task's request, prefixed *Asked:*. A click opens the task's space
  when it is open, else the task in the Tasks view.
- **Tasks:** every task of the workspace in the Tasks view's groups (Needs
  you, Ready to review, Running, Idle, To ship, Done, Archived), with Done
  and Archived expanded. Empty groups are left out. A click works as in
  Recently.
- **Workspace Scratchpads** (right column, 380 points): the kept
  Scratchpads, newest kept first. Each row has the title, a green **Live**
  tag while its task is open, *From <task> · updated <age>*, and the
  purpose. With none, the column explains how to keep one. A click selects
  a row, and its document renders below the list, read-only. A double click,
  or the ◫ button, opens it in the workspace's right panel and leaves the
  page. 🗑 asks *Delete “<title>” from This Workspace?* (the workspace's copy
  is deleted; a task that is still open keeps its own Scratchpad).

### Keeping a Scratchpad

- **The pin in the right panel's header** shows while the right panel's
  active tab is a Scratchpad. Its tooltip reads *Keep in Workspace: save
  this Scratchpad on the workspace page, where it stays after the task*. A
  click keeps the Scratchpad and shows the toast *Kept in <workspace>*.
- Once the Scratchpad is kept, the pin is drawn in the accent color and its
  tooltip reads *Kept in Workspace: show it on the workspace page*. A click
  then opens the page with that Scratchpad selected. The pin does the same
  on the workspace's copy.
- **Keep Scratchpad in Workspace** in the command palette does what the pin
  does.
- **Agents** keep one with `workspace.scratchpad.keep` (see below). The
  `toastty-scratchpad` skill tells them to keep a Scratchpad when it
  records something the workspace should remember, such as a decision, a
  plan or a design, and to leave throwaway ones alone.

## The model

A **workspace Scratchpad** is an ordinary Scratchpad document with its own
`documentID` in the Scratchpad document store, plus an entry that says which
workspace keeps it:

| Field | Meaning |
|---|---|
| `documentID` | The workspace's copy. |
| `workspaceID` | The top-level workspace that keeps it. A task space keeps nothing: keeping from a task space keeps in its parent. |
| `projectRoot` | The workspace's project folder when it was kept. A workspace that is closed and opened again gets a new ID; the page also lists entries whose `projectRoot` is its folder. |
| `source.documentID`, `source.workspaceID` | The task's Scratchpad and the workspace whose tab held it. |
| `source.taskID`, `source.taskTitle` | The task, when the source workspace was a task space. |
| `source.syncedRevision` | The source revision the copy last took. |
| `source.linkEndedAt` | When the link ended; nil while it is live. |
| `keptAt`, `keptBy` | When, and by whom: `user`, or an agent's session ID. |

**The link.** While the source's workspace is open (for a task, while its
task space is open), every change to the source copies over: its HTML,
title and purpose. The copy's revision goes up, and an open panel showing
the copy reloads. Copying happens when the source panel's state changes, as
on every `set-content`, `patch-content` and metadata edit, and again before
the page, the list query or an export reads the copy. When the source's
workspace closes, as at merge cleanup, archive or **Close Task Space**, or
when the source document is gone, Toastty copies it one last time and sets
`linkEndedAt`. From then on the copy changes only when it is deleted. The
task's own Scratchpad is never changed by any of this.

**Keeping twice.** Keeping a source that already has a live copy, or keeping
a copy, returns the existing entry (`created: false`). Keeping a source again
after its link ended makes a new copy.

**Synopsis.** One text per top-level workspace (at most 4,000 characters),
with `updatedAt`, the writing session and `projectRoot` (for the same
reopen rule). Empty text clears it.

**Synopsis shape.** The `toastty-task-start` skill has each task's agent
rewrite the synopsis when its task finishes (*Record what the task did*):
two to four sentences on the workspace's purpose and current state, then
`Recent work:` with one line per task, newest first, at most six, naming
each task's pull request number but not its state.

**Task contexts.** When a task finishes, its agent also saves a Markdown
brief for whoever continues the work, with `workspace.task-context.set`:
Goal, What was done, State, Decisions, Remaining, Open questions, Where to
look (at most 8,000 characters). It is kept under the task ID with its time,
session and the task's title.

**Continue as New Task.** A finished task (stage group Done or To ship; not
Archived) offers it in the Tasks view's detail pane (with a **Context** card
that shows the saved context, or the last reply), in the task's menus, and
as **Continue** on the workspace page's Recently rows. It opens quick entry
in the task's top-level workspace with `continues-<slug>.md` attached
(`TaskContinuation`): a heading, the task's link, branch and base, pull
request and merge commit, project folder and kept Scratchpads, the request
as a quote, then the agent's context or, without one, its last saved reply.
The panel's hint reads *Continues “<title>”* while the file is attached.

**Outcomes.** A task's latest agent reply is only readable while its agent
session lives. When the page or `workspace.overview` reads a reply, Toastty
saves the first 1,200 characters under the task ID. Recently can then still
say what the task did after its session ends.

**Storage.** `~/.toastty/workspace-overview.json` (the runtime home's config
directory), written whole and atomically:
`{version: 1, scratchpads: [entry], synopses: {workspaceID: synopsis},
outcomes: {taskID: {text, at}}, contexts: {taskID: {text, at, sessionID,
taskTitle}}}`. A file without one of the keys reads it as empty. Copies live in `scratchpad-documents/`
like every Scratchpad. Deleting removes both the entry and the copy's file.

**Which tasks are the workspace's.** Tasks placed in the workspace
(`TaskBoardItem.projectWorkspaceID` or the record's `workspaceID`), tasks
whose task space is nested under it, and tasks whose `projectRoot` is the
workspace's project folder.

## Agent commands (Linux only for now)

| Command | Kind | Does |
|---|---|---|
| `workspace.scratchpad.keep` (alias `workspace.scratchpad.promote`) | action | Keeps a Scratchpad, named by `panelID`, or by `sessionID` with an optional `documentID` (the session's default otherwise). Returns the entry and `created`. |
| `workspace.scratchpad.list` | query | The workspace's kept Scratchpads with `documentID`, `title`, `purpose`, `revision`, `updatedAt`, `keptAt`, `keptBy`, `linked`, `missing` and `source`. |
| `workspace.scratchpad.export` | action | Writes a copy's HTML to an app-chosen file and returns its `filePath`. |
| `workspace.scratchpad.open` | action | Opens a copy in a workspace's right panel (changes the view; only on the user's request). |
| `workspace.scratchpad.delete` | action | Deletes a copy and closes the panels that show it (only on the user's request). |
| `workspace.synopsis.set` | action | Sets or clears (`text=`) the synopsis. |
| `workspace.task-context.set` | action | Sets or clears (`text=`) a task's context; without `taskID`, the caller's own task. |
| `workspace.task-context` | query | The task's context (`text`, `updatedAt`, `sessionID`) and `continuation`, the file Continue as New Task attaches (`fileName`, `text`, `hasWrittenContext`). |
| `workspace.overview` | query | The page's content: title, `projectRoot`, synopsis with its `source` (`agent` or `toastty`), counts, `recent` with `outcome` and `outcomeSource` (`reply` or `request`), `tasks`, and `scratchpads`. |

A workspace selector that names a task space means its top-level workspace.
A managed agent that names none means its own workspace. Workspace-scoped
sessions can only reach workspaces in their scope.

## Implementing it on macOS

The Linux code splits so the Mac can take most of it:

- **Move to `Sources/App` unchanged.** These files are platform-neutral:
  - `WorkspaceOverviewStore.swift`, `WorkspaceOverviewService.swift` and
    `WorkspaceOverviewModel.swift`, all in
    `linux/Sources/ToasttyAppLogic/WorkspaceOverview/`. They use only
    `AppStore`, `ScratchpadDocumentStore`, `TaskCoordinator` and
    `TaskBoardStore`.
  - `AppControlExecutor+WorkspaceOverview.swift`, which goes next to the
    other executor extensions. Then drop the `#if os(Linux)` around the
    catalog cases and executor dispatch in `AppControlCatalog.swift` and
    `AppControlExecutor.swift`. The file-private helper doors at the end of
    `AppControlExecutor.swift` can go or stay.
- **Create the service** in `ToasttyApp.init` next to the task stack (Linux:
  `LinuxAppLogic`), and set `WorkspaceOverviewService.current`.
- **Mac UI:**
  - The window state: Linux keeps the page in
    `TasksWindowFeature.overviewWorkspaceID`/`overviewTabID` and does not
    persist it. On the Mac, a `@State` in the window's root view, or a
    non-persisted `WindowState` field, does the same. Clear it whenever
    the selected workspace or tab changes or the Tasks view shows.
  - `SidebarView`'s card header `onTapGesture` (around
    `SidebarView.swift:2037`) toggles the page instead of only calling
    `selectWorkspace`.
  - A `WorkspaceOverviewView` (SwiftUI) mirrors `WorkspaceOverviewPage`. It
    reuses `TasksViewSections`, `TaskBoardPresentation.tasksViewStatusLine`,
    `TaskStageMark` and `TaskAge` for the rows, and a `ScratchpadPanelView`
    for the preview, given a `WebPanelState` for the copy with
    `sessionLink: nil`.
  - The pin is a toolbar button in the right panel's Scratchpad header,
    beside the binding chip.
  - Continue as New Task: drop the `#if os(Linux)` around
    `TaskBoardPresentation.MenuItem.continueAsNewTask`,
    `canContinueAsNewTask`, `TaskBoardStore.continueAsNewTask` and their
    cases in `TaskActions` and `RemoteTaskBoardProjection`; handle the case
    in `TasksView.menuButton`; set `board.continueAsNewTask` where the
    service is made (Linux: `LinuxAppLogic`) to call
    `QuickEntryController.presentContinuation`; show *Continues “title”* in
    the quick entry panel while `continuesTaskTitle` is set; add the Context
    card to the detail pane.
- **Skills.** The `toastty-scratchpad` skill's *Keep a Scratchpad in the
  workspace* section says the commands are Linux-only, and
  `toastty-task-start`'s *Record what the task did* runs each step only
  where `toastty action list` lists its command, so a Mac agent skips it
  today. Once the Mac has the commands, the Mac agents start writing with
  no skill change. Make the Scratchpad skill say they apply everywhere. Only
  then mention the IDs in `toastty-capabilities`:
  `SetupResourcesDriftTests` fails on IDs the running platform does not
  know.

## Not in scope

- Editing a copy by hand, renaming it, or binding an agent to a copy. A copy
  can be opened in the right panel and, once it is there, bound like any
  Scratchpad. Keeping a document under the workspace is not the same as
  making it editable.
- A history of everything the workspace's agents did, beyond the tasks'
  last replies.
- Showing the page on the iPhone.
