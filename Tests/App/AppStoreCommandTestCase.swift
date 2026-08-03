@testable import ToasttyApp
import CoreState
import UniformTypeIdentifiers
import XCTest

@MainActor
class AppStoreCommandTestCase: XCTestCase {
    func makeSingleWindowState(initialTerminalCWD: String) -> (state: AppState, windowID: UUID, workspaceID: UUID) {
        let workspace = WorkspaceState.bootstrap(initialTerminalCWD: initialTerminalCWD)
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 120, y: 120, width: 1280, height: 760),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                )
            ],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: windowID
        )
        return (state, windowID, workspace.id)
    }

    func makeMarkdownFixture(
        fileName: String = "README.md"
    ) throws -> (canonicalPath: String, alternatePath: String) {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-markdown-tests-\(UUID().uuidString)", isDirectory: true)
        let alternateDirectoryURL = rootURL.appendingPathComponent("alternate", isDirectory: true)
        let fileURL = rootURL.appendingPathComponent(fileName, isDirectory: false)

        try fileManager.createDirectory(at: alternateDirectoryURL, withIntermediateDirectories: true)
        try Data("# Toastty Markdown Fixture\n".utf8).write(to: fileURL)
        addTeardownBlock {
            try? fileManager.removeItem(at: rootURL)
        }

        let canonicalPath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        let alternatePath = alternateDirectoryURL
            .appendingPathComponent("../\(fileName)", isDirectory: false)
            .path
        return (canonicalPath, alternatePath)
    }

    func makeLocalDocumentFixture(
        fileName: String,
        content: String = "value: fixture\n"
    ) throws -> String {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-local-document-format-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = rootURL.appendingPathComponent(fileName, isDirectory: false)

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: fileURL)
        addTeardownBlock {
            try? fileManager.removeItem(at: rootURL)
        }

        return fileURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func makeUnsupportedFixture(fileName: String = "README.zip") throws -> String {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-local-document-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = rootURL.appendingPathComponent(fileName, isDirectory: false)

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("zip placeholder\n".utf8).write(to: fileURL)
        addTeardownBlock {
            try? fileManager.removeItem(at: rootURL)
        }

        return fileURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func makeSymlinkedMarkdownFixture() throws -> (canonicalPath: String, symlinkPath: String) {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-local-document-symlink-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("README.md", conformingTo: .plainText)
        let symlinkURL = rootURL.appendingPathComponent("linked-readme.md", conformingTo: .plainText)

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("# Toastty Markdown Fixture\n".utf8).write(to: fileURL)
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: fileURL)
        addTeardownBlock {
            try? fileManager.removeItem(at: rootURL)
        }

        return (
            canonicalPath: fileURL.standardizedFileURL.resolvingSymlinksInPath().path,
            symlinkPath: symlinkURL.path
        )
    }

}
