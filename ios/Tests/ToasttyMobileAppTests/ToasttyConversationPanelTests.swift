import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

@MainActor
final class ToasttyConversationPanelTests: XCTestCase {
    private let gatewayDesignID = UUID(uuidString: "B1000000-0000-0000-0000-000000000001")!

    func testWorkspaceSessionListsEveryPanelKindInWorkspacePageOrder() {
        let snapshot = ToasttyMobileFixture.home
        let sections = ToasttyConversationPanels.sections(in: snapshot, for: gatewayDesignID)
        XCTAssertEqual(sections.count, 1)
        let workspace = snapshot.workspaces.first { $0.id == ToasttyMobileFixture.previewWorkspaceID }!
        XCTAssertEqual(sections[0].panels.map(\.id),
                       ToasttyWorkspacePanels.sorted(workspace.panels).map(\.panelID))
        XCTAssertEqual(Set(sections[0].panels.map(\.panel.kind)), ["scratchpad", "localDocument", "browser"])
        XCTAssertEqual(sections[0].panels.first?.selection.target,
                       .panel(workspaceID: workspace.id, panelID: ToasttyMobileFixture.scratchpadPanelID))
    }

    func testSameTitledPanelsCarryTheirWorkspacePageFolderHints() {
        // Move a session into the playground, whose two reports share a title.
        let source = ToasttyMobileFixture.home
        let session = source.workspaces[0].conversations[0]
        let snapshot = MobileHomeSnapshot(hostName: source.hostName, workspaces: source.workspaces.map {
            let conversations = $0.id == ToasttyMobileFixture.panelOnlyWorkspaceID
                ? [session] : $0.conversations.filter { $0.id != session.id }
            return MobileWorkspace(id: $0.id, title: $0.title, conversations: conversations, panels: $0.panels)
        })
        let panels = ToasttyConversationPanels.sections(in: snapshot, for: session.id).flatMap(\.panels)
        let hints = Dictionary(uniqueKeysWithValues: panels.map { ($0.panel.title + ($0.folderHint ?? ""), $0.id) })
        XCTAssertEqual(hints["report.jsonsmoke"], ToasttyMobileFixture.smokeReportPanelID)
        XCTAssertEqual(hints["report.jsonremote"], ToasttyMobileFixture.remoteReportPanelID)
        XCTAssertNotNil(hints["Navigation sketch"])
    }

    func testBoundScratchpadInAnotherWorkspaceFollowsAsItsOwnSection() throws {
        let snapshot = ToasttyMobileFixture.home
        let id = ToasttyMobileFixture.scratchpadConversationID
        // The release workspace has no panels of its own.
        let sections = ToasttyConversationPanels.sections(in: snapshot, for: id)
        XCTAssertEqual(sections.count, 1)
        let section = try XCTUnwrap(sections.first)
        XCTAssertEqual(section.workspaceID, ToasttyMobileFixture.previewWorkspaceID)
        XCTAssertEqual(section.workspaceTitle, "toastty")
        XCTAssertEqual(section.panels.map(\.id), [ToasttyMobileFixture.scratchpadPanelID])
        let conversation = try XCTUnwrap(ToasttySessionScratchpads.conversation(
            in: snapshot, workspaceID: section.workspaceID, panelID: ToasttyMobileFixture.scratchpadPanelID))
        XCTAssertEqual(conversation.id, id)
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
        XCTAssertTrue(ToasttyConversationPanels.sections(in: snapshot, for: id).isEmpty)
        XCTAssertNil(ToasttySessionScratchpads.conversation(
            in: snapshot, workspaceID: ToasttyMobileFixture.previewWorkspaceID,
            panelID: ToasttyMobileFixture.scratchpadPanelID))
        // Rebinding to another release session moves the extra section with it.
        let replacementID = UUID(uuidString: "B1000000-0000-0000-0000-000000000008")!
        panels[0].associatedConversationID = RemoteConversationID(rawValue: replacementID)
        snapshot = replacingPanels(in: source.workspaces[0].id, with: panels, snapshot: source)
        XCTAssertTrue(ToasttyConversationPanels.sections(in: snapshot, for: id).isEmpty)
        XCTAssertEqual(ToasttyConversationPanels.sections(in: snapshot, for: replacementID).count, 1)
        XCTAssertEqual(ToasttySessionScratchpads.conversation(
            in: snapshot, workspaceID: ToasttyMobileFixture.previewWorkspaceID,
            panelID: ToasttyMobileFixture.scratchpadPanelID)?.id, replacementID)
        snapshot = MobileHomeSnapshot(hostName: source.hostName, workspaces: source.workspaces.map {
            MobileWorkspace(id: $0.id, title: $0.title,
                            conversations: $0.conversations.filter { $0.id != id }, panels: $0.panels)
        })
        XCTAssertTrue(ToasttyConversationPanels.sections(in: snapshot, for: id).isEmpty)
        XCTAssertNil(ToasttySessionScratchpads.conversation(
            in: snapshot, workspaceID: ToasttyMobileFixture.previewWorkspaceID,
            panelID: ToasttyMobileFixture.scratchpadPanelID))
        XCTAssertNil(ToasttySessionScratchpads.conversation(
            in: ToasttyMobileFixture.home, workspaceID: UUID(), panelID: UUID()))
    }

    func testOtherWorkspacesContributeOnlyBoundScratchpads() {
        var snapshot = ToasttyMobileFixture.home
        let id = ToasttyMobileFixture.scratchpadConversationID
        // A second bound Scratchpad in the playground, beside unbound panels.
        var playgroundPanels = snapshot.workspaces.first { $0.id == ToasttyMobileFixture.panelOnlyWorkspaceID }!.panels
        playgroundPanels[0].associatedConversationID = RemoteConversationID(rawValue: id)
        snapshot = replacingPanels(in: ToasttyMobileFixture.panelOnlyWorkspaceID,
                                   with: playgroundPanels, snapshot: snapshot)
        // A bound panel that is not a Scratchpad stays out.
        var previewPanels = snapshot.workspaces[0].panels
        previewPanels[1].associatedConversationID = RemoteConversationID(rawValue: id)
        snapshot = replacingPanels(in: snapshot.workspaces[0].id, with: previewPanels, snapshot: snapshot)
        let sections = ToasttyConversationPanels.sections(in: snapshot, for: id)
        XCTAssertEqual(sections.map(\.workspaceID),
                       [ToasttyMobileFixture.previewWorkspaceID, ToasttyMobileFixture.panelOnlyWorkspaceID])
        XCTAssertEqual(sections.flatMap(\.panels).map(\.id),
                       [ToasttyMobileFixture.scratchpadPanelID, ToasttyMobileFixture.navigationScratchpadPanelID])
        XCTAssertEqual(sections[1].workspaceTitle, "Preview playground")
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
