@testable import ToasttyApp
import AppKit
import CoreState
import SwiftUI
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

    func testWorkspaceTabTrailingAccessoryUsesCloseButtonWhenHovered() {
        XCTAssertEqual(
            WorkspaceView.workspaceTabTrailingAccessory(index: 0, isHovered: true),
            .closeButton
        )
    }

    func testWorkspaceTabTrailingAccessoryShowsCommandDigitBadgesThroughNine() {
        XCTAssertEqual(
            WorkspaceView.workspaceTabTrailingAccessory(index: 0, isHovered: false),
            .badge("⌘1")
        )
        XCTAssertEqual(
            WorkspaceView.workspaceTabTrailingAccessory(index: 8, isHovered: false),
            .badge("⌘9")
        )
        XCTAssertEqual(
            WorkspaceView.workspaceTabTrailingAccessory(index: 9, isHovered: false),
            .empty
        )
    }

    func testWorkspaceTabLeadingPaddingDoesNotReserveHiddenSidebarTitlebarSpace() {
        XCTAssertEqual(
            WorkspaceView.workspaceTabLeadingPadding(sidebarVisible: true),
            ToastyTheme.workspaceTabLeadingPadding
        )
        XCTAssertEqual(
            WorkspaceView.workspaceTabLeadingPadding(sidebarVisible: false),
            ToastyTheme.workspaceTabLeadingPadding
        )
        XCTAssertNotEqual(
            WorkspaceView.workspaceTabLeadingPadding(sidebarVisible: false),
            ToastyTheme.topBarLeadingPaddingWithoutSidebar
        )
    }

    func testWorkspaceTabSelectedBorderFadesWhenAppIsInactive() throws {
        let activeBorder = try XCTUnwrap(
            NSColor(ToastyTheme.workspaceTabSelectedBorderColor(appIsActive: true))
                .usingColorSpace(.deviceRGB)
        )
        let inactiveBorder = try XCTUnwrap(
            NSColor(ToastyTheme.workspaceTabSelectedBorderColor(appIsActive: false))
                .usingColorSpace(.deviceRGB)
        )
        let expectedInactiveBorder = try XCTUnwrap(
            NSColor(ToastyTheme.accent.opacity(0.5)).usingColorSpace(.deviceRGB)
        )

        XCTAssertEqual(activeBorder.alphaComponent, 1, accuracy: 0.001)
        XCTAssertEqual(inactiveBorder.redComponent, expectedInactiveBorder.redComponent, accuracy: 0.001)
        XCTAssertEqual(inactiveBorder.greenComponent, expectedInactiveBorder.greenComponent, accuracy: 0.001)
        XCTAssertEqual(inactiveBorder.blueComponent, expectedInactiveBorder.blueComponent, accuracy: 0.001)
        XCTAssertEqual(inactiveBorder.alphaComponent, expectedInactiveBorder.alphaComponent, accuracy: 0.001)
    }

    func testWorkspaceTabUnreadDotUsesLargerDiameter() {
        XCTAssertEqual(ToastyTheme.workspaceTabUnreadDotDiameter, 7)
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
