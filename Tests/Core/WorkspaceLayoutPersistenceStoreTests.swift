import CoreState
import Foundation
import Testing

struct WorkspaceLayoutPersistenceStoreTests {
    @Test
    func persistsAndLoadsLayoutByProfile() throws {
        let fileURL = try makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = WorkspaceLayoutPersistenceStore(fileURL: fileURL)
        let desktopLayout = makeLayout(title: "Desktop", cwd: "/tmp/desktop")
        let laptopLayout = makeLayout(title: "Laptop", cwd: "/tmp/laptop")

        #expect(store.persistLayout(desktopLayout, for: "desktop"))
        #expect(store.persistLayout(laptopLayout, for: "laptop"))

        let desktop = try #require(store.loadLayout(for: "desktop"))
        let laptop = try #require(store.loadLayout(for: "laptop"))

        #expect(desktop.resolvedProfileID == "desktop")
        #expect(laptop.resolvedProfileID == "laptop")
        #expect(desktop.layout == desktopLayout)
        #expect(laptop.layout == laptopLayout)
    }

    @Test
    func annotationUsageCountsExcludeProfilesRepresentedByLiveState() throws {
        let fileURL = try makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = WorkspaceLayoutPersistenceStore(fileURL: fileURL)
        #expect(store.persistLayout(
            makeLayout(
                title: "Desktop",
                cwd: "/tmp/desktop",
                annotations: [
                    "git-branch": WorkspaceAnnotation(text: "main"),
                    "github-pr": WorkspaceAnnotation(text: "PR #1"),
                ]
            ),
            for: "desktop"
        ))
        #expect(store.persistLayout(
            makeLayout(
                title: "Laptop",
                cwd: "/tmp/laptop",
                annotations: ["git-branch": WorkspaceAnnotation(text: "feature")]
            ),
            for: "laptop"
        ))

        #expect(try store.annotationUsageCounts(excludingProfileIDs: []) == [
            "git-branch": 2,
            "github-pr": 1,
        ])
        #expect(try store.annotationUsageCounts(excludingProfileIDs: ["desktop"]) == [
            "git-branch": 1,
        ])
    }

    @Test
    func annotationUsageCountsFailClosedForUnreadableDocument() throws {
        let fileURL = try makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try Data("not valid json".utf8).write(to: fileURL, options: .atomic)

        let store = WorkspaceLayoutPersistenceStore(fileURL: fileURL)

        #expect(throws: (any Error).self) {
            try store.annotationUsageCounts(excludingProfileIDs: [])
        }
    }

    @Test
    func persistsCommittedSplitRatio() throws {
        let fileURL = try makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state))

        let splitNodeID: UUID
        if case .split(let nodeID, _, _, _, _) = try #require(state.workspacesByID[workspaceID]?.layoutTree) {
            splitNodeID = nodeID
        } else {
            Issue.record("Expected bootstrap split")
            return
        }
        #expect(
            reducer.send(
                .setLayoutSplitRatio(workspaceID: workspaceID, nodeID: splitNodeID, ratio: 0.68),
                state: &state
            )
        )

        let store = WorkspaceLayoutPersistenceStore(fileURL: fileURL)
        #expect(store.persistLayout(WorkspaceLayoutSnapshot(state: state), for: "desktop"))

        let loaded = try #require(store.loadLayout(for: "desktop"))
        let restoredState = loaded.layout.makeAppState()
        let restoredWorkspace = try #require(restoredState.workspacesByID[workspaceID])
        guard case .split(_, _, let restoredRatio, _, _) = restoredWorkspace.layoutTree else {
            Issue.record("Expected restored split")
            return
        }

        #expect(restoredRatio == 0.68)
    }

    @Test
    func usesFallbackAndSingleProfileResolutionOrder() throws {
        let fileURL = try makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = WorkspaceLayoutPersistenceStore(fileURL: fileURL)
        let desktopLayout = makeLayout(title: "Desktop", cwd: "/tmp/desktop")

        #expect(store.persistLayout(desktopLayout, for: "desktop"))

        let fallbackMatch = try #require(
            store.loadLayout(for: "unknown", fallbackProfileID: "desktop")
        )
        #expect(fallbackMatch.resolvedProfileID == "desktop")
        #expect(fallbackMatch.layout == desktopLayout)

        let singleProfileMatch = try #require(store.loadLayout(for: "unknown"))
        #expect(singleProfileMatch.resolvedProfileID == "desktop")
        #expect(singleProfileMatch.layout == desktopLayout)
    }

    @Test
    func rejectsInvalidLayoutBeforePersisting() throws {
        let fileURL = try makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = WorkspaceLayoutPersistenceStore(fileURL: fileURL)
        let orphanWorkspaceID = UUID()
        let invalidLayout = WorkspaceLayoutSnapshot(
            windows: [
                WindowState(
                    id: UUID(),
                    frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                    workspaceIDs: [orphanWorkspaceID],
                    selectedWorkspaceID: orphanWorkspaceID
                ),
            ],
            selectedWindowID: nil,
            workspacesByID: [:]
        )

        #expect(store.persistLayout(invalidLayout, for: "desktop") == false)
        #expect(store.loadLayout(for: "desktop") == nil)
    }

    @Test
    func persistsTerminalPanelsWithoutTitleMetadata() throws {
        let fileURL = try makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = WorkspaceLayoutPersistenceStore(fileURL: fileURL)
        var state = AppState.bootstrap()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let panelID = try #require(workspace.focusedPanelID)
        guard case .terminal(var terminalState) = workspace.panels[panelID] else {
            Issue.record("Expected focused panel to be terminal")
            return
        }

        terminalState.title = "Ephemeral Agent Title"
        terminalState.cwd = "/tmp/ephemeral"
        workspace.panels[panelID] = .terminal(terminalState)
        state.workspacesByID[workspaceID] = workspace

        let layout = WorkspaceLayoutSnapshot(state: state)
        #expect(store.persistLayout(layout, for: "desktop"))

        let persistedData = try Data(contentsOf: fileURL)
        let persistedJSON = String(decoding: persistedData, as: UTF8.self)
        #expect(persistedJSON.contains("Ephemeral Agent Title") == false)

        let loaded = try #require(store.loadLayout(for: "desktop"))
        let restoredState = loaded.layout.makeAppState()
        let restoredWorkspace = try #require(restoredState.workspacesByID[workspaceID])
        guard case .terminal(let restoredTerminalState) = restoredWorkspace.panels[panelID] else {
            Issue.record("Expected restored panel to be terminal")
            return
        }
        #expect(restoredTerminalState.title == "Terminal 1")
        #expect(restoredTerminalState.cwd.isEmpty)
        #expect(restoredTerminalState.launchWorkingDirectory == "/tmp/ephemeral")
    }

    @Test
    func topologyFingerprintIsDeterministicAndContentFree() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let firstWorkspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        #expect(
            reducer.send(
                .createWorkspace(windowID: windowID, title: "Private second workspace", activate: false),
                state: &state
            )
        )
        #expect(reducer.send(.createWorkspaceTab(workspaceID: firstWorkspaceID, seed: nil), state: &state))
        let layout = WorkspaceLayoutSnapshot(state: state)
        let original = WorkspaceLayoutPersistenceStore.diagnosticsSummary(
            for: layout,
            profileID: "desktop"
        )

        var reordered = layout
        reordered.workspacesByID = Dictionary(
            uniqueKeysWithValues: layout.workspacesByID
                .sorted { $0.key.uuidString > $1.key.uuidString }
        )
        for workspaceID in reordered.workspacesByID.keys {
            guard var workspace = reordered.workspacesByID[workspaceID] else { continue }
            workspace.tabsByID = Dictionary(
                uniqueKeysWithValues: workspace.tabsByID
                    .sorted { $0.key.uuidString > $1.key.uuidString }
            )
            reordered.workspacesByID[workspaceID] = workspace
        }
        let reorderedSummary = WorkspaceLayoutPersistenceStore.diagnosticsSummary(
            for: reordered,
            profileID: "desktop"
        )
        #expect(reorderedSummary.fingerprint == original.fingerprint)

        let roundTripped = try JSONDecoder().decode(
            WorkspaceLayoutSnapshot.self,
            from: JSONEncoder().encode(layout)
        )
        let roundTrippedSummary = WorkspaceLayoutPersistenceStore.diagnosticsSummary(
            for: roundTripped,
            profileID: "desktop"
        )
        #expect(roundTrippedSummary.fingerprint == original.fingerprint)

        var contentChanged = layout
        var workspace = try #require(contentChanged.workspacesByID[firstWorkspaceID])
        workspace.title = "Different private title"
        workspace.annotations = ["customer": WorkspaceAnnotation(text: "Different secret")]
        contentChanged.workspacesByID[firstWorkspaceID] = workspace
        let contentChangedSummary = WorkspaceLayoutPersistenceStore.diagnosticsSummary(
            for: contentChanged,
            profileID: "desktop"
        )
        #expect(contentChangedSummary.fingerprint == original.fingerprint)

        var topologyChanged = layout
        topologyChanged.windows[0].workspaceIDs.reverse()
        let topologyChangedSummary = WorkspaceLayoutPersistenceStore.diagnosticsSummary(
            for: topologyChanged,
            profileID: "desktop"
        )
        #expect(topologyChangedSummary.fingerprint != original.fingerprint)
    }

    @Test
    func loadsLegacySingleTabWorkspaceLayoutPayloadFromDisk() throws {
        let fileURL = try makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let profileID = "desktop"
        let windowID = UUID()
        let workspaceID = UUID()
        let slotID = UUID()
        let panelID = UUID()
        let legacyDocument = LegacyWorkspaceLayoutPersistenceDocument(
            version: 1,
            profiles: [
                profileID: LegacyWorkspaceLayoutPersistedProfile(
                    updatedAt: Date(timeIntervalSince1970: 1_710_000_100),
                    layout: LegacyWorkspaceLayoutSnapshotPayload(
                        windows: [
                            WindowState(
                                id: windowID,
                                frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                                workspaceIDs: [workspaceID],
                                selectedWorkspaceID: workspaceID
                            ),
                        ],
                        selectedWindowID: windowID,
                        workspacesByID: [
                            workspaceID: LegacyWorkspaceLayoutWorkspacePayload(
                                id: workspaceID,
                                title: "Desktop",
                                layoutTree: .slot(slotID: slotID, panelID: panelID),
                                panels: [
                                    panelID: .terminal(
                                        WorkspaceLayoutTerminalPanelSnapshot(
                                            shell: "zsh",
                                            launchWorkingDirectory: "/tmp/desktop",
                                            profileBinding: TerminalProfileBinding(profileID: "ssh-prod")
                                        )
                                    ),
                                ],
                                focusedPanelID: panelID
                            ),
                        ]
                    )
                ),
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(legacyDocument).write(to: fileURL, options: .atomic)

        let store = WorkspaceLayoutPersistenceStore(fileURL: fileURL)
        let loaded = try #require(store.loadLayout(for: profileID))
        let restoredState = loaded.layout.makeAppState()
        let restoredWorkspace = try #require(restoredState.workspacesByID[workspaceID])
        let restoredTabID = try #require(restoredWorkspace.selectedTabID)

        #expect(loaded.resolvedProfileID == profileID)
        #expect(restoredWorkspace.tabIDs == [restoredTabID])
        #expect(restoredWorkspace.selectedTabID == restoredTabID)
        #expect(restoredWorkspace.title == "Desktop")
        #expect(restoredWorkspace.focusedPanelID == panelID)

        guard case .terminal(let restoredTerminal) = try #require(restoredWorkspace.tab(id: restoredTabID)?.panels[panelID]) else {
            Issue.record("Expected restored legacy layout panel to remain terminal")
            return
        }

        #expect(restoredTerminal.launchWorkingDirectory == "/tmp/desktop")
        #expect(restoredTerminal.profileBinding == TerminalProfileBinding(profileID: "ssh-prod"))
        try StateValidator.validate(restoredState)
    }

    private func makeTempStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-layout-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("workspace-layout-profiles.json", isDirectory: false)
    }

    private func makeLayout(
        title: String,
        cwd: String,
        annotations: [String: WorkspaceAnnotation] = [:]
    ) -> WorkspaceLayoutSnapshot {
        var state = AppState.bootstrap()
        guard let workspaceID = state.windows.first?.selectedWorkspaceID,
              var workspace = state.workspacesByID[workspaceID],
              let panelID = workspace.focusedPanelID,
              case .terminal(var terminalState) = workspace.panels[panelID] else {
            fatalError("Bootstrap state did not contain expected focused terminal panel")
        }

        workspace.title = title
        workspace.annotations = annotations
        terminalState.cwd = cwd
        workspace.panels[panelID] = .terminal(terminalState)
        state.workspacesByID[workspaceID] = workspace

        return WorkspaceLayoutSnapshot(state: state)
    }
}

private struct LegacyWorkspaceLayoutPersistenceDocument: Codable {
    let version: Int
    let profiles: [String: LegacyWorkspaceLayoutPersistedProfile]
}

private struct LegacyWorkspaceLayoutPersistedProfile: Codable {
    let updatedAt: Date
    let layout: LegacyWorkspaceLayoutSnapshotPayload
}

private struct LegacyWorkspaceLayoutSnapshotPayload: Codable {
    let windows: [WindowState]
    let selectedWindowID: UUID?
    let workspacesByID: [UUID: LegacyWorkspaceLayoutWorkspacePayload]
}

private struct LegacyWorkspaceLayoutWorkspacePayload: Codable {
    let id: UUID
    let title: String
    let layoutTree: LayoutNode
    let panels: [UUID: WorkspaceLayoutPanelSnapshot]
    let focusedPanelID: UUID?
}
