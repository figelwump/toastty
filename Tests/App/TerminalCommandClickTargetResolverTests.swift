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
            .markdownFile(path: fixture.markdownPath, placement: .newTab)
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
            .markdownFile(path: fixture.markdownPath, placement: .rootRight)
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
            .markdownFile(path: fixture.markdownPath, placement: .newTab)
        )
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

    func testResolveDecodesPercentEncodedFileURLs() throws {
        let fixture = try makeFixture(fileName: "my notes.md")

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: try XCTUnwrap(URL(string: fixture.markdownURL.absoluteString)),
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(
            target,
            .markdownFile(path: fixture.markdownPath, placement: .newTab)
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
            .markdownFile(path: fixture.markdownPath, placement: .newTab)
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
            .markdownFile(path: fixture.markdownPath, placement: .newTab)
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
            .markdownFile(path: fixture.markdownPath, placement: .newTab)
        )
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

    func testResolveFallsBackForDirectoryNamedMarkdownFile() throws {
        let fixture = try makeFixture(directoryNamedMarkdownFile: true)

        let target = TerminalCommandClickTargetResolver.resolve(
            hoveredURL: fixture.markdownURL,
            cwd: nil,
            useAlternatePlacement: false
        )

        XCTAssertEqual(target, .passthrough(fixture.markdownURL))
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
}
