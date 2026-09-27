import Foundation

enum TerminalLaunchReason: String, Equatable, Sendable {
    case create
    case restore
}

enum TerminalLaunchWorkingDirectory {
    /// A shell given a directory that no longer exists starts in `/`. Start it
    /// in the nearest parent that still exists instead, or in home when only
    /// `/` is left. An existing directory is returned unchanged.
    static func existing(
        _ path: String,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard isDirectory(expanded, fileManager: fileManager) == false else {
            return path
        }
        var candidate = (expanded as NSString).standardizingPath
        while candidate.hasPrefix("/"), candidate != "/" {
            candidate = (candidate as NSString).deletingLastPathComponent
            if candidate != "/", isDirectory(candidate, fileManager: fileManager) {
                return candidate
            }
        }
        return homeDirectory
    }

    private static func isDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

struct TerminalSurfaceLaunchConfiguration: Equatable, Sendable {
    var environmentVariables: [String: String]
    var initialInput: String?
    var workingDirectoryOverride: String?

    init(
        environmentVariables: [String: String] = [:],
        initialInput: String? = nil,
        workingDirectoryOverride: String? = nil
    ) {
        self.environmentVariables = environmentVariables
        self.initialInput = initialInput
        self.workingDirectoryOverride = workingDirectoryOverride
    }

    var normalizedInitialInput: String? {
        guard let initialInput else { return nil }
        let trimmed = initialInput.trimmingCharacters(in: .newlines)
        guard trimmed.isEmpty == false else { return nil }
        return initialInput.hasSuffix("\n") ? initialInput : initialInput + "\n"
    }

    var isEmpty: Bool {
        environmentVariables.isEmpty && normalizedInitialInput == nil && normalizedWorkingDirectoryOverride == nil
    }

    var normalizedWorkingDirectoryOverride: String? {
        guard let workingDirectoryOverride else { return nil }
        let trimmed = workingDirectoryOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let normalized = (expanded as NSString).standardizingPath
        guard normalized.isEmpty == false else { return nil }
        return normalized
    }

    static let empty = TerminalSurfaceLaunchConfiguration()
}
