@testable import ToasttyApp
import CoreState
import CryptoKit
import Darwin
import Foundation
import XCTest

class AutomationSocketServerWindowTargetingTestCase: XCTestCase {
    func withAutomationHarness(
        state: AppState,
        file: StaticString = #filePath,
        line: UInt = #line,
        body: (AutomationHarness) async throws -> Void
    ) async throws {
        var harness: AutomationHarness? = try await MainActor.run {
            try Self.makeAutomationHarness(state: state)
        }
        do {
            try await body(try XCTUnwrap(harness, file: file, line: line))
            await MainActor.run { harness = nil }
        } catch {
            await MainActor.run { harness = nil }
            throw error
        }
    }

    @MainActor
    static func makeAutomationHarness(state: AppState) throws -> AutomationHarness {
        let socketDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let socketPath = socketDirectory.appendingPathComponent("events-v1.sock", isDirectory: false).path
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        registry.bind(sessionLifecycleTracker: sessionRuntimeStore)
        registry.bind(store: store)
        webPanelRuntimeRegistry.bind(store: store)
        let agentCatalogProvider = TestAgentCatalogProvider()
        let focusedPanelCommandController = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: registry,
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
        )
        let config = AutomationConfig(
            runID: UUID().uuidString,
            fixtureName: nil,
            artifactsDirectory: nil,
            socketPath: socketPath,
            disableAnimations: true,
            fixedLocaleIdentifier: nil,
            fixedTimeZoneIdentifier: nil
        )
        let agentLaunchService = AgentLaunchService(
            store: store,
            terminalCommandRouter: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogProvider,
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { socketPath }
        )
        let server = try AutomationSocketServer(
            socketPath: socketPath,
            automationConfig: config,
            store: store,
            terminalRuntimeRegistry: registry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: focusedPanelCommandController,
            agentLaunchService: agentLaunchService
        )
        return AutomationHarness(
            store: store,
            terminalRuntimeRegistry: registry,
            server: server,
            socketPath: socketPath,
            sessionRuntimeStore: sessionRuntimeStore
        )
    }

    func sendRequest(
        command: String,
        payload: [String: Any],
        socketPath: String
    ) throws -> AutomationSocketTestResponse {
        let request: [String: Any] = [
            "kind": "request",
            "protocolVersion": "1.0",
            "requestID": UUID().uuidString,
            "command": command,
            "payload": payload,
        ]
        return try sendEnvelope(request, socketPath: socketPath)
    }

    func sendEnvelope(
        _ envelope: [String: Any],
        socketPath: String
    ) throws -> AutomationSocketTestResponse {
        let requestData = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let responseData = try withConnectedSocket(socketPath: socketPath) { fileDescriptor in
            try writeAll(data: requestData + Data([0x0A]), to: fileDescriptor)
            return try readLine(from: fileDescriptor)
        }

        guard let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            XCTFail("expected response envelope")
            return AutomationSocketTestResponse(ok: false, result: [:], errorMessage: "invalid response")
        }

        let ok = (object["ok"] as? Bool) ?? false
        let errorMessage = (object["error"] as? [String: Any])?["message"] as? String
        let result = object["result"] as? [String: Any] ?? [:]
        return AutomationSocketTestResponse(ok: ok, result: result, errorMessage: errorMessage)
    }

    func withConnectedSocket<T>(
        socketPath: String,
        body: (Int32) throws -> T
    ) throws -> T {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw AutomationSocketTestError.socketFailure("socket", errno)
        }

        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socketPath.utf8CString)
            let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
            guard pathBytes.count <= maxPathLength else {
                throw AutomationSocketTestError.socketPathTooLong
            }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
                pathBytes.withUnsafeBytes { source in
                    if let destinationAddress = buffer.baseAddress,
                       let sourceAddress = source.baseAddress {
                        memcpy(destinationAddress, sourceAddress, pathBytes.count)
                    }
                }
            }

            let connectResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    connect(fileDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connectResult == 0 else {
                throw AutomationSocketTestError.socketFailure("connect", errno)
            }

            defer { close(fileDescriptor) }
            return try body(fileDescriptor)
        } catch {
            close(fileDescriptor)
            throw error
        }
    }

    func writeAll(data: Data, to fileDescriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in
                write(
                    fileDescriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    data.count - offset
                )
            }

            if written < 0 {
                if errno == EINTR {
                    continue
                }
                throw AutomationSocketTestError.socketFailure("write", errno)
            }

            offset += written
        }
    }

    func readLine(from fileDescriptor: Int32) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = read(fileDescriptor, &chunk, chunk.count)
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw AutomationSocketTestError.socketFailure("read", errno)
            }

            buffer.append(contentsOf: chunk[..<count])
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                return buffer.prefix(upTo: newlineIndex)
            }
        }

        throw AutomationSocketTestError.missingResponse
    }

    func makeTwoWindowFixture() -> TwoWindowFixture {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 48, y: 48, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        return TwoWindowFixture(
            state: state,
            firstWindowID: firstWindowID,
            secondWindowID: secondWindowID,
            firstWorkspaceID: firstWorkspace.id,
            secondWorkspaceID: secondWorkspace.id
        )
    }

    func makeSingleWindowFixture() -> SingleWindowFixture {
        let workspace = WorkspaceState.bootstrap(title: "One")
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                ),
            ],
            workspacesByID: [
                workspace.id: workspace,
            ],
            selectedWindowID: windowID
        )
        return SingleWindowFixture(
            state: state,
            windowID: windowID,
            workspaceID: workspace.id
        )
    }

    func makeSingleWindowUnreadFixture() -> SingleWindowUnreadFixture {
        let currentTab = makeUnreadNavigationTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let unreadTab = makeUnreadNavigationTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [2]
        )
        let workspace = makeUnreadNavigationWorkspace(
            title: "One",
            tabs: [currentTab, unreadTab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                ),
            ],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: windowID
        )
        return SingleWindowUnreadFixture(
            state: state,
            windowID: windowID,
            workspaceID: workspace.id,
            targetTabID: unreadTab.tab.id,
            targetPanelID: unreadTab.panelIDs[2]
        )
    }

    func makeSingleWindowUnreadAndActiveFixture() -> SingleWindowUnreadAndActiveFixture {
        let currentTab = makeUnreadNavigationTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let activeTab = makeUnreadNavigationTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let unreadTab = makeUnreadNavigationTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [2]
        )
        let workspace = makeUnreadNavigationWorkspace(
            title: "One",
            tabs: [currentTab, activeTab, unreadTab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                ),
            ],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: windowID
        )
        return SingleWindowUnreadAndActiveFixture(
            state: state,
            windowID: windowID,
            workspaceID: workspace.id,
            targetTabID: unreadTab.tab.id,
            targetPanelID: unreadTab.panelIDs[2],
            activePanelID: activeTab.panelIDs[1]
        )
    }

    func makeSingleWindowActiveFixture() -> SingleWindowActiveFixture {
        let currentTab = makeUnreadNavigationTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let activeTab = makeUnreadNavigationTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadNavigationWorkspace(
            title: "One",
            tabs: [currentTab, activeTab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                ),
            ],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: windowID
        )
        return SingleWindowActiveFixture(
            state: state,
            windowID: windowID,
            workspaceID: workspace.id,
            targetTabID: activeTab.tab.id,
            targetPanelID: activeTab.panelIDs[1]
        )
    }

    func makeTwoWindowUnreadFixture() -> TwoWindowUnreadFixture {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondCurrentTab = makeUnreadNavigationTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondUnreadTab = makeUnreadNavigationTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [1]
        )
        let secondWorkspace = makeUnreadNavigationWorkspace(
            title: "Two",
            tabs: [secondCurrentTab, secondUnreadTab],
            selectedTabIndex: 0
        )
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 48, y: 48, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        return TwoWindowUnreadFixture(
            state: state,
            firstWindowID: firstWindowID,
            secondWindowID: secondWindowID,
            secondWorkspaceID: secondWorkspace.id,
            targetTabID: secondUnreadTab.tab.id,
            targetPanelID: secondUnreadTab.panelIDs[1]
        )
    }
}

struct AutomationHarness {
    let store: AppStore
    let terminalRuntimeRegistry: TerminalRuntimeRegistry
    let server: AutomationSocketServer
    let socketPath: String
    let sessionRuntimeStore: SessionRuntimeStore
}

struct AutomationSocketTestResponse {
    let ok: Bool
    let result: [String: Any]
    let errorMessage: String?
}

struct TwoWindowFixture {
    let state: AppState
    let firstWindowID: UUID
    let secondWindowID: UUID
    let firstWorkspaceID: UUID
    let secondWorkspaceID: UUID
}

struct SingleWindowFixture {
    let state: AppState
    let windowID: UUID
    let workspaceID: UUID
}

struct SingleWindowUnreadFixture {
    let state: AppState
    let windowID: UUID
    let workspaceID: UUID
    let targetTabID: UUID
    let targetPanelID: UUID
}

struct SingleWindowUnreadAndActiveFixture {
    let state: AppState
    let windowID: UUID
    let workspaceID: UUID
    let targetTabID: UUID
    let targetPanelID: UUID
    let activePanelID: UUID
}

struct SingleWindowActiveFixture {
    let state: AppState
    let windowID: UUID
    let workspaceID: UUID
    let targetTabID: UUID
    let targetPanelID: UUID
}

struct TwoWindowUnreadFixture {
    let state: AppState
    let firstWindowID: UUID
    let secondWindowID: UUID
    let secondWorkspaceID: UUID
    let targetTabID: UUID
    let targetPanelID: UUID
}

private struct UnreadNavigationTabFixture {
    let tab: WorkspaceTabState
    let panelIDs: [UUID]
}

private enum AutomationSocketTestError: Error {
    case missingResponse
    case socketFailure(String, Int32)
    case socketPathTooLong
}

private func makeUnreadNavigationTab(
    focusedPanelIndex: Int,
    unreadPanelIndices: Set<Int>,
    panelCount: Int = 3
) -> UnreadNavigationTabFixture {
    let panelIDs = (0 ..< panelCount).map { _ in UUID() }
    let panels = Dictionary(uniqueKeysWithValues: panelIDs.enumerated().map { index, panelID in
        (
            panelID,
            PanelState.terminal(
                TerminalPanelState(
                    title: "Terminal \(index + 1)",
                    shell: "zsh",
                    cwd: NSHomeDirectory()
                )
            )
        )
    })

    let tab = WorkspaceTabState(
        id: UUID(),
        layoutTree: makeUnreadNavigationLayout(panelIDs: panelIDs),
        panels: panels,
        focusedPanelID: panelIDs[focusedPanelIndex],
        unreadPanelIDs: Set(unreadPanelIndices.map { panelIDs[$0] })
    )

    return UnreadNavigationTabFixture(tab: tab, panelIDs: panelIDs)
}

private func makeUnreadNavigationWorkspace(
    title: String,
    tabs: [UnreadNavigationTabFixture],
    selectedTabIndex: Int
) -> WorkspaceState {
    let tabIDs = tabs.map(\.tab.id)
    return WorkspaceState(
        id: UUID(),
        title: title,
        selectedTabID: tabIDs[selectedTabIndex],
        tabIDs: tabIDs,
        tabsByID: Dictionary(uniqueKeysWithValues: tabs.map { ($0.tab.id, $0.tab) })
    )
}

private func makeUnreadNavigationLayout(panelIDs: [UUID]) -> LayoutNode {
    precondition(panelIDs.isEmpty == false)

    var iterator = panelIDs.makeIterator()
    let firstPanelID = iterator.next()!
    var layout = LayoutNode.slot(slotID: UUID(), panelID: firstPanelID)

    while let panelID = iterator.next() {
        layout = .split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: layout,
            second: .slot(slotID: UUID(), panelID: panelID)
        )
    }

    return layout
}
