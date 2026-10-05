import CoreState
import RemoteProtocol

/// The desktop name of an agent, such as "Claude Code".
///
/// CoreState and ToasttyMobileDomain each extend `AgentKind` with
/// `displayName`, so a file that imports both cannot name either. This file
/// imports only CoreState and so reaches the desktop one.
enum RemoteHostAgentName {
    static func displayName(for agent: AgentKind) -> String {
        agent.displayName
    }
}
