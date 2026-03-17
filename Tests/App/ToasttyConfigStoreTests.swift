@testable import ToasttyApp
import Foundation
import XCTest

final class ToasttyConfigStoreTests: XCTestCase {
    func testLoadParsesTerminalFontSizeAndDefaultTerminalProfile() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let configURL = ToasttyConfigStore.configFileURL(homeDirectoryPath: homeDirectoryURL.path)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        terminal-font-size = 14
        default-terminal-profile = "zmx"
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let config = ToasttyConfigStore.load(homeDirectoryPath: homeDirectoryURL.path)

        XCTAssertEqual(config.terminalFontSizePoints, 14)
        XCTAssertEqual(config.defaultTerminalProfileID, "zmx")
    }

    func testLoadStripsInlineCommentsOutsideQuotedProfileIDs() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let configURL = ToasttyConfigStore.configFileURL(homeDirectoryPath: homeDirectoryURL.path)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        terminal-font-size = 14 # comment
        default-terminal-profile = "ssh#prod" # still valid
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let config = ToasttyConfigStore.load(homeDirectoryPath: homeDirectoryURL.path)

        XCTAssertEqual(config.terminalFontSizePoints, 14)
        XCTAssertEqual(config.defaultTerminalProfileID, "ssh#prod")
    }

    func testEnsureTemplateExistsWritesCommentedExamples() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()

        try ToasttyConfigStore.ensureTemplateExists(homeDirectoryPath: homeDirectoryURL.path)

        let contents = try String(
            contentsOf: ToasttyConfigStore.configFileURL(homeDirectoryPath: homeDirectoryURL.path),
            encoding: .utf8
        )
        XCTAssertEqual(
            contents,
            """
            # Toastty config

            # terminal-font-size sets the default font size baseline for Toastty.
            # UI font adjustments are persisted separately and override this value
            # until you choose Reset Terminal Font.
            # terminal-font-size = 13

            # default-terminal-profile uses a profile ID from
            # ~/.toastty/terminal-profiles.toml for new terminals only,
            # including ordinary split shortcuts like Cmd+D and Cmd+Shift+D.
            # Existing terminals keep their current profiles.
            # default-terminal-profile = "zmx"

            """
        )
    }

    func testEnsureTemplateExistsSkipsWhenLegacyConfigExists() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let legacyConfigURL = homeDirectoryURL
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("toastty", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
        try FileManager.default.createDirectory(
            at: legacyConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "terminal-font-size = 15\n".write(to: legacyConfigURL, atomically: true, encoding: .utf8)

        try ToasttyConfigStore.ensureTemplateExists(homeDirectoryPath: homeDirectoryURL.path)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ToasttyConfigStore.configFileURL(homeDirectoryPath: homeDirectoryURL.path).path
            )
        )
    }
}

private func makeTemporaryHomeDirectory() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("toastty-config-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}
