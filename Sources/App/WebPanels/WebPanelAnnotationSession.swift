import AppKit
import Combine

enum WebPanelAnnotationSource: String {
    case browser
    case scratchpad

    var label: String {
        switch self {
        case .browser: "Browser"
        case .scratchpad: "Scratchpad"
        }
    }

    var annotateLabel: String {
        switch self {
        case .browser: "Annotate Browser Page"
        case .scratchpad: "Annotate Scratchpad"
        }
    }

    var unavailableHelp: String {
        switch self {
        case .browser: "Load a page to annotate it"
        case .scratchpad: "Publish Scratchpad content to annotate it"
        }
    }
}

@MainActor
protocol WebPanelAnnotationRuntime: AnyObject, ObservableObject {
    var annotationSession: WebPanelAnnotationSession { get }
    var annotationSource: WebPanelAnnotationSource { get }
    var annotationDisplayZoom: CGFloat { get }
    func currentAnnotationViewport() async -> BrowserAnnotationViewport
    func captureAnnotationSection(capturedAt: Date) async throws -> BrowserAnnotationCapturedSection
}

extension WebPanelAnnotationRuntime {
    var annotationState: BrowserAnnotationDraftState { annotationSession.annotationState }
    var annotationSendNotice: BrowserAnnotationSendNotice? { annotationSession.annotationSendNotice }
    var isAnnotationEditorActive: Bool { annotationSession.isAnnotationEditorActive }
    var isAnnotationSendInFlight: Bool { annotationSession.isAnnotationSendInFlight }

    func setAnnotationModeEnabled(_ isEnabled: Bool) {
        annotationSession.setAnnotationModeEnabled(isEnabled)
    }

    func clearAnnotations(exitAnnotationMode: Bool = true) {
        annotationSession.clearAnnotations(exitAnnotationMode: exitAnnotationMode)
    }

    @discardableResult
    func removeAnnotation(annotationID: UUID) -> Bool {
        annotationSession.removeAnnotation(annotationID: annotationID)
    }

    @discardableResult
    func updateAnnotationComment(annotationID: UUID, comment: String) -> Bool {
        annotationSession.updateAnnotationComment(annotationID: annotationID, comment: comment)
    }

    func setAnnotationEditorActive(_ isActive: Bool) {
        annotationSession.setAnnotationEditorActive(isActive)
    }

    func setAnnotationSendInFlight(_ inFlight: Bool) {
        annotationSession.setAnnotationSendInFlight(inFlight)
    }

    func postAnnotationSendNotice(message: String, isFailure: Bool) {
        annotationSession.postAnnotationSendNotice(message: message, isFailure: isFailure)
    }

    func clearAnnotationSendNotice(id: UUID) {
        annotationSession.clearAnnotationSendNotice(id: id)
    }

    func currentAnnotationPageGeneration() -> Int {
        annotationSession.contentGeneration
    }

    func captureAnnotationSection() async throws -> BrowserAnnotationCapturedSection {
        try await captureAnnotationSection(capturedAt: Date())
    }

    @discardableResult
    func recordAnnotation(
        in capturedSection: BrowserAnnotationCapturedSection,
        kind: BrowserAnnotationKind,
        comment: String,
        createdAt: Date = Date()
    ) -> BrowserAnnotationItem {
        annotationSession.recordAnnotation(
            in: capturedSection,
            kind: kind,
            comment: comment,
            createdAt: createdAt
        )
    }
}

/// Drafts and editor state follow the content displayed by one web panel.
/// Runtime owners forward objectWillChange so their SwiftUI surfaces update.
@MainActor
final class WebPanelAnnotationSession: ObservableObject {
    @Published private(set) var annotationState = BrowserAnnotationDraftState()
    @Published private(set) var annotationSendNotice: BrowserAnnotationSendNotice?
    @Published private(set) var isAnnotationEditorActive = false
    @Published private(set) var isAnnotationSendInFlight = false
    private(set) var contentGeneration = 0

    func setAnnotationModeEnabled(_ isEnabled: Bool) {
        guard annotationState.isAnnotationModeEnabled != isEnabled else { return }
        annotationState.isAnnotationModeEnabled = isEnabled
        if isEnabled == false {
            isAnnotationEditorActive = false
        }
    }

    func clearAnnotations(exitAnnotationMode: Bool = true) {
        // A clear must also invalidate a committed capture still resolving.
        contentGeneration &+= 1
        guard annotationState.hasDrafts || annotationState.isAnnotationModeEnabled else { return }
        annotationState.clear(exitAnnotationMode: exitAnnotationMode)
        if exitAnnotationMode {
            isAnnotationEditorActive = false
        }
    }

    func invalidateForContentChange() {
        contentGeneration &+= 1
        if annotationState.hasDrafts || annotationState.isAnnotationModeEnabled {
            annotationState.clear(exitAnnotationMode: true)
        }
        isAnnotationEditorActive = false
        annotationSendNotice = nil
    }

    @discardableResult
    func removeAnnotation(annotationID: UUID) -> Bool {
        annotationState.removeAnnotation(annotationID: annotationID)
    }

    @discardableResult
    func updateAnnotationComment(annotationID: UUID, comment: String) -> Bool {
        annotationState.updateAnnotationComment(annotationID: annotationID, comment: comment)
    }

    func setAnnotationEditorActive(_ isActive: Bool) {
        guard isAnnotationEditorActive != isActive else { return }
        isAnnotationEditorActive = isActive
    }

    func setAnnotationSendInFlight(_ inFlight: Bool) {
        guard isAnnotationSendInFlight != inFlight else { return }
        isAnnotationSendInFlight = inFlight
    }

    func postAnnotationSendNotice(message: String, isFailure: Bool) {
        annotationSendNotice = BrowserAnnotationSendNotice(id: UUID(), message: message, isFailure: isFailure)
    }

    func clearAnnotationSendNotice(id: UUID) {
        guard annotationSendNotice?.id == id else { return }
        annotationSendNotice = nil
    }

    @discardableResult
    func recordAnnotation(
        in capturedSection: BrowserAnnotationCapturedSection,
        kind: BrowserAnnotationKind,
        comment: String,
        createdAt: Date = Date()
    ) -> BrowserAnnotationItem {
        annotationState.recordAnnotation(in: capturedSection, kind: kind, comment: comment, createdAt: createdAt)
    }
}
