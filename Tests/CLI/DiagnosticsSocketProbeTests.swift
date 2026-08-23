import CoreState
import Darwin
import Foundation
import Testing
@testable import ToasttyCLIKit

struct DiagnosticsSocketProbeTests {
    @Test
    func permissionDeniedStateRoundTripsAndLegacyStatRemainsDecodable() throws {
        let stateData = try JSONEncoder().encode(DiagnosticsSocketState.permissionDenied)
        #expect(String(decoding: stateData, as: UTF8.self) == "\"permission-denied\"")
        #expect(try JSONDecoder().decode(DiagnosticsSocketState.self, from: stateData) == .permissionDenied)

        let legacyStat = Data(
            #"{"exists":true,"isSocket":true,"mode":"0700","ownerUID":501,"groupID":20,"sizeBytes":0}"#.utf8
        )
        let decodedStat = try JSONDecoder().decode(DiagnosticsSocketStat.self, from: legacyStat)
        #expect(decodedStat.exists)
        #expect(decodedStat.isSocket)
        #expect(decodedStat.errnoCode == nil)
    }

    @Test
    func classifiesNoSocket() throws {
        let root = try makeProbeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("missing.sock", isDirectory: false).path

        let result = DiagnosticsSocketProbe(
            connectProbe: { _, _ in Issue.record("connect should not run"); return connectedResult() },
            pingProbe: { _, _ in Issue.record("ping should not run"); return healthyPingResult() }
        )
        .probe(
            environment: ["TMPDIR": root.path + "/"],
            socketPathOverride: socketPath,
            pathSourceOverride: .cliOption
        )

        #expect(result.state == .noSocket)
        #expect(result.connect.status == "not-found")
        #expect(result.pathSource == .cliOption)
    }

    @Test
    func classifiesHealthySocket() throws {
        let root = try makeProbeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("healthy.sock", isDirectory: false).path
        try makeSocketFile(at: socketPath)

        let result = DiagnosticsSocketProbe(
            connectProbe: { _, _ in connectedResult() },
            pingProbe: { _, _ in healthyPingResult() }
        )
        .probe(
            environment: ["TMPDIR": root.path + "/"],
            socketPathOverride: socketPath,
            pathSourceOverride: .cliOption
        )

        #expect(result.state == .healthy)
        #expect(result.stat.isSocket)
        #expect(result.ping?.automationEnabled == true)
    }

    @Test
    func classifiesRefusedAndTimeout() throws {
        let root = try makeProbeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("refused.sock", isDirectory: false).path
        try makeSocketFile(at: socketPath)

        let refused = DiagnosticsSocketProbe(
            connectProbe: { _, _ in
                DiagnosticsSocketConnectResult(status: "refused", errnoCode: ECONNREFUSED, error: "Connection refused", latencyMs: 1)
            },
            pingProbe: { _, _ in Issue.record("ping should not run"); return healthyPingResult() }
        )
        .probe(
            environment: ["TMPDIR": root.path + "/"],
            socketPathOverride: socketPath,
            pathSourceOverride: .cliOption
        )

        let timeout = DiagnosticsSocketProbe(
            connectProbe: { _, _ in
                DiagnosticsSocketConnectResult(status: "timeout", errnoCode: ETIMEDOUT, error: "connect timed out", latencyMs: 2_000)
            },
            pingProbe: { _, _ in Issue.record("ping should not run"); return healthyPingResult() }
        )
        .probe(
            environment: ["TMPDIR": root.path + "/"],
            socketPathOverride: socketPath,
            pathSourceOverride: .cliOption
        )

        #expect(refused.state == .refused)
        #expect(timeout.state == .timeout)
    }

    @Test
    func classifiesPermissionDeniedWithoutCallingTheSocketStale() throws {
        let root = try makeProbeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("permission-denied.sock", isDirectory: false).path
        try makeSocketFile(at: socketPath)

        for errnoCode in [EPERM, EACCES] {
            let result = DiagnosticsSocketProbe(
                connectProbe: { _, _ in
                    DiagnosticsSocketConnectResult(
                        status: "error",
                        errnoCode: errnoCode,
                        error: String(cString: strerror(errnoCode)),
                        latencyMs: 1
                    )
                },
                pingProbe: { _, _ in Issue.record("ping should not run"); return healthyPingResult() }
            )
            .probe(
                environment: ["TMPDIR": root.path + "/"],
                socketPathOverride: socketPath,
                pathSourceOverride: .cliOption
            )

            #expect(result.state == .permissionDenied)
            #expect(result.connect.errnoCode == errnoCode)
        }
    }

    @Test
    func classifiesPermissionDeniedWhenSandboxBlocksSocketMetadata() {
        for errnoCode in [EPERM, EACCES] {
            let result = DiagnosticsSocketProbe(
                connectProbe: { _, _ in Issue.record("connect should not run"); return connectedResult() },
                pingProbe: { _, _ in Issue.record("ping should not run"); return healthyPingResult() },
                statProbe: { _ in
                    DiagnosticsSocketStat(
                        exists: false,
                        isSocket: false,
                        mode: nil,
                        ownerUID: nil,
                        groupID: nil,
                        sizeBytes: nil,
                        error: String(cString: strerror(errnoCode)),
                        errnoCode: errnoCode
                    )
                }
            )
            .probe(
                environment: ["TMPDIR": "/tmp/"],
                socketPathOverride: "/tmp/toastty-hidden.sock",
                pathSourceOverride: .cliOption
            )

            #expect(result.state == .permissionDenied)
            #expect(result.connect.status == "permission-denied")
            #expect(result.stat.errnoCode == errnoCode)
        }
    }

    @Test
    func classifiesRegularFileAsStale() throws {
        let root = try makeProbeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("not-a-socket.sock", isDirectory: false)
        try Data().write(to: socketPath)

        let result = DiagnosticsSocketProbe(
            connectProbe: { _, _ in Issue.record("connect should not run"); return connectedResult() },
            pingProbe: { _, _ in Issue.record("ping should not run"); return healthyPingResult() }
        )
        .probe(
            environment: ["TMPDIR": root.path + "/"],
            socketPathOverride: socketPath.path,
            pathSourceOverride: .cliOption
        )

        #expect(result.state == .stale)
        #expect(result.stat.exists)
        #expect(result.stat.isSocket == false)
    }
}

private func connectedResult() -> DiagnosticsSocketConnectResult {
    DiagnosticsSocketConnectResult(status: "connected", errnoCode: nil, error: nil, latencyMs: 1)
}

private func healthyPingResult() -> DiagnosticsSocketPingResult {
    DiagnosticsSocketPingResult(
        ok: true,
        latencyMs: 1,
        automationEnabled: true,
        appUptimeMs: 123,
        protocolVersion: "1.0",
        error: nil
    )
}

private func makeProbeTemporaryDirectory() throws -> URL {
    var template = "/tmp/tdp.XXXXXX".utf8CString
    let createdPath = template.withUnsafeMutableBufferPointer { buffer -> String? in
        guard let baseAddress = buffer.baseAddress, mkdtemp(baseAddress) != nil else {
            return nil
        }
        return String(cString: baseAddress)
    }
    guard let createdPath else {
        throw ProbeSocketError.socket(String(cString: strerror(errno)))
    }
    return URL(fileURLWithPath: createdPath, isDirectory: true)
}

private func makeSocketFile(at path: String) throws {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw ProbeSocketError.socket(String(cString: strerror(errno)))
    }
    defer { close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= maxPathLength else {
        throw ProbeSocketError.socket("path too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        pathBytes.withUnsafeBytes { source in
            if let destination = buffer.baseAddress, let source = source.baseAddress {
                memcpy(destination, source, pathBytes.count)
            }
        }
    }

    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        throw ProbeSocketError.socket(String(cString: strerror(errno)))
    }
}

private enum ProbeSocketError: Error {
    case socket(String)
}
