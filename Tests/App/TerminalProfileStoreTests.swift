@testable import ToasttyApp
import CoreState
import Foundation
import XCTest

@MainActor
final class TerminalProfileStoreTests: XCTestCase {
    func testInitLoadsCatalogFromTerminalProfilesFile() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        try writeProfiles(
            """
            [zmx]
            displayName = "ZMX"
            startupCommand = "zmx attach toastty.$TOASTTY_PANEL_ID"
            """,
            homeDirectoryURL: homeDirectoryURL
        )

        let store = TerminalProfileStore(homeDirectoryPath: homeDirectoryURL.path, environment: [:])

        XCTAssertEqual(store.catalog.profiles.map(\.id), ["zmx"])
        XCTAssertEqual(store.catalog.profiles.map(\.badgeLabel), ["ZMX"])
    }

    func testReloadPreservesPreviousCatalogWhenFileIsInvalid() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        try writeProfiles(
            """
            [zmx]
            displayName = "ZMX"
            startupCommand = "zmx attach toastty.$TOASTTY_PANEL_ID"
            """,
            homeDirectoryURL: homeDirectoryURL
        )
        let store = TerminalProfileStore(homeDirectoryPath: homeDirectoryURL.path, environment: [:])

        try writeProfiles(
            """
            [zmx]
            displayName = "Broken"
            """,
            homeDirectoryURL: homeDirectoryURL
        )

        let result = store.reload()

        switch result {
        case .success:
            XCTFail("Expected reload to fail for an invalid profiles file")
        case .failure(let error):
            XCTAssertTrue(error.path.hasSuffix(".toastty/terminal-profiles.toml"))
            XCTAssertEqual(error.message, "terminal-profiles.toml line 1: [zmx] is missing startupCommand")
        }
        XCTAssertEqual(store.catalog.profiles.map(\.id), ["zmx"])
        XCTAssertEqual(store.catalog.profiles.map(\.displayName), ["ZMX"])
    }

    func testReloadReplacesCatalogWhenFileChanges() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        try writeProfiles(
            """
            [zmx]
            displayName = "ZMX"
            startupCommand = "zmx attach toastty.$TOASTTY_PANEL_ID"
            """,
            homeDirectoryURL: homeDirectoryURL
        )
        let store = TerminalProfileStore(homeDirectoryPath: homeDirectoryURL.path, environment: [:])

        try writeProfiles(
            """
            [ssh-prod]
            displayName = "SSH Prod"
            badge = "SSH"
            startupCommand = "ssh prod"
            """,
            homeDirectoryURL: homeDirectoryURL
        )

        let result = store.reload()

        switch result {
        case .success(let catalog):
            XCTAssertEqual(catalog.profiles.map(\.id), ["ssh-prod"])
            XCTAssertEqual(catalog.profiles.map(\.badgeLabel), ["SSH"])
        case .failure(let error):
            XCTFail("Expected reload to succeed, got \(error)")
        }
        XCTAssertEqual(store.catalog.profiles.map(\.id), ["ssh-prod"])
    }
}

private func makeTemporaryHomeDirectory() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("toastty-terminal-profile-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}

private func writeProfiles(_ contents: String, homeDirectoryURL: URL) throws {
    let fileURL = TerminalProfilesFile.fileURL(homeDirectoryPath: homeDirectoryURL.path, environment: [:])
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
}
