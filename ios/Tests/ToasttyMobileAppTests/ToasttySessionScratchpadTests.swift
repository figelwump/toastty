import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

@MainActor
final class ToasttySessionScratchpadTests: XCTestCase {
    func testAssociationResolvesAcrossWorkspacesAndUsesTheConversationRouteIdentity() throws {
        let snapshot = ToasttyMobileFixture.home
        let id = ToasttyMobileFixture.scratchpadConversationID
        let panels = ToasttySessionScratchpads.panels(in: snapshot, for: id)
        XCTAssertEqual(panels.count, 1)
        let panel = try XCTUnwrap(panels.first)
        let conversation = try XCTUnwrap(ToasttySessionScratchpads.conversation(
            in: snapshot, workspaceID: panel.workspaceID, panelID: panel.id))
        XCTAssertNotEqual(panel.workspaceID, conversation.workspaceID)
        XCTAssertEqual(conversation.id, id)
        XCTAssertEqual(panel.selection.id, panel.id)
        let controller = HomeScreenController(runtimeMode: .fixture, snapshot: snapshot, connectionState: .live)
        XCTAssertTrue(controller.openConversation(id: conversation.id))
        XCTAssertEqual([ToasttyMobileRoute]().synchronized(with: controller.selectedConversationPresentation),
                       [.conversation(id)])
    }

    func testMissingAssociationConversationOrPanelNeverUsesAReplacement() {
        let id = ToasttyMobileFixture.scratchpadConversationID
        let source = ToasttyMobileFixture.home
        var panels = source.workspaces[0].panels
        panels[0].associatedConversationID = nil
        var snapshot = replacingPanels(in: source.workspaces[0].id, with: panels, snapshot: source)
        XCTAssertTrue(ToasttySessionScratchpads.panels(in: snapshot, for: id).isEmpty)
        XCTAssertNil(ToasttySessionScratchpads.conversation(
            in: snapshot, workspaceID: ToasttyMobileFixture.previewWorkspaceID,
            panelID: ToasttyMobileFixture.scratchpadPanelID))
        let replacementID = source.workspaces[0].conversations[0].id
        panels[0].associatedConversationID = RemoteConversationID(rawValue: replacementID)
        snapshot = replacingPanels(in: source.workspaces[0].id, with: panels, snapshot: source)
        XCTAssertTrue(ToasttySessionScratchpads.panels(in: snapshot, for: id).isEmpty)
        XCTAssertEqual(ToasttySessionScratchpads.panels(in: snapshot, for: replacementID).count, 1)
        XCTAssertEqual(ToasttySessionScratchpads.conversation(
            in: snapshot, workspaceID: ToasttyMobileFixture.previewWorkspaceID,
            panelID: ToasttyMobileFixture.scratchpadPanelID)?.id, replacementID)
        snapshot = MobileHomeSnapshot(hostName: source.hostName, workspaces: source.workspaces.map {
            MobileWorkspace(id: $0.id, title: $0.title,
                            conversations: $0.conversations.filter { $0.id != id }, panels: $0.panels)
        })
        XCTAssertTrue(ToasttySessionScratchpads.panels(in: snapshot, for: id).isEmpty)
        XCTAssertNil(ToasttySessionScratchpads.conversation(
            in: snapshot, workspaceID: ToasttyMobileFixture.previewWorkspaceID,
            panelID: ToasttyMobileFixture.scratchpadPanelID))
        XCTAssertNil(ToasttySessionScratchpads.conversation(
            in: ToasttyMobileFixture.home, workspaceID: UUID(), panelID: UUID()))
    }

    func testMultiplePanelsRemainDistinctAndNonScratchpadKindsAreExcluded() {
        var snapshot = ToasttyMobileFixture.home
        var second = snapshot.workspaces[0].panels[0]
        second.panelID = UUID()
        second.workspaceTabTitle = "Another tab"
        snapshot = replacingPanels(in: snapshot.workspaces[1].id,
                                   with: snapshot.workspaces[1].panels + [second], snapshot: snapshot)
        var firstWorkspacePanels = snapshot.workspaces[0].panels
        firstWorkspacePanels[1].associatedConversationID = second.associatedConversationID
        snapshot = replacingPanels(in: snapshot.workspaces[0].id, with: firstWorkspacePanels, snapshot: snapshot)
        let panels = ToasttySessionScratchpads.panels(in: snapshot, for: ToasttyMobileFixture.scratchpadConversationID)
        XCTAssertEqual(panels.count, 2)
        XCTAssertNotEqual(panels[0].id, panels[1].id)
        XCTAssertNotEqual(panels[0].menuTitle, panels[1].menuTitle)
        XCTAssertNotEqual(panels[0].selection.target, panels[1].selection.target)
        XCTAssertNil(ToasttySessionScratchpads.conversation(
            in: snapshot, workspaceID: snapshot.workspaces[0].id,
            panelID: snapshot.workspaces[0].panels[1].panelID))
    }

    private func replacingPanels(
        in workspaceID: UUID, with panels: [RemoteWorkspacePanel], snapshot: MobileHomeSnapshot
    ) -> MobileHomeSnapshot {
        MobileHomeSnapshot(hostName: snapshot.hostName, workspaces: snapshot.workspaces.map {
            MobileWorkspace(id: $0.id, title: $0.title, conversations: $0.conversations,
                            panels: $0.id == workspaceID ? panels : $0.panels)
        })
    }
}
