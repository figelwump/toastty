import Foundation

/// The executable a managed agent command resolves to, plus how it was found.
public struct ManagedAgentExecutableResolution: Equatable, Sendable {
    public let executablePath: String
    public let agentBasePath: String?
    /// The initial PATH lookup failed and a login-shell base-path probe was needed.
    public let fallbackProbeUsed: Bool
    /// The base path itself did not contain the command, so the login shell was
    /// asked to resolve the executable directly.
    public let directExecutableProbeUsed: Bool

    public init(
        executablePath: String,
        agentBasePath: String?,
        fallbackProbeUsed: Bool,
        directExecutableProbeUsed: Bool
    ) {
        self.executablePath = executablePath
        self.agentBasePath = agentBasePath
        self.fallbackProbeUsed = fallbackProbeUsed
        self.directExecutableProbeUsed = directExecutableProbeUsed
    }
}

/// Resolves the real binary a managed agent command name runs, skipping Toastty's
/// own command shims.
///
/// The agent shim uses this to find what to exec; `agent.profile.state` uses it to
/// report the same answer before anything launches. Both callers share this type so
/// a preflight cannot verify a different binary than the one that actually runs.
public enum ManagedAgentExecutableResolver {
    /// Command names Toastty ships under more than one spelling.
    public static func firstPartyCommandAliases(for commandName: String) -> [String] {
        switch commandName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mimocode":
            return ["mimo"]
        default:
            return []
        }
    }

    /// Resolves symlinks without requiring the path to exist, so an excluded shim
    /// directory still matches when reached through a symlinked parent.
    public static func canonicalPath(for path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().standardizedFileURL.path
    }

    public typealias BasePathResolverFactory = (
        _ environment: [String: String],
        _ fallbackPath: String?
    ) -> ManagedAgentBasePathResolver

    /// Looks for `commandName` in order: the launch PATH, its first-party aliases,
    /// a login-shell base-path probe, that probe's aliases, and finally a direct
    /// login-shell executable probe. Returns nil when every stage is exhausted or
    /// the only match is an excluded shim.
    ///
    /// The last three stages each spawn a login shell and block until it answers or
    /// times out. Set `allowsLoginShellProbe` to false to stop after the PATH stages
    /// when the caller cannot afford to block, such as on the main actor.
    public static func resolve(
        commandName: String,
        environment: [String: String],
        excludedDirectoryPaths: Set<String> = [],
        excludedExecutablePaths: Set<String> = [],
        allowsLoginShellProbe: Bool = true,
        canonicalPathProvider: (String) -> String? = canonicalPath(for:),
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        makeBasePathResolver: BasePathResolverFactory = { environment, fallbackPath in
            ManagedAgentBasePathResolver(environment: environment, fallbackPath: fallbackPath)
        }
    ) -> ManagedAgentExecutableResolution? {
        let configuredAgentBasePath = normalizedNonEmpty(
            environment[ToasttyLaunchContextEnvironment.agentBasePathKey]
        )
        let aliases = firstPartyCommandAliases(for: commandName)

        func lookup(_ name: String, basePath: String?) -> String? {
            ManagedAgentPathResolver.resolvedExecutablePath(
                commandName: name,
                currentPath: environment["PATH"],
                basePath: basePath,
                excludedDirectoryPaths: excludedDirectoryPaths,
                excludedExecutablePaths: excludedExecutablePaths,
                canonicalPathProvider: canonicalPathProvider,
                isExecutableFile: isExecutableFile
            )
        }

        for name in [commandName] + aliases {
            if let executablePath = lookup(name, basePath: configuredAgentBasePath) {
                return ManagedAgentExecutableResolution(
                    executablePath: executablePath,
                    agentBasePath: configuredAgentBasePath,
                    fallbackProbeUsed: false,
                    directExecutableProbeUsed: false
                )
            }
        }

        guard allowsLoginShellProbe else { return nil }

        let basePathResolver = makeBasePathResolver(
            environment,
            configuredAgentBasePath ?? environment["PATH"]
        )
        let effectiveAgentBasePath = ManagedAgentPathResolver.mergedPath(
            currentPath: configuredAgentBasePath,
            basePath: basePathResolver.resolve()
        )

        for name in [commandName] + aliases {
            if let executablePath = lookup(name, basePath: effectiveAgentBasePath) {
                return ManagedAgentExecutableResolution(
                    executablePath: executablePath,
                    agentBasePath: effectiveAgentBasePath,
                    fallbackProbeUsed: true,
                    directExecutableProbeUsed: false
                )
            }
        }

        let executableResolution = ([commandName] + aliases)
            .lazy
            .compactMap { basePathResolver.resolveExecutable(commandName: $0) }
            .first
        guard let executableResolution,
              ManagedAgentPathResolver.isExecutablePathAllowed(
                  executableResolution.executablePath,
                  excludedDirectoryPaths: excludedDirectoryPaths,
                  excludedExecutablePaths: excludedExecutablePaths,
                  canonicalPathProvider: canonicalPathProvider,
                  isExecutableFile: isExecutableFile
              ) else {
            return nil
        }

        return ManagedAgentExecutableResolution(
            executablePath: executableResolution.executablePath,
            agentBasePath: ManagedAgentPathResolver.mergedPath(
                currentPath: effectiveAgentBasePath,
                basePath: executableResolution.path
            ),
            fallbackProbeUsed: true,
            directExecutableProbeUsed: true
        )
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}
