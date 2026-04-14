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
            focusedPanelModeActive: true,
            focusModeRootNodeID: rightSlotID,
            selectedPanelIDs: [leftPanelID, rightPanelID],
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
            configuredTerminalFontPoints: 15
        )

        let snapshot = WorkspaceLayoutSnapshot(state: state)
        let restoredState = snapshot.makeAppState()

        let restoredWorkspace = try #require(restoredState.workspacesByID[workspaceID])
        #expect(restoredWorkspace.title == "Infra")
        #expect(restoredWorkspace.layoutTree == workspace.layoutTree)
        #expect(restoredWorkspace.focusedPanelID == rightPanelID)

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
        #expect(restoredWorkspace.focusModeRootNodeID == nil)
        #expect(restoredWorkspace.selectedPanelIDs.isEmpty)
        #expect(restoredWorkspace.unreadPanelIDs.isEmpty)
        #expect(restoredWorkspace.unreadWorkspaceNotificationCount == 0)
        #expect(restoredWorkspace.recentlyClosedPanels.isEmpty)

        #expect(restoredState.configuredTerminalFontPoints == nil)
        #expect(restoredState.windows.first?.terminalFontSizePointsOverride == nil)
        #expect(restoredState.effectiveTerminalFontPoints(for: windowID) == AppState.defaultTerminalFontPoints)

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
            focusedPanelID: workspaceOnePanelID
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
            focusedPanelID: workspaceTwoPanelID
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
            configuredTerminalFontPoints: nil
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
    func makeAppStatePreservesWebPanelURLsAndTabTitles() throws {
        let windowID = UUID()
        let workspaceID = UUID()
        let browserTabID = UUID()
        let browserPanelID = UUID()
        let browserSlotID = UUID()

        let browserTab = WorkspaceTabState(
            id: browserTabID,
            customTitle: "Pinned Docs",
            layoutTree: .slot(slotID: browserSlotID, panelID: browserPanelID),
            panels: [
                browserPanelID: .web(
                    WebPanelState(
                        definition: .browser,
                        title: "Example Docs",
                        initialURL: "https://example.com/docs",
                        currentURL: "https://example.com/docs/latest"
                    )
                ),
            ],
            focusedPanelID: browserPanelID
        )

        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Docs",
            selectedTabID: browserTabID,
            tabIDs: [browserTabID],
            tabsByID: [browserTabID: browserTab]
        )

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
            configuredTerminalFontPoints: nil
        )

        let restoredState = WorkspaceLayoutSnapshot(state: state).makeAppState()
        let restoredWorkspace = try #require(restoredState.workspacesByID[workspaceID])
        let restoredTab = try #require(restoredWorkspace.tab(id: browserTabID))

        #expect(restoredTab.customTitle == "Pinned Docs")
        guard case .web(let webState) = restoredTab.panels[browserPanelID] else {
            Issue.record("Expected browser tab panel to restore as web")
            return
        }

        #expect(webState.definition == .browser)
        #expect(webState.title == "Example Docs")
        #expect(webState.initialURL == "https://example.com/docs")
        #expect(webState.currentURL == "https://example.com/docs/latest")
        #expect(webState.restorableURL == "https://example.com/docs/latest")
    }

    @Test
    func makeAppStatePreservesMarkdownPanelFilePath() throws {
        let windowID = UUID()
        let workspaceID = UUID()
        let markdownTabID = UUID()
        let markdownPanelID = UUID()
        let markdownSlotID = UUID()

        let markdownTab = WorkspaceTabState(
            id: markdownTabID,
            customTitle: "Notes",
            layoutTree: .slot(slotID: markdownSlotID, panelID: markdownPanelID),
            panels: [
                markdownPanelID: .web(
                    WebPanelState(
                        definition: .markdown,
                        title: "notes.md",
                        filePath: "/tmp/toastty/notes.md"
                    )
                ),
            ],
            focusedPanelID: markdownPanelID
        )

        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Docs",
            selectedTabID: markdownTabID,
            tabIDs: [markdownTabID],
            tabsByID: [markdownTabID: markdownTab]
        )

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
            configuredTerminalFontPoints: nil
        )

        let restoredState = WorkspaceLayoutSnapshot(state: state).makeAppState()
        let restoredWorkspace = try #require(restoredState.workspacesByID[workspaceID])
        let restoredTab = try #require(restoredWorkspace.tab(id: markdownTabID))

        #expect(restoredTab.customTitle == "Notes")
        guard case .web(let webState) = restoredTab.panels[markdownPanelID] else {
            Issue.record("Expected markdown tab panel to restore as web")
            return
        }

        #expect(webState.definition == .markdown)
        #expect(webState.title == "notes.md")
        #expect(webState.filePath == "/tmp/toastty/notes.md")
        #expect(webState.initialURL == nil)
        #expect(webState.currentURL == nil)
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
            configuredTerminalFontPoints: nil
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
    func makeAppStatePreservesWebPanels() throws {
        let workspaceID = UUID()
        let panelID = UUID()
        let slotID = UUID()
        let webState = WebPanelState(
            definition: .browser,
            title: "Docs",
            initialURL: "https://example.com",
            currentURL: "https://example.com/docs"
        )
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Browser",
            layoutTree: .slot(slotID: slotID, panelID: panelID),
            panels: [
                panelID: .web(webState),
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
            configuredTerminalFontPoints: nil
        )

        let restoredState = WorkspaceLayoutSnapshot(state: state).makeAppState()
        let restoredWorkspace = try #require(restoredState.workspacesByID[workspaceID])
        guard case .web(let restoredWebState) = restoredWorkspace.panels[panelID] else {
            Issue.record("Expected web panel to survive restore")
            return
        }

        #expect(restoredWebState == webState)
        #expect(restoredWorkspace.focusedPanelID == panelID)
    }

    @Test
    func workspaceLayoutSnapshotRoundTripsMultipleTabsAndSelection() throws {
        let windowID = UUID()
        let workspaceID = UUID()
        let firstTabID = UUID()
        let secondTabID = UUID()
        let firstSlotID = UUID()
        let secondSlotID = UUID()
        let firstPanelID = UUID()
        let secondPanelID = UUID()

        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Infra",
            selectedTabID: secondTabID,
            tabIDs: [firstTabID, secondTabID],
            tabsByID: [
                firstTabID: WorkspaceTabState(
                    id: firstTabID,
                    layoutTree: .slot(slotID: firstSlotID, panelID: firstPanelID),
                    panels: [
                        firstPanelID: .terminal(
                            TerminalPanelState(
                                title: "First",
                                shell: "zsh",
                                cwd: "/tmp/first-tab",
                                profileBinding: TerminalProfileBinding(profileID: "zmx")
                            )
                        ),
                    ],
                    focusedPanelID: firstPanelID
                ),
                secondTabID: WorkspaceTabState(
                    id: secondTabID,
                    customTitle: "Deploy",
                    layoutTree: .slot(slotID: secondSlotID, panelID: secondPanelID),
                    panels: [
                        secondPanelID: .terminal(
                            TerminalPanelState(
                                title: "Second",
                                shell: "zsh",
                                cwd: "/tmp/second-tab",
                                profileBinding: TerminalProfileBinding(profileID: "ssh-prod")
                            )
                        ),
                    ],
                    focusedPanelID: secondPanelID,
                ),
            ]
        )

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
            configuredTerminalFontPoints: nil
        )

        let snapshot = WorkspaceLayoutSnapshot(state: state)
        let encoded = try JSONEncoder().encode(snapshot)
        let decodedSnapshot = try JSONDecoder().decode(WorkspaceLayoutSnapshot.self, from: encoded)
        let restoredState = decodedSnapshot.makeAppState()
        let restoredWorkspace = try #require(restoredState.workspacesByID[workspaceID])

        #expect(restoredWorkspace.tabIDs == [firstTabID, secondTabID])
        #expect(restoredWorkspace.selectedTabID == secondTabID)

        guard case .terminal(let firstTerminalState) = try #require(restoredWorkspace.tab(id: firstTabID)?.panels[firstPanelID]) else {
            Issue.record("Expected first restored tab panel to remain terminal")
            return
        }
        guard case .terminal(let secondTerminalState) = try #require(restoredWorkspace.tab(id: secondTabID)?.panels[secondPanelID]) else {
            Issue.record("Expected second restored tab panel to remain terminal")
            return
        }

        #expect(firstTerminalState.launchWorkingDirectory == "/tmp/first-tab")
        #expect(secondTerminalState.launchWorkingDirectory == "/tmp/second-tab")
        #expect(firstTerminalState.profileBinding == TerminalProfileBinding(profileID: "zmx"))
        #expect(secondTerminalState.profileBinding == TerminalProfileBinding(profileID: "ssh-prod"))
        #expect(restoredWorkspace.tab(id: secondTabID)?.customTitle == "Deploy")
        #expect(restoredWorkspace.tab(id: secondTabID)?.displayTitle == "Deploy")
        try StateValidator.validate(restoredState)
    }

    @Test
    func workspaceLayoutTabSnapshotDecodesMissingCustomTitleAsNil() throws {
        let snapshot = WorkspaceLayoutTabSnapshot(
            id: UUID(),
            layoutTree: .slot(slotID: UUID(), panelID: UUID()),
            panels: [:],
            focusedPanelID: nil
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["customTitle"] == nil)

        let decoded = try JSONDecoder().decode(WorkspaceLayoutTabSnapshot.self, from: encoded)
        #expect(decoded.customTitle == nil)
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
            configuredTerminalFontPoints: nil
        )

        let snapshot = WorkspaceLayoutSnapshot(state: state)
        guard case .terminal(let terminalSnapshot) = snapshot.workspacesByID[workspace.id]?.panels[panelID] else {
            Issue.record("Expected terminal snapshot")
            return
        }

        #expect(terminalSnapshot.launchWorkingDirectory == "/tmp/restored")
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
            profileBinding: TerminalProfileBinding(profileID: "zmx")
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let binding = try #require(json["profileBinding"] as? [String: String])

        #expect(binding["profileID"] == "zmx")
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
            configuredTerminalFontPoints: nil
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
