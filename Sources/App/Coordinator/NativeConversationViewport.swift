import AppKit
import RemoteProtocol
import SwiftUI

/// Presentation state only. One instance belongs to each window; it never
/// retains conversation models or views and does not publish scroll ticks.
@MainActor
final class NativeConversationViewportStore: ObservableObject {
    struct Key: Hashable {
        let panelID: UUID
        let conversationID: RemoteConversationID
    }
    struct Position {
        var followsTail: Bool
        var anchor: String?
        var previous: String?
        var next: String?
        var distance: CGFloat
        var fraction: CGFloat
        var width: CGFloat
    }
    private var positions: [Key: Position] = [:]
    private var active: [Key: UUID] = [:]
    private var recent: [Key] = []

    func attach(_ key: Key, token: UUID) -> Position? {
        // A replaced conversation must not inherit a previous session's view.
        for old in Array(positions.keys) where old.panelID == key.panelID && old != key {
            positions.removeValue(forKey: old)
            active.removeValue(forKey: old)
            recent.removeAll { $0 == old }
        }
        active[key] = token
        recent.removeAll { $0 == key }
        recent.append(key)
        while recent.count > 128, let index = recent.firstIndex(where: { active[$0] == nil }) {
            positions.removeValue(forKey: recent.remove(at: index))
        }
        return positions[key]
    }

    func position(for key: Key) -> Position? { positions[key] }
    func isActive(_ key: Key, token: UUID) -> Bool { active[key] == token }
    func save(_ position: Position, key: Key, token: UUID) {
        guard isActive(key, token: token) else { return }
        positions[key] = position
    }
    func detach(_ key: Key, token: UUID) {
        guard isActive(key, token: token) else { return }
        active.removeValue(forKey: key)
    }
}

/// A single mounted scroll view owns measurement and positioning. The store
/// survives its removal, while this object and its weak row registry do not.
@MainActor
final class NativeConversationViewportSession: ObservableObject {
    struct Materialization: Equatable {
        let generation: Int
        let target: String?
    }
    @Published private(set) var followsTail = true
    @Published private(set) var materialization = Materialization(generation: 0, target: nil)
    private var requestedMaterialization = Materialization(generation: 0, target: nil)
    private var lastPublishedTargetGeneration = 0
    private var acknowledgedNilGeneration = 0
    private var materializationAttempts = 0
    private var following = true
    private var store: NativeConversationViewportStore?
    private var key: NativeConversationViewportStore.Key?
    private var token = UUID()
    private var saved: NativeConversationViewportStore.Position?
    private weak var marker: NativeConversationViewportMarkerView?
    private weak var scroll: NSScrollView?
    private weak var observedDocument: NSView?
    private var hasAttachedScroll = false
    private struct Geometry: Equatable {
        let documentFrame: NSRect
        let documentBounds: NSRect
        let clipSize: NSSize
    }
    private var lastGeometry: Geometry?
    private var layoutRevision = 0
    private var rows = NSHashTable<NativeConversationViewportRowView>.weakObjects()
    private var eventIDs: [String] = []
    private var contentLoaded = false
    private enum Restore {
        case pending
        case locating(anchor: String, layoutRevision: Int)
        case releasing(anchor: String)
        case correcting(anchor: String, attempts: Int, previousTop: CGFloat?, layoutRevision: Int)
        case suspended
        case idle
    }
    private var restore = Restore.pending
    private var scheduled = false
    private var applying = false
    private var userScrolling = false
    private var revision = 0
    private var eventMonitor: Any?
    private var observations: [NSObjectProtocol] = []

    func configure(store: NativeConversationViewportStore, panelID: UUID,
                   conversationID: RemoteConversationID?, eventIDs: [String], isHistoryLoaded: Bool) {
        let loadingChanged = contentLoaded != isHistoryLoaded
        let eventsChanged = self.eventIDs != eventIDs
        self.eventIDs = eventIDs
        self.contentLoaded = isHistoryLoaded
        let next = conversationID.map { NativeConversationViewportStore.Key(panelID: panelID, conversationID: $0) }
        if self.store !== store || key != next {
            if let key, let previous = self.store { previous.detach(key, token: token) }
            self.store = store
            key = next
            token = UUID()
            revision += 1
            requestMaterialization(nil, invalidateScope: true)
            materializationAttempts = 0
            saved = next.flatMap { store.attach($0, token: token) }
            restore = .pending
            userScrolling = false
            applying = false
            following = saved?.followsTail ?? true
            publishFollowing()
        } else if loadingChanged || (eventsChanged && isSuspended) {
            reloadPosition()
        }
        scheduleLayout()
    }

    func positionBinding(for snapshot: Materialization, store: NativeConversationViewportStore,
                         panelID: UUID, conversationID: RemoteConversationID?) -> Binding<String?> {
        let owner = ObjectIdentifier(store)
        let key = conversationID.map { NativeConversationViewportStore.Key(panelID: panelID, conversationID: $0) }
        return Binding(get: { [weak self] in
            guard let self, let currentStore = self.store, ObjectIdentifier(currentStore) == owner,
                  self.key == key, self.attached, self.contentLoaded,
                  snapshot == self.requestedMaterialization, snapshot == self.materialization,
                  case .locating = self.restore else { return nil }
            return snapshot.target
        }, set: { _ in
            // SwiftUI identity readback is observation, not reading intent or a saved position.
        })
    }

    private var materializationReleased: Bool {
        requestedMaterialization.target == nil &&
            (lastPublishedTargetGeneration == 0 || acknowledgedNilGeneration > lastPublishedTargetGeneration)
    }

    private func requestMaterialization(_ target: String?, invalidateScope: Bool = false) {
        guard invalidateScope || requestedMaterialization.target != target else { return }
        let snapshot = Materialization(generation: requestedMaterialization.generation + 1, target: target)
        requestedMaterialization = snapshot
        let currentToken = token
        Task { @MainActor [weak self] in
            guard let self, self.token == currentToken, self.requestedMaterialization == snapshot else { return }
            if snapshot.target != nil { self.lastPublishedTargetGeneration = snapshot.generation }
            self.materialization = snapshot
        }
    }

    func markerDidLayout(_ marker: NativeConversationViewportMarkerView, materialization snapshot: Materialization) {
        guard self.marker === marker, attached else { return }
        if snapshot.target == nil, snapshot == materialization, snapshot == requestedMaterialization,
           acknowledgedNilGeneration < snapshot.generation {
            acknowledgedNilGeneration = snapshot.generation
        }
        // This acknowledges our cleared value in the mounted view, not cancellation
        // of every internal SwiftUI adjustment. Correction still needs runtime proof.
        geometryDidChange()
    }

    private var isSuspended: Bool {
        if case .suspended = restore { return true }
        return false
    }

    private func reloadPosition() {
        if let key, let store { saved = store.position(for: key) }
        restore = .pending
        following = saved?.followsTail ?? following
        revision += 1
        requestMaterialization(nil, invalidateScope: true)
        materializationAttempts = 0
        userScrolling = false
        applying = false
        publishFollowing()
    }

    func attach(_ marker: NativeConversationViewportMarkerView) {
        if self.marker !== marker { reloadPosition() }
        self.marker = marker
        if let key, let store, !store.isActive(key, token: token) {
            saved = store.attach(key, token: token)
            restore = .pending
            following = saved?.followsTail ?? true
            revision += 1
            materializationAttempts = 0
            publishFollowing()
        }
        scheduleLayout()
    }

    func detach(_ marker: NativeConversationViewportMarkerView) {
        guard self.marker === marker else { return }
        if let key, let store { store.detach(key, token: token) }
        revision += 1
        requestMaterialization(nil, invalidateScope: true)
        self.marker = nil
        scroll = nil
        observedDocument = nil
        hasAttachedScroll = false
        userScrolling = false
        applying = false
        lastGeometry = nil
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    func register(_ row: NativeConversationViewportRowView) {
        rows.add(row)
        geometryDidChange()
    }

    func geometryDidChange() {
        layoutRevision += 1
        scheduleLayout()
    }

    func revealTail() {
        revision += 1
        requestMaterialization(nil)
        restore = .idle
        following = true
        // Explicit intent survives a switch even before the layout pass that
        // moves the clip view, including a jump requested while history loads.
        if let key, let store {
            store.save(.init(followsTail: true, anchor: nil, previous: nil, next: nil,
                distance: 0, fraction: 0, width: scroll?.contentView.bounds.width ?? 0), key: key, token: token)
        }
        publishFollowing()
        scheduleLayout()
    }

    private var attached: Bool {
        guard marker?.window != nil, let key, let store else { return false }
        return store.isActive(key, token: token)
    }

    func scheduleLayout() {
        guard !scheduled else { return }
        scheduled = true
        let currentToken = token
        let currentRevision = revision
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard self.attached, self.token == currentToken, self.revision == currentRevision else {
                // A newer configuration gets its own guarded layout pass.
                if self.attached { self.scheduleLayout() }
                return
            }
            self.refreshLayout()
        }
    }

    private func installObservers(_ scroll: NSScrollView) {
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        self.scroll = scroll
        observedDocument = scroll.documentView
        hasAttachedScroll = true
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        scroll.documentView?.postsFrameChangedNotifications = true
        func observe(_ name: Notification.Name, object: AnyObject?, action: @escaping @MainActor () -> Void) {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
                MainActor.assumeIsolated { action() }
            })
        }
        observe(NSView.boundsDidChangeNotification, object: scroll.contentView) { [weak self] in self?.boundsChanged() }
        observe(NSView.frameDidChangeNotification, object: scroll.contentView) { [weak self] in self?.geometryDidChange() }
        observe(NSView.frameDidChangeNotification, object: scroll.documentView) { [weak self] in self?.geometryDidChange() }
        observe(NSScrollView.willStartLiveScrollNotification, object: scroll) { [weak self] in self?.beginUserScroll() }
        observe(NSScrollView.didEndLiveScrollNotification, object: scroll) { [weak self] in self?.endUserScroll() }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDown]) { [weak self] event in
            guard let self, let scroll = self.scroll, self.attached, event.window === scroll.window else { return event }
            let inside: Bool
            if event.type == .keyDown {
                let responder = scroll.window?.firstResponder as? NSView
                inside = responder?.isDescendant(of: scroll) == true && [115, 116, 119, 121, 125, 126].contains(event.keyCode)
            } else {
                inside = scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
            }
            guard inside else { return event }
            self.noteUserIntent()
            let revision = self.revision
            let token = self.token
            Task { @MainActor [weak self] in
                guard let self, self.attached, !self.userScrolling,
                      self.revision == revision, self.token == token else { return }
                self.endUserScroll()
            }
            return event
        }
    }

    private func noteUserIntent() {
        guard attached, contentLoaded else { return }
        revision += 1
        requestMaterialization(nil)
        restore = .idle
        following = false
        publishFollowing()
    }

    private func beginUserScroll() {
        guard attached, contentLoaded else { return }
        noteUserIntent()
        userScrolling = true
    }

    private func endUserScroll() {
        guard attached, contentLoaded else { return }
        userScrolling = false
        following = atBottom
        publishFollowing()
        capture()
    }

    private var atBottom: Bool {
        guard let scroll, let document = scroll.documentView else { return false }
        return maximumTop(document, scroll.contentView) - viewportTop(document, scroll.contentView) <= 32
    }

    private var geometry: Geometry? {
        guard let scroll, let document = scroll.documentView else { return nil }
        return Geometry(documentFrame: document.frame, documentBounds: document.bounds,
            clipSize: scroll.contentView.bounds.size)
    }

    private func boundsChanged() {
        guard attached, contentLoaded, !applying, case .idle = restore else { return }
        // Selection autoscroll, accessibility, and animated key scrolling can
        // bypass local event monitors. An unexplained move with unchanged
        // document/viewport geometry is external input, not a tail resize.
        if userScrolling || geometry == lastGeometry {
            following = atBottom
            publishFollowing()
            capture()
        } else if following {
            scheduleLayout()
        } else {
            capture()
        }
    }

    private func refreshLayout() {
        guard attached, let marker, let currentScroll = marker.enclosingScrollView else { return }
        if hasAttachedScroll, scroll !== currentScroll || observedDocument !== currentScroll.documentView {
            reloadPosition()
        }
        if scroll !== currentScroll || observedDocument !== currentScroll.documentView { installObservers(currentScroll) }
        guard let document = currentScroll.documentView, document.bounds.height > 0,
              currentScroll.contentView.bounds.height > 0, contentLoaded else { return }
        let clip = currentScroll.contentView
        switch restore {
        case .pending:
            guard materializationReleased else { return }
            if following { restore = .idle; setTop(maximumTop(document, clip)); capture() }
            else {
                let anchor = [saved?.anchor, saved?.next, saved?.previous].compactMap { $0 }
                    .first { eventIDs.contains($0) } ?? eventIDs.first
                guard let anchor else { return }
                beginLocating(anchor)
            }
        case .locating(let anchor, let lastLayout):
            if visibleRow(anchor, in: currentScroll) != nil {
                restore = .releasing(anchor: anchor)
                requestMaterialization(nil)
                if materializationReleased { scheduleLayout() }
            } else if lastLayout != layoutRevision {
                guard materializationAttempts < 8 else { suspendRestoration(); return }
                materializationAttempts += 1
                restore = .locating(anchor: anchor, layoutRevision: layoutRevision)
                // Keep one identity request alive across real layout changes.
            }
        case .releasing(let anchor):
            guard materializationReleased else { return }
            restore = .correcting(anchor: anchor, attempts: 0, previousTop: nil, layoutRevision: layoutRevision)
            correct(anchor: anchor, attempts: 0, previousTop: nil, document: document, clip: clip)
        case .correcting(let anchor, let attempts, let previousTop, let lastLayout):
            guard lastLayout != layoutRevision else { return }
            correct(anchor: anchor, attempts: attempts, previousTop: previousTop, document: document, clip: clip)
        case .suspended:
            // Keep the previous snapshot after a failed materialization. New
            // content or explicit user input can start a fresh attempt.
            break
        case .idle:
            if following && !userScrolling { setTop(maximumTop(document, clip)) }
            capture()
        }
    }

    private func beginLocating(_ anchor: String) {
        guard materializationReleased else { return }
        guard materializationAttempts < 8 else { suspendRestoration(); return }
        materializationAttempts += 1
        restore = .locating(anchor: anchor, layoutRevision: layoutRevision)
        requestMaterialization(anchor)
    }

    private func suspendRestoration() {
        restore = .suspended
        requestMaterialization(nil)
    }

    private func visibleRow(_ anchor: String, in scroll: NSScrollView) -> NativeConversationViewportRowView? {
        rows.allObjects.first { $0.eventID == anchor && $0.window != nil &&
            $0.enclosingScrollView === scroll && $0.bounds.height > 0 }
    }

    private func correct(anchor: String, attempts: Int, previousTop: CGFloat?, document: NSView, clip: NSClipView) {
        guard materializationReleased else { return }
        guard let scroll, let row = visibleRow(anchor, in: scroll) else {
            beginLocating(anchor)
            return
        }
        let frame = row.convert(row.bounds, to: document)
        let top = document.isFlipped ? frame.minY - document.bounds.minY : document.bounds.maxY - frame.maxY
        let distance: CGFloat
        if anchor == saved?.anchor, let saved {
            distance = abs(saved.width - clip.bounds.width) < 1 ? saved.distance : saved.fraction * frame.height
        } else { distance = 0 }
        let requested = top + min(max(-clip.bounds.height, distance), max(0, frame.height - 1))
        let target = self.top(of: constrainedBounds(forTop: requested, document: document, clip: clip),
            document: document, clip: clip)
        let settled = previousTop.map { abs($0 - top) < 0.5 } == true && abs(viewportTop(document, clip) - target) < 0.5
        setTop(target)
        if settled {
            restore = .idle
            capture()
        } else if attempts >= 8 {
            suspendRestoration()
        } else {
            restore = .correcting(anchor: anchor, attempts: attempts + 1,
                previousTop: top, layoutRevision: layoutRevision)
            // Check convergence on a real AppKit layout opportunity. This does
            // not consume a correction budget just because a Task ran.
            marker?.needsLayout = true
        }
    }

    private func top(of clipBounds: NSRect, document: NSView, clip: NSClipView) -> CGFloat {
        let visible = document.convert(clipBounds, from: clip)
        return document.isFlipped ? visible.minY - document.bounds.minY : document.bounds.maxY - visible.maxY
    }
    private func viewportTop(_ document: NSView, _ clip: NSClipView) -> CGFloat {
        top(of: clip.bounds, document: document, clip: clip)
    }
    private func maximumTop(_ document: NSView, _ clip: NSClipView) -> CGFloat {
        top(of: constrainedBounds(forTop: document.bounds.height, document: document, clip: clip), document: document, clip: clip)
    }
    private func constrainedBounds(forTop top: CGFloat, document: NSView, clip: NSClipView) -> NSRect {
        var visible = document.convert(clip.bounds, from: clip)
        visible.origin.y = document.isFlipped ? document.bounds.minY + top : document.bounds.maxY - visible.height - top
        return clip.constrainBoundsRect(document.convert(visible, to: clip))
    }
    private func setTop(_ top: CGFloat) {
        guard attached, materializationReleased, let scroll, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let target = constrainedBounds(forTop: top, document: document, clip: clip)
        lastGeometry = geometry
        guard abs(clip.bounds.minY - target.minY) > 0.25 else { return }
        applying = true
        clip.scroll(to: target.origin)
        scroll.reflectScrolledClipView(clip)
        applying = false
    }

    private func capture() {
        guard attached, contentLoaded, case .idle = restore, let scroll, let document = scroll.documentView,
              document.bounds.height > 0, let key, let store else { return }
        let clip = scroll.contentView
        let top = viewportTop(document, clip)
        let visible = rows.allObjects.compactMap { row -> (String, CGFloat, CGFloat)? in
            guard row.window != nil, row.enclosingScrollView === scroll else { return nil }
            let rect = row.convert(row.bounds, to: document)
            let rowTop = document.isFlipped ? rect.minY - document.bounds.minY : document.bounds.maxY - rect.maxY
            guard rect.height > 0, rowTop + rect.height > top, rowTop < top + clip.bounds.height else { return nil }
            return (row.eventID, rowTop, rect.height)
        }.sorted { $0.1 < $1.1 }.first
        // Lazy layout can briefly remove every row. Keep the last good anchor.
        guard following || visible != nil else { return }
        let index = visible.flatMap { eventIDs.firstIndex(of: $0.0) }
        let distance = visible.map { top - $0.1 } ?? 0
        let position = NativeConversationViewportStore.Position(followsTail: following, anchor: visible?.0,
            previous: index.flatMap { $0 > 0 ? eventIDs[$0 - 1] : nil },
            next: index.flatMap { $0 + 1 < eventIDs.count ? eventIDs[$0 + 1] : nil },
            distance: distance, fraction: visible.map { distance / $0.2 } ?? 0, width: clip.bounds.width)
        store.save(position, key: key, token: token)
        lastGeometry = geometry
    }

    private func publishFollowing() {
        let token = token
        Task { @MainActor [weak self] in
            guard let self, self.token == token, self.followsTail != self.following else { return }
            self.followsTail = self.following
        }
    }
}

struct NativeConversationViewportMarker: NSViewRepresentable {
    let session: NativeConversationViewportSession
    let store: NativeConversationViewportStore
    let panelID: UUID
    let conversationID: RemoteConversationID?
    let eventIDs: [String]
    let isHistoryLoaded: Bool
    let materialization: NativeConversationViewportSession.Materialization

    func makeNSView(context: Context) -> NativeConversationViewportMarkerView {
        NativeConversationViewportMarkerView(session: session)
    }
    func updateNSView(_ view: NativeConversationViewportMarkerView, context: Context) {
        session.configure(store: store, panelID: panelID, conversationID: conversationID,
            eventIDs: eventIDs, isHistoryLoaded: isHistoryLoaded)
        if view.materialization != materialization {
            view.materialization = materialization
            view.needsLayout = true
        }
    }
    static func dismantleNSView(_ view: NativeConversationViewportMarkerView, coordinator: ()) { view.session.detach(view) }
}

final class NativeConversationViewportMarkerView: NSView {
    let session: NativeConversationViewportSession
    var materialization = NativeConversationViewportSession.Materialization(generation: 0, target: nil)
    init(session: NativeConversationViewportSession) { self.session = session; super.init(frame: .zero); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { session.attach(self) } }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { session.detach(self) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func layout() { super.layout(); session.markerDidLayout(self, materialization: materialization) }
}

struct NativeConversationViewportRow: NSViewRepresentable {
    let eventID: String
    let session: NativeConversationViewportSession
    func makeNSView(context: Context) -> NativeConversationViewportRowView {
        NativeConversationViewportRowView(eventID: eventID, session: session)
    }
    func updateNSView(_ view: NativeConversationViewportRowView, context: Context) {
        view.eventID = eventID
        view.session = session
        session.register(view)
    }
}

final class NativeConversationViewportRowView: NSView {
    var eventID: String
    weak var session: NativeConversationViewportSession?
    init(eventID: String, session: NativeConversationViewportSession) {
        self.eventID = eventID; self.session = session
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { session?.register(self) } }
    override func layout() { super.layout(); session?.geometryDidChange() }
}
