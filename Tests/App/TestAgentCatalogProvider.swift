import CoreState
import Foundation
@testable import ToasttyApp

@MainActor
final class TestAgentCatalogProvider: AgentCatalogProviding {
    var catalog: AgentCatalog

    init(
        profiles: [AgentProfile] = [
            AgentProfile(id: "codex", displayName: "Codex", argv: ["codex"]),
            AgentProfile(id: "claude", displayName: "Claude Code", argv: ["claude"]),
        ]
    ) {
        catalog = AgentCatalog(profiles: profiles)
    }
}
