import CoreState
import Foundation
@testable import ToasttyApp
import XCTest

@MainActor
final class CommandPaletteUsageTrackerTests: XCTestCase {
    func testTrackerPersistsUsageInsideRuntimeHomeConfigDirectory() throws {
        let fileManager = FileManager.default
        let rootURL = try makeShortTemporaryDirectory(prefix: "cpur")
        defer { try? fileManager.removeItem(at: rootURL) }

        let runtimeHomeURL = rootURL.appendingPathComponent("runtime-home", isDirectory: true)
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: rootURL.path,
            environment: ["TOASTTY_RUNTIME_HOME": runtimeHomeURL.path]
        )
        let recordedAt = Date(timeIntervalSinceReferenceDate: 123)
        let tracker = CommandPaletteUsageTracker(
            runtimePaths: runtimePaths,
            fileManager: fileManager,
            dateProvider: { recordedAt }
        )

        tracker.recordSuccessfulExecution(of: "workspace.create")

        let persistedRecords = try loadRecords(
            from: runtimePaths.configDirectoryURL.appending(
                path: "command-palette-usage.json",
                directoryHint: .notDirectory
            )
        )
        XCTAssertEqual(
            persistedRecords["workspace.create"],
            CommandPaletteUsageRecord(count: 1, lastUsedAt: recordedAt)
        )
    }

    func testTrackerPersistsUsageUnderUserHomeConfigDirectoryWithoutRuntimeIsolation() throws {
        let fileManager = FileManager.default
        let rootURL = try makeShortTemporaryDirectory(prefix: "cpuh")
        defer { try? fileManager.removeItem(at: rootURL) }

        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: rootURL.path,
            environment: [:]
        )
        let recordedAt = Date(timeIntervalSinceReferenceDate: 456)
        let tracker = CommandPaletteUsageTracker(
            runtimePaths: runtimePaths,
            fileManager: fileManager,
            dateProvider: { recordedAt }
        )

        tracker.recordSuccessfulExecution(of: "window.create")

        let usageFileURL = rootURL
            .appendingPathComponent(".toastty", isDirectory: true)
            .appendingPathComponent("command-palette-usage.json", isDirectory: false)
        XCTAssertEqual(usageFileURL, runtimePaths.configDirectoryURL.appending(path: "command-palette-usage.json"))
        XCTAssertTrue(fileManager.fileExists(atPath: usageFileURL.path))
    }

    func testTrackerLoadsAndIncrementsExistingUsage() throws {
        let fileManager = FileManager.default
        let rootURL = try makeShortTemporaryDirectory(prefix: "cpul")
        defer { try? fileManager.removeItem(at: rootURL) }

        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: rootURL.path,
            environment: [:]
        )
        let usageFileURL = runtimePaths.configDirectoryURL.appending(
            path: "command-palette-usage.json",
            directoryHint: .notDirectory
        )
        try fileManager.createDirectory(
            at: usageFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeRecords(
            [
                "workspace.create": CommandPaletteUsageRecord(
                    count: 2,
                    lastUsedAt: Date(timeIntervalSinceReferenceDate: 10)
                ),
            ],
            to: usageFileURL
        )

        let recordedAt = Date(timeIntervalSinceReferenceDate: 20)
        let tracker = CommandPaletteUsageTracker(
            runtimePaths: runtimePaths,
            fileManager: fileManager,
            dateProvider: { recordedAt }
        )

        XCTAssertEqual(tracker.useCount(for: "workspace.create"), 2)
        XCTAssertEqual(tracker.lastUsedAt(for: "workspace.create"), Date(timeIntervalSinceReferenceDate: 10))

        tracker.recordSuccessfulExecution(of: "workspace.create")

        XCTAssertEqual(tracker.useCount(for: "workspace.create"), 3)
        let persistedRecords = try loadRecords(from: usageFileURL)
        XCTAssertEqual(
            persistedRecords["workspace.create"],
            CommandPaletteUsageRecord(count: 3, lastUsedAt: recordedAt)
        )
    }

    func testTrackerLoadsLegacyUsageRecordsWithoutLastUsedAt() throws {
        let fileManager = FileManager.default
        let rootURL = try makeShortTemporaryDirectory(prefix: "cpum")
        defer { try? fileManager.removeItem(at: rootURL) }

        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: rootURL.path,
            environment: [:]
        )
        let usageFileURL = runtimePaths.configDirectoryURL.appending(
            path: "command-palette-usage.json",
            directoryHint: .notDirectory
        )
        try fileManager.createDirectory(
            at: usageFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacyJSON = """
        {
          "workspace.create" : {
            "count" : 2
          }
        }
        """
        let legacyData = try XCTUnwrap(legacyJSON.data(using: .utf8))
        try legacyData.write(to: usageFileURL, options: [.atomic])

        let tracker = CommandPaletteUsageTracker(
            runtimePaths: runtimePaths,
            fileManager: fileManager
        )

        XCTAssertEqual(tracker.useCount(for: "workspace.create"), 2)
        XCTAssertNil(tracker.lastUsedAt(for: "workspace.create"))
    }

    private func loadRecords(from fileURL: URL) throws -> [String: CommandPaletteUsageRecord] {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([String: CommandPaletteUsageRecord].self, from: data)
    }

    private func writeRecords(
        _ records: [String: CommandPaletteUsageRecord],
        to fileURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: fileURL, options: [.atomic])
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
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return URL(fileURLWithPath: createdPath, isDirectory: true)
    }
}
