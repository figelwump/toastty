@testable import ToasttyApp
import AppKit
import CoreState
import SwiftUI
import XCTest

@MainActor
final class SidebarViewTests: XCTestCase {
    func testAbbreviatedPathLabelKeepsOnlyLastPathComponent() {
        XCTAssertEqual(SidebarView.abbreviatedPathLabel("/Users/vishal/GiantThings/repos/toastty-session-status"), ".../toastty-session-status")
        XCTAssertEqual(SidebarView.abbreviatedPathLabel("/"), "/")
        XCTAssertEqual(SidebarView.abbreviatedPathLabel("relative"), "relative")
    }

    func testUnreadSessionOutlineOnlyShowsForUnreadAttentionStates() {
        XCTAssertNil(
            SidebarView.unreadSessionOutlineKind(
                for: SessionStatus(kind: .idle, summary: "Idle"),
                showsUnreadSessionAccent: true
            )
        )
        XCTAssertNil(
            SidebarView.unreadSessionOutlineKind(
                for: SessionStatus(kind: .working, summary: "Working"),
                showsUnreadSessionAccent: true
            )
        )
        XCTAssertNil(
            SidebarView.unreadSessionOutlineKind(
                for: SessionStatus(kind: .ready, summary: "Ready"),
                showsUnreadSessionAccent: false
            )
        )
        XCTAssertEqual(
            SidebarView.unreadSessionOutlineKind(
                for: SessionStatus(kind: .needsApproval, summary: "Needs approval"),
                showsUnreadSessionAccent: true
            ),
            .needsApproval
        )
        XCTAssertEqual(
            SidebarView.unreadSessionOutlineKind(
                for: SessionStatus(kind: .ready, summary: "Ready"),
                showsUnreadSessionAccent: true
            ),
            .ready
        )
        XCTAssertEqual(
            SidebarView.unreadSessionOutlineKind(
                for: SessionStatus(kind: .error, summary: "Error"),
                showsUnreadSessionAccent: true
            ),
            .error
        )
    }

    func testSessionIndicatorStateShowsSpinnerOnlyForWorking() {
        XCTAssertEqual(SidebarView.sessionIndicatorState(for: .working), .spinner)
        XCTAssertEqual(SidebarView.sessionIndicatorState(for: .idle), .hidden)
        XCTAssertEqual(SidebarView.sessionIndicatorState(for: .needsApproval), .hidden)
        XCTAssertEqual(SidebarView.sessionIndicatorState(for: .ready), .hidden)
        XCTAssertEqual(SidebarView.sessionIndicatorState(for: .error), .hidden)
    }

    func testBackgroundTabSessionPanelRemainsFocusable() throws {
        let backgroundTab = WorkspaceTabState.bootstrap(terminalTitle: "Background Agent")
        let selectedTab = WorkspaceTabState.bootstrap(terminalTitle: "Foreground Terminal")
        let panelID = try XCTUnwrap(backgroundTab.focusedPanelID)
        let workspace = WorkspaceState(
            id: UUID(),
            title: "One",
            selectedTabID: selectedTab.id,
            tabIDs: [backgroundTab.id, selectedTab.id],
            tabsByID: [
                backgroundTab.id: backgroundTab,
                selectedTab.id: selectedTab,
            ]
        )

        XCTAssertTrue(SidebarView.canFocusSessionPanel(panelID, in: workspace))
    }

    func testUnreadSessionAccentUsesPanelTabUnreadStateAcrossTabs() throws {
        var backgroundTab = WorkspaceTabState.bootstrap(terminalTitle: "Background Agent")
        let selectedTab = WorkspaceTabState.bootstrap(terminalTitle: "Foreground Terminal")
        let backgroundPanelID = try XCTUnwrap(backgroundTab.focusedPanelID)
        let selectedPanelID = try XCTUnwrap(selectedTab.focusedPanelID)
        backgroundTab.unreadPanelIDs = [backgroundPanelID]
        let workspaceID = UUID()
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "One",
            selectedTabID: selectedTab.id,
            tabIDs: [backgroundTab.id, selectedTab.id],
            tabsByID: [
                backgroundTab.id: backgroundTab,
                selectedTab.id: selectedTab,
            ]
        )

        XCTAssertTrue(
            SidebarView.showsUnreadSessionAccent(
                for: backgroundPanelID,
                in: workspace,
                selectedWorkspaceID: workspaceID,
                selectedPanelID: selectedPanelID
            )
        )
    }

    func testUnreadSessionAccentSuppressesFocusedPanelInSelectedWorkspace() throws {
        var selectedTab = WorkspaceTabState.bootstrap(terminalTitle: "Foreground Terminal")
        let selectedPanelID = try XCTUnwrap(selectedTab.focusedPanelID)
        selectedTab.unreadPanelIDs = [selectedPanelID]
        let workspaceID = UUID()
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "One",
            selectedTabID: selectedTab.id,
            tabIDs: [selectedTab.id],
            tabsByID: [selectedTab.id: selectedTab]
        )

        XCTAssertFalse(
            SidebarView.showsUnreadSessionAccent(
                for: selectedPanelID,
                in: workspace,
                selectedWorkspaceID: workspaceID,
                selectedPanelID: selectedPanelID
            )
        )
    }

    func testReadySessionDoesNotRenderStatusChipLabel() throws {
        let hostingView = try makeSidebarHostingView(
            sessionID: "sess-ready",
            sessionStatus: SessionStatus(kind: .ready, summary: "Ready", detail: "Completed response")
        )

        let textValues = renderedTextValues(in: hostingView)
        XCTAssertFalse(
            textValues.contains("ready"),
            "Sidebar text values should not include a ready chip label: \(textValues)"
        )
    }

    func testWorkingSessionDoesNotRenderStatusChipLabel() throws {
        let hostingView = try makeSidebarHostingView(
            sessionID: "sess-working",
            sessionStatus: SessionStatus(kind: .working, summary: "Working", detail: "Streaming changes")
        )

        let textValues = renderedTextValues(in: hostingView)
        XCTAssertFalse(
            textValues.contains("working"),
            "Sidebar text values should not include a working chip label: \(textValues)"
        )
        XCTAssertFalse(textValues.contains("ready"))
        XCTAssertFalse(textValues.contains("needs approval"))
        XCTAssertFalse(textValues.contains("error"))
    }

    func testReadySessionOutlineColorUsesWarmTeal() throws {
        let outlineColor = try XCTUnwrap(
            NSColor(ToastyTheme.sessionStatusOutlineColor(for: .ready)).usingColorSpace(.deviceRGB)
        )
        let expectedColor = try XCTUnwrap(
            NSColor(ToastyTheme.sessionReadyText).usingColorSpace(.deviceRGB)
        )

        XCTAssertEqual(outlineColor.redComponent, expectedColor.redComponent, accuracy: 0.001)
        XCTAssertEqual(outlineColor.greenComponent, expectedColor.greenComponent, accuracy: 0.001)
        XCTAssertEqual(outlineColor.blueComponent, expectedColor.blueComponent, accuracy: 0.001)
        XCTAssertEqual(outlineColor.alphaComponent, expectedColor.alphaComponent, accuracy: 0.001)
    }

    func testUnreadAndAttentionStatusAccentsShareWarmTeal() throws {
        let expectedColor = try XCTUnwrap(
            NSColor(Color(hex: 0x5BA08A)).usingColorSpace(.deviceRGB)
        )

        for color in [
            ToastyTheme.badgeBlue,
            ToastyTheme.sessionNeedsApprovalText,
            ToastyTheme.sessionReadyText,
            ToastyTheme.sessionErrorText,
        ] {
            let resolvedColor = try XCTUnwrap(NSColor(color).usingColorSpace(.deviceRGB))
            XCTAssertEqual(resolvedColor.redComponent, expectedColor.redComponent, accuracy: 0.001)
            XCTAssertEqual(resolvedColor.greenComponent, expectedColor.greenComponent, accuracy: 0.001)
            XCTAssertEqual(resolvedColor.blueComponent, expectedColor.blueComponent, accuracy: 0.001)
            XCTAssertEqual(resolvedColor.alphaComponent, expectedColor.alphaComponent, accuracy: 0.001)
        }
    }

    func testBusySubtitleUpdatesWhenRuntimeRegistryPublishesChange() throws {
        let state = AppState.bootstrap()
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let workspaceID = try XCTUnwrap(state.windows.first?.workspaceIDs.first)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        let runtimeContext = TerminalWindowRuntimeContext(windowID: windowID, runtimeRegistry: registry)
        let sidebarView = SidebarView(
            windowID: windowID,
            store: store,
            terminalRuntimeRegistry: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeContext: runtimeContext
        )
        let hostingView = NSHostingView(rootView: sidebarView.frame(width: ToastyTheme.sidebarWidth))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: ToastyTheme.sidebarWidth, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertFalse(
            renderedTextValues(in: hostingView).contains(where: { $0.contains("1 pane · 1 busy") })
        )

        registry.setWorkspaceActivitySubtext([workspaceID: "1 busy"])
        pumpMainRunLoop()
        hostingView.layoutSubtreeIfNeeded()

        let textValues = renderedTextValues(in: hostingView)
        XCTAssertTrue(
            textValues.contains(where: { $0.contains("1 pane · 1 busy") }),
            "Sidebar text values after runtime update: \(textValues)"
        )
    }

    private func pumpMainRunLoop() {
        let expectation = expectation(description: "Flush SwiftUI update")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    private func makeSidebarHostingView(
        sessionID: String,
        sessionStatus: SessionStatus
    ) throws -> NSView {
        let state = AppState.bootstrap()
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let workspaceID = try XCTUnwrap(state.windows.first?.workspaceIDs.first)
        let workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
        let panelID = try XCTUnwrap(workspace.focusedPanelID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        let runtimeContext = TerminalWindowRuntimeContext(windowID: windowID, runtimeRegistry: registry)
        sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspaceID,
            cwd: "/repo/sidebar",
            repoRoot: "/repo",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        sessionRuntimeStore.updateStatus(
            sessionID: sessionID,
            status: sessionStatus,
            at: Date(timeIntervalSince1970: 1_700_000_001)
        )

        let sidebarView = SidebarView(
            windowID: windowID,
            store: store,
            terminalRuntimeRegistry: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeContext: runtimeContext
        )
        let hostingView = NSHostingView(rootView: sidebarView.frame(width: ToastyTheme.sidebarWidth))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: ToastyTheme.sidebarWidth, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        pumpMainRunLoop()
        hostingView.layoutSubtreeIfNeeded()
        return hostingView
    }

    private func renderedTextValues(in rootView: NSView) -> [String] {
        let subviewValues = recursiveSubviewTextValues(in: rootView)
        let accessibilityValues = recursiveAccessibilityTextValues(in: rootView)
        return Array(Set(subviewValues + accessibilityValues)).sorted()
    }

    private func recursiveSubviewTextValues(in view: NSView) -> [String] {
        var values: [String] = []
        if let textField = view as? NSTextField {
            let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty == false {
                values.append(trimmed)
            }
        }

        for subview in view.subviews {
            values.append(contentsOf: recursiveSubviewTextValues(in: subview))
        }

        return values
    }

    private func recursiveAccessibilityTextValues(in object: AnyObject) -> [String] {
        var values: [String] = []

        for selectorName in ["accessibilityLabel", "accessibilityValue"] {
            let selector = NSSelectorFromString(selectorName)
            guard object.responds(to: selector),
                  let result = object.perform(selector)?.takeUnretainedValue() else {
                continue
            }

            if let string = result as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false {
                    values.append(trimmed)
                }
            }
        }

        let childrenSelector = NSSelectorFromString("accessibilityChildren")
        if object.responds(to: childrenSelector),
           let children = object.perform(childrenSelector)?.takeUnretainedValue() as? [AnyObject] {
            for child in children {
                values.append(contentsOf: recursiveAccessibilityTextValues(in: child))
            }
        }

        return values
    }
}
