import CoreState
import Foundation
import Testing

struct AppStateCodableTests {
    @Test
    func bootstrapUsesDefaultTerminalFontSize() {
        let state = AppState.bootstrap()
        let windowID = try! #require(state.windows.first?.id)

        #expect(AppState.defaultTerminalFontPoints == 12)
        #expect(state.effectiveTerminalFontPoints(for: windowID) == AppState.defaultTerminalFontPoints)
    }

    @Test
    func bootstrapBindsInitialTerminalToConfiguredDefaultProfile() throws {
        let state = AppState.bootstrap(defaultTerminalProfileID: "zmx")
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspace = try #require(state.workspacesByID[workspaceID])
        let panelID = try #require(workspace.focusedPanelID)

        guard case .terminal(let terminalState) = workspace.panels[panelID] else {
            Issue.record("Expected bootstrap panel to be terminal")
            return
        }

        #expect(state.defaultTerminalProfileID == "zmx")
        #expect(terminalState.profileBinding == TerminalProfileBinding(profileID: "zmx"))
    }

    @Test
    func focusedPanelModeTransientFieldsResetWhenDecodingAppState() throws {
        var state = AppState.bootstrap()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        workspace.focusedPanelModeActive = true
        workspace.focusModeRootNodeID = workspace.layoutTree.allSlotInfos.first?.slotID
        workspace.selectedPanelIDs = Set(workspace.panels.keys)
        state.workspacesByID[workspaceID] = workspace

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AppState.self, from: encoded)
        let decodedWorkspace = try #require(decoded.workspacesByID[workspaceID])

        #expect(decodedWorkspace.focusedPanelModeActive == false)
        #expect(decodedWorkspace.focusModeRootNodeID == nil)
        #expect(decodedWorkspace.selectedPanelIDs.isEmpty)
        try StateValidator.validate(decoded)
    }

    @Test
    func appStateCodableRoundTripsMultipleWorkspaceTabs() throws {
        var state = AppState.bootstrap(defaultTerminalProfileID: "zmx")
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(
            reducer.send(
                .createWorkspaceTab(
                    workspaceID: workspaceID,
                    seed: WindowLaunchSeed(
                        terminalCWD: "/tmp/second-tab",
                        terminalProfileBinding: TerminalProfileBinding(profileID: "ssh-prod")
                    )
                ),
                state: &state
            )
        )

        let workspaceBeforeEncode = try #require(state.workspacesByID[workspaceID])
        let originalTabID = try #require(workspaceBeforeEncode.tabIDs.first)
        let secondTabID = try #require(workspaceBeforeEncode.tabIDs.last)
        let originalPanelID = try #require(workspaceBeforeEncode.tab(id: originalTabID)?.focusedPanelID)
        let secondPanelID = try #require(workspaceBeforeEncode.tab(id: secondTabID)?.focusedPanelID)

        #expect(
            reducer.send(
                .setWorkspaceTabCustomTitle(workspaceID: workspaceID, tabID: secondTabID, title: "Deploy"),
                state: &state
            )
        )

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AppState.self, from: encoded)
        let decodedWorkspace = try #require(decoded.workspacesByID[workspaceID])

        #expect(decodedWorkspace.tabIDs == [originalTabID, secondTabID])
        #expect(decodedWorkspace.selectedTabID == secondTabID)

        guard case .terminal(let originalTerminalState) = try #require(decodedWorkspace.tab(id: originalTabID)?.panels[originalPanelID]) else {
            Issue.record("Expected original tab panel to remain terminal after decode")
            return
        }
        guard case .terminal(let secondTerminalState) = try #require(decodedWorkspace.tab(id: secondTabID)?.panels[secondPanelID]) else {
            Issue.record("Expected second tab panel to remain terminal after decode")
            return
        }

        #expect(originalTerminalState.profileBinding == TerminalProfileBinding(profileID: "zmx"))
        #expect(secondTerminalState.profileBinding == TerminalProfileBinding(profileID: "ssh-prod"))
        #expect(secondTerminalState.cwd == "/tmp/second-tab")
        #expect(decodedWorkspace.tab(id: secondTabID)?.customTitle == "Deploy")
        #expect(decodedWorkspace.tab(id: secondTabID)?.displayTitle == "Deploy")
        #expect(decodedWorkspace.tab(id: originalTabID)?.focusedPanelModeActive == false)
        #expect(decodedWorkspace.tab(id: secondTabID)?.focusedPanelModeActive == false)
        #expect(decodedWorkspace.tab(id: originalTabID)?.focusModeRootNodeID == nil)
        #expect(decodedWorkspace.tab(id: secondTabID)?.focusModeRootNodeID == nil)
        #expect(decodedWorkspace.tab(id: originalTabID)?.selectedPanelIDs.isEmpty == true)
        #expect(decodedWorkspace.tab(id: secondTabID)?.selectedPanelIDs.isEmpty == true)
        try StateValidator.validate(decoded)
    }

    @Test
    func appStateDecodesLegacySingleTabWorkspacePayload() throws {
        let windowID = UUID()
        let workspaceID = UUID()
        let slotID = UUID()
        let panelID = UUID()
        let closedSlotID = UUID()
        let payload = LegacyAppStatePayload(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 40, y: 60, width: 1200, height: 800),
                    workspaceIDs: [workspaceID],
                    selectedWorkspaceID: workspaceID
                ),
            ],
            workspacesByID: [
                workspaceID: LegacyWorkspacePayload(
                    id: workspaceID,
                    title: "Infra",
                    layoutTree: .slot(slotID: slotID, panelID: panelID),
                    panels: [
                        panelID: .terminal(
                            TerminalPanelState(
                                title: "Infra Shell",
                                shell: "zsh",
                                cwd: "/tmp/infra",
                                profileBinding: TerminalProfileBinding(profileID: "ssh-prod")
                            )
                        ),
                    ],
                    focusedPanelID: panelID,
                    unreadPanelIDs: [panelID],
                    unreadNotificationCount: 3,
                    recentlyClosedPanels: [
                        ClosedPanelRecord(
                            panelState: .terminal(
                                TerminalPanelState(
                                    title: "Closed Shell",
                                    shell: "bash",
                                    cwd: "/tmp/closed"
                                )
                            ),
                            closedAt: Date(timeIntervalSince1970: 1_710_000_000),
                            sourceSlotID: closedSlotID
                        ),
                    ]
                ),
            ],
            selectedWindowID: windowID,
            defaultTerminalProfileID: "ssh-prod",
            configuredTerminalFontPoints: nil,
            globalTerminalFontPoints: 14
        )

        let decoded = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(payload))
        let decodedWorkspace = try #require(decoded.workspacesByID[workspaceID])
        let decodedTabID = try #require(decodedWorkspace.selectedTabID)
        let decodedTab = try #require(decodedWorkspace.tab(id: decodedTabID))

        #expect(decoded.selectedWindowID == windowID)
        #expect(decoded.defaultTerminalProfileID == "ssh-prod")
        #expect(decoded.window(id: windowID)?.terminalFontSizePointsOverride == 14)
        #expect(decoded.window(id: windowID)?.markdownTextScaleOverride == nil)
        #expect(decoded.effectiveTerminalFontPoints(for: windowID) == 14)
        #expect(decoded.effectiveMarkdownTextScale(for: windowID) == AppState.defaultMarkdownTextScale)
        #expect(decodedWorkspace.title == "Infra")
        #expect(decodedWorkspace.tabIDs == [decodedTabID])
        #expect(decodedWorkspace.selectedTabID == decodedTabID)
        #expect(decodedWorkspace.focusedPanelID == panelID)
        #expect(decodedWorkspace.unreadWorkspaceNotificationCount == 3)
        #expect(decodedWorkspace.unreadPanelIDs == [panelID])
        #expect(decodedWorkspace.focusedPanelModeActive == false)
        #expect(decodedWorkspace.recentlyClosedPanels.count == 1)

        guard case .terminal(let restoredTerminal) = decodedTab.panels[panelID] else {
            Issue.record("Expected legacy single-tab panel to decode as terminal")
            return
        }

        #expect(restoredTerminal.cwd == "/tmp/infra")
        #expect(restoredTerminal.profileBinding == TerminalProfileBinding(profileID: "ssh-prod"))
        try StateValidator.validate(decoded)
    }

    @Test
    func appStateLegacyGlobalFontMatchingConfiguredBaselineDoesNotPinWindowOverride() throws {
        let windowID = UUID()
        let workspace = WorkspaceState.bootstrap(title: "One")
        let payload = LegacyAppStatePayload(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 40, y: 60, width: 1200, height: 800),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                ),
            ],
            workspacesByID: [workspace.id: LegacyWorkspacePayload(workspace)],
            selectedWindowID: windowID,
            defaultTerminalProfileID: nil,
            configuredTerminalFontPoints: 14,
            globalTerminalFontPoints: 14
        )

        let decoded = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(payload))

        #expect(decoded.window(id: windowID)?.terminalFontSizePointsOverride == nil)
        #expect(decoded.effectiveTerminalFontPoints(for: windowID) == 14)
        #expect(decoded.window(id: windowID)?.markdownTextScaleOverride == nil)
        #expect(decoded.effectiveMarkdownTextScale(for: windowID) == AppState.defaultMarkdownTextScale)
    }

    @Test
    func workspaceTabStateCodableNormalizesCustomTitleAndFallsBackToDerivedTitle() throws {
        let panelID = UUID()
        let slotID = UUID()
        let tab = WorkspaceTabState(
            id: UUID(),
            customTitle: "  Deploy  ",
            layoutTree: .slot(slotID: slotID, panelID: panelID),
            panels: [
                panelID: .terminal(TerminalPanelState(title: "Terminal 7", shell: "zsh", cwd: "/tmp/deploy")),
            ],
            focusedPanelID: panelID
        )

        #expect(tab.customTitle == "Deploy")
        #expect(tab.displayTitle == "Deploy")

        let decoded = try JSONDecoder().decode(WorkspaceTabState.self, from: JSONEncoder().encode(tab))
        #expect(decoded.customTitle == "Deploy")
        #expect(decoded.displayTitle == "Deploy")

        let fallbackTab = WorkspaceTabState(
            id: UUID(),
            customTitle: "   ",
            layoutTree: .slot(slotID: slotID, panelID: panelID),
            panels: [
                panelID: .terminal(TerminalPanelState(title: "Terminal 7", shell: "zsh", cwd: "/tmp/deploy")),
            ],
            focusedPanelID: panelID
        )

        #expect(fallbackTab.customTitle == nil)
        let fallbackLabel = try #require(fallbackTab.panels[panelID]?.notificationLabel)
        #expect(fallbackTab.displayTitle == fallbackLabel)
    }

    @Test
    func appStateDecodesLegacyMarkdownPanelPayloadAsLocalDocument() throws {
        let windowID = UUID()
        let workspaceID = UUID()
        let tabID = UUID()
        let panelID = UUID()
        let slotID = UUID()
        let filePath = "/tmp/toastty/notes.md"

        let tab = WorkspaceTabState(
            id: tabID,
            customTitle: "Notes",
            layoutTree: .slot(slotID: slotID, panelID: panelID),
            panels: [
                panelID: .web(
                    WebPanelState(
                        definition: .localDocument,
                        title: "notes.md",
                        filePath: filePath
                    )
                ),
            ],
            focusedPanelID: panelID
        )

        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 40, y: 60, width: 1200, height: 800),
                    workspaceIDs: [workspaceID],
                    selectedWorkspaceID: workspaceID
                ),
            ],
            workspacesByID: [
                workspaceID: WorkspaceState(
                    id: workspaceID,
                    title: "Workspace 1",
                    selectedTabID: tabID,
                    tabIDs: [tabID],
                    tabsByID: [tabID: tab]
                ),
            ],
            selectedWindowID: windowID,
            configuredTerminalFontPoints: nil
        )

        let encoded = try JSONEncoder().encode(state)
        var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var workspacesByID = try decodePairedJSONMap(root["workspacesByID"], label: "AppState.workspacesByID")
        var workspace = try #require(workspacesByID[workspaceID.uuidString] as? [String: Any])
        var tabsByID = try decodePairedJSONMap(workspace["tabsByID"], label: "Workspace.tabsByID")
        var decodedTab = try #require(tabsByID[tabID.uuidString] as? [String: Any])
        var panels = try decodePairedJSONMap(decodedTab["panels"], label: "WorkspaceTab.panels")
        var panel = try #require(panels[panelID.uuidString] as? [String: Any])
        var web = try #require(panel["web"] as? [String: Any])
        let localDocument = try #require(web["localDocument"] as? [String: Any])

        web["definition"] = "markdown"
        web["filePath"] = localDocument["filePath"]
        web.removeValue(forKey: "localDocument")
        panel["web"] = web
        panels[panelID.uuidString] = panel
        decodedTab["panels"] = encodePairedJSONMap(panels)
        tabsByID[tabID.uuidString] = decodedTab
        workspace["tabsByID"] = encodePairedJSONMap(tabsByID)
        workspacesByID[workspaceID.uuidString] = workspace
        root["workspacesByID"] = encodePairedJSONMap(workspacesByID)

        let legacyData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(AppState.self, from: legacyData)
        let decodedWorkspace = try #require(decoded.workspacesByID[workspaceID])
        let restoredTab = try #require(decodedWorkspace.tab(id: tabID))

        guard case .web(let webState) = restoredTab.panels[panelID] else {
            Issue.record("Expected legacy markdown panel to decode as web")
            return
        }

        #expect(webState.definition == .localDocument)
        #expect(webState.title == "notes.md")
        #expect(webState.filePath == filePath)
        #expect(webState.localDocument == LocalDocumentState(filePath: filePath, format: .markdown))
        try StateValidator.validate(decoded)
    }

    @Test
    func appStateRoundTripsPlainTextLocalDocumentAsCodeFormat() throws {
        let windowID = UUID()
        let workspaceID = UUID()
        let tabID = UUID()
        let panelID = UUID()
        let slotID = UUID()
        let filePath = "/tmp/toastty/notes.txt"

        let tab = WorkspaceTabState(
            id: tabID,
            customTitle: "Notes",
            layoutTree: .slot(slotID: slotID, panelID: panelID),
            panels: [
                panelID: .web(
                    WebPanelState(
                        definition: .localDocument,
                        title: "notes.txt",
                        filePath: filePath,
                        localDocument: LocalDocumentState(filePath: filePath, format: .code)
                    )
                ),
            ],
            focusedPanelID: panelID
        )

        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 40, y: 60, width: 1200, height: 800),
                    workspaceIDs: [workspaceID],
                    selectedWorkspaceID: workspaceID
                ),
            ],
            workspacesByID: [
                workspaceID: WorkspaceState(
                    id: workspaceID,
                    title: "Workspace 1",
                    selectedTabID: tabID,
                    tabIDs: [tabID],
                    tabsByID: [tabID: tab]
                ),
            ],
            selectedWindowID: windowID,
            configuredTerminalFontPoints: nil
        )

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AppState.self, from: encoded)
        let decodedWorkspace = try #require(decoded.workspacesByID[workspaceID])
        let decodedTab = try #require(decodedWorkspace.tab(id: tabID))

        guard case .web(let webState) = decodedTab.panels[panelID] else {
            Issue.record("Expected plain-text local document to decode as web")
            return
        }

        #expect(webState.definition == .localDocument)
        #expect(webState.title == "notes.txt")
        #expect(webState.filePath == filePath)
        #expect(webState.localDocument == LocalDocumentState(filePath: filePath, format: .code))
        try StateValidator.validate(decoded)
    }

    @Test
    func closedPanelRecordCodablePreservesRestoreTabMetadata() throws {
        let workspaceID = UUID()
        let historyTabID = UUID()
        let historyPanelID = UUID()
        let historySlotID = UUID()
        let sourceTabID = UUID()
        let predecessorTabID = UUID()
        let successorTabID = UUID()

        let historyTab = WorkspaceTabState(
            id: historyTabID,
            layoutTree: .slot(slotID: historySlotID, panelID: historyPanelID),
            panels: [
                historyPanelID: .terminal(
                    TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")
                ),
            ],
            focusedPanelID: historyPanelID,
            recentlyClosedPanels: [
                ClosedPanelRecord(
                    panelState: .web(
                        WebPanelState(
                            definition: .browser,
                            title: "Docs",
                            initialURL: "https://example.com/docs"
                        )
                    ),
                    closedAt: Date(timeIntervalSince1970: 1_710_000_002),
                    sourceSlotID: UUID(),
                    sourceTabID: sourceTabID,
                    sourceTabIndex: 1,
                    sourceTabPredecessorID: predecessorTabID,
                    sourceTabSuccessorID: successorTabID,
                    sourceTabCustomTitle: "  Pinned Docs  "
                ),
            ]
        )

        let state = AppState(
            windows: [
                WindowState(
                    id: UUID(),
                    frame: CGRectCodable(x: 40, y: 60, width: 1200, height: 800),
                    workspaceIDs: [workspaceID],
                    selectedWorkspaceID: workspaceID
                ),
            ],
            workspacesByID: [
                workspaceID: WorkspaceState(
                    id: workspaceID,
                    title: "Workspace 1",
                    selectedTabID: historyTabID,
                    tabIDs: [historyTabID],
                    tabsByID: [historyTabID: historyTab]
                ),
            ],
            selectedWindowID: nil,
            configuredTerminalFontPoints: nil
        )

        let decoded = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        let decodedRecord = try #require(decoded.workspacesByID[workspaceID]?.recentlyClosedPanels.first)
        #expect(decodedRecord.sourceTabID == sourceTabID)
        #expect(decodedRecord.sourceTabIndex == 1)
        #expect(decodedRecord.sourceTabPredecessorID == predecessorTabID)
        #expect(decodedRecord.sourceTabSuccessorID == successorTabID)
        #expect(decodedRecord.sourceTabCustomTitle == "Pinned Docs")
    }
}

private struct LegacyAppStatePayload: Codable {
    let windows: [WindowState]
    let workspacesByID: [UUID: LegacyWorkspacePayload]
    let selectedWindowID: UUID?
    let defaultTerminalProfileID: String?
    let configuredTerminalFontPoints: Double?
    let globalTerminalFontPoints: Double
}

private struct LegacyWorkspacePayload: Codable {
    let id: UUID
    let title: String
    let layoutTree: LayoutNode
    let panels: [UUID: PanelState]
    let focusedPanelID: UUID?
    let unreadPanelIDs: Set<UUID>
    let unreadNotificationCount: Int
    let recentlyClosedPanels: [ClosedPanelRecord]

    init(
        id: UUID,
        title: String,
        layoutTree: LayoutNode,
        panels: [UUID: PanelState],
        focusedPanelID: UUID?,
        unreadPanelIDs: Set<UUID>,
        unreadNotificationCount: Int,
        recentlyClosedPanels: [ClosedPanelRecord]
    ) {
        self.id = id
        self.title = title
        self.layoutTree = layoutTree
        self.panels = panels
        self.focusedPanelID = focusedPanelID
        self.unreadPanelIDs = unreadPanelIDs
        self.unreadNotificationCount = unreadNotificationCount
        self.recentlyClosedPanels = recentlyClosedPanels
    }

    init(_ workspace: WorkspaceState) {
        id = workspace.id
        title = workspace.title
        layoutTree = workspace.layoutTree
        panels = workspace.panels
        focusedPanelID = workspace.focusedPanelID
        unreadPanelIDs = workspace.unreadPanelIDs
        unreadNotificationCount = workspace.unreadWorkspaceNotificationCount
        recentlyClosedPanels = workspace.recentlyClosedPanels
    }
}
