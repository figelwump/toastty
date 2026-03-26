@testable import ToasttyApp
import CoreState
import Darwin
import Foundation
import XCTest

final class AutomationLifecycleTests: XCTestCase {
    func testMarkReadyWritesUpdatedSocketPath() throws {
        let fileManager = FileManager.default
        let rootURL = try makeShortTemporaryDirectory(prefix: "tal")
        defer { try? fileManager.removeItem(at: rootURL) }

        let artifactsURL = rootURL.appendingPathComponent("artifacts", isDirectory: true)
        let originalSocketPath = rootURL.appendingPathComponent("events-v1.sock", isDirectory: false).path
        let resolvedSocketPath = rootURL.appendingPathComponent("events-v1-4242.sock", isDirectory: false).path
        let config = AutomationConfig(
            runID: "ready-path",
            fixtureName: nil,
            artifactsDirectory: artifactsURL.path,
            socketPath: originalSocketPath,
            disableAnimations: true,
            fixedLocaleIdentifier: nil,
            fixedTimeZoneIdentifier: nil
        )
        let lifecycle = AutomationLifecycle(config: config)

        lifecycle.updateSocketPath(resolvedSocketPath)
        lifecycle.markReady()

        let readyFileURL = artifactsURL.appendingPathComponent("automation-ready-ready-path.json")
        let readyData = try Data(contentsOf: readyFileURL)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: readyData) as? [String: Any]
        )

        XCTAssertEqual(payload["socketPath"] as? String, resolvedSocketPath)
        XCTAssertEqual(payload["status"] as? String, "ready")
        XCTAssertEqual(payload["ready"] as? Bool, true)
    }

    private func makeShortTemporaryDirectory(prefix: String) throws -> URL {
        var template = "/tmp/\(prefix).XXXXXX".utf8CString
        let createdPath = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let baseAddress = buffer.baseAddress, mkdtemp(baseAddress) != nil else {
                return nil
            }
            return String(cString: baseAddress)
        }
        guard let createdPath else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno)
            )
        }
        return URL(fileURLWithPath: createdPath, isDirectory: true)
    }
}
