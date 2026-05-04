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

    func testScratchpadBindingMenuEntriesIncludeCandidatesAndUnbind() {
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

        let entries = ScratchpadBindingMenuEntry.entries(
            candidates: [current, destination],
            isBound: true
        )

        XCTAssertEqual(entries, [
            .candidate(current),
            .candidate(destination),
            .separator,
            .unbind,
        ])
    }

    func testScratchpadBindingMenuEntriesShowNoActiveSessionsFallback() {
        XCTAssertEqual(
            ScratchpadBindingMenuEntry.entries(candidates: [], isBound: false),
            [.noActiveSessions("No active sessions in this tab")]
        )
        XCTAssertEqual(
            ScratchpadBindingMenuEntry.entries(candidates: [], isBound: true),
            [
                .noActiveSessions("No active sessions in this tab"),
                .separator,
                .unbind,
            ]
        )
    }

    func testScratchpadBindingMenuBuilderMarksCurrentCandidateAndUnbindAction() throws {
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

        let menu = ScratchpadBindingMenuBuilder.menu(
            entries: [
                .candidate(current),
                .candidate(destination),
                .separator,
                .unbind,
            ],
            target: self,
            candidateAction: #selector(scratchpadBindingCandidateAction(_:)),
            unbindAction: #selector(scratchpadBindingUnbindAction(_:))
        )

        XCTAssertEqual(menu.items.map(\.title), [
            "Codex - current binding",
            "Claude - right split",
            "",
            "Unbind",
        ])
        XCTAssertEqual(menu.items[0].state, .on)
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertNil(menu.items[0].action)
        let currentPayload = try XCTUnwrap(
            menu.items[0].representedObject as? ScratchpadBindingCandidateMenuPayload
        )
        XCTAssertEqual(currentPayload.candidate, current)

        XCTAssertEqual(menu.items[1].state, .off)
        XCTAssertTrue(menu.items[1].isEnabled)
        XCTAssertEqual(menu.items[1].action, #selector(scratchpadBindingCandidateAction(_:)))
        let destinationPayload = try XCTUnwrap(
            menu.items[1].representedObject as? ScratchpadBindingCandidateMenuPayload
        )
        XCTAssertEqual(destinationPayload.candidate, destination)

        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertEqual(menu.items[3].action, #selector(scratchpadBindingUnbindAction(_:)))
    }

    func testScratchpadBindingMenuBuilderDisablesNoActiveSessionsFallback() {
        let menu = ScratchpadBindingMenuBuilder.menu(
            entries: [.noActiveSessions("No active sessions in this tab")],
            target: self,
            candidateAction: #selector(scratchpadBindingCandidateAction(_:)),
            unbindAction: #selector(scratchpadBindingUnbindAction(_:))
        )

        XCTAssertEqual(menu.items.map(\.title), ["No active sessions in this tab"])
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertNil(menu.items[0].action)
    }

    @MainActor
    func testScratchpadBindingMenuControlRoutesInputToMenuAction() throws {
        let control = ScratchpadBindingMenuControl(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        let recorder = ScratchpadBindingMenuControlActionRecorder()
        control.target = recorder
        control.action = #selector(ScratchpadBindingMenuControlActionRecorder.recordAction(_:))
        control.update(bindingLabel: "Bound to Codex", help: "Change Scratchpad Binding")

        XCTAssertTrue(control.acceptsFirstResponder)
        XCTAssertTrue(control.becomeFirstResponder())
        XCTAssertTrue(control.resignFirstResponder())

        control.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 8, y: 8),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )))
        control.keyDown(with: try XCTUnwrap(Self.keyDownEvent(characters: " ", keyCode: 49)))
        control.keyDown(with: try XCTUnwrap(Self.keyDownEvent(characters: "\r", keyCode: 36)))
        XCTAssertTrue(control.accessibilityPerformPress())

        XCTAssertEqual(recorder.invocationCount, 4)
    }

    @MainActor
    func testScratchpadBindingMenuControlKeepsHitTestingAndAccessibilityOnControl() {
        let control = ScratchpadBindingMenuControl(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        control.setAccessibilityLabel("Scratchpad Binding")
        control.setAccessibilityIdentifier("panel.header.scratchpad.binding")
        control.update(bindingLabel: "Bound to Codex", help: "Change Scratchpad Binding")

        XCTAssertTrue(control.hitTest(NSPoint(x: 8, y: 8)) === control)
        XCTAssertNil(control.hitTest(NSPoint(x: -1, y: 8)))
        XCTAssertEqual(control.toolTip, "Change Scratchpad Binding")
        XCTAssertEqual(control.accessibilityLabel(), "Scratchpad Binding")
        XCTAssertEqual(control.accessibilityIdentifier(), "panel.header.scratchpad.binding")
        XCTAssertEqual(control.accessibilityValue() as? String, "Bound to Codex")
        XCTAssertEqual(control.accessibilityHelp(), "Change Scratchpad Binding")
    }

    @MainActor
    func testScratchpadBindingMenuControlFitsShortLabelAndCapsLongLabel() {
        let control = ScratchpadBindingMenuControl(frame: .zero)
        control.update(bindingLabel: "Unbound", help: "Bind Scratchpad to a Session")
        let shortWidth = control.intrinsicContentSize.width

        control.update(
            bindingLabel: "Bound to Extremely Verbose Agent Session Name That Should Truncate",
            help: "Change Scratchpad Binding"
        )
        let longWidth = control.intrinsicContentSize.width

        XCTAssertLessThan(shortWidth, 120)
        XCTAssertLessThanOrEqual(longWidth, 180)
        XCTAssertGreaterThan(longWidth, shortWidth)
    }

    func testScratchpadActionsMenuContainsDocumentActionsOnly() throws {
        let documentID = UUID()

        let menu = ScratchpadActionsMenuBuilder.menu(
            documentID: documentID,
            target: nil,
            exportAction: nil,
            openInBrowserAction: nil
        )

        XCTAssertEqual(menu.items.map(\.title), ["Export to File...", "Open in Browser"])
        XCTAssertTrue(menu.items.allSatisfy { $0.submenu == nil })

        let exportPayload = try XCTUnwrap(
            menu.items[0].representedObject as? ScratchpadDocumentMenuPayload
        )
        XCTAssertEqual(exportPayload.documentID, documentID)
        let openPayload = try XCTUnwrap(
            menu.items[1].representedObject as? ScratchpadDocumentMenuPayload
        )
        XCTAssertEqual(openPayload.documentID, documentID)
    }

    func testScratchpadActionsMenuDisablesDocumentActionsWithoutDocumentID() {
        let menu = ScratchpadActionsMenuBuilder.menu(
            documentID: nil,
            target: nil,
            exportAction: nil,
            openInBrowserAction: nil
        )

        XCTAssertEqual(menu.items.map(\.title), ["Export to File...", "Open in Browser"])
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertNil(menu.items[0].representedObject)
        XCTAssertFalse(menu.items[1].isEnabled)
        XCTAssertNil(menu.items[1].representedObject)
    }

    @objc private func scratchpadBindingCandidateAction(_ sender: NSMenuItem) {}

    @objc private func scratchpadBindingUnbindAction(_ sender: NSMenuItem) {}

    private static func keyDownEvent(characters: String, keyCode: UInt16) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}

private final class ScratchpadBindingMenuControlActionRecorder: NSObject {
    var invocationCount = 0

    @objc func recordAction(_ sender: Any) {
        invocationCount += 1
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
