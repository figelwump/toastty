import Foundation

public enum AutomationFixtureError: Error, Equatable, Sendable {
    case unknownFixture(String)
}

public enum AutomationFixtureLoader {
    public static func load(named fixtureName: String) -> AppState? {
        switch fixtureName {
        case "default", "single-workspace":
            return .bootstrap()
        case "two-workspaces":
            return makeTwoWorkspaceFixture()
        case "split-workspace":
            return makeSplitWorkspaceFixture()
        case "workspace-tabs-wide":
            return makeWorkspaceTabsWideFixture()
        case "workspace-tabs-wide-unread":
            return makeWorkspaceTabsWideUnreadFixture(sidebarVisible: true)
        case "workspace-tabs-wide-hidden-sidebar-unread":
            return makeWorkspaceTabsWideUnreadFixture(sidebarVisible: false)
        default:
            return nil
        }
    }

    public static func loadRequired(named fixtureName: String) throws -> AppState {
        guard let fixture = load(named: fixtureName) else {
            throw AutomationFixtureError.unknownFixture(fixtureName)
        }
        return fixture
    }

    private static func makeTwoWorkspaceFixture() -> AppState {
        let first = makeWorkspace(
            workspaceID: UUID(uuidString: "A8E51458-95CC-44A1-96D5-ABCF4EF8D601")!,
            slotID: UUID(uuidString: "A8E51458-95CC-44A1-96D5-ABCF4EF8D602")!,
            panelID: UUID(uuidString: "A8E51458-95CC-44A1-96D5-ABCF4EF8D603")!,
            title: "Workspace 1",
            terminalTitle: "Terminal 1"
        )

        let second = makeWorkspace(
            workspaceID: UUID(uuidString: "A8E51458-95CC-44A1-96D5-ABCF4EF8D611")!,
            slotID: UUID(uuidString: "A8E51458-95CC-44A1-96D5-ABCF4EF8D612")!,
            panelID: UUID(uuidString: "A8E51458-95CC-44A1-96D5-ABCF4EF8D613")!,
            title: "Workspace 2",
            terminalTitle: "Terminal 2"
        )

        let windowID = UUID(uuidString: "A8E51458-95CC-44A1-96D5-ABCF4EF8D621")!
        let window = WindowState(
            id: windowID,
            frame: CGRectCodable(x: 80, y: 80, width: 1380, height: 860),
            workspaceIDs: [first.id, second.id],
            selectedWorkspaceID: first.id
        )

        return AppState(
            windows: [window],
            workspacesByID: [
                first.id: first,
                second.id: second,
            ],
            selectedWindowID: windowID
        )
    }

    private static func makeSplitWorkspaceFixture() -> AppState {
        let workspaceID = UUID(uuidString: "C41A0426-5A58-4ECF-8F0F-2AFC7A706901")!
        let leftSlotID = UUID(uuidString: "C41A0426-5A58-4ECF-8F0F-2AFC7A706902")!
        let rightSlotID = UUID(uuidString: "C41A0426-5A58-4ECF-8F0F-2AFC7A706903")!
        let leftPanelID = UUID(uuidString: "C41A0426-5A58-4ECF-8F0F-2AFC7A706904")!
        let rightPanelID = UUID(uuidString: "C41A0426-5A58-4ECF-8F0F-2AFC7A706905")!

        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Workspace 1",
            layoutTree: .split(
                nodeID: UUID(uuidString: "C41A0426-5A58-4ECF-8F0F-2AFC7A706906")!,
                orientation: .horizontal,
                ratio: 0.6,
                first: .slot(slotID: leftSlotID, panelID: leftPanelID),
                second: .slot(slotID: rightSlotID, panelID: rightPanelID)
            ),
            panels: [
                leftPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")),
                rightPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/tmp")),
            ],
            focusedPanelID: leftPanelID
        )

        let windowID = UUID(uuidString: "C41A0426-5A58-4ECF-8F0F-2AFC7A706907")!
        let window = WindowState(
            id: windowID,
            frame: CGRectCodable(x: 100, y: 90, width: 1280, height: 760),
            workspaceIDs: [workspaceID],
            selectedWorkspaceID: workspaceID
        )

        return AppState(
            windows: [window],
            workspacesByID: [workspaceID: workspace],
            selectedWindowID: windowID
        )
    }

    private static func makeWorkspaceTabsWideFixture() -> AppState {
        let workspace = WorkspaceState.bootstrap(title: "Workspace 1")
        let windowID = UUID(uuidString: "32D1DAA2-E951-4215-8975-8D82A3A59321")!
        let window = WindowState(
            id: windowID,
            frame: CGRectCodable(x: 80, y: 80, width: 2300, height: 760),
            workspaceIDs: [workspace.id],
            selectedWorkspaceID: workspace.id,
            sidebarVisible: true
        )

        return AppState(
            windows: [window],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: windowID
        )
    }

    private static func makeWorkspaceTabsWideUnreadFixture(sidebarVisible: Bool) -> AppState {
        var workspace = WorkspaceState.bootstrap(title: "Workspace 1")
        let unreadPanelID = UUID()
        let unreadTab = WorkspaceTabState(
            id: UUID(),
            layoutTree: .slot(slotID: UUID(), panelID: unreadPanelID),
            panels: [
                unreadPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/tmp")),
            ],
            focusedPanelID: unreadPanelID,
            unreadPanelIDs: [unreadPanelID]
        )
        // Keep unread on a background tab; selected-tab unread auto-clears on appear.
        workspace.appendTab(unreadTab, select: false)

        let windowID = UUID(uuidString: "32D1DAA2-E951-4215-8975-8D82A3A59321")!
        let window = WindowState(
            id: windowID,
            frame: CGRectCodable(x: 80, y: 80, width: 2300, height: 760),
            workspaceIDs: [workspace.id],
            selectedWorkspaceID: workspace.id,
            sidebarVisible: sidebarVisible
        )

        return AppState(
            windows: [window],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: windowID
        )
    }

    private static func makeWorkspace(
        workspaceID: UUID,
        slotID: UUID,
        panelID: UUID,
        title: String,
        terminalTitle: String
    ) -> WorkspaceState {
        WorkspaceState(
            id: workspaceID,
            title: title,
            layoutTree: .slot(slotID: slotID, panelID: panelID),
            panels: [
                panelID: .terminal(TerminalPanelState(title: terminalTitle, shell: "zsh", cwd: "/tmp")),
            ],
            focusedPanelID: panelID
        )
    }
}
