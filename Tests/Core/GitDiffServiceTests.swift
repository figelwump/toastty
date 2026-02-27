import CoreState
import Foundation
import Testing

struct GitDiffServiceTests {
    @Test
    func computesUnstagedDiffForTrackedFile() throws {
        let repo = try makeTempRepo()
        try write("line-one\nline-two\n", to: repo.appendingPathComponent("note.md"))
        try runGit(repo: repo, args: ["add", "note.md"])
        try runGit(repo: repo, args: ["commit", "-m", "initial"])

        try write("line-one\nline-two-updated\n", to: repo.appendingPathComponent("note.md"))

        let service = GitDiffService()
        let result = try service.computeDiff(repoRoot: repo.path, files: ["note.md"], staged: false)

        #expect(result.inRepoFiles.count == 1)
        let fileDiff = result.inRepoFiles[0]
        #expect(fileDiff.path == "note.md")
        #expect(fileDiff.additions == 1)
        #expect(fileDiff.deletions == 1)
        #expect(fileDiff.unifiedDiff.contains("line-two-updated"))
    }

    @Test
    func computesStagedDiffWhenRequested() throws {
        let repo = try makeTempRepo()
        try write("a\n", to: repo.appendingPathComponent("a.txt"))
        try runGit(repo: repo, args: ["add", "a.txt"])
        try runGit(repo: repo, args: ["commit", "-m", "initial"])

        try write("a\nb\n", to: repo.appendingPathComponent("a.txt"))
        try runGit(repo: repo, args: ["add", "a.txt"])

        let service = GitDiffService()
        let result = try service.computeDiff(repoRoot: repo.path, files: ["a.txt"], staged: true)

        #expect(result.inRepoFiles.count == 1)
        #expect(result.inRepoFiles[0].additions == 1)
        #expect(result.inRepoFiles[0].deletions == 0)
        #expect(result.inRepoFiles[0].unifiedDiff.contains("+b"))
    }

    @Test
    func separatesOutsideRepoFiles() throws {
        let repo = try makeTempRepo()
        try write("root\n", to: repo.appendingPathComponent("inside.txt"))
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).txt")
        try write("outside\n", to: outside)

        let service = GitDiffService()
        let result = try service.computeDiff(
            repoRoot: repo.path,
            files: ["inside.txt", outside.path],
            staged: false
        )

        #expect(result.inRepoFiles.count == 1)
        #expect(result.outsideRepoFiles == [outside.standardizedFileURL.path])
    }

    private func makeTempRepo() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-git-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try runGit(repo: directory, args: ["init"])
        try runGit(repo: directory, args: ["config", "user.name", "toastty-tests"])
        try runGit(repo: directory, args: ["config", "user.email", "toastty-tests@example.com"])

        return directory
    }

    private func write(_ string: String, to fileURL: URL) throws {
        try string.data(using: .utf8)?.write(to: fileURL, options: [.atomic])
    }

    private func runGit(repo: URL, args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + args

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw TestError.gitFailed(stderr)
        }
    }
}

private enum TestError: Error {
    case gitFailed(String)
}
