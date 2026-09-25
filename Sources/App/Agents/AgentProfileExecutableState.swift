import Foundation

/// The environment a managed agent launches into, used to resolve what a profile's
/// command runs. Every shim directory is excluded from lookups because Toastty puts
/// its command shims first on the launch PATH; both the installed directory and the
/// compatibility directory can hold one.
struct ManagedAgentResolutionContext: Sendable {
    var environment: [String: String]
    var shimDirectoryPaths: [String]

    init(environment: [String: String], shimDirectoryPaths: [String?]) {
        self.environment = environment
        self.shimDirectoryPaths = shimDirectoryPaths.compactMap { path in
            guard let path, path.isEmpty == false else { return nil }
            return path
        }
    }

    var excludedDirectoryPaths: Set<String> {
        Set(shimDirectoryPaths)
    }
}

/// Holds the current resolution context so a configuration reload, which recomputes
/// the agent base path and reinstalls shims, is reflected by later queries.
final class ManagedAgentResolutionContextStore: @unchecked Sendable {
    private let lock = NSLock()
    private var context: ManagedAgentResolutionContext

    init(context: ManagedAgentResolutionContext) {
        self.context = context
    }

    func current() -> ManagedAgentResolutionContext {
        lock.lock()
        defer { lock.unlock() }
        return context
    }

    func update(_ context: ManagedAgentResolutionContext) {
        lock.lock()
        defer { lock.unlock() }
        self.context = context
    }
}

/// Where a profile's definition came from.
enum AgentProfileSource: String, Sendable {
    /// Declared in `~/.toastty/agents.toml`.
    case configured
    /// A built-in profile with no override, so its command name is implied.
    case implicit
}

/// Why a profile's command could not be resolved to an executable.
enum AgentProfileExecutableFailure: String, Sendable {
    /// No directory on the launch PATH held the command.
    case commandNotFound = "command_not_found"
    /// argv[0] is an absolute path that is missing or not executable.
    case explicitPathNotExecutable = "explicit_path_not_executable"
    /// argv[0] is a relative or tilde path. Toastty quotes argv, so the shell does
    /// not expand it and its meaning depends on the launch working directory.
    /// Resolving it here would report a path the launch may never use.
    case explicitPathNotAbsolute = "explicit_path_not_absolute"
}

/// What a profile would actually run, resolved without launching anything.
///
/// Deliberately omits the profile's full argv: the remaining arguments do not
/// affect which executable runs, and they can carry flags a caller has no reason
/// to receive. `~/.toastty/agents.toml` remains the place to read them.
struct AgentProfileExecutableState: Sendable {
    let profileID: String
    let displayName: String
    /// argv[0]: the command name looked up on PATH, or an explicit path.
    let command: String
    /// How many arguments follow `command`, so a wrapped profile is still visible.
    let argumentCount: Int
    let source: AgentProfileSource
    /// True when `command` is a path rather than a bare name, so no PATH lookup applies.
    let commandIsExplicitPath: Bool
    let executablePath: String?
    let failure: AgentProfileExecutableFailure?
    /// A login-shell base-path probe was needed because the launch PATH missed.
    let fallbackProbeUsed: Bool
    /// The login shell resolved the executable directly.
    let directExecutableProbeUsed: Bool
}
