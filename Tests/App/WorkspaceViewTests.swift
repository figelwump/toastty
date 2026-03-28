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
            WorkspaceView.workspaceTabTrailingAccessory(index: 0, isHovered: true, showsCloseAffordance: true),
            .closeButton
        )
    }

    func testWorkspaceTabTrailingAccessoryShowsCommandDigitBadgesThroughNine() {
        XCTAssertEqual(
            WorkspaceView.workspaceTabTrailingAccessory(index: 0, isHovered: false, showsCloseAffordance: true),
            .badge("⌘1")
        )
        XCTAssertEqual(
            WorkspaceView.workspaceTabTrailingAccessory(index: 8, isHovered: false, showsCloseAffordance: true),
            .badge("⌘9")
        )
        XCTAssertEqual(
            WorkspaceView.workspaceTabTrailingAccessory(index: 9, isHovered: false, showsCloseAffordance: true),
            .empty
        )
    }

    func testWorkspaceTabTrailingAccessoryKeepsShortcutBadgeWhenCloseAffordanceIsSuppressed() {
        XCTAssertEqual(
            WorkspaceView.workspaceTabTrailingAccessory(index: 0, isHovered: true, showsCloseAffordance: false),
            .badge("⌘1")
        )
    }

    func testWorkspaceTabManagementAffordancesStayDisabledForSingleTabWorkspaces() {
        XCTAssertFalse(WorkspaceView.workspaceTabManagementAffordancesEnabled(tabCount: 1))
        XCTAssertTrue(WorkspaceView.workspaceTabManagementAffordancesEnabled(tabCount: 2))
    }

    func testResolvedWorkspaceTabWidthStaysAtIdealWidthWhenThereIsRoom() {
        let availableWidth = WorkspaceView.workspaceTabIdealTotalWidth(tabCount: 3) + 120
        XCTAssertEqual(
            WorkspaceView.resolvedWorkspaceTabWidth(availableWidth: availableWidth, tabCount: 3),
            ToastyTheme.workspaceTabWidth
        )
    }

    func testResolvedWorkspaceTabWidthCompressesTabsEquallyWhenHeaderGetsTight() {
        XCTAssertEqual(
            WorkspaceView.resolvedWorkspaceTabWidth(availableWidth: 524, tabCount: 5),
            100
        )
    }

    func testResolvedWorkspaceTabWidthStopsAtConfiguredMinimumWidth() {
        XCTAssertEqual(
            WorkspaceView.resolvedWorkspaceTabWidth(availableWidth: 140, tabCount: 5),
            ToastyTheme.workspaceTabMinimumWidth
        )
    }

    func testWorkspaceTabSelectedAccentFadesWhenAppIsInactive() throws {
        let activeAccent = try XCTUnwrap(
            NSColor(ToastyTheme.workspaceTabSelectedAccentColor(appIsActive: true))
                .usingColorSpace(.deviceRGB)
        )
        let inactiveAccent = try XCTUnwrap(
            NSColor(ToastyTheme.workspaceTabSelectedAccentColor(appIsActive: false))
                .usingColorSpace(.deviceRGB)
        )
        let expectedInactiveAccent = try XCTUnwrap(
            NSColor(ToastyTheme.accent.opacity(0.5)).usingColorSpace(.deviceRGB)
        )

        XCTAssertEqual(activeAccent.alphaComponent, 1, accuracy: 0.001)
        XCTAssertEqual(inactiveAccent.redComponent, expectedInactiveAccent.redComponent, accuracy: 0.001)
        XCTAssertEqual(inactiveAccent.greenComponent, expectedInactiveAccent.greenComponent, accuracy: 0.001)
        XCTAssertEqual(inactiveAccent.blueComponent, expectedInactiveAccent.blueComponent, accuracy: 0.001)
        XCTAssertEqual(inactiveAccent.alphaComponent, expectedInactiveAccent.alphaComponent, accuracy: 0.001)
    }

    func testWorkspaceTabChromeSpecSelectedStateWinsOverHover() throws {
        let spec = WorkspaceView.workspaceTabChromeSpec(
            isSelected: true,
            isHovered: true,
            isRenaming: false,
            appIsActive: true
        )

        try assertColor(spec.background, equals: ToastyTheme.workspaceTabSelectedBackground)
        try assertColor(spec.text, equals: ToastyTheme.primaryText)
        let accentColor = try XCTUnwrap(spec.accentColor)
        try assertColor(accentColor, equals: ToastyTheme.workspaceTabSelectedAccent)
    }

    func testWorkspaceTabChromeSpecSelectedBackgroundMatchesPanelHeaderBackground() throws {
        let spec = WorkspaceView.workspaceTabChromeSpec(
            isSelected: true,
            isHovered: false,
            isRenaming: false,
            appIsActive: true
        )

        try assertColor(spec.background, equals: ToastyTheme.elevatedBackground)
    }

    func testWorkspaceTabChromeSpecRenamingUnselectedUsesVisibleFillWithoutAccent() throws {
        let spec = WorkspaceView.workspaceTabChromeSpec(
            isSelected: false,
            isHovered: false,
            isRenaming: true,
            appIsActive: true
        )

        try assertColor(spec.background, equals: ToastyTheme.workspaceTabHoverBackground)
        try assertColor(spec.text, equals: ToastyTheme.primaryText)
        XCTAssertNil(spec.accentColor)
    }

    func testWorkspaceTabChromeSpecRenamingSelectedPreservesAccent() throws {
        let spec = WorkspaceView.workspaceTabChromeSpec(
            isSelected: true,
            isHovered: false,
            isRenaming: true,
            appIsActive: false
        )

        try assertColor(spec.background, equals: ToastyTheme.workspaceTabSelectedBackground)
        let accentColor = try XCTUnwrap(spec.accentColor)
        try assertColor(accentColor, equals: ToastyTheme.workspaceTabSelectedAccent.opacity(0.5))
    }

    func testWorkspaceTabUnreadDotUsesLargerDiameter() {
        XCTAssertEqual(ToastyTheme.workspaceTabUnreadDotDiameter, 7)
    }

    private func assertColor(
        _ actual: Color,
        equals expected: Color,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actualColor = try XCTUnwrap(NSColor(actual).usingColorSpace(.deviceRGB), file: file, line: line)
        let expectedColor = try XCTUnwrap(NSColor(expected).usingColorSpace(.deviceRGB), file: file, line: line)

        XCTAssertEqual(actualColor.redComponent, expectedColor.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.greenComponent, expectedColor.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.blueComponent, expectedColor.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.alphaComponent, expectedColor.alphaComponent, accuracy: 0.001, file: file, line: line)
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
