@testable import ToasttyApp
import CoreState
import SwiftUI
import XCTest

final class ToasttyCommandMenusTests: XCTestCase {
    func testTerminalProfileMenuModelUsesProfilesAsTopLevelSections() {
        let catalog = TerminalProfileCatalog(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach"
                ),
                TerminalProfile(
                    id: "ssh-prod",
                    displayName: "SSH Prod",
                    badgeLabel: "PROD",
                    startupCommand: "ssh prod"
                ),
            ]
        )

        let model = TerminalProfileMenuModel(
            catalog: catalog,
            registry: makeProfileShortcutRegistry(terminalProfiles: catalog)
        )

        XCTAssertEqual(model.sections.map(\.title), ["ZMX", "SSH Prod"])
        XCTAssertEqual(model.sections.map(\.profileID), ["zmx", "ssh-prod"])
        XCTAssertEqual(
            model.sections.map { $0.actions.map(\.title) },
            [
                ["Split Right", "Split Down"],
                ["Split Right", "Split Down"],
            ]
        )
        XCTAssertEqual(
            model.sections.map { $0.actions.map(\.direction) },
            [
                [.right, .down],
                [.right, .down],
            ]
        )
    }

    func testTerminalProfileMenuModelMapsShortcutsToEachSplitDirection() throws {
        let catalog = TerminalProfileCatalog(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach",
                    shortcutKey: "z"
                ),
            ]
        )

        let model = TerminalProfileMenuModel(
            catalog: catalog,
            registry: makeProfileShortcutRegistry(terminalProfiles: catalog)
        )
        let actions = try XCTUnwrap(model.sections.first?.actions)

        XCTAssertEqual(actions.first?.shortcut, ShortcutChord(key: "z", modifiers: [.command, .control]))
        XCTAssertEqual(actions.last?.shortcut, ShortcutChord(key: "z", modifiers: [.command, .control, .shift]))
    }

    func testTerminalProfileMenuModelOmitsConflictedShortcutFromRegistry() throws {
        let terminalCatalog = TerminalProfileCatalog(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach",
                    shortcutKey: "z"
                ),
            ]
        )
        let registry = makeProfileShortcutRegistry(
            terminalProfiles: terminalCatalog,
            agentProfiles: AgentCatalog(
                profiles: [
                    AgentProfile(
                        id: "codex",
                        displayName: "Codex",
                        argv: ["codex"],
                        shortcutKey: "z"
                    ),
                ]
            )
        )

        let model = TerminalProfileMenuModel(
            catalog: terminalCatalog,
            registry: registry
        )
        let actions = try XCTUnwrap(model.sections.first?.actions)

        XCTAssertNil(actions.first?.shortcut)
        XCTAssertEqual(actions.last?.shortcut, ShortcutChord(key: "z", modifiers: [.command, .control, .shift]))
    }
}

private func makeProfileShortcutRegistry(
    terminalProfiles: TerminalProfileCatalog,
    agentProfiles: AgentCatalog = .empty
) -> ProfileShortcutRegistry {
    ProfileShortcutRegistry(
        terminalProfiles: terminalProfiles,
        terminalProfilesFilePath: "/tmp/terminal-profiles.toml",
        agentProfiles: agentProfiles,
        agentProfilesFilePath: "/tmp/agents.toml"
    )
}
