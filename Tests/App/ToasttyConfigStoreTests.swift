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

    func testRewriteCurrentTemplateWritesCommentedExamplesWhenConfigIsMissing() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()

        let config = try ToasttyConfigStore.rewriteCurrentTemplate(homeDirectoryPath: homeDirectoryURL.path)

        let contents = try String(
            contentsOf: ToasttyConfigStore.configFileURL(homeDirectoryPath: homeDirectoryURL.path),
            encoding: .utf8
        )
        XCTAssertEqual(config, ToasttyConfig())
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

    func testRewriteCurrentTemplatePreservesRecognizedValuesAndDropsCustomContent() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let configURL = ToasttyConfigStore.configFileURL(homeDirectoryPath: homeDirectoryURL.path)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        # old comment
        terminal-font-size = 15
        default-terminal-profile = "zmx"
        retired-setting = "drop me"
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let config = try ToasttyConfigStore.rewriteCurrentTemplate(homeDirectoryPath: homeDirectoryURL.path)
        let contents = try String(contentsOf: configURL, encoding: .utf8)

        XCTAssertEqual(
            config,
            ToasttyConfig(
                terminalFontSizePoints: 15,
                defaultTerminalProfileID: "zmx"
            )
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

            terminal-font-size = 15
            default-terminal-profile = "zmx"

            """
        )
    }

    func testRewriteCurrentTemplateMigratesLegacyConfigAndRewritesIt() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let legacyConfigURL = homeDirectoryURL
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("toastty", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
        try FileManager.default.createDirectory(
            at: legacyConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        terminal-font-size = 15
        """.write(to: legacyConfigURL, atomically: true, encoding: .utf8)

        let config = try ToasttyConfigStore.rewriteCurrentTemplate(homeDirectoryPath: homeDirectoryURL.path)
        let primaryConfigURL = ToasttyConfigStore.configFileURL(homeDirectoryPath: homeDirectoryURL.path)
        let contents = try String(contentsOf: primaryConfigURL, encoding: .utf8)

        XCTAssertEqual(config, ToasttyConfig(terminalFontSizePoints: 15, defaultTerminalProfileID: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryConfigURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyConfigURL.path))
        XCTAssertTrue(contents.contains("terminal-font-size = 15"))
        XCTAssertTrue(contents.contains("# default-terminal-profile = \"zmx\""))
    }

    func testRewriteCurrentTemplateIsIdempotent() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let configURL = ToasttyConfigStore.configFileURL(homeDirectoryPath: homeDirectoryURL.path)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        terminal-font-size = 15
        default-terminal-profile = "zmx"
        """.write(to: configURL, atomically: true, encoding: .utf8)

        _ = try ToasttyConfigStore.rewriteCurrentTemplate(homeDirectoryPath: homeDirectoryURL.path)
        let firstPass = try String(contentsOf: configURL, encoding: .utf8)
        _ = try ToasttyConfigStore.rewriteCurrentTemplate(homeDirectoryPath: homeDirectoryURL.path)
        let secondPass = try String(contentsOf: configURL, encoding: .utf8)

        XCTAssertEqual(firstPass, secondPass)
    }
}

private func makeTemporaryHomeDirectory() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("toastty-config-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}
