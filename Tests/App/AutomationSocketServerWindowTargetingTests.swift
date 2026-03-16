@testable import ToasttyApp
import CoreState
import Darwin
import Foundation
import XCTest

final class AutomationSocketServerWindowTargetingTests: XCTestCase {
    func testWorkspaceActionUsesSoleWindowFallbackWhenSingleWindowExists() async throws {
        let fixture = makeSingleWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.split.right",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.selectedWindowID, fixture.windowID)
            XCTAssertEqual(state.workspacesByID[fixture.workspaceID]?.panels.count, 2)
        }
    }

    func testWorkspaceActionRequiresExplicitTargetWhenMultipleWindowsExist() async throws {
        let fixture = makeTwoWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.split.right",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertFalse(response.ok)
            XCTAssertEqual(
                response.errorMessage,
                "workspaceID or windowID is required when multiple windows exist"
            )

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.selectedWindowID, fixture.firstWindowID)
            XCTAssertEqual(state.workspacesByID[fixture.firstWorkspaceID]?.panels.count, 1)
            XCTAssertEqual(state.workspacesByID[fixture.secondWorkspaceID]?.panels.count, 1)
        }
    }

    func testWorkspaceActionUsesExplicitWindowSelection() async throws {
        let fixture = makeTwoWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.split.right",
                    "args": [
                        "windowID": fixture.secondWindowID.uuidString,
                    ],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.selectedWindowID, fixture.firstWindowID)
            XCTAssertEqual(state.workspacesByID[fixture.firstWorkspaceID]?.panels.count, 1)
            XCTAssertEqual(state.workspacesByID[fixture.secondWorkspaceID]?.panels.count, 2)
        }
    }

    func testWorkspaceActionUsesExplicitWorkspaceSelection() async throws {
        let fixture = makeTwoWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.split.right",
                    "args": [
                        "workspaceID": fixture.secondWorkspaceID.uuidString,
                    ],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.selectedWindowID, fixture.firstWindowID)
            XCTAssertEqual(state.workspacesByID[fixture.firstWorkspaceID]?.panels.count, 1)
            XCTAssertEqual(state.workspacesByID[fixture.secondWorkspaceID]?.panels.count, 2)
        }
    }

    func testWorkspaceProfileSplitBindsTheNewFocusedTerminalPanel() async throws {
        let fixture = makeSingleWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.split.right.with-profile",
                    "args": [
                        "profileID": "smoke-profile",
                    ],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            let workspace = try XCTUnwrap(state.workspacesByID[fixture.workspaceID])
            let focusedPanelID = try XCTUnwrap(workspace.focusedPanelID)
            XCTAssertEqual(workspace.panels.count, 2)
            guard case .terminal(let terminalState) = workspace.panels[focusedPanelID] else {
                XCTFail("expected focused panel to remain terminal")
                return
            }
            XCTAssertEqual(terminalState.profileBinding?.profileID, "smoke-profile")
        }
    }

    func testWorkspaceProfileSplitRequiresProfileID() async throws {
        let fixture = makeSingleWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.split.right.with-profile",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.errorMessage, "profileID is required")

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.workspacesByID[fixture.workspaceID]?.panels.count, 1)
        }
    }

    func testWorkspaceActionRejectsMismatchedWindowAndWorkspace() async throws {
        let fixture = makeTwoWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.split.right",
                    "args": [
                        "windowID": fixture.firstWindowID.uuidString,
                        "workspaceID": fixture.secondWorkspaceID.uuidString,
                    ],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.errorMessage, "workspaceID does not belong to windowID")

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.workspacesByID[fixture.firstWorkspaceID]?.panels.count, 1)
            XCTAssertEqual(state.workspacesByID[fixture.secondWorkspaceID]?.panels.count, 1)
        }
    }

    func testCreateWorkspaceUsesExplicitWindowSelection() async throws {
        let fixture = makeTwoWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "sidebar.workspaces.new",
                    "args": [
                        "windowID": fixture.secondWindowID.uuidString,
                        "title": "Detached",
                    ],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.selectedWindowID, fixture.firstWindowID)

            let firstWindow = try XCTUnwrap(state.window(id: fixture.firstWindowID))
            let secondWindow = try XCTUnwrap(state.window(id: fixture.secondWindowID))
            XCTAssertEqual(firstWindow.workspaceIDs.count, 1)
            XCTAssertEqual(secondWindow.workspaceIDs.count, 2)
            XCTAssertNotEqual(secondWindow.selectedWorkspaceID, fixture.secondWorkspaceID)

            let createdWorkspaceID = try XCTUnwrap(secondWindow.selectedWorkspaceID)
            XCTAssertEqual(state.workspacesByID[createdWorkspaceID]?.title, "Detached")
        }
    }

    func testCreateWorkspaceRequiresExplicitWindowWhenMultipleWindowsExist() async throws {
        let fixture = makeTwoWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "sidebar.workspaces.new",
                    "args": [
                        "title": "Detached",
                    ],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.errorMessage, "windowID is required when multiple windows exist")

            let state = await MainActor.run { harness.store.state }
            let firstWindow = try XCTUnwrap(state.window(id: fixture.firstWindowID))
            let secondWindow = try XCTUnwrap(state.window(id: fixture.secondWindowID))
            XCTAssertEqual(firstWindow.workspaceIDs.count, 1)
            XCTAssertEqual(secondWindow.workspaceIDs.count, 1)
        }
    }

    func testAppFontActionDoesNotRequireWorkspaceTargetWhenMultipleWindowsExist() async throws {
        let fixture = makeTwoWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "app.font.increase",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.globalTerminalFontPoints, AppState.defaultTerminalFontPoints + 1)
            XCTAssertEqual(state.selectedWindowID, fixture.firstWindowID)
        }
    }

    func testTerminalStateIncludesProfileIDWhenTerminalIsProfileBound() async throws {
        let fixture = makeSingleWindowFixture()
        var state = fixture.state
        guard let panelID = state.workspacesByID[fixture.workspaceID]?.focusedPanelID,
              case .terminal(var terminalState)? = state.workspacesByID[fixture.workspaceID]?.panels[panelID] else {
            XCTFail("expected bootstrap fixture to include a focused terminal")
            return
        }
        terminalState.profileBinding = TerminalProfileBinding(profileID: "smoke-profile")
        state.workspacesByID[fixture.workspaceID]?.panels[panelID] = .terminal(terminalState)

        try await withAutomationHarness(state: state) { harness in
            let response = try sendRequest(
                command: "automation.terminal_state",
                payload: [
                    "panelID": panelID.uuidString,
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)
            XCTAssertEqual(response.result["profileID"] as? String, "smoke-profile")
        }
    }

    private func withAutomationHarness(
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
    private static func makeAutomationHarness(state: AppState) throws -> AutomationHarness {
        let socketDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let socketPath = socketDirectory.appendingPathComponent("events-v1.sock", isDirectory: false).path
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
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
        let server = try AutomationSocketServer(
            config: config,
            store: store,
            terminalRuntimeRegistry: registry,
            focusedPanelCommandController: focusedPanelCommandController
        )
        return AutomationHarness(store: store, server: server, socketPath: socketPath)
    }

    private func sendRequest(
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

    private func sendEnvelope(
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

    private func withConnectedSocket<T>(
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

    private func writeAll(data: Data, to fileDescriptor: Int32) throws {
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

    private func readLine(from fileDescriptor: Int32) throws -> Data {
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

    private func makeTwoWindowFixture() -> TwoWindowFixture {
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
            selectedWindowID: firstWindowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        return TwoWindowFixture(
            state: state,
            firstWindowID: firstWindowID,
            secondWindowID: secondWindowID,
            firstWorkspaceID: firstWorkspace.id,
            secondWorkspaceID: secondWorkspace.id
        )
    }

    private func makeSingleWindowFixture() -> SingleWindowFixture {
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
            selectedWindowID: windowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        return SingleWindowFixture(
            state: state,
            windowID: windowID,
            workspaceID: workspace.id
        )
    }
}

private struct AutomationHarness {
    let store: AppStore
    let server: AutomationSocketServer
    let socketPath: String
}

private struct AutomationSocketTestResponse {
    let ok: Bool
    let result: [String: Any]
    let errorMessage: String?
}

private struct TwoWindowFixture {
    let state: AppState
    let firstWindowID: UUID
    let secondWindowID: UUID
    let firstWorkspaceID: UUID
    let secondWorkspaceID: UUID
}

private struct SingleWindowFixture {
    let state: AppState
    let windowID: UUID
    let workspaceID: UUID
}

private enum AutomationSocketTestError: Error {
    case missingResponse
    case socketFailure(String, Int32)
    case socketPathTooLong
}
