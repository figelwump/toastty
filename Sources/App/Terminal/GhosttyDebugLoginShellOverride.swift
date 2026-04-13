import Foundation

struct GhosttyDebugLoginShellOverridePlan: Equatable {
    let shellPath: String
    let requiresTermProgramShim: Bool
}

enum GhosttyDebugLoginShellOverride {
    static let environmentKey = "TOASTTY_DEBUG_LOGIN_SHELL"
    static let termProgramKey = "TERM_PROGRAM"
    static let shimmedTermProgramValue = "ToasttyXcodeDebug"

    static func plan(environment: [String: String]) -> GhosttyDebugLoginShellOverridePlan? {
        guard let shellPath = normalizedShellPath(from: environment[environmentKey]) else {
            return nil
        }

        return GhosttyDebugLoginShellOverridePlan(
            shellPath: shellPath,
            requiresTermProgramShim: normalizedTermProgram(from: environment[termProgramKey]) == nil
        )
    }

    static func normalizedShellPath(from rawValue: String?) -> String? {
        normalizedValue(rawValue)
    }

    static func normalizedTermProgram(from rawValue: String?) -> String? {
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
