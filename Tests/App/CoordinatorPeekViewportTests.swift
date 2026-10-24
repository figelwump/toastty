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
        }

        func expectedMessageCount(for terminal: Terminal) -> Int { messageCounts[terminal.panelID, default: 0] }

        var surface: Surface { Surface(windowID: windowID, window: window, root: host) }
    }

    private struct Surface {
        let windowID: UUID
        let window: NSWindow
        let root: NSView
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

    private func scrollViews(_ root: NSView) -> [NSScrollView] {
        let own = (root as? NSScrollView).map { [$0] } ?? []
        return own + root.subviews.flatMap(scrollViews)
    }

    private func historyIsReady(_ fixture: Fixture, terminal: Terminal, surface: Surface) -> Bool {
        guard let inspection = fixture.controller.peeks.inspections[surface.windowID],
              inspection.panelID == terminal.panelID, inspection.unavailableReason == nil,
              let model = inspection.conversation, let snapshot = model.snapshot else { return false }
        let count = model.events.filter { if case .userMessage = $0.payload { return true }; return false }.count
        return count == fixture.expectedMessageCount(for: terminal)
            && (model.events.last?.sequence ?? 0) >= snapshot.summary.latestSequence
    }

    private func attachedScrollViews(_ matching: [NSTextView], surface: Surface) -> [NSScrollView] {
        var seen: Set<ObjectIdentifier> = []
        return matching.compactMap { text in
            guard text.window === surface.window, !text.isHiddenOrHasHiddenAncestor,
                  let scroll = text.enclosingScrollView, scroll.window === surface.window,
                  !scroll.isHiddenOrHasHiddenAncestor, seen.insert(ObjectIdentifier(scroll)).inserted else { return nil }
            return scroll
        }
    }

    private func hasGeometry(_ scroll: NSScrollView, surface: Surface) -> Bool {
        guard let document = scroll.documentView else { return false }
        return document.window === surface.window && document.bounds.width > 0 && document.bounds.height > 0
            && scroll.contentView.bounds.width > 0 && scroll.contentView.bounds.height > 0
    }

    private func failureContext(_ fixture: Fixture, terminal: Terminal, surface: Surface, stage: String) -> String {
        let inspection = fixture.controller.peeks.inspections[surface.windowID]
        let model = inspection?.conversation
        let currentCount = model?.events.filter { if case .userMessage = $0.payload { return true }; return false }.count
        let matching = textViews(surface.root).filter { $0.string.hasPrefix(terminal.tag) }
        let attached = attachedScrollViews(matching, surface: surface)
        let available = scrollViews(surface.root)
        let inspected = attached + available.filter { candidate in !attached.contains { $0 === candidate } }
        let bounds = inspected.prefix(4).enumerated().map { index, scroll in
            "scroll[\(index)] window=\(scroll.window?.windowNumber.description ?? "nil") hidden=\(scroll.isHiddenOrHasHiddenAncestor) clip=\(scroll.contentView.bounds) document=\(scroll.documentView.map { String(describing: $0.bounds) } ?? "nil")"
        }.joined(separator: "; ")
        let textBounds = matching.prefix(3).map {
            "text window=\($0.window?.windowNumber.description ?? "nil") bounds=\($0.bounds) hidden=\($0.isHiddenOrHasHiddenAncestor) hasEnclosingScroll=\($0.enclosingScrollView != nil)"
        }.joined(separator: "; ")
        return """
        stage=\(stage) expectedWindow=\(surface.windowID) expectedPanel=\(terminal.panelID) tag=\(terminal.tag)
        inspectionPanel=\(inspection?.panelID?.uuidString ?? "nil") unavailable=\(String((inspection?.unavailableReason ?? "none").prefix(240)))
        history=\(currentCount.map(String.init) ?? "nil")/\(fixture.expectedMessageCount(for: terminal)) sequence=\(model?.events.last?.sequence.description ?? "nil")/\(model?.snapshot?.summary.latestSequence.description ?? "nil")
        matchingText=\(matching.count) attachedMatchingScrolls=\(attached.count) availableScrolls=\(available.count)
        expectedNativeWindow=\(surface.window.windowNumber) windowVisible=\(surface.window.isVisible) hostWindow=\(surface.root.window?.windowNumber.description ?? "nil") contentViewMatches=\(surface.window.contentView === surface.root) windowFrame=\(surface.window.frame) hostBounds=\(surface.root.bounds)
        \(textBounds)
        \(bounds)
        """
    }

    private func scrollView(_ fixture: Fixture, terminal: Terminal, surface requestedSurface: Surface? = nil,
                            stage: String, waitForReadiness: Bool = true,
                            file: StaticString = #filePath, line: UInt = #line) throws -> NSScrollView {
        let surface = requestedSurface ?? fixture.surface
        // Readiness never depends on an offset, an expected retained position,
        // or which line is visible. A wrong-but-rendered viewport is ready.
        let deadline = ProcessInfo.processInfo.systemUptime + (waitForReadiness ? 2 : 0)
        while true {
            let matching = textViews(surface.root).filter { $0.string.hasPrefix(terminal.tag) }
            let attached = attachedScrollViews(matching, surface: surface)
            if historyIsReady(fixture, terminal: terminal, surface: surface),
               surface.root.window === surface.window, surface.window.contentView === surface.root,
               surface.root.bounds.width > 0, surface.root.bounds.height > 0,
               attached.count == 1, let scroll = attached.first, hasGeometry(scroll, surface: surface),
               matching.contains(where: { $0.enclosingScrollView === scroll && $0.window === surface.window
                   && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 && $0.bounds.height > 0 }) {
                return scroll
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            surface.root.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let context = failureContext(fixture, terminal: terminal, surface: surface, stage: stage)
        let matching = textViews(surface.root).filter { $0.string.hasPrefix(terminal.tag) }
        // Keep missing text distinct from text that has no enclosing scroll.
        _ = try XCTUnwrap(matching.first, "No matching NSTextView. \(context)", file: file, line: line)
        _ = try XCTUnwrap(matching.compactMap(\.enclosingScrollView).first,
            "Matching NSTextView has no enclosing NSScrollView. \(context)", file: file, line: line)
        return try XCTUnwrap(nil as NSScrollView?,
            "Viewport readiness did not complete (\(waitForReadiness ? "2-second bound" : "immediate sample")). \(context)",
            file: file, line: line)
    }

    private func scroll(_ fixture: Fixture, terminal: Terminal, fraction: CGFloat, stage: String,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let scroll = try scrollView(fixture, terminal: terminal, stage: stage, file: file, line: line)
        let document = try XCTUnwrap(scroll.documentView, file: file, line: line)
        let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
        XCTAssertGreaterThan(maximum, 1500, "The rendered fixture must be much longer than its viewport.", file: file, line: line)
        // Send the same intent notifications as an AppKit live scroll, then
        // move the real clip view. No product scheduler is changed for tests.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum * fraction))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        settle(fixture.host)
    }

    private func position(_ fixture: Fixture, terminal: Terminal, surface requestedSurface: Surface? = nil,
                          stage: String, waitForReadiness: Bool = true,
                          file: StaticString = #filePath, line: UInt = #line) throws -> Position {
        let surface = requestedSurface ?? fixture.surface
        let scroll = try scrollView(fixture, terminal: terminal, surface: surface, stage: stage,
            waitForReadiness: waitForReadiness, file: file, line: line)
        let context = failureContext(fixture, terminal: terminal, surface: surface, stage: stage)
        let clip = scroll.contentView
        let candidates = textViews(surface.root).filter {
            $0.string.hasPrefix(terminal.tag) && $0.enclosingScrollView === scroll &&
                !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.bounds, to: clip).intersects(clip.bounds)
        }.sorted { $0.convert($0.bounds, to: clip).minY < $1.convert($1.bounds, to: clip).minY }
        let text = try XCTUnwrap(candidates.first, "No rendered message intersects the actual clip viewport. \(context)", file: file, line: line)
        let layout = try XCTUnwrap(text.layoutManager, "Visible text has no layout manager. \(context)", file: file, line: line)
        let container = try XCTUnwrap(text.textContainer, "Visible text has no text container. \(context)", file: file, line: line)
        let visible = text.convert(clip.bounds, from: clip).intersection(text.bounds)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        XCTAssertGreaterThan(glyphs.length, 0, "No visible glyphs. \(context)", file: file, line: line)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let content = text.string as NSString
        let textLine = content.lineRange(for: NSRange(location: min(characters.location, max(0, content.length - 1)), length: 0))
        let lineGlyphs = layout.glyphRange(forCharacterRange: textLine, actualCharacterRange: nil)
        let lineRect = layout.boundingRect(forGlyphRange: lineGlyphs, in: container)
        let lineY = text.convert(lineRect, to: clip).minY - clip.bounds.minY
        return Position(offset: clip.bounds.minY, visibleText: content.substring(with: textLine), glyphY: lineY)
    }

    private func assertPosition(_ expected: Position, _ fixture: Fixture, terminal: Terminal, stage: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try position(fixture, terminal: terminal, stage: stage, file: file, line: line)
        XCTAssertEqual(actual.offset, expected.offset, accuracy: 4, "Actual clip offset (\(stage))", file: file, line: line)
        XCTAssertEqual(actual.visibleText, expected.visibleText, "Rendered visible line (\(stage))", file: file, line: line)
        XCTAssertEqual(actual.glyphY, expected.glyphY, accuracy: 4, "Rendered line position within viewport (\(stage))", file: file, line: line)
    }

    func testActualHomeSwitchesEmptyDraftPeeksAndRetainsBothViewports() throws {
        let f = try Fixture(); defer { f.shutdown() }
        let a = try f.terminal("VIEWPORT-A")
        let b = try f.terminal("VIEWPORT-B")
        f.show(a); settle(f.host)
        try scroll(f, terminal: a, fraction: 0.31, stage: "A choose off-bottom position")
        let first = try position(f, terminal: a, stage: "A initial reading position")
        let originalInspection = try XCTUnwrap(f.controller.peeks.inspections[f.windowID])
        XCTAssertEqual(originalInspection.panelID, a.panelID)
        let oldModel = try XCTUnwrap(originalInspection.conversation)
        XCTAssertEqual(oldModel.draft, "")
        f.show(b); settle(f.host)
        try scroll(f, terminal: b, fraction: 0.63, stage: "B choose off-bottom position")
        let second = try position(f, terminal: b, stage: "B initial reading position")
        f.show(a); settle(f.host)
        _ = try scrollView(f, terminal: a, stage: "A reopened model identity")
        let reopenedInspection = try XCTUnwrap(f.controller.peeks.inspections[f.windowID])
        XCTAssertEqual(reopenedInspection.panelID, a.panelID)
        let reopenedModel = try XCTUnwrap(reopenedInspection.conversation)
        XCTAssertFalse(reopenedModel === oldModel, "Reopening an empty-draft Peek must use a new model.")
        try assertPosition(first, f, terminal: a, stage: "A after switching back")
        f.show(b); settle(f.host)
        try assertPosition(second, f, terminal: b, stage: "B after switching back")
        f.controller.peeks.close(in: f.windowID); settle(f.host)
        f.show(a); settle(f.host)
        try assertPosition(first, f, terminal: a, stage: "A after close and reopen")
        try appendAndCheckOffBottom(f, terminal: a, expected: first)
        try scroll(f, terminal: a, fraction: 1, stage: "A move to bottom")
        try f.append(a, text: "VIEWPORT-A new tail\n" + String(repeating: "More tail text\n", count: 15))
        settle(f.host)
        let scroll = try scrollView(f, terminal: a, stage: "A bottom viewport")
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertLessThanOrEqual(document.bounds.maxY - scroll.contentView.bounds.maxY, 32)
    }

    private func appendAndCheckOffBottom(_ fixture: Fixture, terminal: Terminal, expected: Position,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        try fixture.append(terminal, text: "\(terminal.tag) appended while reading earlier text")
        settle(fixture.host)
        try assertPosition(expected, fixture, terminal: terminal, stage: "after off-bottom append",
            file: file, line: line)
    }

    func testActualHomeRestoresPositionWithinSingleLongMessage() throws {
        let f = try Fixture(); defer { f.shutdown() }
        let a = try f.terminal("LONG-A", singleMessage: true)
        let b = try f.terminal("LONG-B", singleMessage: true)
        f.show(a); settle(f.host)
        try scroll(f, terminal: a, fraction: 0.27, stage: "A choose off-bottom position")
        let first = try position(f, terminal: a, stage: "A initial reading position")
        XCTAssertFalse(first.visibleText.contains("line 000"))
        f.show(b); settle(f.host)
        try scroll(f, terminal: b, fraction: 0.69, stage: "B choose off-bottom position")
        let second = try position(f, terminal: b, stage: "B initial reading position")
        f.show(a); settle(f.host)
        try assertPosition(first, f, terminal: a, stage: "A after switching back")
        f.show(b); settle(f.host)
        try assertPosition(second, f, terminal: b, stage: "B after switching back")
        f.controller.peeks.close(in: f.windowID); settle(f.host)
        f.show(a); settle(f.host)
        try assertPosition(first, f, terminal: a, stage: "A after close and reopen")
        try appendAndCheckOffBottom(f, terminal: a, expected: first)
    }
    func testSameConversationHasIndependentViewportsInTwoHomeWindows() throws {
        let f = try Fixture(); defer { f.shutdown() }
        let a = try f.terminal("WINDOW-A", singleMessage: true)
        let b = try f.terminal("WINDOW-B", singleMessage: true)
        f.show(a); settle(f.host)
        try scroll(f, terminal: a, fraction: 0.22, stage: "A choose off-bottom position")
        let first = try position(f, terminal: a, stage: "A initial reading position")
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
        let otherSurface = Surface(windowID: otherID, window: otherWindow, root: otherHost)
        defer { otherWindow.orderOut(nil); otherWindow.contentView = nil }
        f.controller.peeks.openSession(a.sessionID, in: otherID)
        settle(otherHost)
        let scroll = try scrollView(f, terminal: a, surface: otherSurface, stage: "second window initial viewport")
        let document = try XCTUnwrap(scroll.documentView)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: (document.bounds.height - scroll.contentView.bounds.height) * 0.71))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        settle(otherHost)
        let other = try position(f, terminal: a, surface: otherSurface, stage: "second window initial reading position")
        XCTAssertNotEqual(first.visibleText, other.visibleText)
        f.show(b); settle(f.host)
        f.show(a); settle(f.host)
        try assertPosition(first, f, terminal: a, stage: "A after switching back")
        let unchanged = try position(f, terminal: a, surface: otherSurface, stage: "second window after first-window switches")
        XCTAssertEqual(unchanged.offset, other.offset, accuracy: 4)
        XCTAssertEqual(unchanged.visibleText, other.visibleText)
        f.controller.peeks.close(in: otherID); settle(otherHost)
        f.controller.peeks.openSession(a.sessionID, in: otherID); settle(otherHost)
        let reopened = try position(f, terminal: a, surface: otherSurface, stage: "second window after close and reopen")
        XCTAssertEqual(reopened.offset, other.offset, accuracy: 4)
        XCTAssertEqual(reopened.visibleText, other.visibleText)
        XCTAssertEqual(reopened.glyphY, other.glyphY, accuracy: 4)
    }

    func testExternalClipScrollWinsOverAppendAndDeferredWorkFromReplacedPeek() throws {
        let f = try Fixture(); defer { f.shutdown() }
        let a = try f.terminal("DEFERRED-A", singleMessage: true)
        let b = try f.terminal("DEFERRED-B", singleMessage: true)
        f.show(a); settle(f.host)
        let scroll = try scrollView(f, terminal: a, stage: "A bottom viewport")
        let document = try XCTUnwrap(scroll.documentView)
        let maximum = document.bounds.height - scroll.contentView.bounds.height
        XCTAssertGreaterThan(maximum, 1500)
        XCTAssertLessThanOrEqual(maximum - scroll.contentView.bounds.minY, 32)
        // Selection/autoscroll and accessibility can move the clip without
        // live-scroll notifications. Do not drain queued work before append.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum * 0.37))
        scroll.reflectScrolledClipView(scroll.contentView)
        let expected = try position(f, terminal: a, stage: "A immediate position before append", waitForReadiness: false)
        XCTAssertGreaterThan(expected.offset, 100)
        XCTAssertLessThan(expected.offset, maximum - 100)
        try f.append(a, text: "DEFERRED-A appended during navigation")
        f.host.layoutSubtreeIfNeeded()
        f.show(b); settle(f.host, duration: 0.02)
        f.show(a); settle(f.host)
        try assertPosition(expected, f, terminal: a, stage: "A after switching back")
        // The replaced view's queued work must not later push this mount down.
        settle(f.host)
        try assertPosition(expected, f, terminal: a, stage: "A after deferred work drains")
    }

}
