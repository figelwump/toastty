import CoreState
import Foundation
import Testing

struct WorkspaceLayoutSnapshotTests {
    @Test
    func makeAppStateRestoresLayoutAndTerminalLaunchWorkingDirectories() throws {
        let windowID = UUID()
        let workspaceID = UUID()
        let leftPanelID = UUID()
        let rightPanelID = UUID()
        let leftSlotID = UUID()
        let rightSlotID = UUID()

        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Infra",
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.62,
                first: .slot(slotID: leftSlotID, panelID: leftPanelID),
                second: .slot(slotID: rightSlotID, panelID: rightPanelID)
            ),
            panels: [
                leftPanelID: .terminal(TerminalPanelState(title: "Server", shell: "zsh", cwd: "/tmp/infra")),
                rightPanelID: .terminal(TerminalPanelState(title: "Client", shell: "zsh", cwd: "/tmp/ui")),
            ],
            focusedPanelID: rightPanelID,
            auxPanelVisibility: [.diff],
            focusedPanelModeActive: true,
            unreadPanelIDs: [leftPanelID],
            unreadWorkspaceNotificationCount: 3,
            recentlyClosedPanels: [
                ClosedPanelRecord(
                    panelState: .terminal(TerminalPanelState(title: "Old", shell: "zsh", cwd: "/tmp/old")),
                    closedAt: Date(),
                    sourceSlotID: leftSlotID
                ),
            ]
        )

        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 20, y: 30, width: 1200, height: 800),
                    workspaceIDs: [workspaceID],
                    selectedWorkspaceID: workspaceID
                ),
            ],
            workspacesByID: [workspaceID: workspace],
            selectedWindowID: windowID,
            configuredTerminalFontPoints: 15,
            globalTerminalFontPoints: 16
        )

        let snapshot = WorkspaceLayoutSnapshot(state: state)
        let restoredState = snapshot.makeAppState()

        let restoredWorkspace = try #require(restoredState.workspacesByID[workspaceID])
        #expect(restoredWorkspace.title == "Infra")
        #expect(restoredWorkspace.layoutTree == workspace.layoutTree)
        #expect(restoredWorkspace.focusedPanelID == rightPanelID)
        #expect(restoredWorkspace.auxPanelVisibility == [.diff])

        guard case .terminal(let leftTerminalState) = restoredWorkspace.panels[leftPanelID] else {
            Issue.record("Expected left panel to be terminal")
            return
        }
        guard case .terminal(let rightTerminalState) = restoredWorkspace.panels[rightPanelID] else {
            Issue.record("Expected right panel to be terminal")
            return
        }

        #expect(leftTerminalState.title == "Terminal 1")
        #expect(rightTerminalState.title == "Terminal 2")
        #expect(leftTerminalState.cwd.isEmpty)
        #expect(rightTerminalState.cwd.isEmpty)
        #expect(leftTerminalState.launchWorkingDirectory == "/tmp/infra")
        #expect(rightTerminalState.launchWorkingDirectory == "/tmp/ui")

        #expect(restoredWorkspace.focusedPanelModeActive == false)
        #expect(restoredWorkspace.unreadPanelIDs.isEmpty)
        #expect(restoredWorkspace.unreadWorkspaceNotificationCount == 0)
        #expect(restoredWorkspace.recentlyClosedPanels.isEmpty)

        #expect(restoredState.configuredTerminalFontPoints == nil)
        #expect(restoredState.globalTerminalFontPoints == AppState.defaultTerminalFontPoints)

        try StateValidator.validate(restoredState)
    }

    @Test
    func makeAppStateRegeneratesTerminalTitlesPerWorkspace() throws {
        let windowID = UUID()
        let workspaceOneID = UUID()
        let workspaceTwoID = UUID()
        let workspaceOneSlotID = UUID()
        let workspaceTwoSlotID = UUID()
        let workspaceOnePanelID = UUID()
        let workspaceTwoPanelID = UUID()

        let workspaceOne = WorkspaceState(
            id: workspaceOneID,
            title: "One",
            layoutTree: .slot(slotID: workspaceOneSlotID, panelID: workspaceOnePanelID),
            panels: [
                workspaceOnePanelID: .terminal(
                    TerminalPanelState(title: "Agent A", shell: "zsh", cwd: "/tmp/one")
                ),
            ],
            focusedPanelID: workspaceOnePanelID,
            auxPanelVisibility: []
        )

        let workspaceTwo = WorkspaceState(
            id: workspaceTwoID,
            title: "Two",
            layoutTree: .slot(slotID: workspaceTwoSlotID, panelID: workspaceTwoPanelID),
            panels: [
                workspaceTwoPanelID: .terminal(
                    TerminalPanelState(title: "Agent B", shell: "zsh", cwd: "/tmp/two")
                ),
            ],
            focusedPanelID: workspaceTwoPanelID,
            auxPanelVisibility: []
        )

        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                    workspaceIDs: [workspaceOneID, workspaceTwoID],
                    selectedWorkspaceID: workspaceOneID
                ),
            ],
            workspacesByID: [
                workspaceOneID: workspaceOne,
                workspaceTwoID: workspaceTwo,
            ],
            selectedWindowID: windowID,
            configuredTerminalFontPoints: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )

        let restoredState = WorkspaceLayoutSnapshot(state: state).makeAppState()
        let restoredWorkspaceOne = try #require(restoredState.workspacesByID[workspaceOneID])
        let restoredWorkspaceTwo = try #require(restoredState.workspacesByID[workspaceTwoID])

        guard case .terminal(let workspaceOneTerminal) = restoredWorkspaceOne.panels[workspaceOnePanelID] else {
            Issue.record("Expected workspace one panel to be terminal")
            return
        }
        guard case .terminal(let workspaceTwoTerminal) = restoredWorkspaceTwo.panels[workspaceTwoPanelID] else {
            Issue.record("Expected workspace two panel to be terminal")
            return
        }

        #expect(workspaceOneTerminal.title == "Terminal 1")
        #expect(workspaceTwoTerminal.title == "Terminal 1")
    }

    @Test
    func makeAppStatePreservesTerminalProfileBindingAndPanelIDs() throws {
        let workspaceID = UUID()
        let panelID = UUID()
        let slotID = UUID()
        let binding = TerminalProfileBinding(profileID: "zmx")
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Profiled",
            layoutTree: .slot(slotID: slotID, panelID: panelID),
            panels: [
                panelID: .terminal(
                    TerminalPanelState(
                        title: "Terminal 1",
                        shell: "zsh",
                        cwd: "/tmp/profiled",
                        profileBinding: binding
                    )
                ),
            ],
            focusedPanelID: panelID
        )
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                    workspaceIDs: [workspaceID],
                    selectedWorkspaceID: workspaceID
                ),
            ],
            workspacesByID: [workspaceID: workspace],
            selectedWindowID: windowID,
            configuredTerminalFontPoints: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )

        let restoredState = WorkspaceLayoutSnapshot(state: state).makeAppState()
        let restoredWorkspace = try #require(restoredState.workspacesByID[workspaceID])
        #expect(restoredWorkspace.panels[panelID] != nil)

        guard case .terminal(let restoredTerminalState) = restoredWorkspace.panels[panelID] else {
            Issue.record("Expected terminal panel to survive restore")
            return
        }
        #expect(restoredTerminalState.profileBinding == binding)
        #expect(restoredWorkspace.focusedPanelID == panelID)
    }

    @Test
    func makeAppStateRestoresPersistedSemanticTitleForProfiledPane() throws {
        let workspaceID = UUID()
        let panelID = UUID()
        let slotID = UUID()
        let binding = TerminalProfileBinding(profileID: "zmx")
        let runningTitle = "emptyos dev --port 3913"
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Profiled",
            layoutTree: .slot(slotID: slotID, panelID: panelID),
            panels: [
                panelID: .terminal(
                    TerminalPanelState(
                        title: runningTitle,
                        shell: "zsh",
                        cwd: "/tmp/emptyos",
                        profileBinding: binding
                    )
                ),
            ],
            focusedPanelID: panelID
        )
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                    workspaceIDs: [workspaceID],
                    selectedWorkspaceID: workspaceID
                ),
            ],
            workspacesByID: [workspaceID: workspace],
            selectedWindowID: windowID,
            configuredTerminalFontPoints: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )

        let restoredState = WorkspaceLayoutSnapshot(state: state).makeAppState()
        let restoredWorkspace = try #require(restoredState.workspacesByID[workspaceID])

        guard case .terminal(let restoredTerminalState) = restoredWorkspace.panels[panelID] else {
            Issue.record("Expected restored panel to be terminal")
            return
        }

        #expect(restoredTerminalState.title == runningTitle)
        #expect(restoredTerminalState.cwd.isEmpty)
        #expect(restoredTerminalState.launchWorkingDirectory == "/tmp/emptyos")
        #expect(restoredTerminalState.profileBinding == binding)
    }

    @Test
    func snapshotPersistsLaunchWorkingDirectoryWhenLiveCWDIsBlank() {
        let workspace = WorkspaceState.bootstrap(title: "Restore")
        let panelID = workspace.layoutTree.allSlotInfos[0].panelID
        guard case .terminal(let terminalState) = workspace.panels[panelID] else {
            Issue.record("Expected bootstrap panel to be terminal")
            return
        }

        var restoredTerminalState = terminalState
        restoredTerminalState.cwd = ""
        restoredTerminalState.launchWorkingDirectory = "/tmp/restored"

        var restoredWorkspace = workspace
        restoredWorkspace.panels[panelID] = .terminal(restoredTerminalState)

        let state = AppState(
            windows: [
                WindowState(
                    id: UUID(),
                    frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                ),
            ],
            workspacesByID: [workspace.id: restoredWorkspace],
            selectedWindowID: nil,
            configuredTerminalFontPoints: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )

        let snapshot = WorkspaceLayoutSnapshot(state: state)
        guard case .terminal(let terminalSnapshot) = snapshot.workspacesByID[workspace.id]?.panels[panelID] else {
            Issue.record("Expected terminal snapshot")
            return
        }

        #expect(terminalSnapshot.launchWorkingDirectory == "/tmp/restored")
    }

    @Test
    func terminalSnapshotPersistsSemanticRestoreTitleOnlyForProfiledPane() {
        let snapshot = makeTerminalSnapshot(
            terminalState: TerminalPanelState(
                title: "emptyos dev --port 3913",
                shell: "/bin/zsh",
                cwd: "/tmp/emptyos",
                profileBinding: TerminalProfileBinding(profileID: "zmx")
            )
        )

        #expect(snapshot.restoredTitle == "emptyos dev --port 3913")
    }

    @Test
    func terminalSnapshotSkipsTransientRestoreTitleCandidates() {
        let profiledPathSnapshot = makeTerminalSnapshot(
            terminalState: TerminalPanelState(
                title: "/tmp/emptyos",
                shell: "/bin/zsh",
                cwd: "/tmp/emptyos",
                profileBinding: TerminalProfileBinding(profileID: "zmx")
            )
        )
        let profiledWrapperSnapshot = makeTerminalSnapshot(
            terminalState: TerminalPanelState(
                title: "zmx attach toastty.$TOASTTY_PANEL_ID",
                shell: "/bin/zsh",
                cwd: "",
                profileBinding: TerminalProfileBinding(profileID: "zmx")
            )
        )
        let nonProfiledSnapshot = makeTerminalSnapshot(
            terminalState: TerminalPanelState(
                title: "emptyos dev --port 3913",
                shell: "/bin/zsh",
                cwd: "/tmp/emptyos"
            )
        )

        #expect(profiledPathSnapshot.restoredTitle == nil)
        #expect(profiledWrapperSnapshot.restoredTitle == nil)
        #expect(nonProfiledSnapshot.restoredTitle == nil)
    }

    @Test
    func terminalSnapshotDecodesLegacyCWDField() throws {
        let data = try JSONEncoder().encode(
            LegacyTerminalSnapshot(shell: "zsh", cwd: "/tmp/legacy")
        )

        let decoded = try JSONDecoder().decode(WorkspaceLayoutTerminalPanelSnapshot.self, from: data)

        #expect(decoded.shell == "zsh")
        #expect(decoded.launchWorkingDirectory == "/tmp/legacy")
    }

    @Test
    func terminalSnapshotEncodesLegacyCWDFieldForDowngradeCompatibility() throws {
        let snapshot = WorkspaceLayoutTerminalPanelSnapshot(
            shell: "zsh",
            launchWorkingDirectory: "/tmp/compat"
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])

        #expect(json["launchWorkingDirectory"] == "/tmp/compat")
        #expect(json["cwd"] == "/tmp/compat")
    }

    @Test
    func terminalSnapshotEncodesProfileBindingWhenPresent() throws {
        let snapshot = WorkspaceLayoutTerminalPanelSnapshot(
            shell: "zsh",
            launchWorkingDirectory: "/tmp/compat",
            profileBinding: TerminalProfileBinding(profileID: "zmx"),
            restoredTitle: "emptyos dev --port 3913"
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let binding = try #require(json["profileBinding"] as? [String: String])

        #expect(binding["profileID"] == "zmx")
        #expect(json["restoredTitle"] as? String == "emptyos dev --port 3913")
    }

    @Test
    func makeAppStatePreservesMultipleWindowsAndSelectedWindow() throws {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()

        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 20, y: 30, width: 1200, height: 800),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 200, y: 180, width: 960, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: secondWindowID,
            configuredTerminalFontPoints: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )

        let restoredState = WorkspaceLayoutSnapshot(state: state).makeAppState()

        #expect(restoredState.windows == state.windows)
        #expect(restoredState.selectedWindowID == secondWindowID)
        try StateValidator.validate(restoredState)
    }
}

private struct LegacyTerminalSnapshot: Codable {
    let shell: String
    let cwd: String
}

private func makeTerminalSnapshot(terminalState: TerminalPanelState) -> WorkspaceLayoutTerminalPanelSnapshot {
    let workspaceID = UUID()
    let panelID = UUID()
    let state = AppState(
        windows: [
            WindowState(
                id: UUID(),
                frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                workspaceIDs: [workspaceID],
                selectedWorkspaceID: workspaceID
            ),
        ],
        workspacesByID: [
            workspaceID: WorkspaceState(
                id: workspaceID,
                title: "Snapshot",
                layoutTree: .slot(slotID: UUID(), panelID: panelID),
                panels: [panelID: .terminal(terminalState)],
                focusedPanelID: panelID
            ),
        ],
        selectedWindowID: nil,
        configuredTerminalFontPoints: nil,
        globalTerminalFontPoints: AppState.defaultTerminalFontPoints
    )

    guard case .terminal(let snapshot) = WorkspaceLayoutSnapshot(state: state)
        .workspacesByID[workspaceID]?.panels[panelID] else {
        fatalError("expected terminal snapshot")
    }
    return snapshot
}
