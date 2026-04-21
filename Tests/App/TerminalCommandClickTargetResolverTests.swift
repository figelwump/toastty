@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class TerminalCommandClickTargetResolverTests: XCTestCase {
    func testResolveTreatsFileURLMarkdownAsNewTab() throws {
        let fixture = try makeFixture()

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: fixture.markdownURL,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            expectedLocalDocumentTarget(path: fixture.markdownPath, placement: .newTab)
        )
    }

    func testResolveTreatsRelativeMarkdownPathAsRootRightWhenAlternateOpenIsRequested() throws {
        let fixture = try makeFixture()

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: try XCTUnwrap(URL(string: "docs/command-palette.md")),
            cwd: fixture.rootPath,
            useAlternatePlacement: true
        )

        XCTAssertEqual(
            target,
            expectedLocalDocumentTarget(path: fixture.markdownPath, placement: .rootRight)
        )
    }

    func testResolveFallsBackWhenRelativePathHasNoCWD() throws {
        let url = try XCTUnwrap(URL(string: "docs/command-palette.md"))

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: url,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(target, .passthrough(url))
    }

    func testResolveMatchesUppercaseMarkdownExtension() throws {
        let fixture = try makeFixture(fileName: "README.MD")

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: fixture.markdownURL,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            expectedLocalDocumentTarget(path: fixture.markdownPath, placement: .newTab)
        )
    }

    func testResolveTreatsYamlFileAsLocalDocument() throws {
        let fixture = try makeFixture(fileName: "config.yaml")

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: fixture.markdownURL,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            expectedLocalDocumentTarget(path: fixture.markdownPath, placement: .newTab)
        )
    }

    func testResolveTreatsTomlFileAsLocalDocument() throws {
        let fixture = try makeFixture(fileName: "Toastty.toml")

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: fixture.markdownURL,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            expectedLocalDocumentTarget(path: fixture.markdownPath, placement: .newTab)
        )
    }

    func testResolveTreatsJsonFileAsLocalDocument() throws {
        let fixture = try makeFixture(fileName: "package.json")

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: fixture.markdownURL,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            expectedLocalDocumentTarget(path: fixture.markdownPath, placement: .newTab)
        )
    }

    func testResolveTreatsShellScriptAsLocalDocument() throws {
        let fixture = try makeFixture(fileName: "bootstrap.zsh")

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: fixture.markdownURL,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            expectedLocalDocumentTarget(path: fixture.markdownPath, placement: .newTab)
        )
    }

    func testResolveFallsBackForUnsupportedLocalFileExtension() throws {
        let fixture = try makeFixture(fileName: "config.txt")

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: fixture.markdownURL,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(target, .passthrough(fixture.markdownURL))
    }

    func testResolveFallsBackForRemoteMarkdownURL() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/docs/readme.md"))

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: url,
            cwd: "/tmp",
            useAlternatePlacement: false
        )

        XCTAssertEqual(target, .passthrough(url))
    }

    func testResolveTreatsRelativeDirectoryPathAsLocalDirectory() throws {
        let fixture = try makeDirectoryFixture()

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: try XCTUnwrap(URL(string: "docs/worktrees/demo")),
            cwd: fixture.rootPath,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            .localDirectory(path: fixture.directoryPath)
        )
    }

    func testResolveRecoversFromTrailingPunctuationOnRelativeDirectoryPath() throws {
        let fixture = try makeDirectoryFixture()

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: try XCTUnwrap(URL(string: "docs/worktrees/demo).")),
            cwd: fixture.rootPath,
            useAlternatePlacement: true
        )

        XCTAssertEqual(
            target,
            .localDirectory(path: fixture.directoryPath)
        )
    }

    func testResolvePreservesSymlinkDirectoryPathForLocalDirectoryTarget() throws {
        let fixture = try makeSymlinkDirectoryFixture()

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: fixture.symlinkURL,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            .localDirectory(path: fixture.symlinkPath)
        )
    }

    func testResolveDecodesPercentEncodedFileURLs() throws {
        let fixture = try makeFixture(fileName: "my notes.md")

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: try XCTUnwrap(URL(string: fixture.markdownURL.absoluteString)),
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            expectedLocalDocumentTarget(path: fixture.markdownPath, placement: .newTab)
        )
    }

    func testResolveRecoversFromTrailingCommaOnFileURL() throws {
        let fixture = try makeFixture(fileName: "local document markdown editing.md")

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: try XCTUnwrap(URL(string: "\(fixture.markdownURL.absoluteString),")),
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            expectedLocalDocumentTarget(path: fixture.markdownPath, placement: .newTab)
        )
    }

    func testResolveRecoversFromTrailingSentencePunctuationOnRelativeMarkdownPath() throws {
        let fixture = try makeFixture(fileName: "local document panel (draft).md")

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: try XCTUnwrap(URL(string: "docs/local%20document%20panel%20(draft).md).")),
            cwd: fixture.rootPath,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            expectedLocalDocumentTarget(path: fixture.markdownPath, placement: .newTab)
        )
    }

    func testResolveRecoversMalformedAbsoluteMarkdownPathWithAppendedProse() throws {
        let fixture = try makeFixture(fileName: "toastty-markdown-as-code.md")
        let malformedURL = try XCTUnwrap(
            URL(string: "\(fixture.markdownPath) on branch experiment/markdown-as-code.")
        )

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: malformedURL,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            expectedLocalDocumentTarget(path: fixture.markdownPath, placement: .newTab)
        )
    }

    func testResolveIgnoresFragmentsForRelativeMarkdownPaths() throws {
        let fixture = try makeFixture()

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: try XCTUnwrap(URL(string: "docs/command-palette.md#headings")),
            cwd: fixture.rootPath,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            expectedLocalDocumentTarget(path: fixture.markdownPath, placement: .newTab)
        )
    }

    func testResolveTreatsTrailingLineNumberAsLocalDocumentRevealTarget() throws {
        let fixture = try makeFixture()

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: try XCTUnwrap(URL(string: "docs/command-palette.md:42")),
            cwd: fixture.rootPath,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            expectedLocalDocumentTarget(path: fixture.markdownPath, lineNumber: 42, placement: .newTab)
        )
    }

    func testResolveRecoversTrailingPunctuationAfterLineNumberRevealTarget() throws {
        let fixture = try makeFixture()

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: try XCTUnwrap(URL(string: "docs/command-palette.md:42.")),
            cwd: fixture.rootPath,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            expectedLocalDocumentTarget(path: fixture.markdownPath, lineNumber: 42, placement: .newTab)
        )
    }

    func testResolveTreatsAbsolutePathTrailingLineNumberAsLocalDocumentRevealTarget() throws {
        let fixture = try makeFixture()
        let absolutePathURL = try XCTUnwrap(URL(string: "\(fixture.markdownPath):42"))

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: absolutePathURL,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            expectedLocalDocumentTarget(path: fixture.markdownPath, lineNumber: 42, placement: .newTab)
        )
    }

    func testResolvePrefersExactColonFilenameOverTrailingLineParsing() throws {
        let fixture = try makeFixture(fileName: "command-palette.md:42")

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: fixture.markdownURL,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            expectedLocalDocumentTarget(path: fixture.markdownPath, placement: .newTab)
        )
    }

    func testResolveIgnoresZeroLineSuffixForSupportedLocalDocumentPaths() throws {
        let fixture = try makeFixture()
        let url = try XCTUnwrap(URL(string: "docs/command-palette.md:0"))

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: url,
            cwd: fixture.rootPath,
            useAlternatePlacement: false
        )

        XCTAssertEqual(target, .passthrough(url))
    }

    func testResolveDoesNotTreatUnsupportedFileNumericSuffixAsLocalDocumentReveal() throws {
        let fixture = try makeFixture(fileName: "config.txt")
        let url = try XCTUnwrap(URL(string: "docs/config.txt:42"))

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: url,
            cwd: fixture.rootPath,
            useAlternatePlacement: false
        )

        XCTAssertEqual(target, .passthrough(url))
    }

    func testResolveRecoversMalformedAbsoluteDirectoryPathWithAppendedProse() throws {
        let fixture = try makeDirectoryFixture()
        let malformedURL = try XCTUnwrap(
            URL(string: "\(fixture.directoryPath) on branch experiment/markdown-as-code.")
        )

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: malformedURL,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            .localDirectory(path: fixture.directoryPath)
        )
    }

    func testResolveDoesNotRecoverMalformedAbsolutePathToExistingAncestor() throws {
        let fixture = try makeDirectoryFixture()
        let malformedURL = try XCTUnwrap(
            URL(string: "\(fixture.rootPath)/missing-worktree on branch experiment/markdown-as-code.")
        )

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: malformedURL,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(target, .passthrough(malformedURL))
    }

    func testResolveDoesNotRecoverMalformedAbsolutePathThroughExistingFile() throws {
        let fixture = try makeFixture(fileName: "toastty-markdown-as-code.md")
        let malformedURL = try XCTUnwrap(
            URL(string: "\(fixture.markdownPath)/extra on branch experiment")
        )

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: malformedURL,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(target, .passthrough(malformedURL))
    }

    func testResolveDoesNotRecoverShortMalformedAbsoluteComponent() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-terminal-short-link-tests-\(UUID().uuidString)", isDirectory: true)
        let shortDirectoryURL = rootURL.appendingPathComponent("a", isDirectory: true)

        try fileManager.createDirectory(at: shortDirectoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: rootURL)
        }

        let malformedURL = try XCTUnwrap(
            URL(string: "\(shortDirectoryURL.standardizedFileURL.path) on branch experiment")
        )

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: malformedURL,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(target, .passthrough(malformedURL))
    }

    func testResolveFallsBackWhenResolvedSymlinkTargetIsNotMarkdown() throws {
        let fixture = try makeFixture(
            fileName: "linked-plan.md",
            symlinkTargetName: "rendered.html"
        )

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: fixture.markdownURL,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(target, .passthrough(fixture.markdownURL))
    }

    func testResolveTreatsDirectoryNamedMarkdownPathAsLocalDirectory() throws {
        let fixture = try makeFixture(directoryNamedMarkdownFile: true)

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: fixture.markdownURL,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            .localDirectory(path: fixture.markdownPath)
        )
    }

    private func makeFixture(
        fileName: String = "command-palette.md",
        symlinkTargetName: String? = nil,
        directoryNamedMarkdownFile: Bool = false
    ) throws -> (rootPath: String, markdownPath: String, markdownURL: URL) {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-terminal-link-tests-\(UUID().uuidString)", isDirectory: true)
        let docsURL = rootURL.appendingPathComponent("docs", isDirectory: true)
        let markdownURL = docsURL.appendingPathComponent(fileName, isDirectory: directoryNamedMarkdownFile)

        try fileManager.createDirectory(at: docsURL, withIntermediateDirectories: true)
        if directoryNamedMarkdownFile {
            try fileManager.createDirectory(at: markdownURL, withIntermediateDirectories: true)
        } else if let symlinkTargetName {
            let targetURL = docsURL.appendingPathComponent(symlinkTargetName, isDirectory: false)
            try Data("<p>not markdown</p>\n".utf8).write(to: targetURL)
            try fileManager.createSymbolicLink(at: markdownURL, withDestinationURL: targetURL)
        } else {
            try Data("# Markdown Fixture\n".utf8).write(to: markdownURL)
        }

        addTeardownBlock {
            try? fileManager.removeItem(at: rootURL)
        }

        let normalizedMarkdownURL = markdownURL.standardizedFileURL.resolvingSymlinksInPath()
        return (
            rootPath: rootURL.standardizedFileURL.resolvingSymlinksInPath().path,
            markdownPath: normalizedMarkdownURL.path,
            markdownURL: markdownURL
        )
    }

    private func makeDirectoryFixture() throws -> (rootPath: String, directoryPath: String) {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-terminal-directory-link-tests-\(UUID().uuidString)", isDirectory: true)
        let directoryURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("demo", isDirectory: true)

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        addTeardownBlock {
            try? fileManager.removeItem(at: rootURL)
        }

        return (
            rootPath: rootURL.standardizedFileURL.resolvingSymlinksInPath().path,
            directoryPath: directoryURL.standardizedFileURL.path
        )
    }

    private func makeSymlinkDirectoryFixture() throws -> (symlinkPath: String, symlinkURL: URL) {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-terminal-directory-symlink-tests-\(UUID().uuidString)", isDirectory: true)
        let targetURL = rootURL.appendingPathComponent("target", isDirectory: true)
        let symlinkURL = rootURL.appendingPathComponent("linked-target", isDirectory: true)

        try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

        addTeardownBlock {
            try? fileManager.removeItem(at: rootURL)
        }

        return (
            symlinkPath: symlinkURL.standardizedFileURL.path,
            symlinkURL: symlinkURL
        )
    }

    private func expectedLocalDocumentTarget(
        path: String,
        lineNumber: Int? = nil,
        placement: WebPanelPlacement
    ) -> TerminalCommandClickTarget {
        .localDocumentFile(
            path: path,
            lineNumber: lineNumber,
            placement: placement
        )
    }
}
