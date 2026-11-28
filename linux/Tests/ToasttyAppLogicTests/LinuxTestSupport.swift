import Foundation
import Testing
@testable import ToasttyAppLogic

/// Helpers for the Linux-only integration tests.
enum LinuxTestSupport {
    struct ProcessResult: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    enum Failure: Error, CustomStringConvertible {
        case missingExecutable(String)
        case timedOut(String)

        var description: String {
            switch self {
            case .missingExecutable(let path): "missing executable \(path) (run swift build --build-tests)"
            case .timedOut(let what): "timed out waiting for \(what)"
            }
        }
    }

    /// SwiftPM puts every product next to the test runner.
    static func productPath(_ name: String) throws -> String {
        let path = Bundle.main.bundleURL.appendingPathComponent(name).path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw Failure.missingExecutable(path)
        }
        return path
    }

    /// Runs a process without blocking the caller's actor, so a test on the
    /// main actor can drive the app's socket server, which hops to it.
    static func run(
        _ executable: String,
        _ arguments: [String],
        stdin: Data? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 20
    ) async throws -> ProcessResult {
        let box = ProcessBox(executable: executable, arguments: arguments, stdin: stdin, environment: environment)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try box.runBlocking(timeout: timeout) })
            }
        }
    }

    /// Polls `condition` on the main actor until it holds.
    @MainActor
    static func waitUntil(
        _ what: String,
        timeout: TimeInterval = 10,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while condition() == false {
            guard Date() < deadline else { throw Failure.timedOut(what) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A short directory under $TMPDIR (test.sh keeps it short enough for
    /// AF_UNIX socket paths).
    static func makeTemporaryDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A free loopback TCP port.
    static func freeLoopbackPort() throws -> UInt16 {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    /// Sets environment variables for the duration of a test.
    final class ScopedEnvironment {
        private var previous: [String: String?] = [:]

        func set(_ name: String, _ value: String?) {
            if previous.keys.contains(name) == false {
                previous[name] = ProcessInfo.processInfo.environment[name]
            }
            if let value {
                setenv(name, value, 1)
            } else {
                unsetenv(name)
            }
        }

        func restore() {
            for (name, value) in previous {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
            previous.removeAll()
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    let executable: String
    let arguments: [String]
    let stdin: Data?
    let environment: [String: String]?

    init(executable: String, arguments: [String], stdin: Data?, environment: [String: String]?) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        self.environment = environment
    }

    func runBlocking(timeout: TimeInterval) throws -> LinuxTestSupport.ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe()
        let error = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = input
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if let stdin {
            try? input.fileHandleForWriting.write(contentsOf: stdin)
        }
        try? input.fileHandleForWriting.close()
        // Drain while waiting so a chatty child cannot fill the pipe.
        let collected = CollectedOutput()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            collected.stdout = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            collected.stderr = error.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            throw LinuxTestSupport.Failure.timedOut("\(executable) \(arguments.joined(separator: " "))")
        }
        _ = group.wait(timeout: .now() + 5)
        return LinuxTestSupport.ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: collected.stdout, as: UTF8.self),
            stderr: String(decoding: collected.stderr, as: UTF8.self)
        )
    }
}

private final class CollectedOutput: @unchecked Sendable {
    var stdout = Data()
    var stderr = Data()
}
