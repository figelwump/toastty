import AppKit
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
