import Darwin
import Foundation
import Testing
@testable import ToasttyApp

struct AutomationSocketServerTests {
    @Test
    func removedLegacySessionEventsAreRejected() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            let store = AppStore(persistTerminalFontPreference: false)
            let terminalRuntimeRegistry = TerminalRuntimeRegistry()
            let sessionRuntimeStore = SessionRuntimeStore()
            let focusedPanelCommandController = FocusedPanelCommandController(
                store: store,
                runtimeRegistry: terminalRuntimeRegistry,
                slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
            )

            return try AutomationSocketServer(
                socketPath: socketPath,
                automationConfig: nil,
                store: store,
                terminalRuntimeRegistry: terminalRuntimeRegistry,
                sessionRuntimeStore: sessionRuntimeStore,
                focusedPanelCommandController: focusedPanelCommandController
            )
        }
        defer {
            withExtendedLifetime(server) {}
        }

        try waitForSocket(at: socketPath)

        for eventType in ["session.progress", "session.needs_input", "session.error"] {
            let response = try sendEvent(type: eventType, socketPath: socketPath)
            #expect(response.ok == false)
            #expect(response.error?.code == "UNKNOWN_EVENT_TYPE")
        }
    }

    private func temporarySocketPath() -> String {
        "/tmp/toastty-tests-\(UUID().uuidString.prefix(8)).sock"
    }

    private func waitForSocket(at socketPath: String) throws {
        let deadline = Date().addingTimeInterval(1)
        while FileManager.default.fileExists(atPath: socketPath) == false {
            guard Date() < deadline else {
                throw SocketTestError.timeoutWaitingForSocket
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func sendEvent(type eventType: String, socketPath: String) throws -> SocketResponse {
        let request = SocketEventRequest(
            protocolVersion: "1.0",
            kind: "event",
            eventType: eventType,
            payload: [:]
        )
        let payload = try JSONEncoder().encode(request) + Data([0x0A])
        let responseData = try send(payload, to: socketPath)
        return try JSONDecoder().decode(SocketResponse.self, from: responseData)
    }

    private func send(_ payload: Data, to socketPath: String) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketTestError.socket(errno)
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxPathLength else {
            throw SocketTestError.socketPathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                if let destinationAddress = buffer.baseAddress, let sourceAddress = source.baseAddress {
                    memcpy(destinationAddress, sourceAddress, pathBytes.count)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw SocketTestError.socket(errno)
        }

        let bytesWritten = payload.withUnsafeBytes { buffer in
            write(fd, buffer.baseAddress, payload.count)
        }
        guard bytesWritten == payload.count else {
            throw SocketTestError.shortWrite
        }

        var response = Data()
        var byte: UInt8 = 0
        while true {
            let bytesRead = read(fd, &byte, 1)
            if bytesRead == 0 {
                break
            }
            guard bytesRead > 0 else {
                throw SocketTestError.socket(errno)
            }
            if byte == 0x0A {
                return response
            }
            response.append(byte)
        }

        throw SocketTestError.missingResponseTerminator
    }
}

private struct SocketEventRequest: Encodable {
    let protocolVersion: String
    let kind: String
    let eventType: String
    let payload: [String: String]
}

private struct SocketResponse: Decodable {
    let ok: Bool
    let error: SocketResponseError?
}

private struct SocketResponseError: Decodable {
    let code: String
    let message: String
}

private enum SocketTestError: Error {
    case missingResponseTerminator
    case shortWrite
    case socket(Int32)
    case socketPathTooLong
    case timeoutWaitingForSocket
}
