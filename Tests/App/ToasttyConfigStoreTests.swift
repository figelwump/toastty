@testable import ToasttyApp
import Foundation
import XCTest

final class ToasttyConfigStoreTests: XCTestCase {
    func testLoadParsesTerminalFontSizeAndDefaultTerminalProfile() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let configURL = ToasttyConfigStore.configFileURL(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        terminal-font-size = 14
        default-terminal-profile = "zmx"
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let config = ToasttyConfigStore.load(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )

        XCTAssertEqual(config.terminalFontSizePoints, 14)
        XCTAssertEqual(config.defaultTerminalProfileID, "zmx")
    }

    func testLoadStripsInlineCommentsOutsideQuotedProfileIDs() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let configURL = ToasttyConfigStore.configFileURL(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        terminal-font-size = 14 # comment
        default-terminal-profile = "ssh#prod" # still valid
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let config = ToasttyConfigStore.load(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )

        XCTAssertEqual(config.terminalFontSizePoints, 14)
        XCTAssertEqual(config.defaultTerminalProfileID, "ssh#prod")
    }

    func testEnsureTemplateExistsWritesCommentedExamples() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()

        try ToasttyConfigStore.ensureTemplateExists(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )

        let contents = try String(
            contentsOf: ToasttyConfigStore.configFileURL(homeDirectoryPath: homeDirectoryURL.path, environment: [:]),
            encoding: .utf8
        )
        XCTAssertEqual(
            contents,
            """
            # Toastty config

            # terminal-font-size sets the default font size baseline for Toastty.
            # Window-local UI font adjustments are persisted with each window layout
            # until you choose Reset Terminal Font for that window.
            # terminal-font-size = 13

            # default-terminal-profile uses a profile ID from
            # terminal-profiles.toml for new terminals only,
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

        try ToasttyConfigStore.ensureTemplateExists(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ToasttyConfigStore.configFileURL(
                    homeDirectoryPath: homeDirectoryURL.path,
                    environment: [:]
                ).path
            )
        )
    }

    func testConfigFileURLUsesRuntimeHomeWhenSet() {
        let configURL = ToasttyConfigStore.configFileURL(
            homeDirectoryPath: "/tmp/ignored-home",
            environment: ["TOASTTY_RUNTIME_HOME": "/tmp/toastty-runtime-home-tests/config-runtime"]
        )

        XCTAssertEqual(configURL.path, "/tmp/toastty-runtime-home-tests/config-runtime/config")
    }
}

private func makeTemporaryHomeDirectory() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("toastty-config-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}
