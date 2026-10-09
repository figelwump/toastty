import Foundation

/// What finishes, cleans up, and closes a subspace's task, set by whoever
/// created the task space (`worktree-create`, for example) or later through
/// the CLI. Toastty knows nothing about git or GitHub: it shows a button for
/// each hook and runs it. The finish hook names a skill that the task's agent
/// runs in its session, because finishing needs judgment. The cleanup and
/// close hooks name a script inside a skill that runs without an agent,
/// because they remove the task's worktree and workspace, which a session
/// inside it cannot do, and cleanup must also work in bulk after the agent
/// has exited.
public struct WorkspaceTaskHooks: Codable, Equatable, Sendable {
    /// Runs a script inside an installed user skill. Toastty resolves
    /// `<user skills directory>/<skill>/<script>` each time it runs the hook,
    /// so a saved hook keeps working after the skill is updated and in an
    /// isolated dev run, and only scripts inside installed skills can run.
    public struct ScriptHook: Codable, Equatable, Sendable {
        public var skill: String
        /// Relative to the skill's directory, such as `scripts/cleanup.py`.
        public var script: String
        public var arguments: [String]

        public init(skill: String, script: String, arguments: [String] = []) {
            self.skill = skill
            self.script = script
            self.arguments = arguments
        }
    }

    /// The skill the task's agent runs to finish the task, such as
    /// `worktree-done`. Toastty sends it as a skill invocation in the agent's
    /// own syntax.
    public var finishSkill: String?
    public var cleanup: ScriptHook?
    /// Abandons the task: the script closes any pull request, then removes
    /// the worktree and closes the workspace the way cleanup does.
    public var close: ScriptHook?

    public init(finishSkill: String? = nil, cleanup: ScriptHook? = nil, close: ScriptHook? = nil) {
        self.finishSkill = finishSkill
        self.cleanup = cleanup
        self.close = close
    }

    public var isEmpty: Bool {
        finishSkill == nil && cleanup == nil && close == nil
    }

    /// The script hooks, which run without an agent.
    public enum ScriptKind: String, Codable, Equatable, Sendable {
        case cleanup
        case close
    }

    public func script(_ kind: ScriptKind) -> ScriptHook? {
        switch kind {
        case .cleanup: return cleanup
        case .close: return close
        }
    }

    // MARK: - Validation

    public static let maximumSkillNameLength = 64
    public static let maximumArgumentCount = 16
    public static let maximumArgumentLength = 256

    /// A skill directory name: 1-64 ASCII letters, digits, `.`, `_`, or `-`,
    /// not starting with `.`, so it names one directory under the user
    /// skills root and nothing above it.
    public static func validatedSkillName(_ rawValue: String) -> String? {
        let candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.isEmpty == false,
              candidate.count <= maximumSkillNameLength,
              candidate.hasPrefix(".") == false else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard candidate.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return candidate
    }

    /// A relative path inside the skill: no leading `/`, no `..` component,
    /// and no empty component, so it cannot leave the skill's directory.
    public static func validatedScriptPath(_ rawValue: String) -> String? {
        let candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.isEmpty == false,
              candidate.hasPrefix("/") == false,
              candidate.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            return nil
        }
        let components = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ $0.isEmpty == false && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return candidate
    }

    public static func validatedArguments(_ rawValues: [String]) -> [String]? {
        guard rawValues.count <= maximumArgumentCount else { return nil }
        for value in rawValues {
            guard value.isEmpty == false,
                  value.utf8.count <= maximumArgumentLength,
                  value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
                return nil
            }
        }
        return rawValues
    }

    /// Whole-value validation shared by the CLI and defensive decoding.
    public static func validatedScriptHook(skill: String, script: String, arguments: [String]) -> ScriptHook? {
        guard let skill = validatedSkillName(skill),
              let script = validatedScriptPath(script),
              let arguments = validatedArguments(arguments) else {
            return nil
        }
        return ScriptHook(skill: skill, script: script, arguments: arguments)
    }

    /// The hooks with invalid parts dropped, for a hand-edited or stale
    /// layout file.
    public var sanitized: Self {
        var result = Self()
        if let finishSkill, let validated = Self.validatedSkillName(finishSkill) {
            result.finishSkill = validated
        }
        if let cleanup {
            result.cleanup = Self.validatedScriptHook(skill: cleanup.skill, script: cleanup.script, arguments: cleanup.arguments)
        }
        if let close {
            result.close = Self.validatedScriptHook(skill: close.skill, script: close.script, arguments: close.arguments)
        }
        return result
    }
}


/// Where a subspace's task is in its life: being worked on, waiting for the
/// user to review and test it, or accepted. The agent moves it to `review`
/// when the work is ready, the finish skill (or the user) marks it `done`,
/// and new agent work moves it back to `open`. Cleanup then removes the
/// workspace, so there is no stage after `done`.
public enum WorkspaceTaskStage: String, Codable, Equatable, CaseIterable, Sendable {
    case open
    case review
    case done
}
