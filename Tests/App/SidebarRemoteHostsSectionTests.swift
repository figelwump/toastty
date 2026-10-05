import AppKit
import CoreState
import SwiftUI
import XCTest
@testable import ToasttyApp
import ToasttyMobileDomain

/// Hosts the real sidebar with a remote-hosts context and drives it with
/// mouse events. The remote test host has no accessibility tree, so the
/// assertions read the rows' `SidebarSemanticTextBridge` text.
///
/// Set `REMOTE_HOSTS_EVIDENCE_DIR` to also write PNG captures of each step
/// (`env TEST_RUNNER_REMOTE_HOSTS_EVIDENCE_DIR=<dir> xcodebuild test …`).
@MainActor
final class SidebarRemoteHostsSectionTests: XCTestCase {
    private static let studio = RemoteHostConfiguration(
        id: "studio",
        displayName: "Studio",
        gatewayURL: URL(string: "https://studio.example-tailnet.ts.net")!,
        sshDestination: "studio"
    )
    private static let lab = RemoteHostConfiguration(
        id: "lab",
        displayName: "Lab",
        gatewayURL: URL(string: "https://lab.example-tailnet.ts.net")!,
        sshDestination: "lab"
    )

    func testRemoteGroupsListSessionsAndAClickOpensAnAttachedTerminal() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let registry = TerminalRuntimeRegistry()
        // Mini is paired and reachable, Studio is not paired, and Lab is
        // paired but its gateway cannot be reached.
        let hostsStore = RemoteHostsFixtures.makeStore(
            configurations: [RemoteHostsFixtures.mini, Self.studio, Self.lab],
            pairedRemoteIDs: ["mini", "lab"],
            gateway: { gatewayURL in
                gatewayURL == Self.lab.gatewayURL
                    ? RemoteHostsFakeGateway(helloFailure: .network(reason: .cannotConnect))
                    : RemoteHostsFakeGateway()
            }
        )
        hostsStore.reload()
        try await waitUntil {
            hostsStore.host(id: "mini")?.status == .live
                && hostsStore.host(id: "studio")?.status == .notPaired
                && hostsStore.host(id: "lab")?.status == .reconnecting
        }
        let opener = RemoteHostTerminalOpener(
            store: store,
            terminalRuntimeRegistry: registry,
            hostsStore: hostsStore,
            homeDirectoryPath: "/tmp"
        )

        let sidebarWidth: CGFloat = 300
        let sidebar = SidebarView(
            windowID: windowID,
            store: store,
            terminalRuntimeRegistry: registry,
            sessionRuntimeStore: SessionRuntimeStore(),
            annotationStyleStore: makeTestAnnotationStyleStore(),
            terminalRuntimeContext: TerminalWindowRuntimeContext(windowID: windowID, runtimeRegistry: registry)
        )
        .environment(\.remoteHostsSidebarContext, RemoteHostsSidebarContext(hostsStore: hostsStore, opener: opener))
        .frame(width: sidebarWidth, height: 640)
        .background(ToastyTheme.chromeBackground)
        let hostingView = NSHostingView(rootView: sidebar)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: sidebarWidth, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        // SwiftUI buttons ignore clicks in a window that is not on screen.
        // The window stays far outside every display.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.close() }
        pumpMainRunLoop(duration: 0.3)

        let texts = semanticTexts(in: hostingView)
        XCTAssertTrue(texts.contains("Remote Mini, connected, 3 sessions"), "\(texts)")
        XCTAssertTrue(texts.contains("Remote Studio, not paired, 0 sessions"), "\(texts)")
        XCTAssertTrue(texts.contains("Remote Lab, reconnecting, 0 sessions"), "\(texts)")
        let attachableLabel = "Remote session Fix sidebar hover, Claude Code, approval, opens a terminal"
        let plainLabel = "Remote session Started from phone, Claude Code, working, no terminal to attach to"
        XCTAssertTrue(texts.contains(attachableLabel), "\(texts)")
        XCTAssertTrue(texts.contains(plainLabel), "\(texts)")
        writeEvidence(of: hostingView, named: "1-remote-groups")

        // A session without a terminal explains itself and opens nothing.
        try click(semanticText: plainLabel, in: hostingView, window: window)
        pumpMainRunLoop(duration: 0.3)
        XCTAssertEqual(store.state.windows.first?.workspaceIDs.count, 1)
        XCTAssertTrue(
            semanticTexts(in: hostingView).contains { $0.contains("remoteAttachCommand") },
            "\(semanticTexts(in: hostingView))"
        )
        writeEvidence(of: hostingView, named: "2-session-without-terminal")

        // An attachable session opens a tab, in a workspace named after the
        // remote, whose terminal runs the attach command.
        try click(semanticText: attachableLabel, in: hostingView, window: window)
        pumpMainRunLoop(duration: 0.3)
        let window0 = try XCTUnwrap(store.state.windows.first)
        XCTAssertEqual(window0.workspaceIDs.count, 2)
        let remoteWorkspace = try XCTUnwrap(store.state.workspacesByID[try XCTUnwrap(window0.workspaceIDs.last)])
        XCTAssertEqual(remoteWorkspace.title, "Mini")
        XCTAssertEqual(window0.selectedWorkspaceID, remoteWorkspace.id)
        let panelID = try XCTUnwrap(remoteWorkspace.tab(id: try XCTUnwrap(remoteWorkspace.tabIDs.first))?.panels.keys.first)
        XCTAssertEqual(
            registry.pendingInitialInput(forPanelID: panelID),
            "\"$TOASTTY_CLI_PATH\" remote attach mini \(RemoteHostsFixtures.attachableID.uuidString)"
        )
        XCTAssertFalse(semanticTexts(in: hostingView).contains { $0.contains("remoteAttachCommand") })
        writeEvidence(of: hostingView, named: "3-after-open")
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while condition() == false {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting for the remote hosts to settle")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func pumpMainRunLoop(duration: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    private func semanticBridges(in view: NSView) -> [NSTextField] {
        var result: [NSTextField] = []
        if let field = view as? NSTextField, field.isHidden {
            result.append(field)
        }
        for subview in view.subviews {
            result.append(contentsOf: semanticBridges(in: subview))
        }
        return result
    }

    private func semanticTexts(in view: NSView) -> [String] {
        semanticBridges(in: view).map(\.stringValue)
    }

    /// Sends a real click at the row's bridge, which sits at the row center.
    private func click(semanticText: String, in view: NSView, window: NSWindow) throws {
        let bridge = try XCTUnwrap(semanticBridges(in: view).first { $0.stringValue == semanticText })
        let location = bridge.convert(NSPoint(x: bridge.bounds.midX, y: bridge.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ))
            window.sendEvent(event)
            // SwiftUI resolves the press on a later run-loop pass.
            pumpMainRunLoop(duration: 0.05)
        }
    }

    private func writeEvidence(of view: NSView, named name: String) {
        guard let directory = ProcessInfo.processInfo.environment["REMOTE_HOSTS_EVIDENCE_DIR"],
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: directoryURL.appendingPathComponent("\(name).png"))
    }
}
