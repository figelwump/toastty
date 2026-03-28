@testable import ToasttyApp
import CoreState
import Foundation
import XCTest

final class AgentCommandShimInstallerTests: XCTestCase {
    func testSyncInstallationCreatesManagedLinksWhenEnabled() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let helperURL = try makeExecutableHelper(in: homeDirectoryURL)
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )
        let installer = AgentCommandShimInstaller(
            runtimePaths: runtimePaths,
            helperExecutablePathProvider: { helperURL.path }
        )

        let syncedInstallation = try installer.syncInstallation(enabled: true)
        let installation = try XCTUnwrap(syncedInstallation)

        XCTAssertEqual(installation.directoryURL.path, runtimePaths.agentShimDirectoryURL.path)
        for commandName in ["codex", "claude"] {
            let linkURL = installation.directoryURL.appendingPathComponent(commandName, isDirectory: false)
            XCTAssertTrue(FileManager.default.fileExists(atPath: linkURL.path))
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path),
                helperURL.path
            )
        }
    }

    func testSyncInstallationCreatesConfiguredWrapperLinksWhenEnabled() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let helperURL = try makeExecutableHelper(in: homeDirectoryURL)
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )
        let installer = AgentCommandShimInstaller(
            runtimePaths: runtimePaths,
            managedCommandNames: ["codex", "claude", "run-sandboxed.sh", "agent-safehouse"],
            helperExecutablePathProvider: { helperURL.path }
        )

        let syncedInstallation = try installer.syncInstallation(enabled: true)
        let installation = try XCTUnwrap(syncedInstallation)

        for commandName in ["run-sandboxed.sh", "agent-safehouse"] {
            let linkURL = installation.directoryURL.appendingPathComponent(commandName, isDirectory: false)
            XCTAssertTrue(FileManager.default.fileExists(atPath: linkURL.path))
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path),
                helperURL.path
            )
        }
    }

    func testSyncInstallationRemovesStaleManagedWrapperLinksWhenConfiguredSetShrinks() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let helperURL = try makeExecutableHelper(in: homeDirectoryURL)
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )

        let initialInstaller = AgentCommandShimInstaller(
            runtimePaths: runtimePaths,
            managedCommandNames: ["codex", "claude", "run-sandboxed.sh"],
            helperExecutablePathProvider: { helperURL.path }
        )
        _ = try initialInstaller.syncInstallation(enabled: true)

        let updatedInstaller = AgentCommandShimInstaller(
            runtimePaths: runtimePaths,
            managedCommandNames: ["codex", "claude"],
            helperExecutablePathProvider: { helperURL.path }
        )
        _ = try updatedInstaller.syncInstallation(enabled: true)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: runtimePaths.agentShimDirectoryURL
                    .appendingPathComponent("run-sandboxed.sh", isDirectory: false)
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: runtimePaths.agentShimDirectoryURL
                    .appendingPathComponent("codex", isDirectory: false)
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: runtimePaths.agentShimDirectoryURL
                    .appendingPathComponent("claude", isDirectory: false)
                    .path
            )
        )
    }

    func testSyncInstallationRemovesEmptyManagedShimDirectoryWhenDisabled() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let helperURL = try makeExecutableHelper(in: homeDirectoryURL)
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )
        let installer = AgentCommandShimInstaller(
            runtimePaths: runtimePaths,
            helperExecutablePathProvider: { helperURL.path }
        )

        _ = try installer.syncInstallation(enabled: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtimePaths.agentShimDirectoryURL.path))

        let disabledInstallation = try installer.syncInstallation(enabled: false)

        XCTAssertNil(disabledInstallation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimePaths.agentShimDirectoryURL.path))
    }

    func testSyncInstallationKeepsUnrelatedFilesWhenDisablingManagedLinks() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let helperURL = try makeExecutableHelper(in: homeDirectoryURL)
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )
        let installer = AgentCommandShimInstaller(
            runtimePaths: runtimePaths,
            helperExecutablePathProvider: { helperURL.path }
        )

        let syncedInstallation = try installer.syncInstallation(enabled: true)
        let installation = try XCTUnwrap(syncedInstallation)
        let unrelatedFileURL = installation.directoryURL.appendingPathComponent("keep-me.txt", isDirectory: false)
        try "keep".write(to: unrelatedFileURL, atomically: true, encoding: .utf8)

        _ = try installer.syncInstallation(enabled: false)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installation.directoryURL.appendingPathComponent("codex", isDirectory: false).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installation.directoryURL.appendingPathComponent("claude", isDirectory: false).path
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFileURL.path))
    }

    func testSyncInstallationKeepsUnrelatedSymlinksWhenConfiguredSetShrinks() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let helperURL = try makeExecutableHelper(in: homeDirectoryURL)
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )
        let initialInstaller = AgentCommandShimInstaller(
            runtimePaths: runtimePaths,
            managedCommandNames: ["codex", "claude", "run-sandboxed.sh"],
            helperExecutablePathProvider: { helperURL.path }
        )
        let installation = try XCTUnwrap(initialInstaller.syncInstallation(enabled: true))
        let unrelatedTargetURL = homeDirectoryURL.appendingPathComponent("custom-target", isDirectory: false)
        try "custom".write(to: unrelatedTargetURL, atomically: true, encoding: .utf8)
        let unrelatedLinkURL = installation.directoryURL.appendingPathComponent("custom-wrapper", isDirectory: false)
        try FileManager.default.createSymbolicLink(
            atPath: unrelatedLinkURL.path,
            withDestinationPath: unrelatedTargetURL.path
        )

        let updatedInstaller = AgentCommandShimInstaller(
            runtimePaths: runtimePaths,
            managedCommandNames: ["codex", "claude"],
            helperExecutablePathProvider: { helperURL.path }
        )
        _ = try updatedInstaller.syncInstallation(enabled: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedLinkURL.path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: unrelatedLinkURL.path),
            unrelatedTargetURL.path
        )
    }

    func testInstallDoesNotOverwriteExistingNonSymlinkCommandFile() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let helperURL = try makeExecutableHelper(in: homeDirectoryURL)
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )
        try FileManager.default.createDirectory(at: runtimePaths.agentShimDirectoryURL, withIntermediateDirectories: true)
        let conflictingCommandURL = runtimePaths.agentShimDirectoryURL.appendingPathComponent("codex", isDirectory: false)
        try "custom wrapper".write(to: conflictingCommandURL, atomically: true, encoding: .utf8)
        let installer = AgentCommandShimInstaller(
            runtimePaths: runtimePaths,
            helperExecutablePathProvider: { helperURL.path }
        )

        XCTAssertThrowsError(try installer.syncInstallation(enabled: true)) { error in
            guard case .managedCommandConflict(let path) = error as? AgentCommandShimInstallerError else {
                return XCTFail("Expected managed command conflict, got \(error)")
            }
            XCTAssertEqual(path, conflictingCommandURL.path)
        }
        XCTAssertEqual(
            try String(contentsOf: conflictingCommandURL, encoding: .utf8),
            "custom wrapper"
        )
    }

    func testDisableLeavesUserSuppliedManagedCommandNamesUntouched() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )
        try FileManager.default.createDirectory(at: runtimePaths.agentShimDirectoryURL, withIntermediateDirectories: true)
        let codexURL = runtimePaths.agentShimDirectoryURL.appendingPathComponent("codex", isDirectory: false)
        let claudeURL = runtimePaths.agentShimDirectoryURL.appendingPathComponent("claude", isDirectory: false)
        try "custom codex".write(to: codexURL, atomically: true, encoding: .utf8)
        try "custom claude".write(to: claudeURL, atomically: true, encoding: .utf8)
        let installer = AgentCommandShimInstaller(
            runtimePaths: runtimePaths,
            helperExecutablePathProvider: { nil }
        )

        _ = try installer.syncInstallation(enabled: false)

        XCTAssertEqual(try String(contentsOf: codexURL, encoding: .utf8), "custom codex")
        XCTAssertEqual(try String(contentsOf: claudeURL, encoding: .utf8), "custom claude")
    }

    private func makeExecutableHelper(in directoryURL: URL) throws -> URL {
        let helperURL = directoryURL.appendingPathComponent("toastty-agent-shim-helper", isDirectory: false)
        FileManager.default.createFile(atPath: helperURL.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: helperURL.path)
        return helperURL
    }
}

private func makeTemporaryHomeDirectory() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("toastty-agent-shim-installer-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}
