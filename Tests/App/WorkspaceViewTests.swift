@testable import ToasttyApp
import CoreState
import XCTest

final class WorkspaceViewTests: XCTestCase {
    func testWorkspaceAgentTopBarModelUsesConfiguredProfileOrderAndDisplayNames() {
        let catalog = AgentCatalog(
            profiles: [
                AgentProfile(id: "codex", displayName: "Codex", argv: ["codex"]),
                AgentProfile(id: "claude", displayName: "Claude Code", argv: ["claude"]),
            ]
        )

        let model = WorkspaceAgentTopBarModel(
            catalog: catalog,
            profileShortcutRegistry: makeProfileShortcutRegistry(agentProfiles: catalog)
        )

        XCTAssertEqual(model.actions.map(\.profileID), ["codex", "claude"])
        XCTAssertEqual(model.actions.map(\.title), ["Codex", "Claude Code"])
        XCTAssertEqual(model.actions.map(\.helpText), ["Run Codex", "Run Claude Code"])
        XCTAssertFalse(model.showsAddAgentsButton)
    }

    func testWorkspaceAgentTopBarModelIncludesShortcutInHelpTextWhenConfigured() {
        let catalog = AgentCatalog(
            profiles: [
                AgentProfile(id: "codex", displayName: "Codex", argv: ["codex"], shortcutKey: "c")
            ]
        )

        let model = WorkspaceAgentTopBarModel(
            catalog: catalog,
            profileShortcutRegistry: makeProfileShortcutRegistry(agentProfiles: catalog)
        )

        XCTAssertEqual(model.actions.map(\.helpText), ["Run Codex (⌃⌘C)"])
    }

    func testWorkspaceAgentTopBarModelShowsAddAgentsButtonWithoutConfiguredProfiles() {
        let model = WorkspaceAgentTopBarModel(
            catalog: .empty,
            profileShortcutRegistry: makeProfileShortcutRegistry(agentProfiles: .empty)
        )

        XCTAssertTrue(model.actions.isEmpty)
        XCTAssertTrue(model.showsAddAgentsButton)
        XCTAssertEqual(WorkspaceAgentTopBarModel.addAgentsTitle, "Add Agents…")
    }

    private func makeProfileShortcutRegistry(
        agentProfiles: AgentCatalog
    ) -> ProfileShortcutRegistry {
        ProfileShortcutRegistry(
            terminalProfiles: .empty,
            terminalProfilesFilePath: "/tmp/terminal-profiles.toml",
            agentProfiles: agentProfiles,
            agentProfilesFilePath: "/tmp/agents.toml"
        )
    }
}
