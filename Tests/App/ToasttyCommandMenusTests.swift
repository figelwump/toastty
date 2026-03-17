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

        let model = TerminalProfileMenuModel(catalog: catalog)

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

        let model = TerminalProfileMenuModel(catalog: catalog)
        let actions = try XCTUnwrap(model.sections.first?.actions)

        XCTAssertEqual(actions.first?.shortcutKey, "z")
        XCTAssertEqual(actions.last?.shortcutKey, "z")
        XCTAssertEqual(actions.first?.shortcutModifiers, [.command, .control])
        XCTAssertEqual(actions.last?.shortcutModifiers, [.command, .control, .shift])
    }
}
