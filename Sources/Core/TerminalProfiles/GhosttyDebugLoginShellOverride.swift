import Foundation

public struct GhosttyDebugLoginShellOverridePlan: Equatable {
    public let shellPath: String
    public let requiresTermProgramShim: Bool

    public init(
        shellPath: String,
        requiresTermProgramShim: Bool
    ) {
        self.shellPath = shellPath
        self.requiresTermProgramShim = requiresTermProgramShim
    }
}

public enum GhosttyDebugLoginShellOverride {
    public static let environmentKey = "TOASTTY_DEBUG_LOGIN_SHELL"
    public static let termProgramKey = "TERM_PROGRAM"
    public static let shimmedTermProgramValue = "ToasttyXcodeDebug"

    public static func plan(environment: [String: String]) -> GhosttyDebugLoginShellOverridePlan? {
        guard let shellPath = normalizedShellPath(from: environment[environmentKey]) else {
            return nil
        }

        return GhosttyDebugLoginShellOverridePlan(
            shellPath: shellPath,
            requiresTermProgramShim: normalizedTermProgram(from: environment[termProgramKey]) == nil
        )
    }

    public static func normalizedShellPath(from rawValue: String?) -> String? {
        normalizedValue(rawValue)
    }

    public static func normalizedTermProgram(from rawValue: String?) -> String? {
        normalizedValue(rawValue)
    }

    private static func normalizedValue(_ rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}
