import AppKit
import CoreState
import RemoteProtocol
import SwiftUI
import XCTest
@testable import ToasttyApp

/// Uses the production Home surface and Peek store. These tests must run in an
/// isolated GUI test host; build-for-testing alone is not viewport evidence.
@MainActor
final class CoordinatorPeekViewportTests: XCTestCase {
    private struct Terminal {
        let panelID: UUID
        let sessionID: String
        let nativeSessionID: String
        let tag: String
    }

    @MainActor
    private final class Fixture {
        let tasks: TaskCoordinatorTests.Fixture
        let service: ConversationService
        let board: TaskBoardStore
        let controller: CoordinatorHomeController
        let windowID: UUID
        let window: NSWindow
        let host: NSHostingView<CoordinatorHomeSurface>
        private var sequence = 0
        private var messageCounts: [UUID: Int] = [:]

        init() throws {
            tasks = try TaskCoordinatorTests.Fixture()
            windowID = try XCTUnwrap(tasks.store.state.windows.first?.id)
            let paths = ToasttyRuntimePaths.resolve(environment: [ToasttyRuntimePaths.environmentKey:
                tasks.root.appendingPathComponent("viewport-runtime").path])
            var configuration = CoordinatorSessionConfiguration()
            configuration.automaticWorkEnabled = false
            try CoordinatorSessionState(configuration: configuration).save(to:
                paths.configDirectoryURL.appendingPathComponent("coordinator-session.json"))
            let terminals = TerminalRuntimeRegistry(focusCoordinator: TerminalFocusCoordinator(), activateApp: {
                XCTFail("Viewport tests must not activate a terminal.")
            })
            service = ConversationService(store: tasks.store, sessionRuntimeStore: tasks.sessionRuntimeStore,
                terminalRuntimeRegistry: terminals, runtimePaths: paths)
            let prs = PullRequestStateCache(runner: TaskBoardTests.FakeGitHub())
            board = TaskBoardStore(coordinator: tasks.coordinator, store: tasks.store,
                sessionRuntimeStore: tasks.sessionRuntimeStore, pullRequests: prs,
                refreshInterval: nil, releaseCheckInterval: nil)
            controller = CoordinatorHomeController(store: tasks.store, launcher: tasks.launcher,
                sessionRuntimeStore: tasks.sessionRuntimeStore, runtimePaths: paths,
                service: service, tasks: tasks.coordinator, board: board, pullRequests: prs)
            host = NSHostingView(rootView: CoordinatorHomeSurface(windowID: windowID,
                store: tasks.store, board: board, sessionRuntimeStore: tasks.sessionRuntimeStore,
                controller: controller, peeks: controller.peeks))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
        }

        func shutdown() {
            window.orderOut(nil)
            window.contentView = nil
            service.setLocalPanelIDs([])
            tasks.sessionRuntimeStore.reset()
        }

        func terminal(_ tag: String, singleMessage: Bool = false) throws -> Terminal {
            let before = Set(tasks.store.state.workspacesByID.keys)
            XCTAssertTrue(tasks.store.send(.createWorkspace(windowID: windowID, title: tag, activate: false)))
            let workspace = try XCTUnwrap(tasks.store.state.workspacesByID.values.first { !before.contains($0.id) })
            let panel = try XCTUnwrap(workspace.focusedPanelID)
            let terminal = Terminal(panelID: panel, sessionID: UUID().uuidString, nativeSessionID: UUID().uuidString, tag: tag)
            tasks.sessionRuntimeStore.startSession(sessionID: terminal.sessionID, agent: .claude, panelID: panel,
                windowID: windowID, workspaceID: workspace.id, codexStatusTrackingSource: .externallyReported,
                cwd: tasks.projectRoot, repoRoot: nil, at: Date())
            let transcript = tasks.root.appendingPathComponent("viewport-\(terminal.nativeSessionID).jsonl")
            try Data().write(to: transcript)
            let resume = ManagedAgentResumeRecord(agent: .claude, nativeSessionID: terminal.nativeSessionID,
                sessionFilePath: transcript.path, cwd: tasks.projectRoot, capturedAt: Date())
            XCTAssertTrue(tasks.sessionRuntimeStore.confirmNativeSessionBinding(
                managedSessionID: terminal.sessionID, panelID: panel, record: resume))
            XCTAssertTrue(tasks.store.send(.updateTerminalPanelResumeRecord(panelID: panel, resumeRecord: resume)))
            XCTAssertTrue(tasks.sessionRuntimeStore.resetProviderConversationFeed(managedSessionID: terminal.sessionID,
                provider: .claude, nativeSessionID: terminal.nativeSessionID, snapshotID: terminal.sessionID, at: Date()))
            controller.peeks.openSession(terminal.sessionID, in: windowID)
            if singleMessage {
                try append(terminal, text: (0..<400).map { "\(tag) line \(String(format: "%03d", $0)) visible text" }.joined(separator: "\n"))
            } else {
                for item in 0..<80 { try append(terminal, text: "\(tag) message \(String(format: "%03d", item))\nSecond line of this message.") }
            }
            return terminal
        }

        func append(_ terminal: Terminal, text: String) throws {
            sequence += 1
            // The real service replays this runtime-owned feed after demand
            // removal. Navigation never reinjects or repairs the projection.
            XCTAssertTrue(tasks.sessionRuntimeStore.ingestProviderConversationObservation(
                managedSessionID: terminal.sessionID, provider: .claude, nativeSessionID: terminal.nativeSessionID,
                snapshotID: terminal.sessionID,
                observation: .init(timestamp: Date(), fingerprint: "viewport-\(sequence)",
                    payload: .transcript(.userMessage(.init(text: text))), mayAuthorizeCurrentRuntime: false)))
            messageCounts[terminal.panelID, default: 0] += 1
            service.syncConversations()
            controller.peeks.inspections[windowID]?.conversation?.refresh()
        }

        func show(_ terminal: Terminal) {
            controller.peeks.openSession(terminal.sessionID, in: windowID)
            let messages = controller.peeks.inspections[windowID]?.conversation?.events.filter {
                if case .userMessage = $0.payload { return true }; return false
            }
            XCTAssertEqual(messages?.count, messageCounts[terminal.panelID],
                "History must replay before checking viewport retention.")
        }
    }

    private struct Position {
        let offset: CGFloat
        let visibleText: String
        let glyphY: CGFloat
    }

    private func settle(_ host: NSView, duration: TimeInterval = 0.35) {
        let until = Date().addingTimeInterval(duration)
        while Date() < until {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func textViews(_ root: NSView) -> [NSTextView] {
        (root as? NSTextView).map { [$0] } ?? root.subviews.flatMap(textViews)
    }

    private func scrollView(_ fixture: Fixture, tag: String, root: NSView? = nil) throws -> NSScrollView {
        try XCTUnwrap(textViews(root ?? fixture.host).first { $0.string.hasPrefix(tag) }?.enclosingScrollView)
    }

    private func scroll(_ fixture: Fixture, tag: String, fraction: CGFloat) throws {
        let scroll = try scrollView(fixture, tag: tag)
        let document = try XCTUnwrap(scroll.documentView)
        let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
        XCTAssertGreaterThan(maximum, 1500, "The rendered fixture must be much longer than its viewport.")
        // Send the same intent notifications as an AppKit live scroll, then
        // move the real clip view. No product scheduler is changed for tests.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum * fraction))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        settle(fixture.host)
    }

    private func position(_ fixture: Fixture, tag: String, root: NSView? = nil) throws -> Position {
        let scroll = try scrollView(fixture, tag: tag, root: root)
        let clip = scroll.contentView
        let candidates = textViews(root ?? fixture.host).filter {
            $0.string.hasPrefix(tag) && $0.enclosingScrollView === scroll &&
                $0.convert($0.bounds, to: clip).intersects(clip.bounds)
        }.sorted { $0.convert($0.bounds, to: clip).minY < $1.convert($1.bounds, to: clip).minY }
        let text = try XCTUnwrap(candidates.first, "No rendered message intersects the actual clip viewport.")
        let layout = try XCTUnwrap(text.layoutManager)
        let container = try XCTUnwrap(text.textContainer)
        let visible = text.convert(clip.bounds, from: clip).intersection(text.bounds)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        XCTAssertGreaterThan(glyphs.length, 0)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let content = text.string as NSString
        let line = content.lineRange(for: NSRange(location: min(characters.location, max(0, content.length - 1)), length: 0))
        let lineGlyphs = layout.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
        let lineRect = layout.boundingRect(forGlyphRange: lineGlyphs, in: container)
        let lineY = text.convert(lineRect, to: clip).minY - clip.bounds.minY
        return Position(offset: clip.bounds.minY, visibleText: content.substring(with: line), glyphY: lineY)
    }

    private func assertPosition(_ expected: Position, _ fixture: Fixture, tag: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try position(fixture, tag: tag)
        XCTAssertEqual(actual.offset, expected.offset, accuracy: 4, "Actual clip offset", file: file, line: line)
        XCTAssertEqual(actual.visibleText, expected.visibleText, "Rendered visible line", file: file, line: line)
        XCTAssertEqual(actual.glyphY, expected.glyphY, accuracy: 4, "Rendered line position within viewport", file: file, line: line)
    }

    func testActualHomeSwitchesEmptyDraftPeeksAndRetainsBothViewports() throws {
        let f = try Fixture(); defer { f.shutdown() }
        let a = try f.terminal("VIEWPORT-A")
        let b = try f.terminal("VIEWPORT-B")
        f.show(a); settle(f.host)
        try scroll(f, tag: a.tag, fraction: 0.31)
        let first = try position(f, tag: a.tag)
        weak var oldModel = f.controller.peeks.inspections[f.windowID]?.conversation
        XCTAssertEqual(oldModel?.draft, "")
        f.show(b); settle(f.host)
        XCTAssertNil(oldModel, "An empty draft must not retain its model merely to retain the viewport.")
        try scroll(f, tag: b.tag, fraction: 0.63)
        let second = try position(f, tag: b.tag)
        f.show(a); settle(f.host)
        try assertPosition(first, f, tag: a.tag)
        f.show(b); settle(f.host)
        try assertPosition(second, f, tag: b.tag)
        f.controller.peeks.close(in: f.windowID); settle(f.host)
        f.show(a); settle(f.host)
        try assertPosition(first, f, tag: a.tag)
        try appendAndCheckOffBottom(f, terminal: a, expected: first)
        try scroll(f, tag: a.tag, fraction: 1)
        try f.append(a, text: "VIEWPORT-A new tail\n" + String(repeating: "More tail text\n", count: 15))
        settle(f.host)
        let scroll = try scrollView(f, tag: a.tag)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertLessThanOrEqual(document.bounds.maxY - scroll.contentView.bounds.maxY, 32)
    }

    private func appendAndCheckOffBottom(_ fixture: Fixture, terminal: Terminal, expected: Position) throws {
        try fixture.append(terminal, text: "\(terminal.tag) appended while reading earlier text")
        settle(fixture.host)
        try assertPosition(expected, fixture, tag: terminal.tag)
    }

    func testActualHomeRestoresPositionWithinSingleLongMessage() throws {
        let f = try Fixture(); defer { f.shutdown() }
        let a = try f.terminal("LONG-A", singleMessage: true)
        let b = try f.terminal("LONG-B", singleMessage: true)
        f.show(a); settle(f.host)
        try scroll(f, tag: a.tag, fraction: 0.27)
        let first = try position(f, tag: a.tag)
        XCTAssertFalse(first.visibleText.contains("line 000"))
        f.show(b); settle(f.host)
        try scroll(f, tag: b.tag, fraction: 0.69)
        let second = try position(f, tag: b.tag)
        f.show(a); settle(f.host)
        try assertPosition(first, f, tag: a.tag)
        f.show(b); settle(f.host)
        try assertPosition(second, f, tag: b.tag)
        f.controller.peeks.close(in: f.windowID); settle(f.host)
        f.show(a); settle(f.host)
        try assertPosition(first, f, tag: a.tag)
        try appendAndCheckOffBottom(f, terminal: a, expected: first)
    }
    func testSameConversationHasIndependentViewportsInTwoHomeWindows() throws {
        let f = try Fixture(); defer { f.shutdown() }
        let a = try f.terminal("WINDOW-A", singleMessage: true)
        let b = try f.terminal("WINDOW-B", singleMessage: true)
        f.show(a); settle(f.host)
        try scroll(f, tag: a.tag, fraction: 0.22)
        let first = try position(f, tag: a.tag)
        let before = Set(f.tasks.store.state.windows.map(\.id))
        XCTAssertTrue(f.tasks.store.send(.createWindow(seed: nil, initialFrame: nil)))
        let otherID = try XCTUnwrap(f.tasks.store.state.windows.first { !before.contains($0.id) }?.id)
        let otherHost = NSHostingView(rootView: CoordinatorHomeSurface(windowID: otherID,
            store: f.tasks.store, board: f.board, sessionRuntimeStore: f.tasks.sessionRuntimeStore,
            controller: f.controller, peeks: f.controller.peeks))
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        otherWindow.contentView = otherHost
        otherWindow.orderFront(nil)
        defer { otherWindow.orderOut(nil); otherWindow.contentView = nil }
        f.controller.peeks.openSession(a.sessionID, in: otherID)
        settle(otherHost)
        let scroll = try scrollView(f, tag: a.tag, root: otherHost)
        let document = try XCTUnwrap(scroll.documentView)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: (document.bounds.height - scroll.contentView.bounds.height) * 0.71))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        settle(otherHost)
        let other = try position(f, tag: a.tag, root: otherHost)
        XCTAssertNotEqual(first.visibleText, other.visibleText)
        f.show(b); settle(f.host)
        f.show(a); settle(f.host)
        try assertPosition(first, f, tag: a.tag)
        let unchanged = try position(f, tag: a.tag, root: otherHost)
        XCTAssertEqual(unchanged.offset, other.offset, accuracy: 4)
        XCTAssertEqual(unchanged.visibleText, other.visibleText)
        f.controller.peeks.close(in: otherID); settle(otherHost)
        f.controller.peeks.openSession(a.sessionID, in: otherID); settle(otherHost)
        let reopened = try position(f, tag: a.tag, root: otherHost)
        XCTAssertEqual(reopened.offset, other.offset, accuracy: 4)
        XCTAssertEqual(reopened.visibleText, other.visibleText)
        XCTAssertEqual(reopened.glyphY, other.glyphY, accuracy: 4)
    }

    func testExternalClipScrollWinsOverAppendAndDeferredWorkFromReplacedPeek() throws {
        let f = try Fixture(); defer { f.shutdown() }
        let a = try f.terminal("DEFERRED-A", singleMessage: true)
        let b = try f.terminal("DEFERRED-B", singleMessage: true)
        f.show(a); settle(f.host)
        let scroll = try scrollView(f, tag: a.tag)
        let document = try XCTUnwrap(scroll.documentView)
        let maximum = document.bounds.height - scroll.contentView.bounds.height
        XCTAssertGreaterThan(maximum, 1500)
        XCTAssertLessThanOrEqual(maximum - scroll.contentView.bounds.minY, 32)
        // Selection/autoscroll and accessibility can move the clip without
        // live-scroll notifications. Do not drain queued work before append.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum * 0.37))
        scroll.reflectScrolledClipView(scroll.contentView)
        let expected = try position(f, tag: a.tag)
        XCTAssertGreaterThan(expected.offset, 100)
        XCTAssertLessThan(expected.offset, maximum - 100)
        try f.append(a, text: "DEFERRED-A appended during navigation")
        f.host.layoutSubtreeIfNeeded()
        f.show(b); settle(f.host, duration: 0.02)
        f.show(a); settle(f.host)
        try assertPosition(expected, f, tag: a.tag)
        // The replaced view's queued work must not later push this mount down.
        settle(f.host)
        try assertPosition(expected, f, tag: a.tag)
    }

}
