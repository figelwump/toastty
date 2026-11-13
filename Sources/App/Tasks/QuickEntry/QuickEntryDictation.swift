import Foundation

/// What a dictation session reports, on the main actor.
enum QuickEntryDictationEvent: Equatable, Sendable {
    /// The microphone is on.
    case listening
    /// The speech model downloads first. The words come when it is done.
    case downloadingModel
    /// The words of the sentence in progress. They can still change, and
    /// each event replaces the one before.
    case volatile(String)
    /// Words that no longer change. They take the place of the volatile
    /// words.
    case final(String)
    /// The session is over. `error` says why, when `stop()` did not end it.
    case ended(error: String?)
}

/// Turns speech into text for the quick entry panel, one session at a time.
@MainActor
protocol QuickEntryDictationEngine: AnyObject {
    /// Starts a session. Events arrive until `.ended`.
    func start(onEvent: @escaping @MainActor (QuickEntryDictationEvent) -> Void)
    /// Turns the microphone off. The last words still arrive, then `.ended`.
    func stop()
    /// Ends the session at once. No further event arrives.
    func cancel()
}

enum QuickEntryDictation {
    /// The setting "Dictate on open": the panel listens each time it opens.
    static let dictatesOnOpenDefaultsKey = "toastty.quickEntry.dictatesOnOpen"

    /// How long the quick entry shortcut stays down before it counts as
    /// held, which starts dictation until the key is released.
    static let holdDuration: Duration = .milliseconds(350)

    /// The engine that runs on this Mac, or `nil` before macOS 26, which
    /// has no speech recognition that an app can run on the device with
    /// live results.
    @MainActor
    static func makeSystemEngine() -> (any QuickEntryDictationEngine)? {
        if #available(macOS 26.0, *) {
            return SpeechAnalyzerDictationEngine()
        }
        return nil
    }

    /// Dictated words as they go into a text, between the character before
    /// the caret and the one after it. The recognizer starts each sentence
    /// after the first with a space; the text may or may not have one.
    static func insertion(of words: String, before: Character?, after: Character?) -> String {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }
        let leading = before.map { $0.isWhitespace || $0.isNewline } ?? true ? "" : " "
        let trailing = after.map { $0.isWhitespace || $0.isNewline || $0.isPunctuation } ?? true ? "" : " "
        return leading + trimmed + trailing
    }
}
