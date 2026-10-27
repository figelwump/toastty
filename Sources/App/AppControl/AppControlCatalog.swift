import CoreState
import Foundation

enum AppControlActionID: String, CaseIterable, Sendable {
    case windowCreate = "window.create"
    case windowSidebarToggle = "window.sidebar.toggle"
    case workspaceCreate = "workspace.create"
    case workspaceSelect = "workspace.select"
    case workspaceMove = "workspace.move"
    case workspaceRename = "workspace.rename"
    case workspaceSetAnnotation = "workspace.set-annotation"
    case workspaceClearAnnotation = "workspace.clear-annotation"
    case workspaceSetParent = "workspace.set-parent"
    case workspaceSetDone = "workspace.set-done"
    case workspaceClearDone = "workspace.clear-done"
    case workspaceClose = "workspace.close"
    case workspaceTabCreate = "workspace.tab.create"
    case workspaceTabSelect = "workspace.tab.select"
    case workspaceTabMove = "workspace.tab.move"
    case workspaceTabSelectPrevious = "workspace.tab.select-previous"
    case workspaceTabSelectNext = "workspace.tab.select-next"
    case workspaceTabRename = "workspace.tab.rename"
    case workspaceTabClose = "workspace.tab.close"
    case workspaceReopenLastClosedPanel = "workspace.reopen-last-closed-panel"
    case panelFocusNextUnreadOrActive = "panel.focus-next-unread-or-active"
    case workspaceSplitHorizontal = "workspace.split.horizontal"
    case workspaceSplitVertical = "workspace.split.vertical"
    case workspaceSplitRight = "workspace.split.right"
    case workspaceSplitDown = "workspace.split.down"
    case workspaceSplitLeft = "workspace.split.left"
    case workspaceSplitUp = "workspace.split.up"
    case workspaceSplitRightWithProfile = "workspace.split.right.with-profile"
    case workspaceSplitDownWithProfile = "workspace.split.down.with-profile"
    case panelClose = "panel.close"
    case workspaceFocusSlotPrevious = "workspace.focus-slot.previous"
    case workspaceFocusSlotNext = "workspace.focus-slot.next"
    case workspaceFocusSlotLeft = "workspace.focus-slot.left"
    case workspaceFocusSlotRight = "workspace.focus-slot.right"
    case workspaceFocusSlotUp = "workspace.focus-slot.up"
    case workspaceFocusSlotDown = "workspace.focus-slot.down"
    case workspaceFocusPanel = "workspace.focus-panel"
    case workspaceResizeSplitLeft = "workspace.resize-split.left"
    case workspaceResizeSplitRight = "workspace.resize-split.right"
    case workspaceResizeSplitUp = "workspace.resize-split.up"
    case workspaceResizeSplitDown = "workspace.resize-split.down"
    case workspaceEqualizeSplits = "workspace.equalize-splits"
    case panelCreateBrowser = "panel.create.browser"
    case panelBrowserReload = "panel.browser.reload"
    case panelCreateLocalDocument = "panel.create.local-document"
    case panelScratchpadSetContent = "panel.scratchpad.set-content"
    case panelScratchpadPatchContent = "panel.scratchpad.patch-content"
    case panelScratchpadRebind = "panel.scratchpad.rebind"
    case panelScratchpadExport = "panel.scratchpad.export"
    case panelScratchpadUpdateMetadata = "panel.scratchpad.update-metadata"
    case panelScratchpadMakeDefault = "panel.scratchpad.make-default"
    case panelScratchpadUnbind = "panel.scratchpad.unbind"
    case panelLocalDocumentSearchStart = "panel.local-document.search.start"
    case panelLocalDocumentSearchUpdateQuery = "panel.local-document.search.update-query"
    case panelLocalDocumentSearchNext = "panel.local-document.search.next"
    case panelLocalDocumentSearchPrevious = "panel.local-document.search.previous"
    case panelLocalDocumentSearchHide = "panel.local-document.search.hide"
    case panelFocusModeToggle = "panel.focus-mode.toggle"
    case appFontIncrease = "app.font.increase"
    case appFontDecrease = "app.font.decrease"
    case appFontReset = "app.font.reset"
    case appMarkdownTextIncrease = "app.markdown-text.increase"
    case appMarkdownTextDecrease = "app.markdown-text.decrease"
    case appMarkdownTextReset = "app.markdown-text.reset"
    case appBrowserZoomIncrease = "app.browser-zoom.increase"
    case appBrowserZoomDecrease = "app.browser-zoom.decrease"
    case appBrowserZoomReset = "app.browser-zoom.reset"
    case agentLaunch = "agent.launch"
    case configReload = "config.reload"
    case terminalSendText = "terminal.send-text"
    case terminalDropImageFiles = "terminal.drop-image-files"
    case sessionExitAfterTurn = "session.exit-after-turn"
    case taskCreate = "task.create"
    case taskRetry = "task.retry"
    case taskDelete = "task.delete"
    case taskSetWorkspace = "task.set-workspace"
    case taskStartWork = "task.start-work"
    case taskSend = "task.send"
    case taskWatch = "task.watch"
    case taskUnwatch = "task.unwatch"
    case taskMerge = "task.merge"
    case taskCancelMerge = "task.cancel-merge"
    case taskCleanUp = "task.clean-up"
    case taskReadyForReview = "task.ready-for-review"
    case taskPacketPublish = "task.packet.publish"
    case taskPacketGet = "task.packet.get"
    case taskMarkDone = "task.mark-done"
    case taskArchive = "task.archive"
    case taskRelease = "task.release"
    case taskAdopt = "task.adopt"
    case coordinatorPost = "coordinator.post"
    case coordinatorShowTerminal = "coordinator.show-terminal"
    case coordinatorChatShow = "coordinator.chat.show"
    case coordinatorTasksShow = "coordinator.tasks.show"

    static func resolve(_ rawValue: String) -> Self? {
        if let action = Self(rawValue: rawValue) {
            return action
        }
        return allCases.first { $0.aliases.contains(rawValue) }
    }

    var aliases: [String] {
        switch self {
        case .windowSidebarToggle:
            return ["window.toggle-sidebar"]
        case .workspaceCreate:
            return ["sidebar.workspaces.new"]
        case .workspaceTabCreate:
            return ["workspace.tab.new"]
        case .panelFocusNextUnreadOrActive:
            return ["workspace.focus-next-unread-or-active"]
        case .panelClose:
            return ["workspace.close-focused-panel"]
        case .panelCreateLocalDocument:
            return ["panel.create.localDocument", "panel.create.markdown"]
        case .panelScratchpadSetContent:
            return ["panel.scratchpad.setContent"]
        case .panelScratchpadPatchContent:
            return ["panel.scratchpad.patchContent"]
        case .panelScratchpadRebind:
            return ["panel.scratchpad.bind"]
        case .panelLocalDocumentSearchStart:
            return ["panel.markdown.search.start"]
        case .panelLocalDocumentSearchUpdateQuery:
            return ["panel.markdown.search.update-query"]
        case .panelLocalDocumentSearchNext:
            return ["panel.markdown.search.next"]
        case .panelLocalDocumentSearchPrevious:
            return ["panel.markdown.search.previous"]
        case .panelLocalDocumentSearchHide:
            return ["panel.markdown.search.hide"]
        case .panelFocusModeToggle:
            return ["topbar.toggle.focused-panel"]
        case .coordinatorChatShow:
            // The coordinator chat replaced the Tasks view.
            return ["window.tasks.show", "window.tasks.hide"]
        case .appMarkdownTextIncrease:
            return ["app.markdown_text.increase"]
        case .appMarkdownTextDecrease:
            return ["app.markdown_text.decrease"]
        case .appMarkdownTextReset:
            return ["app.markdown_text.reset"]
        case .appBrowserZoomIncrease:
            return ["app.browser_zoom.increase"]
        case .appBrowserZoomDecrease:
            return ["app.browser_zoom.decrease"]
        case .appBrowserZoomReset:
            return ["app.browser_zoom.reset"]
        default:
            return []
        }
    }

    var descriptor: AppControlCommandDescriptor {
        switch self {
        case .windowCreate:
            return .init(id: rawValue, kind: .action, summary: "Create a new window.", selectors: [.windowID])
        case .windowSidebarToggle:
            return .init(id: rawValue, kind: .action, summary: "Toggle sidebar visibility for a window.", selectors: [.windowID], aliases: aliases)
        case .workspaceCreate:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Create a workspace in a window. When a managed session calls this, the new workspace nests under the caller's workspace as a task space unless parent=none.",
                selectors: [.windowID],
                parameters: [.title(required: false), .activate(required: false), .workspaceParent(required: false)],
                aliases: aliases
            )
        case .workspaceSelect:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Change the user's visible workspace by ID or 1-based index. Use only for user-authorized navigation, not inspection or verification.",
                selectors: [.windowID, .workspaceID],
                parameters: [
                    .index(summary: "1-based workspace index in the target window.", required: false),
                    .focusUnreadSessionPanel(required: false),
                ]
            )
        case .workspaceMove:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Move a workspace from one 1-based index to another within the target window.",
                selectors: [.windowID],
                parameters: [
                    .index(summary: "1-based source workspace index in the target window.", required: true),
                    .toIndex(summary: "1-based destination workspace index in the target window.", required: true),
                ]
            )
        case .workspaceRename:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Rename a workspace.",
                selectors: [.windowID, .workspaceID],
                parameters: [.title(required: true)]
            )
        case .workspaceSetAnnotation:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Set or update a structured annotation chip under a workspace name.",
                selectors: [.windowID, .workspaceID],
                parameters: [
                    .annotationKey(required: true),
                    .annotationText(required: true),
                    .annotationURL(required: false),
                    .annotationColor(required: false),
                    .annotationPrimary(required: false),
                ]
            )
        case .workspaceClearAnnotation:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Remove a workspace annotation chip by key.",
                selectors: [.windowID, .workspaceID],
                parameters: [.annotationKey(required: true)]
            )
        case .workspaceSetParent:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Nest a workspace under a top-level workspace in the same window as a task space, or detach it with parent=none. Nesting stays one level deep, so a parent that is itself a task space resolves to its root.",
                selectors: [.windowID, .workspaceID],
                parameters: [.workspaceParent(required: true)]
            )
        case .workspaceSetDone:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Mark a task space's task done, shown as a check on its row. Targets the calling agent's own workspace when no workspace is given; a top-level workspace is rejected. An agent in the workspace starting new work clears the mark.",
                selectors: [.windowID, .workspaceID]
            )
        case .workspaceClearDone:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Clear a workspace's done mark. Targets the calling agent's own workspace when no workspace is given.",
                selectors: [.windowID, .workspaceID]
            )
        case .workspaceClose:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Close a workspace. Its task spaces stay open as top-level workspaces.",
                selectors: [.windowID, .workspaceID],
                parameters: [.init(
                    name: "requireDone",
                    summary: "true to refuse unless the workspace is still marked done: new work since the mark was set clears it.",
                    valueType: .boolean,
                    required: false
                )]
            )
        case .workspaceTabCreate:
            return .init(id: rawValue, kind: .action, summary: "Create a terminal tab and return workspaceID, tabID and panelID. Managed callers default to their own workspace.", selectors: [.windowID, .workspaceID], parameters: [.terminalCreationActivation(required: false)], aliases: aliases)
        case .workspaceTabSelect:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Change the selected workspace tab by ID or 1-based index. Use only for user-authorized navigation, not inspection or verification.",
                selectors: [.windowID, .workspaceID],
                parameters: [.tabID(required: false), .index(summary: "1-based tab index in the target workspace.", required: false)]
            )
        case .workspaceTabMove:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Move a tab from one 1-based index to another within the target workspace.",
                selectors: [.windowID, .workspaceID],
                parameters: [
                    .index(summary: "1-based source tab index in the target workspace.", required: true),
                    .toIndex(summary: "1-based destination tab index in the target workspace.", required: true),
                ]
            )
        case .workspaceTabSelectPrevious:
            return .init(id: rawValue, kind: .action, summary: "Change the selected tab to the previous tab in the target workspace. Use only for user-authorized navigation.", selectors: [.windowID, .workspaceID])
        case .workspaceTabSelectNext:
            return .init(id: rawValue, kind: .action, summary: "Change the selected tab to the next tab in the target workspace. Use only for user-authorized navigation.", selectors: [.windowID, .workspaceID])
        case .workspaceTabRename:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Rename the selected or explicit tab.",
                selectors: [.windowID, .workspaceID],
                parameters: [.tabID(required: false), .index(summary: "1-based tab index in the target workspace.", required: false), .title(required: true)]
            )
        case .workspaceTabClose:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Close the selected or explicit tab.",
                selectors: [.windowID, .workspaceID],
                parameters: [.tabID(required: false), .index(summary: "1-based tab index in the target workspace.", required: false)]
            )
        case .workspaceReopenLastClosedPanel:
            return .init(id: rawValue, kind: .action, summary: "Reopen the most recently closed panel.", selectors: [.windowID, .workspaceID])
        case .panelFocusNextUnreadOrActive:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Foreground navigation: focus the next unread or active session panel, possibly switching workspace, tab, or window.",
                selectors: [.windowID],
                aliases: aliases
            )
        case .workspaceSplitHorizontal:
            return terminalSplitDescriptor(summary: "Create a terminal split horizontally.")
        case .workspaceSplitVertical:
            return terminalSplitDescriptor(summary: "Create a terminal split vertically.")
        case .workspaceSplitRight:
            return terminalSplitDescriptor(summary: "Create a terminal split to the right.")
        case .workspaceSplitDown:
            return terminalSplitDescriptor(summary: "Create a terminal split downward.")
        case .workspaceSplitLeft:
            return terminalSplitDescriptor(summary: "Create a terminal split to the left.")
        case .workspaceSplitUp:
            return terminalSplitDescriptor(summary: "Create a terminal split upward.")
        case .workspaceSplitRightWithProfile:
            return terminalSplitDescriptor(summary: "Split right with a terminal profile.", withProfile: true)
        case .workspaceSplitDownWithProfile:
            return terminalSplitDescriptor(summary: "Split down with a terminal profile.", withProfile: true)
        case .panelClose:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Close the focused panel without interactive confirmation.",
                selectors: [.windowID, .workspaceID],
                parameters: [.terminateRunningProcess(required: false)],
                aliases: aliases
            )
        case .workspaceFocusSlotPrevious:
            return .init(id: rawValue, kind: .action, summary: "Focus the previous slot.", selectors: [.windowID, .workspaceID])
        case .workspaceFocusSlotNext:
            return .init(id: rawValue, kind: .action, summary: "Focus the next slot.", selectors: [.windowID, .workspaceID])
        case .workspaceFocusSlotLeft:
            return .init(id: rawValue, kind: .action, summary: "Focus the slot to the left.", selectors: [.windowID, .workspaceID])
        case .workspaceFocusSlotRight:
            return .init(id: rawValue, kind: .action, summary: "Focus the slot to the right.", selectors: [.windowID, .workspaceID])
        case .workspaceFocusSlotUp:
            return .init(id: rawValue, kind: .action, summary: "Focus the slot above.", selectors: [.windowID, .workspaceID])
        case .workspaceFocusSlotDown:
            return .init(id: rawValue, kind: .action, summary: "Focus the slot below.", selectors: [.windowID, .workspaceID])
        case .workspaceFocusPanel:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Foreground navigation: focus a panel by panel ID within the target workspace and select the tab containing it. Use only for user-authorized navigation, not inspection or verification.",
                selectors: [.windowID, .workspaceID],
                parameters: [.panelID(required: true)]
            )
        case .workspaceResizeSplitLeft:
            return .init(id: rawValue, kind: .action, summary: "Resize the focused split to the left.", selectors: [.windowID, .workspaceID], parameters: [.amount(required: false)])
        case .workspaceResizeSplitRight:
            return .init(id: rawValue, kind: .action, summary: "Resize the focused split to the right.", selectors: [.windowID, .workspaceID], parameters: [.amount(required: false)])
        case .workspaceResizeSplitUp:
            return .init(id: rawValue, kind: .action, summary: "Resize the focused split upward.", selectors: [.windowID, .workspaceID], parameters: [.amount(required: false)])
        case .workspaceResizeSplitDown:
            return .init(id: rawValue, kind: .action, summary: "Resize the focused split downward.", selectors: [.windowID, .workspaceID], parameters: [.amount(required: false)])
        case .workspaceEqualizeSplits:
            return .init(id: rawValue, kind: .action, summary: "Equalize split ratios in the target workspace.", selectors: [.windowID, .workspaceID])
        case .panelCreateBrowser:
            return .init(id: rawValue, kind: .action, summary: "Create a browser panel.", selectors: [.windowID, .workspaceID], parameters: [.placement(required: false), .url(required: false)])
        case .panelCreateLocalDocument:
            return .init(id: rawValue, kind: .action, summary: "Open a local document panel.", selectors: [.windowID, .workspaceID], parameters: [.filePath(required: true), .placement(required: false)], aliases: aliases)
        case .panelScratchpadSetContent:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Create or update a session Scratchpad. documentID selects a bound document; omit it to use the default.",
                selectors: [],
                parameters: [
                    .sessionID(required: true),
                    .scratchpadDocumentID(required: false),
                    .filePath(summary: "HTML file to render in the session Scratchpad.", required: false),
                    .content(required: false),
                    .title(required: false),
                    .scratchpadPurpose(required: false),
                    .expectedRevision(required: false),
                    .scratchpadCreatePolicy(required: false),
                ],
                aliases: aliases
            )
        case .panelScratchpadPatchContent:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Patch a bound Scratchpad by documentID, or the session default when omitted.",
                selectors: [],
                parameters: [
                    .sessionID(required: true),
                    .scratchpadDocumentID(required: false),
                    .patch(required: true),
                    .expectedRevision(required: true),
                ],
                aliases: aliases
            )
        case .panelScratchpadRebind:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Rebind a Scratchpad panel to another active managed session in the same workspace tab.",
                selectors: [.windowID, .workspaceID, .panelID],
                parameters: [.sessionID(required: true)],
                aliases: aliases
            )
        case .panelScratchpadExport:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Export Scratchpad HTML to an app-chosen local file path.",
                selectors: [.windowID, .workspaceID, .panelID],
                parameters: [.sessionID(required: false), .scratchpadDocumentID(required: false)]
            )
        case .panelScratchpadUpdateMetadata:
            return .init(
                id: rawValue, kind: .action,
                summary: "Edit a bound Scratchpad title or purpose without replacing HTML. Empty values clear metadata; omitted values are preserved.",
                selectors: [],
                parameters: [.sessionID(required: true), .scratchpadDocumentID(required: true), .title(required: false), .scratchpadPurpose(required: false), .expectedRevision(required: false)]
            )
        case .panelScratchpadMakeDefault:
            return .init(
                id: rawValue, kind: .action, summary: "Make a bound Scratchpad the default for session-only commands.",
                selectors: [], parameters: [.sessionID(required: true), .scratchpadDocumentID(required: true)]
            )
        case .panelScratchpadUnbind:
            return .init(
                id: rawValue, kind: .action, summary: "Remove a session binding while keeping the Scratchpad open and its content saved.",
                selectors: [], parameters: [.sessionID(required: true), .scratchpadDocumentID(required: true)]
            )
        case .panelLocalDocumentSearchStart:
            return .init(id: rawValue, kind: .action, summary: "Show find for a local-document panel.", selectors: [.windowID, .workspaceID, .panelID], aliases: aliases)
        case .panelLocalDocumentSearchUpdateQuery:
            return .init(id: rawValue, kind: .action, summary: "Update the active local-document find query.", selectors: [.windowID, .workspaceID, .panelID], parameters: [.query(required: true)], aliases: aliases)
        case .panelLocalDocumentSearchNext:
            return .init(id: rawValue, kind: .action, summary: "Advance to the next local-document find match.", selectors: [.windowID, .workspaceID, .panelID], aliases: aliases)
        case .panelLocalDocumentSearchPrevious:
            return .init(id: rawValue, kind: .action, summary: "Move to the previous local-document find match.", selectors: [.windowID, .workspaceID, .panelID], aliases: aliases)
        case .panelLocalDocumentSearchHide:
            return .init(id: rawValue, kind: .action, summary: "Hide find for a local-document panel.", selectors: [.windowID, .workspaceID, .panelID], aliases: aliases)
        case .panelFocusModeToggle:
            return .init(id: rawValue, kind: .action, summary: "Toggle focused panel mode.", selectors: [.windowID, .workspaceID], aliases: aliases)
        case .appFontIncrease:
            return .init(id: rawValue, kind: .action, summary: "Increase terminal font size for a window.", selectors: [.windowID])
        case .appFontDecrease:
            return .init(id: rawValue, kind: .action, summary: "Decrease terminal font size for a window.", selectors: [.windowID])
        case .appFontReset:
            return .init(id: rawValue, kind: .action, summary: "Reset terminal font size for a window.", selectors: [.windowID])
        case .appMarkdownTextIncrease:
            return .init(id: rawValue, kind: .action, summary: "Increase local-document text scale for a window.", selectors: [.windowID], aliases: aliases)
        case .appMarkdownTextDecrease:
            return .init(id: rawValue, kind: .action, summary: "Decrease local-document text scale for a window.", selectors: [.windowID], aliases: aliases)
        case .appMarkdownTextReset:
            return .init(id: rawValue, kind: .action, summary: "Reset local-document text scale for a window.", selectors: [.windowID], aliases: aliases)
        case .panelBrowserReload:
            return .init(id: rawValue, kind: .action, summary: "Reload a browser without changing selection or focus. Requires panelID; completion is reported by panel.browser.state.", selectors: [.panelID])
        case .appBrowserZoomIncrease:
            return .init(id: rawValue, kind: .action, summary: "Increase browser zoom for a browser panel.", selectors: [.windowID, .workspaceID, .panelID], aliases: aliases)
        case .appBrowserZoomDecrease:
            return .init(id: rawValue, kind: .action, summary: "Decrease browser zoom for a browser panel.", selectors: [.windowID, .workspaceID, .panelID], aliases: aliases)
        case .appBrowserZoomReset:
            return .init(id: rawValue, kind: .action, summary: "Reset browser zoom for a browser panel.", selectors: [.windowID, .workspaceID, .panelID], aliases: aliases)
        case .agentLaunch:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Launch an agent profile into a terminal without changing selection or keyboard focus. Managed callers default to their own workspace and tab. Prefer the panelID returned by creation.",
                selectors: [.windowID, .workspaceID, .panelID],
                parameters: [
                    .profileID(required: true),
                    .tabID(required: false),
                    .cwd(required: false),
                    .environment(required: false),
                    .model(required: false),
                    .reasoningEffort(required: false),
                    .initialCommands(required: false),
                    .initialPrompt(required: false),
                    .forkFromSessionID(required: false),
                    .additionalDirectories(required: false),
                ]
            )
        case .configReload:
            return .init(id: rawValue, kind: .action, summary: "Reload Toastty configuration and profiles.", selectors: [])
        case .terminalSendText:
            return .init(id: rawValue, kind: .action, summary: "Send text to a terminal panel, optionally only when it still hosts an expected managed session.", selectors: [.windowID, .workspaceID, .panelID], parameters: [.text(required: true), .submit(required: false), .expectedSessionID(required: false), .allowUnavailable(required: false)])
        case .terminalDropImageFiles:
            return .init(id: rawValue, kind: .action, summary: "Drop local files into a terminal panel.", selectors: [.windowID, .workspaceID, .panelID], parameters: [.files(required: true), .cwd(required: false), .allowUnavailable(required: false)])
        case .sessionExitAfterTurn:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "When the running turn of the panel's managed Claude Code or Codex session completes, type the agent's native /exit. Skipped if anyone typed into the session or sent it a phone message during the turn, or if the turn ends without completing. Requires the session to be in a running turn in a top-level workspace; sessions in task spaces are refused.",
                selectors: [.windowID, .workspaceID, .panelID],
                parameters: [.expectedSessionID(required: true)]
            )
        case .taskCreate:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Create a task. Toastty saves it, makes a task space under the workspace, and starts the agent there with the prompt, the text as written and the attached files. With startWork=true, the agent starts in a new git worktree instead of the project directory. With fork=true, from a Claude Code or Codex session, the agent starts as a fork of the caller's conversation once the caller's turn ends; the caller keeps running. Returns taskID at once, while setup continues; poll task.get for its state. workspace defaults to the calling agent's workspace. [defaults] in ~/.toastty/tasks.toml fills an agent, model or effort the request leaves out. A task with no workspace waits in Needs you until one is picked with task.set-workspace. Optional: when [triage] in tasks.toml has a command, it first chooses the workspace, agent, model, effort and first prompt the request leaves out. A repeated clientRequestID from the same caller returns the first task.",
                selectors: [],
                parameters: [
                    .taskText(required: false),
                    .taskFiles(required: false),
                    .taskClientRequestID(required: false),
                    .taskTitle(required: false),
                    .taskSlug(required: false),
                    .taskWorkspace(required: false),
                    .taskAgent(required: false),
                    .taskModel(required: false),
                    .taskEffort(required: false),
                    .taskPrompt(required: false),
                    .taskStartWork(required: false),
                    .taskBase(required: false),
                    .taskBranchPrefix(required: false),
                    .taskFork(required: false),
                ]
            )
        case .taskStartWork:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Move the calling agent's task into its own git worktree. Toastty fetches the base, adds the worktree next to the main checkout on branch <prefix>/<slug>, and runs the workspace's create_hook. Once the caller's turn ends, it forks the caller's Claude Code or Codex conversation into a new terminal in the worktree, waits for the fork's own conversation, then closes the caller's pane. Other agents start fresh there and the caller stays. Returns taskID at once; end the turn so the move can continue. From a session that is not a task's, it makes the task first: a top-level workspace gets a new task space.",
                selectors: [],
                parameters: [
                    .taskBase(required: false),
                    .taskBranchPrefix(required: false),
                    .taskTitle(required: false),
                    .taskSlug(required: false),
                ]
            )
        case .taskRetry:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Run setup again for a task whose setup failed, or a move into a worktree that failed. It continues from the last step that finished. A task that still needs a workspace or an agent fills them again: from triage when [triage] has a command, otherwise from [defaults], and without a workspace it waits for one.",
                selectors: [],
                parameters: [.taskID(required: true)]
            )
        case .taskDelete:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Delete a task and its attachments and stop its setup. A task space that setup made is closed if nothing used it; otherwise it stays without its task link.",
                selectors: [],
                parameters: [.taskID(required: true)]
            )
        case .taskSetWorkspace:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Place a task that has not started in a workspace: an open one (workspace), a recently closed one (recentWorkspace, from task.workspace-choices), which Toastty opens again, or a project directory (rootDirectory), which Toastty opens as a new workspace unless the project is open. [defaults], or triage when it is on, then fills anything else the task still needs, and setup starts.",
                selectors: [],
                parameters: [
                    .taskID(required: true),
                    .taskWorkspace(required: false),
                    .taskRecentWorkspace(required: false),
                    .taskRootDirectory(required: false),
                ]
            )
        case .taskSend:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Type a message into a task's agent and submit it. Toastty finds the task's current agent session when it delivers, so the task ID keeps working after a relaunch, a fork or start-work. A busy agent queues the message as typed input. Fails when the task has no running agent. Any unscoped caller may send to any task; a workspace-scoped session only to tasks it may see in task.list.",
                selectors: [],
                parameters: [.taskID(required: true), .taskMessage(required: true)]
            )
        case .taskWatch:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Be told once when a task reaches a condition. When it holds, Toastty sends a one-line message to the notified task's agent, as task.send does, so a waiting agent can end its turn instead of polling. idle means the agent finished a turn after the watch was made; waiting means it waits for an approval or an answer; a stage condition (ready-for-review, merged, to-ship, done) holds once task.get's stage reaches it and stays true after the task moves past it; archived holds only for an archived task. notifyTaskID defaults to the calling agent's own task. With wait=true, nothing is notified: the watch is kept in memory for a caller that polls task.watches, as toastty task watch --wait does. Saved watches survive a relaunch. A watch whose task is deleted or archived fires with that reason.",
                selectors: [],
                parameters: [.taskID(required: true), .taskWatchCondition(required: true), .taskNotifyTaskID(required: false), .taskWatchWait(required: false)]
            )
        case .taskUnwatch:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Cancel a watch made with task.watch.",
                selectors: [],
                parameters: [.taskWatchID(required: true)]
            )
        case .taskMerge:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Merge a task's pull request: what a merge skill calls once its checks pass. It records the user's acceptance and hands the merge to Toastty's merge owner, then returns. Toastty merges at the checkout's commit with GitHub's merge API (never auto-merge), waits for checks that still run, and after the agent's turn ends closes the task space, removes the worktree and deletes the branch. With head, it refuses unless the checkout is still at that commit. Without taskID, a task's agent merges its own task. Refused after the user cancelled the merge, for the agent turn that was checking it.",
                selectors: [],
                parameters: [.taskID(required: false), .taskHead(required: false)]
            )
        case .taskCancelMerge:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Stop a merge the user accepted while the task's agent checks it or Toastty waits for GitHub's checks. Clears the acceptance and the task space's done mark. Refused while Toastty is merging or after the pull request merged.",
                selectors: [],
                parameters: [.taskID(required: false)]
            )
        case .taskCleanUp:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Try again a cleanup that stopped: after a merge (\"Merged · clean up?\"), an archive, or a release.",
                selectors: [],
                parameters: [.taskID(required: true)]
            )
        case .taskReadyForReview:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Mark a task's work, which has no pull request, ready for the user to review. The task waits in Needs you until the user marks it done. Without taskID, a task's agent marks its own task.",
                selectors: [],
                parameters: [.taskID(required: false)]
            )
        case .taskPacketPublish:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Publish the next version of a task's review packet: summary, look_at (the one thing to check first), checks [{name, ok, log}], not_verified (what was not checked; [] must be written out) and screenshots [{name, pair before|after|null, width}]. Refuses a packet without summary, look_at or not_verified, with an unknown key, or whose screenshots do not match the given files by name. Toastty copies the screenshots, stores the packet under ~/.toastty/task-packets/<task-id>/v<N>/ with the worktree's commit, and marks the task ready for review, as task.ready-for-review does. Without taskID, a task's agent publishes for its own task.",
                selectors: [],
                parameters: [
                    .taskID(required: false),
                    .init(name: "packet", summary: "The packet, as a JSON object or its text.", valueType: .string, required: true),
                    .init(name: "screenshots", summary: "Absolute path of a screenshot the packet names; its file name without the extension is the screenshot's name. Repeat for more.", valueType: .string, required: false, repeatable: true),
                ]
            )
        case .taskPacketGet:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Return a task's review packet, the newest unless version names an older one, with each screenshot's stored path, latestVersion, the worktree's currentHead, and stale: true when commits landed in the worktree after the newest packet was published. Changes nothing; it is an action because it reads git. Without taskID, a task's agent reads its own task's packet.",
                selectors: [],
                parameters: [
                    .taskID(required: false),
                    .init(name: "version", summary: "Packet version to read, from 1.", valueType: .integer, required: false),
                ]
            )
        case .taskMarkDone:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Finish a task without a merge. Its task space gets the done mark too; new work there clears that mark again.",
                selectors: [],
                parameters: [.taskID(required: true)]
            )
        case .taskArchive:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Close a task without merging. Checks first and refuses with the reason: unsaved documents, a merge under way, uncommitted changes without discardChanges, or a detached worktree whose commit is on no remote branch or tag without deleteUnpushedCommits. Then, in the background and each step saved: closes the pull request only with closePullRequest, closes the task space, removes the worktree, and deletes the local branch when the remote has all its commits (or with deleteUnpushedCommits). The remote branch stays. Running it again continues a stopped archive.",
                selectors: [],
                parameters: [
                    .taskID(required: true),
                    .init(name: "closePullRequest", summary: "true also closes the task's pull request on GitHub.", valueType: .boolean, required: false),
                    .init(name: "deleteUnpushedCommits", summary: "true deletes the local branch, or a detached worktree, even with commits no remote has.", valueType: .boolean, required: false),
                    .init(name: "discardChanges", summary: "true removes the worktree even with uncommitted changes.", valueType: .boolean, required: false),
                ]
            )
        case .taskRelease:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Start a release task for a project that tasks.toml gives a release_skill or a release_prompt. Toastty fetches the remote's default branch (the fetch must succeed) and starts the default agent in a new worktree on no branch at that commit. Its first message names release_skill, then release_prompt, then the project's To ship tasks. Release tags matching release_tags mark tasks shipped. Uses the given workspace's project, or the calling agent's.",
                selectors: [.windowID, .workspaceID]
            )
        case .taskAdopt:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Give a task space without a task record one, so Toastty tracks it as a task: its stage, its pull request, and its Done history after it closes. Targets the calling agent's own workspace when no workspace is given; a top-level workspace is rejected. Returns the existing task when it has one.",
                selectors: [.windowID, .workspaceID]
            )
        case .coordinatorPost:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Post to the coordinator's chat: kind packet (a task published a review packet), task-started, question or note. Every kind but note names its task; question and note need text. A note with a task goes into that task's card thread. Toastty saves each event in coordinator/events.jsonl. Only the coordinator's own session, or a caller outside any agent session, may post.",
                selectors: [],
                parameters: [
                    .init(
                        name: "kind",
                        summary: "packet, task-started, question or note.",
                        valueType: .string,
                        required: true,
                        allowedValues: CoordinatorEvent.Kind.postingKinds.map(\.rawValue)
                    ),
                    .taskID(required: false),
                    .init(name: "text", summary: "What the card says, up to \(CoordinatorEvent.maximumTextLength) characters.", valueType: .string, required: false),
                    .init(name: "options", summary: "A question's answer choice. At most \(CoordinatorEvent.maximumOptionCount) different, nonempty choices, each up to \(CoordinatorEvent.maximumOptionLength) characters after trimming. Repeat for more.", valueType: .string, required: false, repeatable: true),
                ]
            )
        case .coordinatorShowTerminal:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Show the coordinator's terminal: select its hidden workspace in the window that holds it, with the raw terminal instead of the chat. Fails while the coordinator workspace does not exist.",
                selectors: []
            )
        case .coordinatorChatShow:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Show the coordinator chat: select the coordinator workspace, with the chat over its terminal and its right panel beside it. With taskID, the chat opens and scrolls to that task's newest card when that is a question, else its newest packet card, else its last card. Fails while the coordinator workspace does not exist. window.tasks.show and window.tasks.hide, from before the chat replaced the Tasks view, run it too.",
                selectors: [],
                parameters: [.taskID(required: false)],
                aliases: aliases
            )
        case .coordinatorTasksShow:
            return .init(
                id: rawValue,
                kind: .action,
                summary: "Show All tasks in the coordinator workspace's right panel beside the chat. With group, that group opens with its first row selected. Project selects the window's shared project filter by project root or unique title. Fails while the coordinator workspace does not exist.",
                selectors: [],
                parameters: [
                    .init(
                        name: "group",
                        summary: "Stage group to open and select in.",
                        valueType: .string,
                        required: false,
                        allowedValues: TaskStage.Group.allCases.map(CoordinatorAllTasks.groupID)
                    ),
                    .init(name: "project", summary: "Project root or unique project title to show. Needs group.", valueType: .string, required: false),
                ]
            )
        }
    }

    private func terminalSplitDescriptor(summary: String, withProfile: Bool = false) -> AppControlCommandDescriptor {
        .init(
            id: rawValue,
            kind: .action,
            summary: summary + " Uses panelID as the source, or the target tab's focused slot. Managed callers default to their own workspace and tab. Returns workspaceID, tabID and panelID.",
            selectors: [.windowID, .workspaceID, .panelID],
            parameters: [.tabID(required: false), .terminalCreationActivation(required: false)] +
                (withProfile ? [.profileID(required: true)] : [])
        )
    }
}

enum AppControlQueryID: String, CaseIterable, Sendable {
    case annotationKeys = "annotation.keys"
    case workspaceList = "workspace.list"
    case workspaceSnapshot = "workspace.snapshot"
    case terminalState = "terminal.state"
    case terminalVisibleText = "terminal.visible-text"
    case panelLocalDocumentState = "panel.local-document.state"
    case panelBrowserState = "panel.browser.state"
    case panelScratchpadLookup = "panel.scratchpad.lookup"
    case panelScratchpadList = "panel.scratchpad.list"
    case panelScratchpadState = "panel.scratchpad.state"
    case agentProfileState = "agent.profile.state"
    case taskGet = "task.get"
    case taskList = "task.list"
    case taskWorkspaceChoices = "task.workspace-choices"
    case taskWatches = "task.watches"
    case coordinatorStatus = "coordinator.status"
    case coordinatorChatState = "coordinator.chat.state"

    static func resolve(_ rawValue: String) -> Self? {
        if let query = Self(rawValue: rawValue) {
            return query
        }
        return allCases.first { $0.aliases.contains(rawValue) }
    }

    var aliases: [String] {
        switch self {
        case .panelLocalDocumentState:
            return ["panel.markdown.state"]
        case .panelScratchpadState:
            return ["panel.scratchpadState"]
        case .panelScratchpadLookup:
            return ["panel.scratchpadLookup"]
        default:
            return []
        }
    }

    var descriptor: AppControlCommandDescriptor {
        switch self {
        case .annotationKeys:
            return .init(
                id: rawValue,
                kind: .query,
                summary: "Return runtime-global workspace annotation keys previously registered in this Toastty instance.",
                selectors: []
            )
        case .workspaceList:
            return .init(
                id: rawValue,
                kind: .query,
                summary: "List workspaces in window order with titles, annotations, done marks, terminal working directories, active agent sessions, busy terminal and unsaved document counts, without selecting or focusing anything. Workspace-scoped callers see only workspaces in their scope.",
                selectors: [.windowID]
            )
        case .workspaceSnapshot:
            return .init(id: rawValue, kind: .query, summary: "Return workspace structure, task space links, done mark, and tab metadata without selecting the workspace or changing focus. Panel details cover its selected tab.", selectors: [.windowID, .workspaceID])
        case .terminalState:
            return .init(id: rawValue, kind: .query, summary: "Return terminal state metadata.", selectors: [.windowID, .workspaceID, .panelID])
        case .terminalVisibleText:
            return .init(
                id: rawValue,
                kind: .query,
                summary: "Return the text in a terminal panel, including another terminal in the same workspace. Reads by other sessions are shown to the user and can be denied per panel.",
                selectors: [.windowID, .workspaceID, .panelID],
                parameters: [.contains(required: false), .tail(required: false), .includeScrollback(required: false)]
            )
        case .panelLocalDocumentState:
            return .init(id: rawValue, kind: .query, summary: "Return local-document panel state.", selectors: [.windowID, .workspaceID, .panelID], aliases: aliases)
        case .panelBrowserState:
            return .init(id: rawValue, kind: .query, summary: "Return browser navigation status and host attachment state without selecting or focusing the panel. May create its runtime and start loading in the background; host ready is not navigation success.", selectors: [.windowID, .workspaceID, .panelID])
        case .panelScratchpadLookup:
            return .init(
                id: rawValue,
                kind: .query,
                summary: "Return metadata for a bound Scratchpad by documentID, or the session default, without exporting content.",
                selectors: [],
                parameters: [.sessionID(required: true), .scratchpadDocumentID(required: false)],
                aliases: aliases
            )
        case .panelScratchpadList:
            return .init(
                id: rawValue, kind: .query,
                summary: "List an active session's bound open Scratchpads with titles, purposes, revisions and default status without changing selection or focus.",
                selectors: [], parameters: [.sessionID(required: true)]
            )
        case .panelScratchpadState:
            return .init(id: rawValue, kind: .query, summary: "Return Scratchpad panel state.", selectors: [.windowID, .workspaceID, .panelID], aliases: aliases)
        case .agentProfileState:
            return .init(
                id: rawValue,
                kind: .query,
                summary: "Return the executable an agent profile would run, resolved in the launch environment and skipping Toastty's command shims. Launches no agent and starts no shell; omits the profile's arguments.",
                selectors: [],
                parameters: [.profileID(required: true)]
            )
        case .taskGet:
            return .init(
                id: rawValue,
                kind: .query,
                summary: "Return one task: its text, title, chosen workspace, agent, model, effort and first prompt, setup state (routing while Toastty fills what the task left out, needsWorkspace with a reason, settingUp, setupFailed with a reason, or started), triageNote when triage did not answer in full, task space, agentState (notRunning, busy, waiting, idle or error, with the session and when its status last changed), and lastReply: the agent's latest message from its transcript, cut at 16 KB. Without taskID, a task's agent gets its own task.",
                selectors: [],
                parameters: [.taskID(required: false)]
            )
        case .taskList:
            return .init(
                id: rawValue,
                kind: .query,
                summary: "List tasks, oldest first, in the task.get shape without lastReply unless includeReply=true. Every answer has a cursor; with changedSince set to an earlier cursor, only tasks whose record, stage or agentState changed since are listed, deleted task IDs are in deletedTaskIDs, tasks first listed after the cursor are in createdTaskIDs (leaving out tasks the calling session created), and reset=true means the cursor was from an earlier launch, so every task is listed. A workspace-scoped session sees only tasks it created or whose workspace or task space is in its scope.",
                selectors: [],
                parameters: [
                    .taskChangedSince(required: false),
                    .taskIncludeReply(required: false),
                    .init(name: "parent", summary: "List only the tasks this task started.", valueType: .uuid, required: false),
                ]
            )
        case .taskWorkspaceChoices:
            return .init(
                id: rawValue,
                kind: .query,
                summary: "The workspaces a task can be placed in with task.set-workspace: the open top-level workspaces, then recently closed ones whose project is not open. With taskID, also the project triage suggested for that task when triage is on, under suggested, with the choice that places it there. A workspace-scoped session sees only open workspaces in its scope.",
                selectors: [],
                parameters: [
                    .taskID(required: false),
                ]
            )
        case .taskWatches:
            return .init(
                id: rawValue,
                kind: .query,
                summary: "List watches from task.watch: pending ones, and fired ones for a while after they fire, with the reason and whether the message was delivered. Filter by watchID, by the watched taskID, or by notifyTaskID.",
                selectors: [],
                parameters: [.taskWatchID(required: false), .taskID(required: false), .taskNotifyTaskID(required: false)]
            )
        case .coordinatorStatus:
            return .init(
                id: rawValue,
                kind: .query,
                summary: "The coordinator's state: off, waitingForWindow, waitingForRestore, starting, running or failed (with reason), its workspace, panel and session, and the paths of events.jsonl and routing.md.",
                selectors: []
            )
        case .coordinatorChatState:
            return .init(
                id: rawValue,
                kind: .query,
                summary: "What the coordinator chat shows: pages (open chat pages), canSend, and items in time order, each with type, id and for a card kind, taskID, packetVersion, superseded and isNew; expandedCardIDs lists the cards an open page has expanded. Changes nothing.",
                selectors: []
            )
        }
    }
}

private extension AppControlParameterDescriptor {
    static func workspaceParent(required: Bool) -> Self {
        .init(
            name: "parent",
            summary: "Workspace ID to nest under as a task space, or none for a top-level workspace. Sidebar shows task spaces in a Task Spaces group inside the parent card.",
            valueType: .string,
            required: required
        )
    }

    static func activate(required: Bool) -> Self {
        .init(
            name: "activate",
            summary: "Select the new workspace immediately. Defaults to true.",
            valueType: .boolean,
            required: required
        )
    }

    static func terminalCreationActivation(required: Bool) -> Self {
        .init(
            name: "activate",
            summary: "Select the new tab or focus the new panel within the target workspace. Defaults to true. false preserves tab selection and panel focus. Does not select a different workspace or window.",
            valueType: .boolean,
            required: required
        )
    }

    static func amount(required: Bool) -> Self {
        .init(name: "amount", summary: "Positive resize amount.", valueType: .integer, required: required)
    }

    static func annotationKey(required: Bool) -> Self {
        .init(
            name: "key",
            summary: "Stable semantic identity such as linear, github-pr, github-issue, or git-branch. The same key updates one workspace chip and keeps one claimed color across workspaces. Uses 1-32 ASCII letters, digits, '.', '_', or '-'; lowercased on write.",
            valueType: .string,
            required: required
        )
    }

    static func annotationText(required: Bool) -> Self {
        .init(
            name: "text",
            summary: "Chip text, up to 80 characters, no control or bidi characters.",
            valueType: .string,
            required: required
        )
    }

    static func annotationURL(required: Bool) -> Self {
        .init(
            name: "url",
            summary: "Optional absolute http or https link opened when the chip is clicked.",
            valueType: .string,
            required: required
        )
    }

    static func annotationColor(required: Bool) -> Self {
        .init(
            name: "color",
            summary: "First-use global color for this key. Locked while any annotation with the key exists; omit for an automatic claim.",
            valueType: .string,
            required: required,
            allowedValues: AnnotationColorToken.NamedColor.allCases.map(\.rawValue) + ["#RRGGBB"]
        )
    }

    static func annotationPrimary(required: Bool) -> Self {
        .init(
            name: "primary",
            summary: "true makes this the workspace's one primary annotation, replacing any other; false removes that role from this key; omit to leave it unchanged. A task space's row in its parent's Task Spaces group shows its primary annotation, or its github-pr annotation when none is primary; the row truncates long text, so keep primary text short, such as PR #1234 or ENG-512. Use PR #<number> for all pull request chips, including primary annotations.",
            valueType: .boolean,
            required: required
        )
    }

    static func allowUnavailable(required: Bool) -> Self {
        .init(name: "allowUnavailable", summary: "Return availability metadata instead of failing when a terminal surface is unavailable.", valueType: .boolean, required: required)
    }

    static func expectedSessionID(required: Bool) -> Self {
        .init(name: "expectedSessionID", summary: "Only deliver when the target panel still hosts this active managed session.", valueType: .string, required: required)
    }

    static func contains(required: Bool) -> Self {
        .init(name: "contains", summary: "Substring to test against visible terminal text.", valueType: .string, required: required)
    }

    static func tail(required: Bool) -> Self {
        .init(name: "tail", summary: "Return only the last N lines.", valueType: .integer, required: required)
    }

    static func includeScrollback(required: Bool) -> Self {
        .init(name: "includeScrollback", summary: "Include scrollback above the viewport, not just the visible screen.", valueType: .boolean, required: required)
    }

    static func cwd(required: Bool) -> Self {
        .init(name: "cwd", summary: "Base directory for relative file paths or agent launches.", valueType: .string, required: required)
    }

    static func environment(required: Bool) -> Self {
        .init(
            name: "env.NAME",
            summary: "Environment variable for agent.launch. Repeat with env.KEY=value.",
            valueType: .string,
            required: required,
            repeatable: true
        )
    }

    static func filePath(required: Bool) -> Self {
        .init(name: "filePath", summary: "Local file path to open.", valueType: .string, required: required)
    }

    static func filePath(summary: String, required: Bool) -> Self {
        .init(name: "filePath", summary: summary, valueType: .string, required: required)
    }

    static func focusUnreadSessionPanel(required: Bool) -> Self {
        .init(
            name: "focusUnreadSessionPanel",
            summary: "Also focus the newest unread managed-session panel visible in the selected workspace tab. Defaults to false.",
            valueType: .boolean,
            required: required
        )
    }

    static func content(required: Bool) -> Self {
        .init(name: "content", summary: "Inline content payload. Use filePath for non-trivial HTML.", valueType: .string, required: required)
    }

    static func patch(required: Bool) -> Self {
        .init(name: "patch", summary: "Scratchpad patch JSON. Use --stdin patch for non-trivial patches.", valueType: .string, required: required)
    }

    static func expectedRevision(required: Bool) -> Self {
        .init(name: "expectedRevision", summary: "Reject the write unless the current document revision matches this value.", valueType: .integer, required: required)
    }

    static func scratchpadDocumentID(required: Bool) -> Self {
        .init(name: "documentID", summary: "Stable UUID of an open Scratchpad bound to sessionID in the same workspace tab.", valueType: .uuid, required: required)
    }

    static func scratchpadPurpose(required: Bool) -> Self {
        .init(name: "purpose", summary: "Optional description of what this Scratchpad is for, up to 1024 characters. Empty clears it; omission preserves it.", valueType: .string, required: required)
    }

    static func scratchpadCreatePolicy(required: Bool) -> Self {
        .init(
            name: "createPolicy",
            summary: "reuse updates the default; additional creates another binding without changing the default; new replaces only the default binding. Defaults to reuse.",
            valueType: .string,
            required: required,
            allowedValues: ScratchpadPanelCreatePolicy.allCases.map(\.rawValue)
        )
    }

    static func taskText(required: Bool) -> Self {
        .init(name: "text", summary: "The task, as written. The agent receives it unchanged. Required unless prompt is given.", valueType: .string, required: required)
    }

    static func taskFiles(required: Bool) -> Self {
        .init(name: "files", summary: "Absolute path of a file to attach; Toastty keeps a copy. Repeat for more files.", valueType: .string, required: required, repeatable: true)
    }

    static func taskClientRequestID(required: Bool) -> Self {
        .init(name: "clientRequestID", summary: "The caller's key for this request. A repeat with the same key returns the first task.", valueType: .string, required: required)
    }

    static func taskTitle(required: Bool) -> Self {
        .init(name: "title", summary: "One-line title. Defaults to the first line of the text.", valueType: .string, required: required)
    }

    static func taskSlug(required: Bool) -> Self {
        .init(name: "slug", summary: "Lowercase words joined by hyphens; names the task space. Defaults to one made from the title.", valueType: .string, required: required)
    }

    static func taskWorkspace(required: Bool) -> Self {
        .init(name: "workspace", summary: "Workspace ID the task belongs to. A subspace means its parent. Defaults to the calling agent's workspace.", valueType: .uuid, required: required)
    }

    static func taskAgent(required: Bool) -> Self {
        .init(name: "agent", summary: "Agent profile ID from agents.toml.", valueType: .string, required: required)
    }

    static func taskModel(required: Bool) -> Self {
        .init(name: "model", summary: "Model for the agent.", valueType: .string, required: required)
    }

    static func taskEffort(required: Bool) -> Self {
        .init(name: "effort", summary: "Reasoning effort for the agent.", valueType: .string, required: required)
    }

    static func taskRecentWorkspace(required: Bool) -> Self {
        .init(name: "recentWorkspace", summary: "ID of a recently closed workspace from task.workspace-choices. Toastty opens it again.", valueType: .uuid, required: required)
    }

    static func taskRootDirectory(required: Bool) -> Self {
        .init(name: "rootDirectory", summary: "A project directory that is not open. Toastty opens a workspace there.", valueType: .string, required: required)
    }

    static func taskPrompt(required: Bool) -> Self {
        .init(name: "prompt", summary: "First prompt, sent before the task text.", valueType: .string, required: required)
    }

    static func taskStartWork(required: Bool) -> Self {
        .init(name: "startWork", summary: "true makes a git worktree during setup and starts the agent there.", valueType: .boolean, required: required)
    }

    static func taskBase(required: Bool) -> Self {
        .init(name: "base", summary: "Branch on the remote, fetched now, or local commit the worktree starts from. Defaults to the remote's default branch.", valueType: .string, required: required)
    }

    static func taskBranchPrefix(required: Bool) -> Self {
        .init(name: "branchPrefix", summary: "First part of the worktree's branch name, before /<slug>. Defaults to the workspace's branch_prefix in tasks.toml, else task.", valueType: .string, required: required)
    }

    static func taskFork(required: Bool) -> Self {
        .init(name: "fork", summary: "true starts the agent as a fork of the calling Claude Code or Codex session's conversation, after the caller's current turn ends. It uses the caller's agent; model and effort default to the caller's task's. The caller keeps running.", valueType: .boolean, required: required)
    }

    static func taskMessage(required: Bool) -> Self {
        .init(name: "text", summary: "The message, typed into the agent and submitted.", valueType: .string, required: required)
    }

    static func taskWatchCondition(required: Bool) -> Self {
        .init(
            name: "until",
            summary: "What to wait for: idle, waiting, or a stage.",
            valueType: .string,
            required: required,
            allowedValues: TaskWatchCondition.allCases.map(\.rawValue)
        )
    }

    static func taskNotifyTaskID(required: Bool) -> Self {
        .init(name: "notifyTaskID", summary: "Task whose agent gets the message.", valueType: .uuid, required: required)
    }

    static func taskWatchWait(required: Bool) -> Self {
        .init(name: "wait", summary: "true keeps the watch in memory for polling instead of notifying a task.", valueType: .boolean, required: required)
    }

    static func taskWatchID(required: Bool) -> Self {
        .init(name: "watchID", summary: "Watch ID from task.watch.", valueType: .uuid, required: required)
    }

    static func taskChangedSince(required: Bool) -> Self {
        .init(name: "changedSince", summary: "Cursor from an earlier task.list.", valueType: .string, required: required)
    }

    static func taskIncludeReply(required: Bool) -> Self {
        .init(name: "includeReply", summary: "true adds each task's lastReply.", valueType: .boolean, required: required)
    }

    static func taskHead(required: Bool) -> Self {
        .init(name: "head", summary: "The commit the merge checks ran on; the merge is refused if the checkout moved.", valueType: .string, required: required)
    }

    static func taskID(required: Bool) -> Self {
        .init(name: "taskID", summary: "Task ID from task.create or task.list.", valueType: .uuid, required: required)
    }

    static func files(required: Bool) -> Self {
        .init(name: "files", summary: "Image file path. Repeat to provide multiple paths.", valueType: .string, required: required, repeatable: true)
    }

    static func initialPrompt(required: Bool) -> Self {
        .init(name: "initialPrompt", summary: "Initial prompt passed to supported agent profiles at launch.", valueType: .string, required: required)
    }

    static func initialCommands(required: Bool) -> Self {
        .init(
            name: "initialCommands",
            summary: "Shell command to run after cwd setup and before the agent command. Repeat to provide multiple commands.",
            valueType: .string,
            required: required,
            repeatable: true
        )
    }

    static func model(required: Bool) -> Self {
        .init(
            name: "model",
            summary: "Action-local provider model selection. Provider CLI validates the delivered value.",
            valueType: .string,
            required: required,
            supportedProfileIDs: AgentLaunchArgumentOverrideAdapter.modelSupportedAgents.map(\.rawValue)
        )
    }

    static func forkFromSessionID(required: Bool) -> Self {
        .init(name: "forkFromSessionID", summary: "Fork the confirmed native conversation of an active Toastty managed session. Requires an explicit cwd and access to the source workspace. Claude requires CLI 2.1.257 or later.", valueType: .string, required: required, supportedProfileIDs: ["codex", "claude"])
    }

    static func additionalDirectories(required: Bool) -> Self {
        .init(name: "additionalDirectories", summary: "Existing absolute directory to grant the provider access to. Repeat for multiple directories.", valueType: .string, required: required, repeatable: true, supportedProfileIDs: ["codex", "claude"])
    }

    static func reasoningEffort(required: Bool) -> Self {
        .init(
            name: "reasoningEffort",
            summary: "Action-local provider reasoning selection. Provider CLI validates the delivered value.",
            valueType: .string,
            required: required,
            supportedProfileIDs: AgentLaunchArgumentOverrideAdapter.reasoningEffortSupportedAgents.map(\.rawValue)
        )
    }

    static func index(summary: String, required: Bool) -> Self {
        .init(name: "index", summary: summary, valueType: .integer, required: required)
    }

    static func panelID(required: Bool) -> Self {
        .init(name: "panelID", summary: "Panel UUID.", valueType: .uuid, required: required)
    }

    static func placement(required: Bool) -> Self {
        .init(name: "placement", summary: "Panel placement strategy.", valueType: .string, required: required, allowedValues: ["rightPanel", "newTab", "splitRight", "rootRight"])
    }

    static func profileID(required: Bool) -> Self {
        .init(name: "profileID", summary: "Agent or terminal profile ID.", valueType: .string, required: required)
    }

    static func query(required: Bool) -> Self {
        .init(name: "query", summary: "Find query. Use an empty string to clear the current query while keeping find visible.", valueType: .string, required: required)
    }

    static func submit(required: Bool) -> Self {
        .init(name: "submit", summary: "Submit the text after sending it.", valueType: .boolean, required: required)
    }

    static func sessionID(required: Bool) -> Self {
        .init(name: "sessionID", summary: "Active managed session ID.", valueType: .string, required: required)
    }

    static func tabID(required: Bool) -> Self {
        .init(name: "tabID", summary: "Workspace tab UUID.", valueType: .uuid, required: required)
    }

    static func text(required: Bool) -> Self {
        .init(name: "text", summary: "Text payload.", valueType: .string, required: required)
    }

    static func terminateRunningProcess(required: Bool) -> Self {
        .init(
            name: "terminateRunningProcess",
            summary: "Allow panel.close to terminate a running terminal process. Defaults to false and does not discard unsaved documents.",
            valueType: .boolean,
            required: required
        )
    }

    static func toIndex(summary: String, required: Bool) -> Self {
        .init(name: "toIndex", summary: summary, valueType: .integer, required: required)
    }

    static func title(required: Bool) -> Self {
        .init(name: "title", summary: "Title text.", valueType: .string, required: required)
    }

    static func url(required: Bool) -> Self {
        .init(name: "url", summary: "Initial browser URL.", valueType: .string, required: required)
    }
}
