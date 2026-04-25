@testable import ToasttyApp
import Foundation
import XCTest

final class ToasttyConfigStoreTests: XCTestCase {
    func testLoadParsesTerminalFontSizeDefaultTerminalProfileAndAgentShimFlag() throws {
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
        enable-agent-command-shims = false
        url-opening-destination = system-browser
        url-opening-browser-placement = newTab
        url-opening-alternate-browser-placement = newTab
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let config = ToasttyConfigStore.load(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )

        XCTAssertEqual(config.terminalFontSizePoints, 14)
        XCTAssertEqual(config.defaultTerminalProfileID, "zmx")
        XCTAssertFalse(config.enableAgentCommandShims)
        XCTAssertEqual(
            config.urlRoutingPreferences,
            URLRoutingPreferences(
                destination: .systemBrowser,
                browserPlacement: .newTab,
                alternateBrowserPlacement: .newTab
            )
        )
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
        XCTAssertTrue(config.enableAgentCommandShims)
        XCTAssertEqual(config.urlRoutingPreferences, URLRoutingPreferences())
    }

    func testLoadDefaultsAgentCommandShimsToEnabledWhenKeyIsMissing() throws {
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
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let config = ToasttyConfigStore.load(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )

        XCTAssertTrue(config.enableAgentCommandShims)
        XCTAssertEqual(config.urlRoutingPreferences, URLRoutingPreferences())
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

            # enable-agent-command-shims controls whether Toastty prepends
            # managed codex/claude wrappers into terminal PATH so manual
            # invocations report session status automatically.
            # Set this to false if you do not want Toastty intercepting
            # those commands in Toastty terminals.
            # enable-agent-command-shims = false

            # url-opening-destination controls where Toastty opens app-owned
            # web URLs such as Toastty Help links.
            # Supported values: toastty-browser, system-browser.
            # The default is toastty-browser.
            # url-opening-destination = toastty-browser

            # url-opening-browser-placement controls how Toastty places those
            # internally opened browser panels for default opens such as
            # terminal Cmd-click links.
            # Supported values: rightPanel, newTab. Legacy rootRight is still accepted.
            # The default is newTab.
            # url-opening-browser-placement = newTab

            # url-opening-alternate-browser-placement controls how Toastty
            # places alternate browser opens such as terminal
            # Cmd+Shift+click links.
            # Supported values: rightPanel, newTab. Legacy rootRight is still accepted.
            # The default is rightPanel.
            # url-opening-alternate-browser-placement = rightPanel

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

    // MARK: - Config Reference

    func testWriteConfigReferenceCreatesReferenceFile() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()

        try ToasttyConfigStore.writeConfigReference(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )

        let referenceURL = ToasttyConfigStore.configReferenceFileURL(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )
        let contents = try String(contentsOf: referenceURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("# Toastty config"))
        XCTAssertTrue(contents.contains("# Reference only: Toastty regenerates this file on launch and when you open"))
        XCTAssertTrue(contents.contains("# Edit the live Toastty config file instead of making changes here."))
        XCTAssertTrue(contents.contains("# terminal-font-size"))
        XCTAssertTrue(contents.contains("# default-terminal-profile"))
        XCTAssertTrue(contents.contains("# url-opening-destination"))
        XCTAssertTrue(contents.contains("# url-opening-browser-placement"))
        XCTAssertTrue(contents.contains("# url-opening-alternate-browser-placement"))
    }

    func testWriteConfigReferenceOverwritesExistingFile() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let referenceURL = ToasttyConfigStore.configReferenceFileURL(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )
        try FileManager.default.createDirectory(
            at: referenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "stale content".write(to: referenceURL, atomically: true, encoding: .utf8)

        try ToasttyConfigStore.writeConfigReference(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )

        let contents = try String(contentsOf: referenceURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("# Toastty config"))
        XCTAssertFalse(contents.contains("stale content"))
    }

    func testConfigReferenceFileURLUsesRuntimeHomeWhenSet() {
        let referenceURL = ToasttyConfigStore.configReferenceFileURL(
            homeDirectoryPath: "/tmp/ignored-home",
            environment: ["TOASTTY_RUNTIME_HOME": "/tmp/toastty-runtime-home-tests/ref-runtime"]
        )

        XCTAssertEqual(referenceURL.path, "/tmp/toastty-runtime-home-tests/ref-runtime/config-reference")
    }

    func testLoadDefaultsURLRoutingPreferencesToToasttyBrowserInNewTabWithRightPanelAlternate() throws {
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
        enable-agent-command-shims = true
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let config = ToasttyConfigStore.load(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )

        XCTAssertEqual(
            config.urlRoutingPreferences,
            URLRoutingPreferences(
                destination: .toasttyBrowser,
                browserPlacement: .newTab,
                alternateBrowserPlacement: .rightPanel
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
