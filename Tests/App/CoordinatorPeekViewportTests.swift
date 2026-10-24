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
        // Full messages are unique in this fixture, including messages with a repeated second line.
        let fullMessage: String
        let lineRange: NSRange
        let visibleText: String
        let glyphY: CGFloat
    }

    // BEGIN viewport timeline diagnostic
    private struct TimelineView: Encodable {
        let identity: String
        let window: String?
        let frame: [Double]
        let bounds: [Double]
    }

    private struct TimelineGeometry: Encodable {
        let surfaceID: UUID
        let window: String?
        let windowNumber: Int?
        let windowFrame: [Double]?
        let surface: TimelineView?
        let scroll: TimelineView?
        let clip: TimelineView?
        let document: TimelineView?
        let currentClip: String?
        let currentDocument: String?
        let clipPostsBounds: Bool?
        let clipPostsFrame: Bool?
        let documentPostsFrame: Bool?
    }

    private struct TimelinePosition: Encodable {
        let offset: Double
        let messagePrefix: String
        let messageUTF16Length: Int
        let lineRange: [Int]
        let visibleText: String
        let glyphY: Double

        init(_ value: Position) {
            offset = Double(value.offset)
            messagePrefix = String(value.fullMessage.prefix(80))
            messageUTF16Length = (value.fullMessage as NSString).length
            lineRange = [value.lineRange.location, value.lineRange.length]
            visibleText = String(value.visibleText.prefix(160))
            glyphY = Double(value.glyphY)
        }
    }

    // BEGIN typed viewport snapshot diagnostic
    #if DEBUG
    private enum StateMapping: String, Encodable {
        case notDiscovered = "not-discovered", selected, matched, absent, ambiguous
        case discoveryCapped = "discovery-capped", discoveryFailed = "discovery-failed"
        case replacedOrUnattached = "replaced-or-unattached", replacedOrDeallocated = "replaced-or-deallocated"
    }
    private struct TimelineState: Encodable {
        let mapping: StateMapping
        let candidateCount: Int
        let selectedMarker: String?
        let selectedSession: String?
        let state: NativeConversationViewportSession.DiagnosticSnapshot?
    }

    #endif
    // END typed viewport snapshot diagnostic
    private struct TimelineRecord: Encodable {
        let elapsed: Double
        let stage: String
        let event: String
        let insideTestScrollAndReflect: Bool
        let geometry: TimelineGeometry?
        // BEGIN typed viewport snapshot diagnostic
        #if DEBUG
        var restoration: TimelineState?
        #endif
        // END typed viewport snapshot diagnostic
        var maximum: Double?
        var targetY: Double?
        var fraction: Double?
        var requestBasis: String?
        var expected: TimelinePosition?
        var actual: TimelinePosition?
        var sameFullMessage: Bool?
        var textIdentities: [String]?
        var textCount: Int?
        var notificationObject: String?
        var screenVisibleFrame: [Double]?
        var contentBounds: [Double]?
        var backingScale: Double?
    }

    @MainActor
    private final class Timeline {
        @MainActor
        private final class Scope {
            let id: UUID
            let wasObserved: Bool
            weak var window: NSWindow?
            weak var surface: NSView?
            weak var scroll: NSScrollView?
            weak var clip: NSClipView?
            weak var document: NSView?
            // BEGIN typed viewport snapshot diagnostic
            #if DEBUG
            weak var marker: NativeConversationViewportMarkerView?
            weak var session: NativeConversationViewportSession?
            var mapping: StateMapping = .notDiscovered
            var candidateCount = 0
            #endif
            // END typed viewport snapshot diagnostic
            var tokens: [NSObjectProtocol] = []

            init(_ surface: Surface, scroll: NSScrollView? = nil) {
                id = surface.windowID
                wasObserved = scroll != nil
                window = surface.window
                self.surface = surface.root
                self.scroll = scroll
                clip = scroll?.contentView
                document = scroll?.documentView
            }

            func removeObservers() {
                tokens.forEach(NotificationCenter.default.removeObserver)
                tokens.removeAll()
            }
        }

        let method: String
        let continueAfterFailure: Bool
        private let start = ProcessInfo.processInfo.systemUptime
        private let encoder = JSONEncoder()
        private var records: [Data] = []
        private var encodedBytes = 0
        private var scopes: [UUID: Scope] = [:]
        private var currentScope: Scope?
        private var stage = "setup"
        private var stopped = false
        private var emitted = false
        private var stoppedBeforeBodyEnd = false
        private(set) var bodyReachedEnd = false
        private var fixtureCount = 0
        private var recordLimitReached = false
        private var byteLimitReached = false
        private var encodingFailed = false
        private var missingViews = false
        private var notificationsDisabled = false
        private var replacementGap = false
        private var identityListCapped = false
        // BEGIN typed viewport snapshot diagnostic
        #if DEBUG
        private final class WeakMarker {
            weak var value: NativeConversationViewportMarkerView?
            init(_ value: NativeConversationViewportMarkerView) { self.value = value }
        }
        private var collectingMarkers = false
        private var markers: [WeakMarker] = []
        private var markerListCapped = false
        private var stateMappingInconclusive = false

        func beginMarkerDiscovery() {
            markers.removeAll(); markerListCapped = false; collectingMarkers = !stopped
        }
        func endMarkerDiscovery() { collectingMarkers = false }
        func visit(_ view: NSView) {
            guard collectingMarkers, let marker = view as? NativeConversationViewportMarkerView else { return }
            guard markers.count < 128 else { markerListCapped = true; return }
            markers.append(WeakMarker(marker))
        }
        private func bindState(_ scope: Scope) {
            scope.marker = nil; scope.session = nil; scope.candidateCount = 0
            guard let window = scope.window, let scroll = scope.scroll else {
                scope.mapping = .replacedOrDeallocated; markers.removeAll(); return
            }
            let candidates = markers.compactMap(\.value).filter {
                $0.window === window && $0.enclosingScrollView === scroll
            }
            scope.candidateCount = candidates.count
            if markerListCapped { scope.mapping = .discoveryCapped }
            else if candidates.isEmpty { scope.mapping = .absent }
            else if candidates.count != 1 { scope.mapping = .ambiguous }
            else if let marker = candidates.first {
                scope.marker = marker; scope.session = marker.session; scope.mapping = .selected
            }
            markers.removeAll()
        }
        private func state(_ scope: Scope?) -> TimelineState {
            guard let scope, scope.wasObserved else {
                return TimelineState(mapping: .notDiscovered, candidateCount: 0,
                    selectedMarker: nil, selectedSession: nil, state: nil)
            }
            var mapping = scope.mapping
            var snapshot: NativeConversationViewportSession.DiagnosticSnapshot?
            if mapping == .selected {
                if let marker = scope.marker, let session = scope.session,
                   let window = scope.window, let scroll = scope.scroll,
                   marker.window === window, marker.enclosingScrollView === scroll,
                   marker.session === session {
                    let value = session.diagnosticSnapshot()
                    // Retain mismatched sampled values, but do not claim a current mapping.
                    mapping = value.marker == Self.identity(marker) && value.scroll == Self.identity(scroll)
                        && value.window == Self.identity(window) && scope.clip === scroll.contentView
                        && scope.document === scroll.documentView ? .matched : .replacedOrUnattached
                    snapshot = value
                } else { mapping = .replacedOrDeallocated }
            }
            if mapping != .matched { stateMappingInconclusive = true }
            return TimelineState(mapping: mapping, candidateCount: scope.candidateCount,
                selectedMarker: Self.identity(scope.marker), selectedSession: Self.identity(scope.session), state: snapshot)
        }
        #endif
        // END typed viewport snapshot diagnostic
        var insideTestScrollAndReflect = false

        init(method: String, continueAfterFailure: Bool) {
            self.method = method
            self.continueAfterFailure = continueAfterFailure
            mark("method-begin")
        }

        private static func identity(_ object: AnyObject?) -> String? {
            object.map { String(describing: ObjectIdentifier($0)) }
        }

        private static func rect(_ value: NSRect) -> [Double] {
            [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)]
        }

        private static func view(_ value: NSView?) -> TimelineView? {
            value.map { TimelineView(identity: identity($0)!, window: identity($0.window),
                frame: rect($0.frame), bounds: rect($0.bounds)) }
        }

        private func record(_ event: String, scope: Scope? = nil) -> TimelineRecord {
            let scope = scope ?? currentScope
            let geometry = scope.map { scope in
                if scope.window == nil || scope.surface == nil { missingViews = true }
                if scope.wasObserved && (scope.scroll == nil || scope.clip == nil || scope.document == nil) { missingViews = true }
                if scope.scroll != nil && (scope.clip !== scope.scroll?.contentView || scope.document !== scope.scroll?.documentView) {
                    replacementGap = true
                }
                return TimelineGeometry(surfaceID: scope.id, window: Self.identity(scope.window),
                    windowNumber: scope.window?.windowNumber, windowFrame: scope.window.map { Self.rect($0.frame) },
                    surface: Self.view(scope.surface), scroll: Self.view(scope.scroll), clip: Self.view(scope.clip),
                    document: Self.view(scope.document), currentClip: Self.identity(scope.scroll?.contentView),
                    currentDocument: Self.identity(scope.scroll?.documentView),
                    clipPostsBounds: scope.clip?.postsBoundsChangedNotifications,
                    clipPostsFrame: scope.clip?.postsFrameChangedNotifications,
                    documentPostsFrame: scope.document?.postsFrameChangedNotifications)
            }
            var result = TimelineRecord(elapsed: ProcessInfo.processInfo.systemUptime - start, stage: stage,
                event: event, insideTestScrollAndReflect: insideTestScrollAndReflect, geometry: geometry)
            // BEGIN typed viewport snapshot diagnostic
            #if DEBUG
            result.restoration = state(scope)
            #endif
            // END typed viewport snapshot diagnostic
            return result
        }

        private func append(_ value: TimelineRecord) {
            guard !stopped else { return }
            guard records.count < 512 else { recordLimitReached = true; stop(); return }
            guard let data = try? encoder.encode(value) else { encodingFailed = true; stop(); return }
            // Reserve 16 KiB for the fixed header and JSON framing.
            guard encodedBytes + data.count + 1 <= 245760 else { byteLimitReached = true; stop(); return }
            encodedBytes += data.count + 1
            records.append(data)
        }

        func begin(_ value: String, surface: Surface) {
            guard !stopped else { return }
            stage = value
            currentScope = scopes[surface.windowID]
            mark("stage-begin")
        }

        func mark(_ event: String) {
            guard !stopped else { return }
            append(record(event))
        }

        func fixture(_ surface: Surface) {
            guard !stopped else { return }
            fixtureCount += 1
            let scope = Scope(surface)
            var value = record("fixture-window", scope: scope)
            value.screenVisibleFrame = surface.window.screen.map { Self.rect($0.visibleFrame) }
            value.contentBounds = surface.window.contentView.map { Self.rect($0.bounds) }
            value.backingScale = Double(surface.window.backingScaleFactor)
            if surface.window.screen == nil { missingViews = true }
            append(value)
        }

        func discovered(_ surface: Surface, scroll: NSScrollView, texts: [NSTextView]) {
            guard !stopped else { return }
            if let old = scopes[surface.windowID], old.scroll === scroll,
               old.clip === scroll.contentView, old.document === scroll.documentView {
                // BEGIN typed viewport snapshot diagnostic
                #if DEBUG
                bindState(old)
                #endif
                // END typed viewport snapshot diagnostic
                currentScope = old
                textIdentity("discovered-existing-views", texts: texts)
                return
            }
            if let old = scopes[surface.windowID] {
                old.removeObservers()
                replacementGap = true // New views were not observed before this existing discovery point.
            }
            let scope = Scope(surface, scroll: scroll)
            // BEGIN typed viewport snapshot diagnostic
            #if DEBUG
            bindState(scope)
            #endif
            // END typed viewport snapshot diagnostic
            scopes[surface.windowID] = scope
            currentScope = scope
            guard let clip = scope.clip, let document = scope.document else {
                missingViews = true; mark("discovery-missing-clip-or-document"); return
            }
            if !clip.postsBoundsChangedNotifications || !clip.postsFrameChangedNotifications || !document.postsFrameChangedNotifications {
                notificationsDisabled = true
            }
            for (name, object) in [(NSView.boundsDidChangeNotification, clip as NSView),
                                   (NSView.frameDidChangeNotification, clip as NSView),
                                   (NSView.frameDidChangeNotification, document)] {
                scope.tokens.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self, weak scope] notification in
                    let event = notification.name.rawValue
                    let sender = (notification.object as? NSView).map { String(describing: ObjectIdentifier($0)) }
                    MainActor.assumeIsolated {
                        guard let self, let scope, !self.stopped else { return }
                        var value = self.record(event, scope: scope)
                        value.notificationObject = sender
                        self.append(value)
                    }
                })
            }
            textIdentity("discovered-views", texts: texts)
        }

        func textIdentity(_ event: String, texts: [NSTextView]) {
            guard !stopped else { return }
            var value = record(event)
            value.textCount = texts.count
            value.textIdentities = texts.prefix(128).map { Self.identity($0)! }
            if texts.count > 128 { identityListCapped = true }
            append(value)
        }

        func failedDiscovery(texts: [NSTextView]) {
            // BEGIN typed viewport snapshot diagnostic
            #if DEBUG
            currentScope?.marker = nil; currentScope?.session = nil
            currentScope?.mapping = .discoveryFailed
            currentScope?.candidateCount = 0
            stateMappingInconclusive = true
            #endif
            // END typed viewport snapshot diagnostic
            missingViews = true
            textIdentity("discovery-failed", texts: texts)
        }

        func request(maximum: CGFloat, fraction: CGFloat?, basis: String) {
            guard !stopped else { return }
            var value = record(fraction == nil ? "tail-check-maximum" : "scroll-request")
            value.maximum = Double(maximum)
            value.fraction = fraction.map(Double.init)
            value.targetY = fraction.map { Double(maximum * $0) }
            value.requestBasis = basis
            append(value)
        }

        func sample(_ value: Position, stage: String, expected: Position? = nil) {
            guard !stopped else { return }
            self.stage = stage
            var result = record(expected == nil ? "computed-position" : "comparison")
            result.actual = TimelinePosition(value)
            result.expected = expected.map(TimelinePosition.init)
            result.sameFullMessage = expected.map { $0.fullMessage == value.fullMessage }
            append(result)
        }

        func finishBody() {
            stoppedBeforeBodyEnd = stopped
            mark("method-body-end")
            bodyReachedEnd = true
        }

        func stop() {
            scopes.values.forEach { $0.removeObservers() }
            stopped = true
        }

        func attachment() -> XCTAttachment? {
            guard !emitted else { return nil }
            emitted = true
            stop()
            struct Header: Encodable {
                // BEGIN typed viewport snapshot diagnostic
                #if DEBUG
                var stateMappingInconclusive = false
                #endif
                // END typed viewport snapshot diagnostic
                let schemaVersion = 1
                let base = "cae0f793ea9a50ce4ce996b1fd2c4ad0aeedc59b"
                let method: String
                let continueAfterFailure: Bool
                let incomplete: Bool
                let flags: [String: Bool]
                let fixtureCount: Int
                let recordCount: Int
                let maxRecords = 512
                let maxEncodedRecordBytes = 245760
                let maxEncodedBytes = 262144
                let coordinates = "rect arrays are x,y,width,height in each view's existing coordinate system"
                let limits = "Callback delivery may be deferred; not write time. Exact discovered views only; gaps before discovery/replacement. Object addresses may be reused after deallocation. No writer attribution. Test-scroll interval does not identify synchronous notification writers. Position text is a bounded summary. Process termination can prevent attachment emission."
            }
            let flags = ["bodyDidNotReachEnd": !bodyReachedEnd, "fixtureMissing": fixtureCount == 0,
                "recordLimitReached": recordLimitReached, "byteLimitReached": byteLimitReached,
                "encodingFailed": encodingFailed, "missingViews": missingViews,
                "notificationsDisabled": notificationsDisabled, "replacementGap": replacementGap,
                "identityListCapped": identityListCapped, "stoppedBeforeBodyEnd": stoppedBeforeBodyEnd]
            var header = Header(method: method, continueAfterFailure: continueAfterFailure,
                incomplete: flags.values.contains(true), flags: flags, fixtureCount: fixtureCount, recordCount: records.count)
            // BEGIN typed viewport snapshot diagnostic
            #if DEBUG
            header.stateMappingInconclusive = stateMappingInconclusive
            #endif
            // END typed viewport snapshot diagnostic
            let fallback = Data(#"{"schemaVersion":1,"incomplete":true,"flags":{"attachmentEncodingFailed":true},"records":[]}"#.utf8)
            let oversized = Data(#"{"schemaVersion":1,"incomplete":true,"flags":{"attachmentTooLarge":true},"records":[]}"#.utf8)
            var data = (try? encoder.encode(header)) ?? Data()
            if data.last == UInt8(ascii: "}") {
                data.removeLast()
                data.append(Data(",\"records\":[".utf8))
                for (index, record) in records.enumerated() {
                    if index > 0 { data.append(UInt8(ascii: ",")) }
                    data.append(record)
                }
                data.append(Data("]}".utf8))
            } else { data = fallback }
            let attachment = XCTAttachment(data: data.count <= 262144 ? data : oversized, uniformTypeIdentifier: "public.json")
            attachment.name = "peek-test-timeline-\(method)"
            attachment.lifetime = .keepAlways
            return attachment
        }
    }

    private var timeline: Timeline?
    // END viewport timeline diagnostic
    private func settle(_ host: NSView, duration: TimeInterval = 0.35) {
        let until = Date().addingTimeInterval(duration)
        while Date() < until {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func textViews(_ root: NSView) -> [NSTextView] {
        // BEGIN typed viewport snapshot diagnostic
        #if DEBUG
        timeline?.visit(root)
        #endif
        // END typed viewport snapshot diagnostic
        return (root as? NSTextView).map { [$0] } ?? root.subviews.flatMap(textViews)
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
        // BEGIN viewport timeline diagnostic
        timeline?.begin(stage, surface: surface)
        // END viewport timeline diagnostic
        // Readiness never depends on an offset, an expected retained position,
        // or which line is visible. A wrong-but-rendered viewport is ready.
        let deadline = ProcessInfo.processInfo.systemUptime + (waitForReadiness ? 2 : 0)
        while true {
            // BEGIN typed viewport snapshot diagnostic
            #if DEBUG
            timeline?.beginMarkerDiscovery()
            #endif
            // END typed viewport snapshot diagnostic
            let matching = textViews(surface.root).filter { $0.string.hasPrefix(terminal.tag) }
            // BEGIN typed viewport snapshot diagnostic
            #if DEBUG
            timeline?.endMarkerDiscovery()
            #endif
            // END typed viewport snapshot diagnostic
            let attached = attachedScrollViews(matching, surface: surface)
            if historyIsReady(fixture, terminal: terminal, surface: surface),
               surface.root.window === surface.window, surface.window.contentView === surface.root,
               surface.root.bounds.width > 0, surface.root.bounds.height > 0,
               attached.count == 1, let scroll = attached.first, hasGeometry(scroll, surface: surface),
               matching.contains(where: { $0.enclosingScrollView === scroll && $0.window === surface.window
                   && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 && $0.bounds.height > 0 }) {
                // BEGIN viewport timeline diagnostic
                timeline?.discovered(surface, scroll: scroll, texts: matching)
                // END viewport timeline diagnostic
                return scroll
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            surface.root.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let context = failureContext(fixture, terminal: terminal, surface: surface, stage: stage)
        let matching = textViews(surface.root).filter { $0.string.hasPrefix(terminal.tag) }
        // BEGIN viewport timeline diagnostic
        timeline?.failedDiscovery(texts: matching)
        // END viewport timeline diagnostic
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
        // BEGIN viewport timeline diagnostic
        timeline?.request(maximum: maximum, fraction: fraction, basis: "existing maximum local and fraction")
        // END viewport timeline diagnostic
        XCTAssertGreaterThan(maximum, 1500, "The rendered fixture must be much longer than its viewport.", file: file, line: line)
        // Send the same intent notifications as an AppKit live scroll, then
        // move the real clip view. No product scheduler is changed for tests.
        // BEGIN viewport timeline diagnostic
        timeline?.mark("before-willStartLiveScroll")
        // END viewport timeline diagnostic
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        // BEGIN viewport timeline diagnostic
        timeline?.mark("after-willStartLiveScroll")
        // END viewport timeline diagnostic
        // BEGIN viewport timeline diagnostic
        timeline?.insideTestScrollAndReflect = true
        timeline?.mark("before-scroll")
        // END viewport timeline diagnostic
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum * fraction))
        // BEGIN viewport timeline diagnostic
        timeline?.mark("after-scroll")
        // END viewport timeline diagnostic
        scroll.reflectScrolledClipView(scroll.contentView)
        // BEGIN viewport timeline diagnostic
        timeline?.mark("after-reflect")
        timeline?.insideTestScrollAndReflect = false
        // END viewport timeline diagnostic
        // BEGIN viewport timeline diagnostic
        timeline?.mark("before-didEndLiveScroll")
        // END viewport timeline diagnostic
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        // BEGIN viewport timeline diagnostic
        timeline?.mark("after-didEndLiveScroll")
        // END viewport timeline diagnostic
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
        // BEGIN viewport timeline diagnostic
        timeline?.textIdentity("selected-position-text", texts: [text])
        timeline?.textIdentity("position-candidates", texts: candidates)
        // END viewport timeline diagnostic
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
        return Position(offset: clip.bounds.minY, fullMessage: content as String, lineRange: textLine,
            visibleText: content.substring(with: textLine), glyphY: lineY)
    }

    private func assertPosition(_ expected: Position, _ fixture: Fixture, terminal: Terminal, stage: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try position(fixture, terminal: terminal, stage: stage, file: file, line: line)
        assertPosition(expected, actual, stage: stage, file: file, line: line)
    }

    private func assertPosition(_ expected: Position, _ actual: Position, stage: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        // BEGIN viewport timeline diagnostic
        timeline?.sample(actual, stage: stage, expected: expected)
        // END viewport timeline diagnostic
        func describe(_ position: Position) -> String {
            let firstLine = String(position.fullMessage.prefix(80).prefix { $0 != "\n" })
            return "firstLine=\(firstLine.debugDescription) utf16Length=\((position.fullMessage as NSString).length) lineRange=\(position.lineRange) offset=\(position.offset)"
        }
        let context = "stage=\(String(stage.prefix(120))) expected={\(describe(expected))} actual={\(describe(actual))}"
        // Compare reading content and viewport-relative geometry; keep raw offsets for diagnostics.
        XCTAssertTrue(actual.fullMessage == expected.fullMessage, "Rendered message identity (\(context))", file: file, line: line)
        XCTAssertEqual(actual.lineRange, expected.lineRange, "Rendered logical line range (\(context))", file: file, line: line)
        XCTAssertEqual(actual.visibleText, expected.visibleText, "Rendered visible line (\(context))", file: file, line: line)
        XCTAssertEqual(actual.glyphY, expected.glyphY, accuracy: 4, "Rendered line position within viewport (\(context))", file: file, line: line)
    }

    func testActualHomeSwitchesEmptyDraftPeeksAndRetainsBothViewports() throws {
        // BEGIN viewport timeline diagnostic
        let recorder = Timeline(method: #function, continueAfterFailure: continueAfterFailure)
        timeline = recorder
        addTeardownBlock { [weak self, recorder] in
            MainActor.assumeIsolated {
                if let attachment = recorder.attachment() { self?.add(attachment) }
            }
        }
        defer {
            if let attachment = recorder.attachment() { add(attachment) }
            timeline = nil
        }
        // END viewport timeline diagnostic
        let f = try Fixture(); defer { f.shutdown() }
        // BEGIN viewport timeline diagnostic
        defer { timeline?.stop() }
        timeline?.fixture(f.surface)
        // END viewport timeline diagnostic
        let a = try f.terminal("VIEWPORT-A")
        let b = try f.terminal("VIEWPORT-B")
        f.show(a); settle(f.host)
        try scroll(f, terminal: a, fraction: 0.31, stage: "A choose off-bottom position")
        let first = try position(f, terminal: a, stage: "A initial reading position")
        // BEGIN viewport timeline diagnostic
        timeline?.sample(first, stage: "A initial reading position")
        // END viewport timeline diagnostic
        let originalInspection = try XCTUnwrap(f.controller.peeks.inspections[f.windowID])
        XCTAssertEqual(originalInspection.panelID, a.panelID)
        let oldModel = try XCTUnwrap(originalInspection.conversation)
        XCTAssertEqual(oldModel.draft, "")
        f.show(b); settle(f.host)
        try scroll(f, terminal: b, fraction: 0.63, stage: "B choose off-bottom position")
        let second = try position(f, terminal: b, stage: "B initial reading position")
        // BEGIN viewport timeline diagnostic
        timeline?.sample(second, stage: "B initial reading position")
        // END viewport timeline diagnostic
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
        // BEGIN viewport timeline diagnostic
        timeline?.mark("before-tail-assertion")
        // END viewport timeline diagnostic
        XCTAssertLessThanOrEqual(document.bounds.maxY - scroll.contentView.bounds.maxY, 32)
        // BEGIN viewport timeline diagnostic
        timeline?.finishBody()
        // END viewport timeline diagnostic
    }

    private func appendAndCheckOffBottom(_ fixture: Fixture, terminal: Terminal, expected: Position,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        try fixture.append(terminal, text: "\(terminal.tag) appended while reading earlier text")
        settle(fixture.host)
        try assertPosition(expected, fixture, terminal: terminal, stage: "after off-bottom append",
            file: file, line: line)
    }

    func testActualHomeRestoresPositionWithinSingleLongMessage() throws {
        // BEGIN viewport timeline diagnostic
        let recorder = Timeline(method: #function, continueAfterFailure: continueAfterFailure)
        timeline = recorder
        addTeardownBlock { [weak self, recorder] in
            MainActor.assumeIsolated {
                if let attachment = recorder.attachment() { self?.add(attachment) }
            }
        }
        defer {
            if let attachment = recorder.attachment() { add(attachment) }
            timeline = nil
        }
        // END viewport timeline diagnostic
        let f = try Fixture(); defer { f.shutdown() }
        // BEGIN viewport timeline diagnostic
        defer { timeline?.stop() }
        timeline?.fixture(f.surface)
        // END viewport timeline diagnostic
        let a = try f.terminal("LONG-A", singleMessage: true)
        let b = try f.terminal("LONG-B", singleMessage: true)
        f.show(a); settle(f.host)
        try scroll(f, terminal: a, fraction: 0.27, stage: "A choose off-bottom position")
        let first = try position(f, terminal: a, stage: "A initial reading position")
        // BEGIN viewport timeline diagnostic
        timeline?.sample(first, stage: "A initial reading position")
        // END viewport timeline diagnostic
        XCTAssertFalse(first.visibleText.contains("line 000"))
        f.show(b); settle(f.host)
        try scroll(f, terminal: b, fraction: 0.69, stage: "B choose off-bottom position")
        let second = try position(f, terminal: b, stage: "B initial reading position")
        // BEGIN viewport timeline diagnostic
        timeline?.sample(second, stage: "B initial reading position")
        // END viewport timeline diagnostic
        f.show(a); settle(f.host)
        try assertPosition(first, f, terminal: a, stage: "A after switching back")
        f.show(b); settle(f.host)
        try assertPosition(second, f, terminal: b, stage: "B after switching back")
        f.controller.peeks.close(in: f.windowID); settle(f.host)
        f.show(a); settle(f.host)
        try assertPosition(first, f, terminal: a, stage: "A after close and reopen")
        try appendAndCheckOffBottom(f, terminal: a, expected: first)
        // BEGIN viewport timeline diagnostic
        timeline?.finishBody()
        // END viewport timeline diagnostic
    }
    func testSameConversationHasIndependentViewportsInTwoHomeWindows() throws {
        // BEGIN viewport timeline diagnostic
        let recorder = Timeline(method: #function, continueAfterFailure: continueAfterFailure)
        timeline = recorder
        addTeardownBlock { [weak self, recorder] in
            MainActor.assumeIsolated {
                if let attachment = recorder.attachment() { self?.add(attachment) }
            }
        }
        defer {
            if let attachment = recorder.attachment() { add(attachment) }
            timeline = nil
        }
        // END viewport timeline diagnostic
        let f = try Fixture(); defer { f.shutdown() }
        // BEGIN viewport timeline diagnostic
        defer { timeline?.stop() }
        timeline?.fixture(f.surface)
        // END viewport timeline diagnostic
        let a = try f.terminal("WINDOW-A", singleMessage: true)
        let b = try f.terminal("WINDOW-B", singleMessage: true)
        f.show(a); settle(f.host)
        try scroll(f, terminal: a, fraction: 0.22, stage: "A choose off-bottom position")
        let first = try position(f, terminal: a, stage: "A initial reading position")
        // BEGIN viewport timeline diagnostic
        timeline?.sample(first, stage: "A initial reading position")
        // END viewport timeline diagnostic
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
        // BEGIN viewport timeline diagnostic
        defer { timeline?.stop() }
        timeline?.fixture(otherSurface)
        // END viewport timeline diagnostic
        f.controller.peeks.openSession(a.sessionID, in: otherID)
        settle(otherHost)
        let scroll = try scrollView(f, terminal: a, surface: otherSurface, stage: "second window initial viewport")
        let document = try XCTUnwrap(scroll.documentView)
        // BEGIN viewport timeline diagnostic
        timeline?.mark("before-willStartLiveScroll")
        // END viewport timeline diagnostic
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        // BEGIN viewport timeline diagnostic
        timeline?.mark("after-willStartLiveScroll")
        // END viewport timeline diagnostic
        // BEGIN viewport timeline diagnostic
        // Snapshot the unchanged inline expression below; keep both expressions identical.
        timeline?.request(maximum: document.bounds.height - scroll.contentView.bounds.height,
            fraction: 0.71, basis: "immediate pre-call snapshot of original inline expression")
        // END viewport timeline diagnostic
        // BEGIN viewport timeline diagnostic
        timeline?.insideTestScrollAndReflect = true
        timeline?.mark("before-scroll")
        // END viewport timeline diagnostic
        scroll.contentView.scroll(to: NSPoint(x: 0, y: (document.bounds.height - scroll.contentView.bounds.height) * 0.71))
        // BEGIN viewport timeline diagnostic
        timeline?.mark("after-scroll")
        // END viewport timeline diagnostic
        scroll.reflectScrolledClipView(scroll.contentView)
        // BEGIN viewport timeline diagnostic
        timeline?.mark("after-reflect")
        timeline?.insideTestScrollAndReflect = false
        // END viewport timeline diagnostic
        // BEGIN viewport timeline diagnostic
        timeline?.mark("before-didEndLiveScroll")
        // END viewport timeline diagnostic
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        // BEGIN viewport timeline diagnostic
        timeline?.mark("after-didEndLiveScroll")
        // END viewport timeline diagnostic
        settle(otherHost)
        let other = try position(f, terminal: a, surface: otherSurface, stage: "second window initial reading position")
        // BEGIN viewport timeline diagnostic
        timeline?.sample(other, stage: "second window initial reading position")
        // END viewport timeline diagnostic
        XCTAssertNotEqual(first.visibleText, other.visibleText)
        f.show(b); settle(f.host)
        f.show(a); settle(f.host)
        try assertPosition(first, f, terminal: a, stage: "A after switching back")
        let unchanged = try position(f, terminal: a, surface: otherSurface, stage: "second window after first-window switches")
        // BEGIN viewport timeline diagnostic
        timeline?.sample(unchanged, stage: "second window after first-window switches")
        // END viewport timeline diagnostic
        assertPosition(other, unchanged, stage: "second window after first-window switches")
        f.controller.peeks.close(in: otherID); settle(otherHost)
        f.controller.peeks.openSession(a.sessionID, in: otherID); settle(otherHost)
        let reopened = try position(f, terminal: a, surface: otherSurface, stage: "second window after close and reopen")
        // BEGIN viewport timeline diagnostic
        timeline?.sample(reopened, stage: "second window after close and reopen")
        // END viewport timeline diagnostic
        assertPosition(other, reopened, stage: "second window after close and reopen")
        // BEGIN viewport timeline diagnostic
        timeline?.finishBody()
        // END viewport timeline diagnostic
    }

    func testExternalClipScrollWinsOverAppendAndDeferredWorkFromReplacedPeek() throws {
        // BEGIN viewport timeline diagnostic
        let recorder = Timeline(method: #function, continueAfterFailure: continueAfterFailure)
        timeline = recorder
        addTeardownBlock { [weak self, recorder] in
            MainActor.assumeIsolated {
                if let attachment = recorder.attachment() { self?.add(attachment) }
            }
        }
        defer {
            if let attachment = recorder.attachment() { add(attachment) }
            timeline = nil
        }
        // END viewport timeline diagnostic
        let f = try Fixture(); defer { f.shutdown() }
        // BEGIN viewport timeline diagnostic
        defer { timeline?.stop() }
        timeline?.fixture(f.surface)
        // END viewport timeline diagnostic
        let a = try f.terminal("DEFERRED-A", singleMessage: true)
        let b = try f.terminal("DEFERRED-B", singleMessage: true)
        f.show(a); settle(f.host)
        let scroll = try scrollView(f, terminal: a, stage: "A bottom viewport")
        let document = try XCTUnwrap(scroll.documentView)
        let maximum = document.bounds.height - scroll.contentView.bounds.height
        // BEGIN viewport timeline diagnostic
        timeline?.request(maximum: maximum, fraction: nil, basis: "existing initial tail bound; no test scroll yet")
        // END viewport timeline diagnostic
        XCTAssertGreaterThan(maximum, 1500)
        XCTAssertLessThanOrEqual(maximum - scroll.contentView.bounds.minY, 32)
        // Selection/autoscroll and accessibility can move the clip without
        // live-scroll notifications. Do not drain queued work before append.
        // BEGIN viewport timeline diagnostic
        timeline?.insideTestScrollAndReflect = true
        timeline?.mark("before-scroll")
        // END viewport timeline diagnostic
        // BEGIN viewport timeline diagnostic
        timeline?.request(maximum: maximum, fraction: 0.37, basis: "existing maximum local times 0.37")
        // END viewport timeline diagnostic
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum * 0.37))
        // BEGIN viewport timeline diagnostic
        timeline?.mark("after-scroll")
        // END viewport timeline diagnostic
        scroll.reflectScrolledClipView(scroll.contentView)
        // BEGIN viewport timeline diagnostic
        timeline?.mark("after-reflect")
        timeline?.insideTestScrollAndReflect = false
        // END viewport timeline diagnostic
        let expected = try position(f, terminal: a, stage: "A immediate position before append", waitForReadiness: false)
        // BEGIN viewport timeline diagnostic
        timeline?.sample(expected, stage: "A immediate position before append")
        // END viewport timeline diagnostic
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
        // BEGIN viewport timeline diagnostic
        timeline?.finishBody()
        // END viewport timeline diagnostic
    }

}
