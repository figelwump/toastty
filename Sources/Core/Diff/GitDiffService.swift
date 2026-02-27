import Foundation

public enum GitDiffError: Error, Equatable, Sendable {
    case invalidRepoRoot(String)
    case commandFailed(command: [String], exitCode: Int32, stderr: String)
}

public struct FileDiff: Equatable, Sendable {
    public var path: String
    public var additions: Int
    public var deletions: Int
    public var unifiedDiff: String

    public init(path: String, additions: Int, deletions: Int, unifiedDiff: String) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
        self.unifiedDiff = unifiedDiff
    }
}

public struct DiffComputationResult: Equatable, Sendable {
    public var repoRoot: String
    public var inRepoFiles: [FileDiff]
    public var outsideRepoFiles: [String]

    public init(repoRoot: String, inRepoFiles: [FileDiff], outsideRepoFiles: [String]) {
        self.repoRoot = repoRoot
        self.inRepoFiles = inRepoFiles
        self.outsideRepoFiles = outsideRepoFiles
    }
}

public struct GitDiffService: Sendable {
    public init() {}

    public func computeDiff(repoRoot: String, files: [String], staged: Bool) throws -> DiffComputationResult {
        let repoURL = URL(fileURLWithPath: repoRoot).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repoURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitDiffError.invalidRepoRoot(repoRoot)
        }

        let normalizedFiles = normalizeFiles(files, repoRoot: repoURL)
        let split = splitFilesByRepo(normalizedFiles, repoRoot: repoURL)
        let relativeInRepoFiles = split.inRepoFiles.map { String($0.dropFirst(repoURL.path.count + 1)) }

        let statsByPath = try loadStatsByPath(repoRoot: repoURL.path, relativePaths: relativeInRepoFiles, staged: staged)

        var fileDiffs: [FileDiff] = []
        for relativePath in relativeInRepoFiles {
            let stat = statsByPath[relativePath] ?? (0, 0)
            let unifiedDiff = try loadUnifiedDiff(repoRoot: repoURL.path, relativePath: relativePath, staged: staged)
            fileDiffs.append(
                FileDiff(
                    path: relativePath,
                    additions: stat.additions,
                    deletions: stat.deletions,
                    unifiedDiff: unifiedDiff
                )
            )
        }

        return DiffComputationResult(
            repoRoot: repoURL.path,
            inRepoFiles: fileDiffs,
            outsideRepoFiles: split.outsideRepoFiles
        )
    }

    private func normalizeFiles(_ files: [String], repoRoot: URL) -> [String] {
        files.map { file in
            if file.hasPrefix("/") {
                return URL(fileURLWithPath: file).standardizedFileURL.path
            }
            return repoRoot.appendingPathComponent(file).standardizedFileURL.path
        }
    }

    private func splitFilesByRepo(_ files: [String], repoRoot: URL) -> (inRepoFiles: [String], outsideRepoFiles: [String]) {
        let prefix = repoRoot.path + "/"
        var inRepo: [String] = []
        var outside: [String] = []

        for file in files {
            if file == repoRoot.path || file.hasPrefix(prefix) {
                if inRepo.contains(file) == false {
                    inRepo.append(file)
                }
            } else {
                if outside.contains(file) == false {
                    outside.append(file)
                }
            }
        }

        return (inRepo, outside)
    }

    private func loadStatsByPath(repoRoot: String, relativePaths: [String], staged: Bool) throws -> [String: (additions: Int, deletions: Int)] {
        guard relativePaths.isEmpty == false else { return [:] }

        var arguments = ["-C", repoRoot, "diff"]
        if staged {
            arguments.append("--cached")
        }
        arguments.append(contentsOf: ["--numstat", "--"]) 
        arguments.append(contentsOf: relativePaths)

        let output = try runGit(arguments)
        var statsByPath: [String: (additions: Int, deletions: Int)] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 3 else { continue }

            let additions = Int(parts[0]) ?? 0
            let deletions = Int(parts[1]) ?? 0
            let path = String(parts[2])
            statsByPath[path] = (additions: additions, deletions: deletions)
        }
        return statsByPath
    }

    private func loadUnifiedDiff(repoRoot: String, relativePath: String, staged: Bool) throws -> String {
        var arguments = ["-C", repoRoot, "diff"]
        if staged {
            arguments.append("--cached")
        }
        arguments.append(contentsOf: ["--", relativePath])
        return try runGit(arguments)
    }

    private func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)

        if process.terminationStatus != 0 {
            throw GitDiffError.commandFailed(command: arguments, exitCode: process.terminationStatus, stderr: stderr)
        }

        return stdout
    }
}
