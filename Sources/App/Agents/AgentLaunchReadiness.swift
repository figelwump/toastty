import CoreState
import Foundation

/// Shared rules for launching an agent into a terminal that was just
/// created and for choosing a workspace's directory.
enum AgentLaunchReadiness {
    /// How long a new terminal may take to show its first shell prompt.
    static let defaultTimeout: Duration = .seconds(10)
    static let retryInterval: Duration = .milliseconds(250)

    /// A new terminal is not ready at once: it reports itself busy until its
    /// shell prints the first prompt, and its surface can refuse input for a
    /// moment after that. Both refusals happen before any text is sent, so
    /// they are retried until `timeout` passes. A delivery the terminal did
    /// not confirm is never retried, because part of the command may
    /// already be in the terminal.
    @MainActor
    static func launchWhenTerminalIsReady(
        timeout: Duration,
        beforeEachAttempt: @MainActor () -> Void = {},
        attempt: @MainActor () async throws -> AgentLaunchResult
    ) async throws -> AgentLaunchResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            beforeEachAttempt()
            do {
                return try await attempt()
            } catch let error as AgentLaunchError {
                switch error {
                case .panelBusy, .terminalUnavailable:
                    guard clock.now < deadline else { throw error }
                    try await Task.sleep(for: retryInterval)
                default:
                    throw error
                }
            }
        }
    }

    /// The directory a new session starts in: the first terminal, in tab
    /// order, whose directory is known and still exists. This does not
    /// follow focus, so the answer stays the same between asking and
    /// starting.
    static func launchDirectory(in workspace: WorkspaceState, fileManager: FileManager = .default) -> String? {
        for tab in workspace.orderedTabs {
            for slot in tab.layoutTree.allSlotInfos {
                guard case .terminal(let terminal) = tab.panels[slot.panelID],
                      let directory = terminal.agentLaunchWorkingDirectory else { continue }
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue {
                    return directory
                }
            }
        }
        return nil
    }
}

extension AgentLaunchProfileSummary {
    /// The effort values each provider's command accepts. Empty for a
    /// provider with no effort setting.
    var reasoningEffortChoices: [String] {
        guard supportsReasoningEffort else { return [] }
        switch agent {
        case .claude: return ["low", "medium", "high", "xhigh", "max"]
        case .codex: return ["low", "medium", "high", "xhigh"]
        case .pi: return ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
        default: return []
        }
    }
}
