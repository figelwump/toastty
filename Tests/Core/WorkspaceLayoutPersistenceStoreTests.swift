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
        #expect(restoredTerminalState.cwd == "/tmp/ephemeral")
    }

    private func makeTempStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-layout-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("workspace-layout-profiles.json", isDirectory: false)
    }

    private func makeLayout(title: String, cwd: String) -> WorkspaceLayoutSnapshot {
        var state = AppState.bootstrap()
        guard let workspaceID = state.windows.first?.selectedWorkspaceID,
              var workspace = state.workspacesByID[workspaceID],
              let panelID = workspace.focusedPanelID,
              case .terminal(var terminalState) = workspace.panels[panelID] else {
            fatalError("Bootstrap state did not contain expected focused terminal panel")
        }

        workspace.title = title
        terminalState.cwd = cwd
        workspace.panels[panelID] = .terminal(terminalState)
        state.workspacesByID[workspaceID] = workspace

        return WorkspaceLayoutSnapshot(state: state)
    }
}
