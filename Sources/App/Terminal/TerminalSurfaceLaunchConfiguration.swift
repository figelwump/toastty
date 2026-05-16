import Foundation

enum TerminalLaunchReason: String, Equatable, Sendable {
    case create
    case restore
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
