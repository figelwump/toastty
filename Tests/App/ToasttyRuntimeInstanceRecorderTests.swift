import CoreState
import Foundation
import XCTest
@testable import ToasttyApp

final class ToasttyRuntimeInstanceRecorderTests: XCTestCase {
    func testRecordLaunchPersistsResolvedSocketPathForRuntimeIsolatedDevRun() throws {
        let fileManager = FileManager.default
        let rootURL = try makeShortTemporaryDirectory(prefix: "ttri")
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

    func testRecordLaunchUsesSocketPathOverrideWhenProvided() throws {
        let fileManager = FileManager.default
        let rootURL = try makeShortTemporaryDirectory(prefix: "ttrio")
        defer { try? fileManager.removeItem(at: rootURL) }

        let environment = [
            "TOASTTY_RUNTIME_HOME": rootURL.appendingPathComponent("runtime-home", isDirectory: true).path,
            "TMPDIR": rootURL.appendingPathComponent("tmp", isDirectory: true).path + "/",
        ]
        let socketPathOverride = rootURL.appendingPathComponent("alternate.sock", isDirectory: false).path

        ToasttyRuntimeInstanceRecorder.recordLaunch(
            socketPathOverride: socketPathOverride,
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

        XCTAssertEqual(manifest["socketPath"] as? String, socketPathOverride)
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
