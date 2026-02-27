import CoreState
import Foundation

final class AutomationLifecycle {
    private let config: AutomationConfig
    private var didSignalReady = false

    init(config: AutomationConfig) {
        self.config = config
    }

    func markReady() {
        guard didSignalReady == false else { return }
        didSignalReady = true

        guard let artifactsDirectory = config.artifactsDirectory else { return }

        let fileManager = FileManager.default
        let artifactsURL = URL(fileURLWithPath: artifactsDirectory, isDirectory: true)
        do {
            try fileManager.createDirectory(at: artifactsURL, withIntermediateDirectories: true)

            let readyPayload = AutomationReadyPayload(
                runID: config.runID,
                fixture: config.fixtureName,
                status: "ready",
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
        let allowed = CharacterSet.alphanumerics
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("-") })
    }
}

private struct AutomationReadyPayload: Codable {
    let runID: String
    let fixture: String?
    let status: String
    let timestamp: String
}
