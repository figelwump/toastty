import CoreState
import Foundation

// MARK: - Browser annotation mode (Linux)
//
// The draft model, display geometry, session, payload builder, screenshot
// writer, send gate and send flow are the shared macOS files
// (Sources/App/WebPanels/BrowserAnnotation*.swift, WebPanelAnnotationSession,
// BrowserPanelScreenshotWriter). This file adds what macOS keeps inside
// AppKit views:
//
// - `BrowserAnnotatedScreenshotRenderer`: the macOS renderer draws with
//   CoreGraphics; on Linux the GTK frontend installs a cairo renderer with
//   `LinuxAppLogic.installAnnotationScreenshotRenderer(_:)`.
// - `LinuxWebPanelAnnotationController`: the interaction state machine of
//   `BrowserAnnotationOverlayNSView` (drag/click gestures, the pending draft
//   whose capture runs while its comment is typed, create/edit/detail
//   popovers and their click-away rules, hover, scroll tracking) without
//   AppKit, so the GTK overlay only draws and forwards events.

/// What the frontend's screenshot renderer draws: the captured PNG plus
/// numbered marks in normalized top-left coordinates.
public struct LinuxAnnotationRenderRequest: Sendable, Equatable {
    public struct Mark: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// Normalized (0...1) point from the viewport's top-left corner.
            case point(CGPoint)
            /// Normalized rectangle from the viewport's top-left corner.
            case rectangle(CGRect)
        }

        public let number: Int
        public let kind: Kind

        public init(number: Int, kind: Kind) {
            self.number = number
            self.kind = kind
        }
    }

    public let pngData: Data
    /// Viewport size in view points when the section was captured.
    public let viewportSize: CGSize
    public let marks: [Mark]

    public init(pngData: Data, viewportSize: CGSize, marks: [Mark]) {
        self.pngData = pngData
        self.viewportSize = viewportSize
        self.marks = marks
    }

    /// macOS `BrowserAnnotatedScreenshotRenderer.markScale`: screenshots are
    /// usually denser than the viewport, so marks scale by the pixel ratio.
    public func markScale(imagePixelWidth: Int) -> CGFloat {
        BrowserAnnotatedScreenshotRenderer.markScale(
            imageSize: CGSize(width: imagePixelWidth, height: 1),
            viewportSize: viewportSize
        )
    }
}

public typealias LinuxAnnotationScreenshotRendering = @Sendable (LinuxAnnotationRenderRequest) throws -> Data

/// Linux stand-in for the CoreGraphics renderer in
/// `BrowserAnnotatedScreenshotRenderer.swift` (excluded on Linux). Same
/// static API, so the shared `BrowserAnnotationScreenshotWriter` calls it
/// unchanged.
enum BrowserAnnotatedScreenshotRenderer {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var renderer: LinuxAnnotationScreenshotRendering?
    }

    private static let storage = Storage()

    static var renderer: LinuxAnnotationScreenshotRendering? {
        get { storage.lock.withLock { storage.renderer } }
        set { storage.lock.withLock { storage.renderer = newValue } }
    }

    static func render(section: BrowserAnnotationSection) throws -> Data {
        guard let renderer else { throw BrowserAnnotatedScreenshotRendererError.bitmapContextUnavailable }
        guard section.pngData.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            throw BrowserAnnotatedScreenshotRendererError.invalidPNGData
        }
        return try renderer(renderRequest(for: section))
    }

    static func renderRequest(for section: BrowserAnnotationSection) -> LinuxAnnotationRenderRequest {
        LinuxAnnotationRenderRequest(
            pngData: section.pngData,
            viewportSize: section.viewportSize,
            marks: section.annotations.map { item in
                switch item.kind {
                case .point(let point): .init(number: item.sequenceNumber, kind: .point(point))
                case .rectangle(let rect): .init(number: item.sequenceNumber, kind: .rectangle(rect))
                }
            }
        )
    }

    static func markScale(imageSize: CGSize, viewportSize: CGSize) -> CGFloat {
        guard viewportSize.width > 0 else { return 1 }
        let scale = imageSize.width / viewportSize.width
        return scale > 0 ? scale : 1
    }
}

enum BrowserAnnotatedScreenshotRendererError: LocalizedError, Equatable {
    case invalidPNGData
    case bitmapContextUnavailable
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidPNGData: "browser annotation screenshot data is not a valid PNG"
        case .bitmapContextUnavailable: "failed to create an annotation rendering context"
        case .pngEncodingFailed: "failed to encode annotated browser screenshot"
        }
    }
}

/// Mark metrics and colors shared by the overlay and the rendered
/// screenshot (public view of the shared `BrowserAnnotationMarkStyle`).
public enum LinuxAnnotationMarkStyle {
    public static var bubbleDiameter: CGFloat { BrowserAnnotationMarkStyle.bubbleDiameter }
    public static var bubbleRingWidth: CGFloat { BrowserAnnotationMarkStyle.bubbleRingWidth }
    public static var rectangleLineWidth: CGFloat { BrowserAnnotationMarkStyle.rectangleLineWidth }
    public static var rectangleFillAlpha: CGFloat { BrowserAnnotationMarkStyle.rectangleFillAlpha }
    public static var hoverRingExtraRadius: CGFloat { BrowserAnnotationMarkStyle.hoverRingExtraRadius }
    public static var hoverRingAlpha: CGFloat { BrowserAnnotationMarkStyle.hoverRingAlpha }
    public static var numberFontSize: CGFloat { BrowserAnnotationMarkStyle.numberFontSize }
    public static var shadowBlurRadius: CGFloat { BrowserAnnotationMarkStyle.shadowBlurRadius }
    /// Offset in top-left (y down) coordinates.
    public static var shadowOffsetDown: CGFloat { -BrowserAnnotationMarkStyle.shadowOffset.height }
    public static var shadowAlpha: CGFloat { BrowserAnnotationMarkStyle.shadowColor.alphaComponent }

    /// sRGB components of the mark red.
    public static var markColor: (red: Double, green: Double, blue: Double) {
        let color = BrowserAnnotationMarkStyle.markColor
        return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }
}

/// One mark in overlay coordinates (top-left origin, view points).
public struct LinuxAnnotationMark: Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        case point(center: CGPoint)
        case rectangle(CGRect)
    }

    /// nil for the pending draft whose comment is being typed.
    public let annotationID: UUID?
    public let number: Int
    public let shape: Shape
    /// Click/hover target and popover anchor.
    public let bubbleRect: CGRect
    public let isHovered: Bool
}

/// The comment popover the overlay should show.
public struct LinuxAnnotationPopover: Equatable, Sendable {
    public enum Purpose: Equatable, Sendable {
        case create
        case edit(annotationID: UUID)
        case view(annotationID: UUID)
    }

    /// Identity of this popover session; a new value means a new popover.
    public let id: UUID
    public let purpose: Purpose
    public let number: Int
    /// The comment (edit/view) or empty (create).
    public let comment: String
    /// Anchor in overlay coordinates.
    public let anchorRect: CGRect

    public var isEditing: Bool {
        if case .view = purpose { return false }
        return true
    }
}

public struct LinuxAnnotationSendCandidate: Equatable, Sendable {
    public let sessionID: String
    public let panelID: UUID
    public let label: String
    /// Why the session cannot receive annotations now ("awaiting approval").
    public let blockedReason: String?
}

public struct LinuxAnnotationNotice: Equatable, Sendable {
    public let id: UUID
    public let message: String
    public let isFailure: Bool
}

public enum LinuxAnnotationCopy {
    public static func clearConfirmationTitle(draftCount: Int) -> String {
        BrowserAnnotationCopy.clearConfirmationTitle(draftCount: draftCount)
    }
}

/// Annotation mode for one browser panel. Owns no widgets: the GTK overlay
/// reads `marks`, `pendingMark`, `inProgressRectangle` and `popover`,
/// forwards pointer, scroll and key events, and redraws on `onChange`.
@MainActor
public final class LinuxWebPanelAnnotationController {
    struct Dependencies {
        var candidates: @MainActor () -> [BrowserScreenshotSendCandidate]
        var availability: @MainActor (BrowserScreenshotSendCandidate) -> BrowserAnnotationSendAvailability
        var sendPayload: @MainActor (String, BrowserScreenshotSendCandidate) -> Bool
    }

    /// One in-flight gesture: the mark shows immediately while the viewport
    /// capture runs and the comment popover is open.
    private struct PendingDraft {
        let startPoint: CGPoint
        let endPoint: CGPoint
        let overlaySize: CGSize
        let sequenceNumber: Int
        let pageGeneration: Int
        let captureTask: Task<BrowserAnnotationCapturedSection, Error>

        var isRectangle: Bool {
            hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y) > BrowserAnnotationMarkStyle.dragThreshold
        }

        var rectangle: CGRect {
            CGRect(
                x: min(startPoint.x, endPoint.x), y: min(startPoint.y, endPoint.y),
                width: abs(endPoint.x - startPoint.x), height: abs(endPoint.y - startPoint.y)
            )
        }

        var bubbleRect: CGRect {
            BrowserAnnotationDisplayGeometry.bubbleRect(center: isRectangle ? rectangle.origin : endPoint)
        }
    }

    private struct PopoverSession {
        let id = UUID()
        let purpose: LinuxAnnotationPopover.Purpose
        let number: Int
        let comment: String
        let anchorRect: CGRect
        var currentText: String

        var isEditing: Bool {
            if case .view = purpose { return false }
            return true
        }
    }

    private weak var runtime: BrowserPanelRuntime?
    private let dependencies: Dependencies
    private var observation: AnyCancellable?
    private var notifyScheduled = false

    /// Called after every change the overlay should reflect.
    public var onChange: (@MainActor () -> Void)?
    /// Annotation mode turned on: the overlay should take keyboard focus.
    public var onRequestFocus: (@MainActor () -> Void)?

    /// Overlay size in view points (set by the overlay on resize/draw).
    public var overlaySize: CGSize = .zero

    private var dragStartPoint: CGPoint?
    private var dragCurrentPoint: CGPoint?
    private var pendingDraft: PendingDraft?
    private var isResolvingPendingDraft = false
    private var popoverSession: PopoverSession?
    private var hoveredAnnotationID: UUID?
    private var wasAnnotationModeEnabled = false
    /// Live scroll offset estimate in view points; reconciled with the page.
    private var scrollEstimatePoints: CGPoint?
    private var isViewportReconcileInFlight = false
    private var isViewportReconcileQueued = false
    private var outstandingWork = 0

    /// The last payload handed to an agent (automation and tests).
    public private(set) var lastSentPayload: String?
    /// Annotated screenshot paths from the last successful send.
    public private(set) var lastSentScreenshotPaths: [String] = []
    /// Session that received the last successful send.
    public private(set) var lastSentSessionID: String?

    init(runtime: BrowserPanelRuntime, dependencies: Dependencies) {
        self.runtime = runtime
        self.dependencies = dependencies
        observation = runtime.annotationSession.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the change lands.
            self?.scheduleSynchronize()
        }
    }

    // MARK: State

    private var session: WebPanelAnnotationSession? { runtime?.annotationSession }

    public var isAnnotationModeEnabled: Bool { session?.annotationState.isAnnotationModeEnabled ?? false }
    public var draftCount: Int { session?.annotationState.draftCount ?? 0 }
    public var hasDrafts: Bool { session?.annotationState.hasDrafts ?? false }
    public var isSendInFlight: Bool { session?.isAnnotationSendInFlight ?? false }
    public var isEditorActive: Bool { session?.isAnnotationEditorActive ?? false }
    /// Send menus are disabled while sending or while a comment is edited.
    public var isSendDisabled: Bool { hasDrafts == false || isSendInFlight || isEditorActive }
    public var hasPendingDraft: Bool { pendingDraft != nil }
    /// A capture, save, or send is still resolving.
    public var isBusy: Bool { outstandingWork > 0 || isSendInFlight || isResolvingPendingDraft }

    public var notice: LinuxAnnotationNotice? {
        session?.annotationSendNotice.map { LinuxAnnotationNotice(id: $0.id, message: $0.message, isFailure: $0.isFailure) }
    }

    public var popover: LinuxAnnotationPopover? {
        popoverSession.map {
            LinuxAnnotationPopover(id: $0.id, purpose: $0.purpose, number: $0.number, comment: $0.comment, anchorRect: $0.anchorRect)
        }
    }

    /// Text currently typed in the open editor popover.
    public var popoverText: String? { popoverSession?.currentText }

    /// Saved annotations (number order) with their comments, for automation.
    public var annotationSummaries: [(number: Int, comment: String)] {
        (session?.annotationState.sections.flatMap(\.annotations) ?? [])
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
            .map { ($0.sequenceNumber, $0.comment) }
    }

    /// Draft marks projected into the overlay, lowest number first.
    public var marks: [LinuxAnnotationMark] {
        currentDisplayMarks().map { mark in
            let shape: LinuxAnnotationMark.Shape = switch mark.shape {
            case .point(let center): .point(center: center)
            case .rectangle(let rect): .rectangle(rect)
            }
            return LinuxAnnotationMark(
                annotationID: mark.annotationID, number: mark.sequenceNumber, shape: shape,
                bubbleRect: mark.bubbleRect, isHovered: mark.annotationID == hoveredAnnotationID
            )
        }
    }

    /// The mark of the gesture whose comment is being typed.
    public var pendingMark: LinuxAnnotationMark? {
        guard isAnnotationModeEnabled, let draft = pendingDraft else { return nil }
        return LinuxAnnotationMark(
            annotationID: nil, number: draft.sequenceNumber,
            shape: draft.isRectangle ? .rectangle(draft.rectangle) : .point(center: draft.endPoint),
            bubbleRect: draft.bubbleRect, isHovered: false
        )
    }

    /// The rectangle being dragged out right now.
    public var inProgressRectangle: CGRect? {
        guard let start = dragStartPoint, let current = dragCurrentPoint,
              hypot(current.x - start.x, current.y - start.y) > BrowserAnnotationMarkStyle.dragThreshold else {
            return nil
        }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    /// Whether the pointer at `point` is over a mark's bubble (cursor shape).
    public func isOverMark(_ point: CGPoint) -> Bool { displayMark(at: point) != nil }

    // MARK: Mode

    public func setAnnotationModeEnabled(_ isEnabled: Bool) {
        runtime?.setAnnotationModeEnabled(isEnabled)
        synchronizeWithRuntimeState()
    }

    public func toggleAnnotationMode() {
        setAnnotationModeEnabled(isAnnotationModeEnabled == false)
    }

    public func clearAnnotations(exitAnnotationMode: Bool) {
        runtime?.clearAnnotations(exitAnnotationMode: exitAnnotationMode)
        synchronizeWithRuntimeState()
    }

    public func clearNotice(id: UUID) {
        runtime?.clearAnnotationSendNotice(id: id)
    }

    private func scheduleSynchronize() {
        guard notifyScheduled == false else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.notifyScheduled = false
                self.synchronizeWithRuntimeState()
            }
        }
    }

    private func synchronizeWithRuntimeState() {
        let isEnabled = isAnnotationModeEnabled
        if isEnabled != wasAnnotationModeEnabled {
            wasAnnotationModeEnabled = isEnabled
            if isEnabled {
                onRequestFocus?()
                scheduleViewportReconcile()
            } else {
                dragStartPoint = nil
                dragCurrentPoint = nil
                hoveredAnnotationID = nil
                dismissActiveSession(cancelDraft: true)
                // A draft mid-save keeps resolving (the user committed it);
                // anything else is orphaned once the mode closes.
                if isResolvingPendingDraft == false { cancelPendingDraft() }
                scrollEstimatePoints = nil
            }
        }
        if let session = popoverSession, let annotationID = Self.annotationID(of: session.purpose),
           runtime?.annotationState.annotationItem(withID: annotationID) == nil {
            dismissActiveSession(cancelDraft: false)
        }
        changed()
    }

    private func changed() {
        onChange?()
    }

    // MARK: Pointer input (overlay coordinates, top-left origin)

    /// Primary button pressed. Returns whether the overlay handled it.
    @discardableResult
    public func pointerPressed(at rawPoint: CGPoint) -> Bool {
        guard let runtime, runtime.annotationState.isAnnotationModeEnabled, runtime.isAnnotationSendInFlight == false else {
            return false
        }
        if popoverSession != nil {
            resolveActiveSessionFromClickAway()
            return true
        }
        guard pendingDraft == nil else { return true }
        let point = clampedPoint(rawPoint)
        if let mark = displayMark(at: point) {
            openDetailPopover(annotationID: mark.annotationID, anchorRect: mark.bubbleRect)
            return true
        }
        dragStartPoint = point
        dragCurrentPoint = point
        changed()
        return true
    }

    public func pointerDragged(to point: CGPoint) {
        guard dragStartPoint != nil else { return }
        dragCurrentPoint = clampedPoint(point)
        changed()
    }

    public func pointerReleased(at point: CGPoint) {
        guard let startPoint = dragStartPoint, isAnnotationModeEnabled else { return }
        let endPoint = clampedPoint(point)
        dragStartPoint = nil
        dragCurrentPoint = nil
        beginDraft(startPoint: startPoint, endPoint: endPoint)
        changed()
    }

    public func pointerMoved(to point: CGPoint) {
        guard isAnnotationModeEnabled else { return }
        let hitID = displayMark(at: point)?.annotationID
        guard hitID != hoveredAnnotationID else { return }
        hoveredAnnotationID = hitID
        changed()
    }

    public func pointerLeft() {
        guard hoveredAnnotationID != nil else { return }
        hoveredAnnotationID = nil
        changed()
    }

    /// A scroll over the overlay. Returns whether the page should scroll
    /// (the overlay then scrolls it and calls `pageDidScroll()`): the page
    /// stays frozen while a comment is composed so the popover keeps its mark.
    public func shouldScrollPage(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        if popoverSession?.isEditing == true || pendingDraft != nil { return false }
        if popoverSession != nil { dismissActiveSession(cancelDraft: false) }
        if var estimate = scrollEstimatePoints {
            estimate.x = max(0, estimate.x + deltaX)
            estimate.y = max(0, estimate.y + deltaY)
            scrollEstimatePoints = estimate
            changed()
        }
        return true
    }

    /// The page scrolled (by the overlay, a key, or the page itself):
    /// re-read the real offset.
    public func pageDidScroll() {
        scheduleViewportReconcile()
    }

    /// Escape: cancels a drag, then a popover, then leaves annotation mode.
    @discardableResult
    public func escapePressed() -> Bool {
        guard isAnnotationModeEnabled else { return false }
        if dragStartPoint != nil {
            dragStartPoint = nil
            dragCurrentPoint = nil
            changed()
        } else if popoverSession != nil {
            dismissActiveSession(cancelDraft: true)
        } else {
            setAnnotationModeEnabled(false)
        }
        return true
    }

    // MARK: Popover input

    public func popoverTextChanged(_ text: String) {
        popoverSession?.currentText = text
    }

    /// Add / Save (Enter): commits a non-empty comment.
    public func savePopover(text: String) {
        guard let session = popoverSession else { return }
        let comment = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard comment.isEmpty == false else { return }
        switch session.purpose {
        case .create:
            dismissActiveSession(cancelDraft: false)
            resolvePendingDraft(comment: comment)
        case .edit(let annotationID):
            dismissActiveSession(cancelDraft: false)
            runtime?.updateAnnotationComment(annotationID: annotationID, comment: comment)
        case .view:
            dismissActiveSession(cancelDraft: false)
        }
        changed()
    }

    /// Escape / Cancel in the popover.
    public func cancelPopover() {
        guard popoverSession != nil else { return }
        dismissActiveSession(cancelDraft: true)
        changed()
    }

    /// Edit in the detail popover.
    public func editFromDetailPopover() {
        guard let session = popoverSession, case .view(let annotationID) = session.purpose else { return }
        dismissActiveSession(cancelDraft: false)
        openEditPopover(annotationID: annotationID, anchorRect: session.anchorRect)
    }

    /// Delete in the edit/detail popover.
    public func deletePopoverAnnotation() {
        guard let session = popoverSession, let annotationID = Self.annotationID(of: session.purpose) else { return }
        dismissActiveSession(cancelDraft: false)
        runtime?.removeAnnotation(annotationID: annotationID)
        changed()
    }

    /// The popover closed on its own (outside click while it holds the
    /// pointer grab): same as macOS's click on the overlay — non-empty
    /// editors commit, empty editors and detail popovers just close.
    public func popoverDismissedByOutsideClick() {
        resolveActiveSessionFromClickAway()
    }

    // MARK: Sending

    public var sendCandidates: [LinuxAnnotationSendCandidate] {
        dependencies.candidates().map { candidate in
            LinuxAnnotationSendCandidate(
                sessionID: candidate.sessionID, panelID: candidate.panelID, label: candidate.label,
                blockedReason: dependencies.availability(candidate).blockedReason
            )
        }
    }

    /// Renders, writes and sends the drafts to `sessionID` (macOS
    /// `BrowserAnnotationSendFlow`). Returns false when the session is not a
    /// candidate.
    @discardableResult
    public func send(toSessionID sessionID: String) -> Bool {
        guard let runtime, let candidate = dependencies.candidates().first(where: { $0.sessionID == sessionID }) else {
            return false
        }
        let sendPayload = dependencies.sendPayload
        BrowserAnnotationSendFlow.send(
            runtime: runtime,
            candidate: candidate,
            availability: dependencies.availability,
            sendPayload: { [weak self] payload, candidate in
                let sent = sendPayload(payload, candidate)
                if sent, let self {
                    self.lastSentPayload = payload
                    self.lastSentSessionID = candidate.sessionID
                    self.lastSentScreenshotPaths = payload.split(separator: "\n")
                        .compactMap { line -> String? in
                            guard line.hasPrefix("Screenshot "), let colon = line.range(of: ": ") else { return nil }
                            return String(line[colon.upperBound...])
                        }
                }
                return sent
            }
        )
        changed()
        return true
    }

    // MARK: Draft lifecycle (BrowserAnnotationOverlayNSView)

    private func beginDraft(startPoint: CGPoint, endPoint: CGPoint) {
        guard let runtime, pendingDraft == nil, popoverSession == nil else { return }
        let captureTask = Task { @MainActor [weak runtime] () throws -> BrowserAnnotationCapturedSection in
            guard let runtime else { throw CancellationError() }
            return try await runtime.captureAnnotationSection()
        }
        let draft = PendingDraft(
            startPoint: startPoint, endPoint: endPoint, overlaySize: overlaySize,
            sequenceNumber: runtime.annotationState.nextSequenceNumber,
            pageGeneration: runtime.currentAnnotationPageGeneration(),
            captureTask: captureTask
        )
        pendingDraft = draft
        popoverSession = PopoverSession(
            purpose: .create, number: draft.sequenceNumber, comment: "", anchorRect: draft.bubbleRect, currentText: ""
        )
        runtime.setAnnotationEditorActive(true)
    }

    private func resolvePendingDraft(comment: String) {
        guard let draft = pendingDraft, let runtime else {
            pendingDraft = nil
            return
        }
        isResolvingPendingDraft = true
        outstandingWork += 1
        Task { @MainActor [weak self] in
            defer {
                if let self {
                    self.isResolvingPendingDraft = false
                    self.pendingDraft = nil
                    self.outstandingWork -= 1
                    self.changed()
                }
            }
            do {
                let section = try await draft.captureTask.value
                guard runtime.currentAnnotationPageGeneration() == draft.pageGeneration else { return }
                let kind = BrowserAnnotationDisplayGeometry.annotationKind(
                    startPoint: draft.startPoint,
                    endPoint: draft.endPoint,
                    overlaySize: draft.overlaySize,
                    viewportSize: section.viewportSize
                )
                runtime.recordAnnotation(in: section, kind: kind, comment: comment)
                let zoom = runtime.annotationDisplayZoom
                self?.scrollEstimatePoints = CGPoint(x: section.scrollOffset.x * zoom, y: section.scrollOffset.y * zoom)
            } catch {
                runtime.postAnnotationSendNotice(message: "Couldn't capture the page — annotation discarded", isFailure: true)
                NSLog("Browser annotation capture failed: %@", error.localizedDescription)
            }
        }
    }

    private func cancelPendingDraft() {
        pendingDraft?.captureTask.cancel()
        pendingDraft = nil
    }

    private func openEditPopover(annotationID: UUID, anchorRect: CGRect) {
        guard let runtime, let item = runtime.annotationState.annotationItem(withID: annotationID) else { return }
        popoverSession = PopoverSession(
            purpose: .edit(annotationID: annotationID), number: item.sequenceNumber, comment: item.comment,
            anchorRect: anchorRect, currentText: item.comment
        )
        runtime.setAnnotationEditorActive(true)
        changed()
    }

    private func openDetailPopover(annotationID: UUID, anchorRect: CGRect) {
        guard let runtime, let item = runtime.annotationState.annotationItem(withID: annotationID) else { return }
        popoverSession = PopoverSession(
            purpose: .view(annotationID: annotationID), number: item.sequenceNumber, comment: item.comment,
            anchorRect: anchorRect, currentText: item.comment
        )
        changed()
    }

    private func dismissActiveSession(cancelDraft: Bool) {
        guard let session = popoverSession else { return }
        popoverSession = nil
        if cancelDraft, case .create = session.purpose { cancelPendingDraft() }
        runtime?.setAnnotationEditorActive(false)
    }

    private func resolveActiveSessionFromClickAway() {
        guard let session = popoverSession else { return }
        let comment = session.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch session.purpose {
        case .view:
            dismissActiveSession(cancelDraft: false)
        case .create:
            if comment.isEmpty {
                dismissActiveSession(cancelDraft: true)
            } else {
                dismissActiveSession(cancelDraft: false)
                resolvePendingDraft(comment: comment)
            }
        case .edit(let annotationID):
            dismissActiveSession(cancelDraft: false)
            if comment.isEmpty == false {
                runtime?.updateAnnotationComment(annotationID: annotationID, comment: comment)
            }
        }
        changed()
    }

    // MARK: Geometry

    private func displayMark(at point: CGPoint) -> BrowserAnnotationDisplayMark? {
        // Highest numbers draw last (on top), so search from the end.
        currentDisplayMarks().reversed().first { $0.bubbleRect.contains(point) }
    }

    private func currentDisplayMarks() -> [BrowserAnnotationDisplayMark] {
        guard let runtime, runtime.annotationState.isAnnotationModeEnabled, let scrollEstimatePoints else { return [] }
        return BrowserAnnotationDisplayGeometry.displayMarks(
            sections: runtime.annotationState.sections,
            currentScrollOffsetPoints: scrollEstimatePoints,
            pageZoom: runtime.annotationDisplayZoom,
            overlayBounds: CGRect(origin: .zero, size: overlaySize)
        )
    }

    private func scheduleViewportReconcile() {
        guard isViewportReconcileInFlight == false else {
            isViewportReconcileQueued = true
            return
        }
        isViewportReconcileInFlight = true
        outstandingWork += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.outstandingWork -= 1 }
            guard let runtime = self.runtime else {
                self.isViewportReconcileInFlight = false
                return
            }
            let viewport = await runtime.currentAnnotationViewport()
            let zoom = runtime.annotationDisplayZoom
            if runtime.annotationState.isAnnotationModeEnabled {
                self.scrollEstimatePoints = CGPoint(x: viewport.scrollOffset.x * zoom, y: viewport.scrollOffset.y * zoom)
            }
            self.isViewportReconcileInFlight = false
            self.changed()
            if self.isViewportReconcileQueued {
                self.isViewportReconcileQueued = false
                self.scheduleViewportReconcile()
            }
        }
    }

    private func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), overlaySize.width), y: min(max(point.y, 0), overlaySize.height))
    }

    private static func annotationID(of purpose: LinuxAnnotationPopover.Purpose) -> UUID? {
        switch purpose {
        case .create: nil
        case .edit(let annotationID), .view(let annotationID): annotationID
        }
    }
}
