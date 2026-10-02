import CoreState
import Darwin
import Foundation

/// Grok's TUI discovers additive hooks in GROK_HOME. Standalone mode keeps the
/// backend in the launched process so its hooks retain this panel's identity.
enum GrokLaunchInstrumentation {
    /// UI launches can name Grok by absolute path, bypassing the command shim.
    /// The small exec wrapper records that process before it can emit hooks.
    static func argvForDispatch(_ argv: [String], environment: [String: String]) -> [String] {
        guard let ownerPath = environment[ToasttyLaunchContextEnvironment.managedAgentArtifactOwnerFileKey] else {
            return argv
        }
        let wrapper = URL(fileURLWithPath: ownerPath).deletingLastPathComponent()
            .appendingPathComponent("grok-launch.sh")
        return ["/bin/sh", wrapper.path] + argv
    }

    static func prepare(
        argv: [String],
        cliExecutablePath: String,
        sessionID: String,
        fileManager: FileManager,
        artifactStore: ManagedAgentLaunchArtifactStore?,
        launchEnvironment: [String: String]
    ) throws -> PreparedAgentLaunchCommand {
        let unchanged = PreparedAgentLaunchCommand(argv: argv, environment: [:], artifacts: nil)
        guard let artifactStore, let invocation = invocation(argv: argv),
              UUID(uuidString: sessionID) != nil else { return unchanged }
        let arguments = Array(argv.dropFirst(invocation.index + 1))
        let options = Array(arguments.prefix { $0 != "--" })
        let passthrough: Set<String> = ["login", "logout", "update", "help", "version", "mcp", "config", "agent", "hooks", "plugins", "doctor", "--help", "-h", "--version", "-V"]
        guard arguments.first.map({ !passthrough.contains($0) }) ?? true,
              !options.contains("--leader"),
              !options.contains(where: { $0.hasPrefix("--leader=") || $0 == "--leader-socket" || $0.hasPrefix("--leader-socket=") }) else {
            return unchanged
        }
        let environment = ProcessInfo.processInfo.environment
            .merging(launchEnvironment) { _, new in new }
            .merging(invocation.environment) { _, new in new }
        let homePath: String
        if let explicitHome = environment["GROK_HOME"] {
            homePath = explicitHome
        } else {
            let userHome = environment["HOME"] ?? fileManager.homeDirectoryForCurrentUser.path
            guard userHome.hasPrefix("/") else { return unchanged }
            homePath = URL(fileURLWithPath: userHome).appendingPathComponent(".grok").path
        }
        guard homePath.hasPrefix("/") else { return unchanged }
        let home = URL(fileURLWithPath: homePath).standardizedFileURL
        let hooks = home.appendingPathComponent("hooks", isDirectory: true)
        // Do not put generated hooks into a user's symlinked dotfiles directory.
        guard !isSymbolicLink(home), !isSymbolicLink(hooks) else { return unchanged }
        let artifacts = try artifactStore.makeDirectory(agent: .grok, sessionID: sessionID, lifetime: .agentProcess)
        guard artifacts.storage == .durable, let ownerURL = artifacts.ownerRecordURL else {
            artifactStore.removeAbandoned(artifacts)
            return unchanged
        }
        do {
            try fileManager.createDirectory(at: hooks, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let launchWrapper = artifacts.directoryURL.appendingPathComponent("grok-launch.sh")
            try AgentLaunchInstrumentation.writeExecutableScript(
                "#!/bin/sh\n(umask 077 && printf '%s\\n' \"$$\" > \(AgentLaunchInstrumentation.shellQuote(ownerURL.path)))\nexec \"$@\"\n",
                to: launchWrapper,
                fileManager: fileManager
            )
            let helper = artifacts.directoryURL.appendingPathComponent("grok-hooks.sh")
            try AgentLaunchInstrumentation.writeExecutableScript(
                AgentLaunchInstrumentation.makeTelemetryForwarderScript(
                    cliExecutablePath: cliExecutablePath,
                    source: "grok-hooks",
                    telemetryErrorLogURL: AgentLaunchInstrumentation.telemetryErrorLogURL(in: artifacts.directoryURL),
                    stderrFallbackURL: artifacts.directoryURL.appendingPathComponent("grok-hooks.stderr"),
                    inputMode: .none
                ),
                to: helper,
                fileManager: fileManager
            )
            let quote = AgentLaunchInstrumentation.shellQuote
            // Grok pre-expands bare $VAR references; parameter defaults preserve
            // shell-owned PPID for execution rather than environment lookup.
            // Check the producer PID as well as the inherited session ID. A
            // nested Grok process may inherit the root's environment but must
            // never claim its native conversation. Drain skipped payloads so
            // unrelated sessions do not see a broken stdin pipe.
            let command = "if [ \"${TOASTTY_SESSION_ID:-}\" = \(quote(sessionID)) ] && [ \"${PPID:-0}\" = \"$(cat \(quote(ownerURL.path)) 2>/dev/null)\" ] && [ -x \(quote(helper.path)) ]; then /bin/sh \(quote(helper.path)); else cat >/dev/null; fi; exit 0"
            let names = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Notification", "Stop", "StopFailure", "StopCancelled", "SessionEnd"]
            let entries: [String: Any] = Dictionary(uniqueKeysWithValues: names.map { name in
                (name, [["hooks": [["type": "command", "command": command, "timeout": 5]]]])
            })
            let jsonURL = artifacts.directoryURL.appendingPathComponent("hooks.json")
            try JSONSerialization.data(withJSONObject: ["hooks": entries], options: [.sortedKeys]).write(to: jsonURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jsonURL.path)
            try artifactStore.registerGrokHookLink(
                artifacts: artifacts,
                linkURL: hooks.appendingPathComponent("toastty-\(sessionID).json")
            )
            var preparedArgv = argv
            if !options.contains("--no-leader") {
                preparedArgv.insert("--no-leader", at: invocation.index + 1)
            }
            return PreparedAgentLaunchCommand(
                argv: preparedArgv,
                environment: [
                    "GROK_HOME": home.path,
                    ToasttyLaunchContextEnvironment.managedAgentArtifactOwnerFileKey: ownerURL.path,
                ],
                artifacts: PreparedAgentLaunchArtifacts(directory: artifacts, codexSessionLogURL: nil, cleanupPolicy: .retainAfterSessionStop)
            )
        } catch {
            artifactStore.removeAbandoned(artifacts)
            throw error
        }
    }

    private static func invocation(argv: [String]) -> (index: Int, environment: [String: String])? {
        guard let executable = argv.first else { return nil }
        if URL(fileURLWithPath: executable).lastPathComponent == "grok" { return (0, [:]) }
        guard URL(fileURLWithPath: executable).lastPathComponent == "env" else { return nil }
        var environment: [String: String] = [:]
        for index in argv.indices.dropFirst() {
            let argument = argv[index]
            if let separator = argument.firstIndex(of: "="), argument.first != "-" {
                environment[String(argument[..<separator])] = String(argument[argument.index(after: separator)...])
            } else {
                guard URL(fileURLWithPath: argument).lastPathComponent == "grok" else { return nil }
                return (index, environment)
            }
        }
        return nil
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }
}
