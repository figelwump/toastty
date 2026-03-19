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

        let model = WorkspaceAgentTopBarModel(catalog: catalog)

        XCTAssertEqual(model.actions.map(\.profileID), ["codex", "claude"])
        XCTAssertEqual(model.actions.map(\.title), ["Codex", "Claude Code"])
    }

    func testWorkspaceAgentTopBarModelIsEmptyWithoutConfiguredProfiles() {
        let model = WorkspaceAgentTopBarModel(catalog: .empty)

        XCTAssertTrue(model.actions.isEmpty)
    }
}
