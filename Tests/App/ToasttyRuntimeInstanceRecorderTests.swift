import Foundation
import XCTest
@testable import ToasttyApp

final class ToasttyRuntimeInstanceRecorderTests: XCTestCase {
    func testRecordLaunchPersistsResolvedSocketPathForRuntimeIsolatedDevRun() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-runtime-instance-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let environment = [
            "TOASTTY_RUNTIME_HOME": rootURL.appendingPathComponent("runtime-home", isDirectory: true).path,
            "TMPDIR": rootURL.appendingPathComponent("tmp", isDirectory: true).path + "/",
            "TOASTTY_DERIVED_PATH": rootURL.appendingPathComponent("Derived", isDirectory: true).path,
        ]

        ToasttyRuntimeInstanceRecorder.recordLaunch(
            fileManager: fileManager,
            homeDirectoryPath: rootURL.path,
            environment: environment,
            arguments: ["/tmp/Toastty"]
        )

        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: rootURL.path,
            environment: environment
        )
        let instanceFileURL = try XCTUnwrap(runtimePaths.instanceFileURL)
        let instanceData = try Data(contentsOf: instanceFileURL)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: instanceData) as? [String: Any]
        )

        XCTAssertEqual(
            manifest["socketPath"] as? String,
            runtimePaths.automationSocketFileURL?.path
        )
        XCTAssertEqual(
            manifest["derivedPath"] as? String,
            environment["TOASTTY_DERIVED_PATH"]
        )
    }
}
