#if DEBUG
import UIKit

// Temporary diagnostics for the fast-typing underline investigation. Keep this
// separate from observable app state and from system connection logging.
@MainActor
final class ToasttyComposerTrace {
    static let shared: ToasttyComposerTrace? = isEnabled(
        environment: ProcessInfo.processInfo.environment,
        infoDictionary: Bundle.main.infoDictionary ?? [:]
    ) ? ToasttyComposerTrace() : nil

    enum Event: String, Codable {
        case created, dismantled, synchronized, textChanged, selectionChanged
        case focusBegan, focusEnded, unmarkTextCalled, measured, laidOut
        case scrollingChanged, selectionRevealed, offsetNormalized
        case replacementReceived, replacementDeferred, replacementApplied, replacementUnchanged, replacementRejected
        case screenshot
    }

    struct TraceRange: Codable, Equatable {
        let location: Int
        let length: Int

        init(_ range: NSRange) {
            location = range.location == NSNotFound ? -1 : range.location
            length = range.length
        }
    }

    struct Geometry: Codable {
        let width: Double?
        let height: Double?
        let contentWidth: Double?
        let contentHeight: Double?
        let offsetX: Double?
        let offsetY: Double?

        init(_ view: UITextView) {
            width = Self.finite(view.bounds.width)
            height = Self.finite(view.bounds.height)
            contentWidth = Self.finite(view.contentSize.width)
            contentHeight = Self.finite(view.contentSize.height)
            offsetX = Self.finite(view.contentOffset.x)
            offsetY = Self.finite(view.contentOffset.y)
        }

        static func finite(_ value: CGFloat) -> Double? {
            value.isFinite ? Double(value) : nil
        }
    }

    struct Measurement: Codable {
        let width: Double?
        let naturalHeight: Double?
        let fittedHeight: Double?
        let maximumHeight: Double?

        init(width: CGFloat, naturalHeight: CGFloat, fittedHeight: CGFloat, maximumHeight: CGFloat) {
            self.width = Geometry.finite(width)
            self.naturalHeight = Geometry.finite(naturalHeight)
            self.fittedHeight = Geometry.finite(fittedHeight)
            self.maximumHeight = Geometry.finite(maximumHeight)
        }
    }

    struct Entry: Codable {
        let sequence: UInt64
        let elapsedMilliseconds: UInt64
        let composerID: UInt64
        let event: Event
        let textLength: Int
        let selectedRange: TraceRange
        let markedRange: TraceRange?
        let isFirstResponder: Bool
        let isScrollEnabled: Bool
        let usesTextKit2: Bool
        let replacementLength: Int?
        let editRevision: UInt64?
        let replacementRevision: UInt64?
        let expectedEditRevision: UInt64?
        let geometry: Geometry?
        let measurement: Measurement?
        let requestedOffsetY: Double?
    }

    struct UnderlineRun: Codable {
        let range: TraceRange
        let style: Int?
        let hasStyle: Bool
        let hasColor: Bool
    }

    struct DecorationSnapshot: Codable {
        let sequence: UInt64
        let composerID: UInt64
        let runs: [UnderlineRun]
        let runsTruncated: Bool
        let typingHasUnderlineStyle: Bool
        let typingHasUnderlineColor: Bool
        let autocorrectionType: Int
        let spellCheckingType: Int
        let inlinePredictionType: Int
        let smartQuotesType: Int
        let smartDashesType: Int
        let smartInsertDeleteType: Int
    }

    struct Snapshot: Codable {
        let schemaVersion: Int
        let capturedAt: Date
        let elapsedMillisecondsAtCapture: UInt64
        let appVersion: String
        let appBuild: String
        let operatingSystemVersion: String
        let capacity: Int
        let droppedEntryCount: UInt64
        let entries: [Entry]
        let decorations: [DecorationSnapshot]

        func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(self)
        }
    }

    private let capacity: Int
    private let uptime: () -> TimeInterval
    private let startUptime: TimeInterval
    private var buffer: [Entry?]
    private var nextIndex = 0
    private var count = 0
    private var nextSequence: UInt64 = 1
    private var nextComposerID: UInt64 = 1
    private var decorations: [DecorationSnapshot] = []

    init(capacity: Int = 32_768, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.capacity = max(1, capacity)
        self.uptime = uptime
        startUptime = uptime()
        buffer = Array(repeating: nil, count: self.capacity)
    }

    static func isEnabled(environment: [String: String], infoDictionary: [String: Any]) -> Bool {
        if let override = environment["TOASTTY_MOBILE_COMPOSER_TRACE"] {
            return override == "1"
        }
        // Generated build-setting substitutions are plist strings.
        return infoDictionary["ToasttyComposerTraceEnabled"] as? String == "YES"
    }

    func newComposerID() -> UInt64 {
        defer { nextComposerID += 1 }
        return nextComposerID
    }

    func record(
        _ event: Event, in view: UITextView, composerID: UInt64,
        replacementLength: Int? = nil,
        editRevision: UInt64? = nil, replacementRevision: UInt64? = nil,
        expectedEditRevision: UInt64? = nil, measurement: Measurement? = nil,
        requestedOffsetY: CGFloat? = nil
    ) {
        let markedRange = view.markedTextRange.map { range in
            TraceRange(NSRange(
                location: view.offset(from: view.beginningOfDocument, to: range.start),
                length: view.offset(from: range.start, to: range.end)
            ))
        }
        let includesGeometry: Bool
        switch event {
        case .created, .dismantled, .measured, .laidOut, .scrollingChanged,
             .selectionRevealed, .offsetNormalized, .screenshot:
            includesGeometry = true
        case .synchronized, .textChanged, .selectionChanged, .focusBegan, .focusEnded, .unmarkTextCalled,
             .replacementReceived, .replacementDeferred, .replacementApplied, .replacementUnchanged, .replacementRejected:
            includesGeometry = false
        }
        let sequence = nextSequence
        buffer[nextIndex] = Entry(
            sequence: sequence,
            elapsedMilliseconds: UInt64(max(0, (uptime() - startUptime) * 1_000)),
            composerID: composerID, event: event, textLength: view.textStorage.length,
            selectedRange: TraceRange(view.selectedRange), markedRange: markedRange,
            isFirstResponder: view.isFirstResponder, isScrollEnabled: view.isScrollEnabled,
            usesTextKit2: view.textLayoutManager != nil,
            replacementLength: replacementLength,
            editRevision: editRevision, replacementRevision: replacementRevision,
            expectedEditRevision: expectedEditRevision,
            geometry: includesGeometry ? Geometry(view) : nil, measurement: measurement,
            requestedOffsetY: requestedOffsetY.flatMap(Geometry.finite)
        )
        nextIndex = (nextIndex + 1) % capacity
        count = min(count + 1, capacity)
        nextSequence += 1
        if event == .created || event == .screenshot || event == .dismantled {
            captureDecorations(in: view, composerID: composerID, sequence: sequence)
        }
    }

    func snapshot(capturedAt: Date = Date()) -> Snapshot {
        let firstIndex = (nextIndex - count + capacity) % capacity
        let entries = (0..<count).compactMap { buffer[(firstIndex + $0) % capacity] }
        let oldestSequence = entries.first?.sequence ?? nextSequence
        return Snapshot(
            schemaVersion: 1, capturedAt: capturedAt,
            elapsedMillisecondsAtCapture: UInt64(max(0, (uptime() - startUptime) * 1_000)),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            capacity: capacity, droppedEntryCount: nextSequence - 1 - UInt64(count),
            entries: entries, decorations: decorations.filter { $0.sequence >= oldestSequence }
        )
    }

    private func captureDecorations(in view: UITextView, composerID: UInt64, sequence: UInt64) {
        var runs: [UnderlineRun] = []
        var truncated = false
        // Only copy numeric ranges and the underline style. Never serialize an
        // attribute dictionary, an attributed string, or a color description.
        view.textStorage.enumerateAttributes(in: NSRange(location: 0, length: view.textStorage.length)) { attributes, range, stop in
            guard attributes[.underlineStyle] != nil || attributes[.underlineColor] != nil else { return }
            guard runs.count < 64 else {
                truncated = true
                stop.pointee = true
                return
            }
            runs.append(UnderlineRun(
                range: TraceRange(range), style: (attributes[.underlineStyle] as? NSNumber)?.intValue,
                hasStyle: attributes[.underlineStyle] != nil,
                hasColor: attributes[.underlineColor] != nil
            ))
        }
        decorations.append(DecorationSnapshot(
            sequence: sequence, composerID: composerID, runs: runs, runsTruncated: truncated,
            typingHasUnderlineStyle: view.typingAttributes[.underlineStyle] != nil,
            typingHasUnderlineColor: view.typingAttributes[.underlineColor] != nil,
            autocorrectionType: view.autocorrectionType.rawValue,
            spellCheckingType: view.spellCheckingType.rawValue,
            inlinePredictionType: view.inlinePredictionType.rawValue,
            smartQuotesType: view.smartQuotesType.rawValue,
            smartDashesType: view.smartDashesType.rawValue,
            smartInsertDeleteType: view.smartInsertDeleteType.rawValue
        ))
        if decorations.count > 16 { decorations.removeFirst() }
    }
}

extension ToasttyComposerUIKitTextView {
    func traceTyping(
        _ event: ToasttyComposerTrace.Event,
        replacementLength: Int? = nil, editRevision: UInt64? = nil,
        replacementRevision: UInt64? = nil, expectedEditRevision: UInt64? = nil,
        measurement: ToasttyComposerTrace.Measurement? = nil, requestedOffsetY: CGFloat? = nil
    ) {
        guard let typingTrace else { return }
        typingTrace.record(
            event, in: self, composerID: typingTraceInstanceID,
            replacementLength: replacementLength,
            editRevision: editRevision, replacementRevision: replacementRevision,
            expectedEditRevision: expectedEditRevision,
            measurement: measurement, requestedOffsetY: requestedOffsetY
        )
    }
}
#endif
