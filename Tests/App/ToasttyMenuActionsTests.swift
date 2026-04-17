@testable import ToasttyApp
import CoreState
import Foundation
import XCTest

@MainActor
final class ToasttyMenuActionsTests: XCTestCase {
    func testOpenAgentProfilesConfigurationResultCreatesTemplateAndUsesToasttyLocalOpen() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        var capturedOpen: (url: URL, format: LocalDocumentFormat)?

        let result = ToasttyMenuActions.openAgentProfilesConfigurationResult(
            homeDirectoryPath: homeDirectoryURL.path,
            openManagedLocalDocument: { fileURL, format in
                capturedOpen = (fileURL, format)
                return true
            },
            openExternally: { _ in
                XCTFail("expected Toastty local open to win")
                return false
            }
        )

        if case .success = result {
        } else {
            XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(capturedOpen?.url.path, AgentProfilesFile.fileURL(homeDirectoryPath: homeDirectoryURL.path).path)
        XCTAssertEqual(capturedOpen?.format, .toml)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: AgentProfilesFile.fileURL(homeDirectoryPath: homeDirectoryURL.path).path
            )
        )
    }

    func testOpenToasttyConfigResultFallsBackToExternalOpenWhenToasttyLocalOpenFails() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        var capturedExternalURL: URL?

        let result = ToasttyMenuActions.openToasttyConfigResult(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:],
            openManagedLocalDocument: { _, _ in false },
            openExternally: { url in
                capturedExternalURL = url
                return true
            }
        )

        if case .success = result {
        } else {
            XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(
            capturedExternalURL?.path,
            ToasttyConfigStore.configFileURL(
                homeDirectoryPath: homeDirectoryURL.path,
                environment: [:]
            ).path
        )
    }

    func testOpenToasttyConfigResultReturnsFailureWhenLocalAndExternalOpenFail() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()

        let result = ToasttyMenuActions.openToasttyConfigResult(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:],
            openManagedLocalDocument: { _, _ in false },
            openExternally: { _ in false }
        )

        switch result {
        case .success:
            XCTFail("expected failure when both open paths fail")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("Toastty couldn't open"))
        }
    }

    func testOpenConfigReferenceResultWritesReferenceNoticeAndUsesToasttyLocalOpen() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        var capturedOpen: (url: URL, format: LocalDocumentFormat)?

        let result = ToasttyMenuActions.openConfigReferenceResult(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:],
            openManagedLocalDocument: { fileURL, format in
                capturedOpen = (fileURL, format)
                return true
            },
            openExternally: { _ in
                XCTFail("expected Toastty local open to win")
                return false
            }
        )

        let referenceURL = ToasttyConfigStore.configReferenceFileURL(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:]
        )
        let contents = try String(contentsOf: referenceURL, encoding: .utf8)

        if case .success = result {
        } else {
            XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(capturedOpen?.url.path, referenceURL.path)
        XCTAssertEqual(capturedOpen?.format, .toml)
        XCTAssertTrue(contents.contains("# Reference only: Toastty regenerates this file on launch and when you open"))
        XCTAssertTrue(contents.contains("# Edit the live Toastty config file instead of making changes here."))
    }

    func testOpenTerminalProfilesConfigurationResultUsesTomlLocalOpen() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        var capturedOpen: (url: URL, format: LocalDocumentFormat)?

        let result = ToasttyMenuActions.openTerminalProfilesConfigurationResult(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:],
            openManagedLocalDocument: { fileURL, format in
                capturedOpen = (fileURL, format)
                return true
            },
            openExternally: { _ in
                XCTFail("expected Toastty local open to win")
                return false
            }
        )

        if case .success = result {
        } else {
            XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(
            capturedOpen?.url.path,
            TerminalProfilesFile.fileURL(
                homeDirectoryPath: homeDirectoryURL.path,
                environment: [:]
            ).path
        )
        XCTAssertEqual(capturedOpen?.format, .toml)
    }

    private func makeTemporaryHomeDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-menu-actions-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        return directoryURL
    }
}
