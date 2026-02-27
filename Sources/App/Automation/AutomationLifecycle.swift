import CoreState
import Foundation

final class AutomationLifecycle {
    private let config: AutomationConfig
    private let startupError: String?
    private let readySignalLock = NSLock()
    private var didSignalReady = false

    init(config: AutomationConfig, startupError: String? = nil) {
        self.config = config
        self.startupError = startupError
    }

    func markReady(runtimeError: String? = nil) {
        let shouldSignal = claimReadySignal()
        guard shouldSignal else { return }
        guard let artifactsDirectory = config.artifactsDirectory else { return }

        let fileManager = FileManager.default
        let artifactsURL = URL(fileURLWithPath: artifactsDirectory, isDirectory: true)
        let combinedError = [startupError, runtimeError]
            .compactMap { $0 }
            .joined(separator: " | ")
        let finalError = combinedError.isEmpty ? nil : combinedError

        do {
            try fileManager.createDirectory(at: artifactsURL, withIntermediateDirectories: true)

            let readyPayload = AutomationReadyPayload(
                protocolVersion: "1.0",
                ready: finalError == nil,
                runID: config.runID,
                fixture: config.fixtureName,
                socketPath: config.socketPath,
                status: finalError == nil ? "ready" : "error",
                error: finalError,
                timestamp: ISO8601DateFormatter().string(from: Date())
            )
            let readyData = try JSONEncoder().encode(readyPayload)
            let fileURL = artifactsURL.appendingPathComponent("automation-ready-\(sanitizedRunID(config.runID)).json")
            try readyData.write(to: fileURL, options: [.atomic])
        } catch {
            // Automation mode should not crash the app due to artifact I/O failures.
        }
    }

    private func sanitizedRunID(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "run"
    }

    private func claimReadySignal() -> Bool {
        readySignalLock.lock()
        defer { readySignalLock.unlock() }
        guard didSignalReady == false else { return false }
        didSignalReady = true
        return true
    }
}

private struct AutomationReadyPayload: Codable {
    let protocolVersion: String
    let ready: Bool
    let runID: String
    let fixture: String?
    let socketPath: String
    let status: String
    let error: String?
    let timestamp: String
}
