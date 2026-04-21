import Foundation
@testable import ToasttyApp
import XCTest

final class CommandPaletteFileSearchEngineTests: XCTestCase {
    func testSearchMatchesWhitespaceSeparatedTermsAcrossTitleAndPath() {
        let scope = PaletteFileSearchScope(
            rootPath: "/tmp/toastty-worktree",
            kind: .repositoryRoot
        )
        let releaseNotesPath = "/tmp/toastty-worktree/artifacts/release-notes.md"
        let snapshot = makeSnapshot(
            scope: scope,
            files: [
                makeFileResult(
                    filePath: releaseNotesPath,
                    relativePath: "artifacts/releases/1.2.3/release-notes.md"
                ),
                makeFileResult(
                    filePath: "/tmp/toastty-worktree/docs/release-process.md",
                    relativePath: "docs/release-process.md"
                ),
            ]
        )

        let results = CommandPaletteFileSearchEngine.search(
            snapshot: snapshot,
            query: "rel 1.2.3"
        )

        XCTAssertEqual(results.map(\.id), [releaseNotesPath])
    }

    func testSearchCollapsesRepeatedInternalWhitespace() {
        let scope = PaletteFileSearchScope(
            rootPath: "/tmp/toastty-worktree",
            kind: .repositoryRoot
        )
        let releaseNotesPath = "/tmp/toastty-worktree/artifacts/release-notes.md"
        let snapshot = makeSnapshot(
            scope: scope,
            files: [
                makeFileResult(
                    filePath: releaseNotesPath,
                    relativePath: "artifacts/releases/1.2.3/release-notes.md"
                ),
            ]
        )

        let results = CommandPaletteFileSearchEngine.search(
            snapshot: snapshot,
            query: "  rel   1.2.3  "
        )

        XCTAssertEqual(results.map(\.id), [releaseNotesPath])
    }

    func testSearchPrefersFilesWithMoreTitleTermHits() {
        let scope = PaletteFileSearchScope(
            rootPath: "/tmp/toastty-worktree",
            kind: .repositoryRoot
        )
        let directReleasePath = "/tmp/toastty-worktree/release-notes-1.2.3.md"
        let nestedReleasePath = "/tmp/toastty-worktree/artifacts/notes.md"
        let snapshot = makeSnapshot(
            scope: scope,
            files: [
                makeFileResult(
                    filePath: directReleasePath,
                    relativePath: "release-notes-1.2.3.md"
                ),
                makeFileResult(
                    filePath: nestedReleasePath,
                    relativePath: "artifacts/releases/1.2.3/release-notes.md"
                ),
            ]
        )

        let results = CommandPaletteFileSearchEngine.search(
            snapshot: snapshot,
            query: "rel 1.2.3"
        )

        XCTAssertEqual(results.map(\.id), [directReleasePath, nestedReleasePath])
    }

    func testSearchReturnsNoResultsForEmptySnapshot() {
        let snapshot = CommandPaletteFileSearchSnapshot.empty(
            scope: PaletteFileSearchScope(
                rootPath: "/tmp/toastty-worktree",
                kind: .repositoryRoot
            )
        )

        XCTAssertTrue(
            CommandPaletteFileSearchEngine.search(snapshot: snapshot, query: "read").isEmpty
        )
        XCTAssertTrue(
            CommandPaletteFileSearchEngine.recentResults(in: snapshot).isEmpty
        )
    }

    func testRecentResultsSortByRecencyThenUsageThenPath() {
        let scope = PaletteFileSearchScope(
            rootPath: "/tmp/toastty-worktree",
            kind: .repositoryRoot
        )
        let rootReadme = "/tmp/toastty-worktree/README.md"
        let nestedReadme = "/tmp/toastty-worktree/artifacts/tmp/README.md"
        let snapshot = makeSnapshot(
            scope: scope,
            files: [
                makeFileResult(
                    filePath: rootReadme,
                    relativePath: "README.md"
                ),
                makeFileResult(
                    filePath: nestedReadme,
                    relativePath: "artifacts/tmp/README.md"
                ),
            ],
            usageMetrics: [
                "file-open:\(rootReadme)": .init(
                    useCount: 2,
                    lastUsedAt: Date(timeIntervalSinceReferenceDate: 10)
                ),
                "file-open:\(nestedReadme)": .init(
                    useCount: 5,
                    lastUsedAt: Date(timeIntervalSinceReferenceDate: 10)
                ),
            ]
        )

        let results = CommandPaletteFileSearchEngine.recentResults(in: snapshot)

        XCTAssertEqual(results.map(\.id), [nestedReadme, rootReadme])
    }

    private func makeSnapshot(
        scope: PaletteFileSearchScope,
        files: [PaletteFileResult],
        usageMetrics: [String: CommandPaletteFileUsageMetrics] = [:]
    ) -> CommandPaletteFileSearchSnapshot {
        CommandPaletteFileSearchEngine.makeSnapshot(
            scope: scope,
            files: files,
            usageMetrics: usageMetrics
        )
    }

    private func makeFileResult(
        filePath: String,
        relativePath: String
    ) -> PaletteFileResult {
        PaletteFileResult(
            filePath: filePath,
            fileName: URL(fileURLWithPath: filePath).lastPathComponent,
            relativePath: relativePath,
            destination: .localDocument(filePath: filePath)
        )
    }
}
