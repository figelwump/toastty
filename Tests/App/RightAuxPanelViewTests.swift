import AppKit
import CoreState
import SwiftUI
import XCTest
@testable import ToasttyApp

final class RightAuxPanelViewTests: XCTestCase {
    func testTabStripShowsWhenAnyRightPanelTabExists() {
        XCTAssertFalse(RightAuxPanelTabStrip.showsTabStrip(tabCount: 0))
        XCTAssertTrue(RightAuxPanelTabStrip.showsTabStrip(tabCount: 1))
        XCTAssertTrue(RightAuxPanelTabStrip.showsTabStrip(tabCount: 2))
    }

    func testTabListReservesSpaceForAddMenu() {
        XCTAssertEqual(
            RightAuxPanelTabStrip.tabListAvailableWidth(totalWidth: 360),
            322
        )
        XCTAssertEqual(
            RightAuxPanelTabStrip.tabListAvailableWidth(totalWidth: 24),
            0
        )
    }

    func testTabWidthCompressesWithinRightPanelMinimum() {
        XCTAssertEqual(
            RightAuxPanelTabStrip.resolvedTabWidth(availableWidth: 360, tabCount: 2),
            142
        )
        XCTAssertEqual(
            RightAuxPanelTabStrip.resolvedTabWidth(availableWidth: 260, tabCount: 4),
            82
        )
    }

    func testUnreadDotShowsForPanelInUnreadSet() {
        let unreadPanelID = UUID()
        let readPanelID = UUID()

        XCTAssertTrue(
            RightAuxPanelTabStrip.showsUnreadDot(
                unreadPanelIDs: [unreadPanelID],
                panelID: unreadPanelID
            )
        )
        XCTAssertFalse(
            RightAuxPanelTabStrip.showsUnreadDot(
                unreadPanelIDs: [unreadPanelID],
                panelID: readPanelID
            )
        )
    }

    func testTabAccessibilityLabelIncludesUnreadState() {
        XCTAssertEqual(
            RightAuxPanelTabStrip.tabAccessibilityLabel(title: "Scratchpad", hasUnread: true),
            "Scratchpad, unread"
        )
        XCTAssertEqual(
            RightAuxPanelTabStrip.tabAccessibilityLabel(title: "Scratchpad", hasUnread: false),
            "Scratchpad"
        )
    }

    func testRightAuxPanelFocusRequiresVisibleSelectedFocusedPanel() {
        let focusedPanelID = UUID()

        XCTAssertTrue(
            RightAuxPanelView.isRightAuxPanelFocused(
                isWorkspaceSelected: true,
                isWorkspaceTabSelected: true,
                isRightAuxPanelVisible: true,
                focusedPanelID: focusedPanelID
            )
        )
        XCTAssertFalse(
            RightAuxPanelView.isRightAuxPanelFocused(
                isWorkspaceSelected: false,
                isWorkspaceTabSelected: true,
                isRightAuxPanelVisible: true,
                focusedPanelID: focusedPanelID
            )
        )
        XCTAssertFalse(
            RightAuxPanelView.isRightAuxPanelFocused(
                isWorkspaceSelected: true,
                isWorkspaceTabSelected: false,
                isRightAuxPanelVisible: true,
                focusedPanelID: focusedPanelID
            )
        )
        XCTAssertFalse(
            RightAuxPanelView.isRightAuxPanelFocused(
                isWorkspaceSelected: true,
                isWorkspaceTabSelected: true,
                isRightAuxPanelVisible: false,
                focusedPanelID: focusedPanelID
            )
        )
        XCTAssertFalse(
            RightAuxPanelView.isRightAuxPanelFocused(
                isWorkspaceSelected: true,
                isWorkspaceTabSelected: true,
                isRightAuxPanelVisible: true,
                focusedPanelID: nil
            )
        )
    }

    func testSelectedAccentOnlyShowsForActiveRightPanelTab() {
        XCTAssertNil(
            RightAuxPanelTabStrip.selectedAccentColor(
                isActive: false,
                appIsActive: true,
                isRightAuxPanelFocused: true
            )
        )
        XCTAssertNotNil(
            RightAuxPanelTabStrip.selectedAccentColor(
                isActive: true,
                appIsActive: true,
                isRightAuxPanelFocused: true
            )
        )
    }

    func testSelectedAccentIsFullStrengthWhenRightPanelFocused() throws {
        let accentColor = try XCTUnwrap(
            RightAuxPanelTabStrip.selectedAccentColor(
                isActive: true,
                appIsActive: true,
                isRightAuxPanelFocused: true
            )
        )

        try assertColor(accentColor, equals: ToastyTheme.workspaceTabSelectedAccent)
    }

    func testSelectedAccentMutesWhenRightPanelUnfocusedOrAppInactive() throws {
        let unfocusedAccentColor = try XCTUnwrap(
            RightAuxPanelTabStrip.selectedAccentColor(
                isActive: true,
                appIsActive: true,
                isRightAuxPanelFocused: false
            )
        )
        let inactiveAccentColor = try XCTUnwrap(
            RightAuxPanelTabStrip.selectedAccentColor(
                isActive: true,
                appIsActive: false,
                isRightAuxPanelFocused: true
            )
        )
        let mutedAccentColor = ToastyTheme.workspaceTabSelectedAccent.opacity(0.5)

        try assertColor(unfocusedAccentColor, equals: mutedAccentColor)
        try assertColor(inactiveAccentColor, equals: mutedAccentColor)
    }

    func testRightPanelTabBackgroundHierarchyUsesStrongerSelectedFill() throws {
        try assertColor(
            RightAuxPanelTabStrip.tabBackgroundColor(isActive: true, isHovered: true),
            equals: ToastyTheme.rightAuxPanelTabSelectedBackground
        )
        try assertColor(
            RightAuxPanelTabStrip.tabBackgroundColor(isActive: false, isHovered: true),
            equals: ToastyTheme.rightAuxPanelTabHoverBackground
        )
        try assertColor(
            RightAuxPanelTabStrip.tabBackgroundColor(isActive: false, isHovered: false),
            equals: ToastyTheme.chromeBackground
        )
    }

    func testRightPanelTabAccentLineIsThinnerThanWorkspaceTabAccent() {
        XCTAssertEqual(ToastyTheme.rightAuxPanelTabAccentLineHeight, 1)
        XCTAssertLessThan(
            ToastyTheme.rightAuxPanelTabAccentLineHeight,
            ToastyTheme.workspaceTabAccentLineHeight
        )
    }

    func testPanelCardSuppressesGenericHoverCloseInRightAuxPanel() {
        XCTAssertTrue(
            PanelCardView.showsHoveredCloseAffordance(
                appIsActive: true,
                isHovered: true,
                chromeContext: .mainSplit
            )
        )
        XCTAssertFalse(
            PanelCardView.showsHoveredCloseAffordance(
                appIsActive: true,
                isHovered: true,
                chromeContext: .rightAuxPanel
            )
        )
    }

    func testScratchpadBindCandidatesUseCurrentTabManagedSessionsOnly() {
        let workspaceID = UUID()
        let windowID = UUID()
        let currentPanelID = UUID()
        let destinationPanelID = UUID()
        let hiddenPanelID = UUID()
        let processWatchPanelID = UUID()
        let currentSlotID = UUID()
        let destinationSlotID = UUID()
        let tab = WorkspaceTabState(
            id: UUID(),
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: currentSlotID, panelID: currentPanelID),
                second: .slot(slotID: destinationSlotID, panelID: destinationPanelID)
            ),
            panels: [
                currentPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")),
                destinationPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/tmp")),
                hiddenPanelID: .terminal(TerminalPanelState(title: "Hidden", shell: "zsh", cwd: "/tmp")),
                processWatchPanelID: .terminal(TerminalPanelState(title: "Watch", shell: "zsh", cwd: "/tmp")),
            ],
            focusedPanelID: currentPanelID
        )
        var registry = SessionRegistry()
        registry.startSession(
            sessionID: "sess-current",
            agent: .codex,
            panelID: currentPanelID,
            windowID: windowID,
            workspaceID: workspaceID,
            displayTitleOverride: "Codex",
            cwd: "/tmp",
            repoRoot: "/tmp",
            at: Date(timeIntervalSince1970: 100)
        )
        registry.startSession(
            sessionID: "sess-destination",
            agent: .claude,
            panelID: destinationPanelID,
            windowID: windowID,
            workspaceID: workspaceID,
            displayTitleOverride: "Claude",
            cwd: "/tmp",
            repoRoot: "/tmp",
            at: Date(timeIntervalSince1970: 200)
        )
        registry.startSession(
            sessionID: "sess-hidden",
            agent: .pi,
            panelID: hiddenPanelID,
            windowID: windowID,
            workspaceID: workspaceID,
            displayTitleOverride: "Pi",
            cwd: "/tmp",
            repoRoot: "/tmp",
            at: Date(timeIntervalSince1970: 300)
        )
        registry.startSession(
            sessionID: "sess-watch",
            agent: .processWatch,
            panelID: processWatchPanelID,
            windowID: windowID,
            workspaceID: workspaceID,
            displayTitleOverride: "npm test",
            cwd: "/tmp",
            repoRoot: "/tmp",
            at: Date(timeIntervalSince1970: 400)
        )

        let candidates = ScratchpadAgentBindCandidateBuilder.candidates(
            workspaceTab: tab,
            sessionRegistry: registry,
            currentSessionID: "sess-current"
        )

        XCTAssertEqual(candidates.map(\.sessionID), ["sess-current", "sess-destination"])
        XCTAssertEqual(candidates[0].label, "Codex - current binding")
        XCTAssertEqual(candidates[1].label, "Claude - right split")
    }

    func testScratchpadActionsMenuSnapshotsCandidateAndDocumentPayloads() throws {
        let documentID = UUID()
        let current = ScratchpadAgentBindCandidate(
            sessionID: "sess-current",
            agent: .codex,
            panelID: UUID(),
            label: "Codex - current binding",
            isCurrent: true
        )
        let destination = ScratchpadAgentBindCandidate(
            sessionID: "sess-destination",
            agent: .claude,
            panelID: UUID(),
            label: "Claude - right split",
            isCurrent: false
        )

        let menu = ScratchpadActionsMenuBuilder.menu(
            documentID: documentID,
            candidates: [current, destination],
            target: nil,
            rebindAction: nil,
            exportAction: nil,
            openInBrowserAction: nil
        )

        let bindItem = menu.items[0]
        let bindSubmenu = try XCTUnwrap(bindItem.submenu)
        XCTAssertTrue(bindItem.isEnabled)
        XCTAssertEqual(bindSubmenu.items[0].state, .on)
        XCTAssertFalse(bindSubmenu.items[0].isEnabled)

        let destinationPayload = try XCTUnwrap(
            bindSubmenu.items[1].representedObject as? ScratchpadCandidateMenuPayload
        )
        XCTAssertEqual(destinationPayload.candidate, destination)

        let exportPayload = try XCTUnwrap(
            menu.items[2].representedObject as? ScratchpadDocumentMenuPayload
        )
        XCTAssertEqual(exportPayload.documentID, documentID)
        let openPayload = try XCTUnwrap(
            menu.items[3].representedObject as? ScratchpadDocumentMenuPayload
        )
        XCTAssertEqual(openPayload.documentID, documentID)
    }

    func testScratchpadActionsMenuDisablesBindWhenNoAlternativeCandidates() throws {
        let current = ScratchpadAgentBindCandidate(
            sessionID: "sess-current",
            agent: .codex,
            panelID: UUID(),
            label: "Codex - current binding",
            isCurrent: true
        )

        let menu = ScratchpadActionsMenuBuilder.menu(
            documentID: nil,
            candidates: [current],
            target: nil,
            rebindAction: nil,
            exportAction: nil,
            openInBrowserAction: nil
        )

        let bindItem = menu.items[0]
        let bindSubmenu = try XCTUnwrap(bindItem.submenu)
        XCTAssertFalse(bindItem.isEnabled)
        XCTAssertEqual(bindSubmenu.items.map(\.title), ["No other agents in this tab"])
        XCTAssertFalse(bindSubmenu.items[0].isEnabled)
        XCTAssertFalse(menu.items[2].isEnabled)
        XCTAssertNil(menu.items[2].representedObject)
        XCTAssertFalse(menu.items[3].isEnabled)
        XCTAssertNil(menu.items[3].representedObject)
    }
}

private func assertColor(
    _ actual: Color,
    equals expected: Color,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let actualColor = try XCTUnwrap(
        NSColor(actual).usingColorSpace(.deviceRGB),
        file: file,
        line: line
    )
    let expectedColor = try XCTUnwrap(
        NSColor(expected).usingColorSpace(.deviceRGB),
        file: file,
        line: line
    )

    XCTAssertEqual(actualColor.redComponent, expectedColor.redComponent, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(actualColor.greenComponent, expectedColor.greenComponent, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(actualColor.blueComponent, expectedColor.blueComponent, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(actualColor.alphaComponent, expectedColor.alphaComponent, accuracy: 0.001, file: file, line: line)
}
