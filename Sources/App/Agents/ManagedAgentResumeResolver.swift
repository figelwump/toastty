import CoreState
import Foundation

enum ManagedAgentResumeResolution: Equatable {
    case none
    case clearRecord(reason: ManagedAgentResumeResolver.ClearReason)
    case launch(TerminalSurfaceLaunchConfiguration)
}

enum ManagedAgentResumeResolver {
    enum ClearReason: String, Equatable {
        case missingSessionFile = "missing_session_file"
        case missingWorkingDirectory = "missing_working_directory"
    }

    static func resolve(
        panelID: UUID,
        terminalState: TerminalPanelState,
        launchReason: TerminalLaunchReason,
        baseEnvironmentVariables: [String: String] = [:],
        agentCatalog: AgentCatalog = .empty,
        fileManager: FileManager = .default
    ) -> ManagedAgentResumeResolution {
        guard launchReason == .restore,
              let record = terminalState.resumeRecord else {
            return .none
        }

        guard let argv = resumeArgv(for: record, agentCatalog: agentCatalog) else {
            return .none
        }

        guard fileManager.fileExists(atPath: record.sessionFilePath) else {
            return .clearRecord(reason: .missingSessionFile)
        }

        guard let cwd = normalizedExistingDirectory(record.cwd, fileManager: fileManager) else {
            return .clearRecord(reason: .missingWorkingDirectory)
        }

        return .launch(
            TerminalSurfaceLaunchConfiguration(
                environmentVariables: baseEnvironmentVariables.merging([
                    "TOASTTY_PANEL_ID": panelID.uuidString,
                    "TOASTTY_LAUNCH_REASON": launchReason.rawValue,
                    "TOASTTY_MANAGED_AGENT_RESUME_PROVIDER": record.agent.rawValue,
                    "TOASTTY_MANAGED_AGENT_NATIVE_SESSION_ID": record.nativeSessionID,
                ], uniquingKeysWith: { _, new in new }),
                initialInput: ShellCommandRenderer.render(argv: argv),
                workingDirectoryOverride: cwd
            )
        )
    }
}

private extension ManagedAgentResumeResolver {
    static func resumeArgv(
        for record: ManagedAgentResumeRecord,
        agentCatalog: AgentCatalog
    ) -> [String]? {
        let resumeArguments: [String]
        switch record.agent {
        case .codex:
            resumeArguments = ["resume", record.nativeSessionID]
        case .claude:
            resumeArguments = ["--resume", record.nativeSessionID]
        case .pi:
            resumeArguments = ["--session", record.sessionFilePath]
        default:
            return nil
        }

        guard let profile = agentCatalog.profile(id: record.agent.rawValue),
              profile.argv.isEmpty == false else {
            return [record.agent.rawValue] + resumeArguments
        }

        let insertionIndex = ManagedAgentCommandResolver.launchInsertionIndex(for: record.agent, argv: profile.argv)
        guard profile.argv.indices.contains(insertionIndex) else {
            return [record.agent.rawValue] + resumeArguments
        }

        return Array(profile.argv.prefix(insertionIndex + 1))
            + resumeArguments
            + Array(profile.argv.dropFirst(insertionIndex + 1))
    }

    static func normalizedExistingDirectory(_ path: String, fileManager: FileManager) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let normalized = (expanded as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: normalized, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return normalized
    }
}
