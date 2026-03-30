@testable import ToasttyApp
import AppKit
import CoreState
import SwiftUI
import XCTest

final class WorkspaceViewTests: XCTestCase {
    @MainActor
    private struct WorkspaceHarness {
        let windowID: UUID
        let workspaceID: UUID
        let panelID: UUID
        let store: AppStore
        let hostingView: NSView
        let window: NSWindow
    }

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

    func testWorkspaceTabManagementAffordancesStayEnabledForVisibleTabs() {
        XCTAssertFalse(WorkspaceView.workspaceTabManagementAffordancesEnabled(tabCount: 0))
        XCTAssertTrue(WorkspaceView.workspaceTabManagementAffordancesEnabled(tabCount: 1))
        XCTAssertTrue(WorkspaceView.workspaceTabManagementAffordancesEnabled(tabCount: 2))
    }

    func testSingleTabWorkspaceStillInstallsTabContextMenu() {
        XCTAssertFalse(WorkspaceView.workspaceTabInstallsContextMenu(tabCount: 0))
        XCTAssertTrue(WorkspaceView.workspaceTabInstallsContextMenu(tabCount: 1))
        XCTAssertTrue(WorkspaceView.workspaceTabInstallsContextMenu(tabCount: 2))
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
            104
        )
    }

    func testResolvedWorkspaceTabWidthStopsAtConfiguredMinimumWidth() {
        XCTAssertEqual(
            WorkspaceView.resolvedWorkspaceTabWidth(availableWidth: 140, tabCount: 5),
            ToastyTheme.workspaceTabMinimumWidth
        )
    }

    func testResolvedWorkspaceTitleWidthUsesIntrinsicWidthWhenItFits() {
        XCTAssertEqual(
            WorkspaceView.resolvedWorkspaceTitleWidth(
                preferredWidth: 120,
                availableWidth: 900,
                trailingWidth: 240,
                tabCount: 3
            ),
            120
        )
    }

    func testResolvedWorkspaceTitleWidthShrinksOnlyAfterTabsReachMinimumWidth() {
        XCTAssertEqual(
            WorkspaceView.resolvedWorkspaceTitleWidth(
                preferredWidth: 320,
                availableWidth: 580,
                trailingWidth: 200,
                tabCount: 3
            ),
            206
        )
    }

    func testWorkspaceTabIdealTotalWidthRemovesInterTabGap() {
        XCTAssertEqual(
            WorkspaceView.workspaceTabIdealTotalWidth(tabCount: 2),
            ToastyTheme.workspaceTabWidth * 2
        )
    }

    func testWorkspaceHeaderTitleOriginYAlignsToTitlebarToggleBaseline() {
        let titleHeight: CGFloat = 16
        XCTAssertEqual(
            WorkspaceView.workspaceHeaderTitleOriginY(
                boundsHeight: ToastyTheme.topBarHeight,
                titleHeight: titleHeight
            ),
            ToastyTheme.titlebarSidebarToggleTopPadding +
                ((ToastyTheme.titlebarSidebarToggleButtonSize - titleHeight) / 2)
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
        XCTAssertNil(spec.borderColor)
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
        let borderColor = try XCTUnwrap(spec.borderColor)
        try assertColor(borderColor, equals: ToastyTheme.subtleBorder)
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
        XCTAssertNil(spec.borderColor)
    }

    func testWorkspaceTabChromeSpecUnselectedStateUsesSubtleOutline() throws {
        let spec = WorkspaceView.workspaceTabChromeSpec(
            isSelected: false,
            isHovered: false,
            isRenaming: false,
            appIsActive: true
        )

        try assertColor(spec.background, equals: .clear)
        try assertColor(spec.text, equals: ToastyTheme.workspaceTabUnselectedText)
        XCTAssertNil(spec.accentColor)
        let borderColor = try XCTUnwrap(spec.borderColor)
        try assertColor(borderColor, equals: ToastyTheme.subtleBorder)
    }

    func testWorkspaceTabChromeSpecHoveredUnselectedKeepsOutline() throws {
        let spec = WorkspaceView.workspaceTabChromeSpec(
            isSelected: false,
            isHovered: true,
            isRenaming: false,
            appIsActive: true
        )

        try assertColor(spec.background, equals: ToastyTheme.workspaceTabHoverBackground)
        try assertColor(spec.text, equals: ToastyTheme.workspaceTabHoverText)
        XCTAssertNil(spec.accentColor)
        let borderColor = try XCTUnwrap(spec.borderColor)
        try assertColor(borderColor, equals: ToastyTheme.subtleBorder)
    }

    func testWorkspaceTabUnreadDotUsesLargerDiameter() {
        XCTAssertEqual(ToastyTheme.workspaceTabUnreadDotDiameter, 7)
    }

    @MainActor
    func testPendingPanelFlashRequestPulsesAndClearsSelectedTerminalPanel() throws {
        let harness = try makeWorkspaceHarness()
        pumpMainRunLoop(duration: 0.2)
        harness.hostingView.layoutSubtreeIfNeeded()
        let baselineBitmap = try renderedBitmap(for: harness.hostingView)
        let sampledRegion = stableTerminalCornerRegion(in: baselineBitmap)

        harness.store.pendingPanelFlashRequest = PendingPanelFlashRequest(
            requestID: UUID(),
            windowID: harness.windowID,
            workspaceID: harness.workspaceID,
            panelID: harness.panelID
        )
        pumpMainRunLoop(duration: 0.12)
        harness.hostingView.layoutSubtreeIfNeeded()
        let peakBitmap = try renderedBitmap(for: harness.hostingView)

        pumpMainRunLoop(duration: 0.5)
        harness.hostingView.layoutSubtreeIfNeeded()
        let settledBitmap = try renderedBitmap(for: harness.hostingView)

        XCTAssertNil(harness.store.pendingPanelFlashRequest)
        XCTAssertGreaterThan(
            try differingPixelCount(
                in: sampledRegion,
                between: baselineBitmap,
                and: peakBitmap
            ),
            0,
            "Expected the terminal panel to visibly pulse when an explicit navigation flash request is handled"
        )
        XCTAssertEqual(
            try differingPixelCount(
                in: sampledRegion,
                between: baselineBitmap,
                and: settledBitmap
            ),
            0,
            "Expected the terminal panel pulse to settle back to its baseline appearance"
        )

        harness.window.orderOut(nil)
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

    @MainActor
    private func makeWorkspaceHarness() throws -> WorkspaceHarness {
        let state = AppState.bootstrap()
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
        let panelID = try XCTUnwrap(workspace.focusedPanelID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)
        registry.synchronize(with: store.state)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let tempHomeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempHomeDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let agentCatalogStore = AgentCatalogStore(homeDirectoryPath: tempHomeDirectory.path)
        let terminalProfileStore = TerminalProfileStore(
            homeDirectoryPath: tempHomeDirectory.path,
            environment: [:]
        )
        let agentLaunchService = AgentLaunchService(
            store: store,
            terminalCommandRouter: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogStore
        )
        let workspaceView = WorkspaceView(
            windowID: windowID,
            store: store,
            agentCatalogStore: agentCatalogStore,
            terminalProfileStore: terminalProfileStore,
            terminalRuntimeRegistry: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            profileShortcutRegistry: makeProfileShortcutRegistry(agentProfiles: .empty),
            agentLaunchService: agentLaunchService,
            openAgentProfilesConfiguration: {},
            terminalRuntimeContext: TerminalWindowRuntimeContext(
                windowID: windowID,
                runtimeRegistry: registry
            ),
            sidebarVisible: true
        )
        let hostingView = NSHostingView(rootView: workspaceView.frame(width: 900, height: 600))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        pumpMainRunLoop()
        hostingView.layoutSubtreeIfNeeded()
        return WorkspaceHarness(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            store: store,
            hostingView: hostingView,
            window: window
        )
    }

    @MainActor
    private func pumpMainRunLoop(duration: TimeInterval = 0) {
        let expectation = expectation(description: "Flush SwiftUI update")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        guard duration > 0 else { return }
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    @MainActor
    private func renderedBitmap(for view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }

    @MainActor
    private func differingPixelCount(
        between lhs: NSBitmapImageRep,
        and rhs: NSBitmapImageRep
    ) throws -> Int {
        try differingPixelCount(
            in: NSRect(x: 0, y: 0, width: lhs.pixelsWide, height: lhs.pixelsHigh),
            between: lhs,
            and: rhs
        )
    }

    @MainActor
    private func stableTerminalCornerRegion(in bitmap: NSBitmapImageRep) -> NSRect {
        let insetX = CGFloat(max(32, bitmap.pixelsWide / 7))
        let insetY = CGFloat(max(32, bitmap.pixelsHigh / 7))
        let regionWidth = CGFloat(max(48, bitmap.pixelsWide / 10))
        let regionHeight = CGFloat(max(48, bitmap.pixelsHigh / 10))

        return NSRect(
            x: CGFloat(bitmap.pixelsWide) - insetX - regionWidth,
            y: insetY,
            width: regionWidth,
            height: regionHeight
        )
    }

    @MainActor
    private func differingPixelCount(
        in region: NSRect,
        between lhs: NSBitmapImageRep,
        and rhs: NSBitmapImageRep
    ) throws -> Int {
        XCTAssertEqual(lhs.pixelsWide, rhs.pixelsWide)
        XCTAssertEqual(lhs.pixelsHigh, rhs.pixelsHigh)

        let lhsData = try XCTUnwrap(lhs.bitmapData)
        let rhsData = try XCTUnwrap(rhs.bitmapData)
        let bytesPerPixel = max(1, lhs.bitsPerPixel / 8)
        XCTAssertEqual(lhs.bytesPerRow * lhs.pixelsHigh, rhs.bytesPerRow * rhs.pixelsHigh)

        let minX = max(0, min(lhs.pixelsWide - 1, Int(region.minX.rounded(.down))))
        let maxX = max(minX + 1, min(lhs.pixelsWide, Int(region.maxX.rounded(.up))))
        let minY = max(0, min(lhs.pixelsHigh - 1, Int(region.minY.rounded(.down))))
        let maxY = max(minY + 1, min(lhs.pixelsHigh, Int(region.maxY.rounded(.up))))

        var differenceCount = 0
        for y in minY..<maxY {
            let rowOffset = y * lhs.bytesPerRow
            for x in minX..<maxX {
                let pixelOffset = rowOffset + (x * bytesPerPixel)
                for byteOffset in 0..<bytesPerPixel where lhsData[pixelOffset + byteOffset] != rhsData[pixelOffset + byteOffset] {
                    differenceCount += 1
                    break
                }
            }
        }

        return differenceCount
    }
}
