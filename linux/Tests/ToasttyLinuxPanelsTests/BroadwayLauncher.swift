import Foundation
import Glibc

// Kept identical to linux/Tests/ToasttyLinuxTests/BroadwayLauncher.swift
// (test targets cannot share sources).

/// Starts `gtk4-broadwayd` for a GUI test and returns once it accepts
/// connections. A fixed sleep after launch raced a loaded machine, and a
/// display already taken by another broadwayd (a leaked one, or another test
/// run) made ours exit on the busy port while the app then found no display
/// and crashed. Busy displays are skipped, and a server that exits or never
/// becomes ready is replaced by one on another display.
enum BroadwayLauncher {
    struct LaunchError: Error, CustomStringConvertible {
        let description: String
    }

    /// `preferred` (e.g. from BROADWAY_TEST_DISPLAY) is tried first, then
    /// displays from `displays` in random order.
    static func start(
        _ broadwayd: String,
        displays: Range<Int>,
        preferred: Int? = nil,
        environment: [String: String],
        log: URL,
        attempts: Int = 6,
        readyTimeout: TimeInterval = 10
    ) throws -> (process: Process, display: Int) {
        var candidates = displays.shuffled()
        if let preferred {
            candidates.removeAll { $0 == preferred }
            candidates.insert(preferred, at: 0)
        }
        var tried: [String] = []
        for display in candidates.prefix(attempts) {
            if portAcceptsConnections(httpPort(display)) {
                tried.append(":\(display) busy")
                continue
            }
            let process = try launch(broadwayd, display: display, environment: environment, log: log)
            let deadline = Date().addingTimeInterval(readyTimeout)
            while Date() < deadline, process.isRunning {
                if portAcceptsConnections(httpPort(display)) { return (process, display) }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                tried.append(":\(display) not ready after \(Int(readyTimeout))s")
            } else {
                tried.append(":\(display) exited with \(process.terminationStatus)")
            }
        }
        throw LaunchError(description: "gtk4-broadwayd did not start (\(tried.joined(separator: ", "))); see \(log.path)")
    }

    /// broadwayd serves display N over HTTP on port 8080 + N.
    static func httpPort(_ display: Int) -> UInt16 { UInt16(8080 + display) }

    private static func launch(_ path: String, display: Int, environment: [String: String], log: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [":\(display)"]
        process.environment = environment
        if !FileManager.default.fileExists(atPath: log.path) {
            _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return process
    }

    private static func portAcceptsConnections(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
