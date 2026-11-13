import AppKit
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// A speech engine that says what a test tells it to.
@MainActor
final class FakeDictationEngine: QuickEntryDictationEngine {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private var onEvent: (@MainActor (QuickEntryDictationEvent) -> Void)?
    /// What the recognizer still reports after the microphone goes off.
    var eventsAfterStop: [QuickEntryDictationEvent] = []
    /// False keeps the session open after `stop()`, until `finish()`.
    var finishesOnStop = true

    var isRunning: Bool { onEvent != nil }

    func start(onEvent: @escaping @MainActor (QuickEntryDictationEvent) -> Void) {
        startCount += 1
        self.onEvent = onEvent
    }

    func stop() {
        stopCount += 1
        if finishesOnStop { finish() }
    }

    func cancel() {
        cancelCount += 1
        onEvent = nil
    }

    func send(_ event: QuickEntryDictationEvent) {
        onEvent?(event)
    }

    func finish(error: String? = nil) {
        eventsAfterStop.forEach(send)
        eventsAfterStop = []
        let onEvent = self.onEvent
        self.onEvent = nil
        onEvent?(.ended(error: error))
    }
}

/// Dictation in the quick entry panel, driven as a user drives it: the
/// shortcut's press and release, the panel's keys and its text view. The
/// speech engine is a fake; the panel, its model and its text view are
/// real.
@MainActor
struct QuickEntryDictationTests {
    private static let hold: Duration = .milliseconds(60)

    private func harness(
        _ engine: FakeDictationEngine?,
        defaults: UserDefaults? = nil
    ) throws -> QuickEntryTests.Harness {
        try QuickEntryTests.Harness(
            dictationEngine: engine,
            dictationDefaults: defaults,
            dictationHoldDuration: Self.hold
        )
    }

    private func scratchDefaults() throws -> (UserDefaults, String) {
        let name = "toastty-quick-entry-dictation-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    // MARK: - Dictate on open is off: hold to talk

    @Test func aTapOfTheShortcutOpensThePanelForTyping() async throws {
        let engine = FakeDictationEngine()
        let harness = try harness(engine)
        harness.controller.handleHotKeyPress()
        harness.controller.handleHotKeyRelease()
        let model = try #require(harness.controller.model)
        #expect(model.canDictate)
        // Longer than a hold: the key is up, so nothing listens.
        try await Task.sleep(for: Self.hold * 3)
        #expect(engine.startCount == 0)
        #expect(model.isDictating == false)
        #expect(model.dictationStatus == nil)
        harness.controller.dismiss()
    }

    @Test func holdingTheShortcutDictatesUntilItsRelease() async throws {
        let engine = FakeDictationEngine()
        let harness = try harness(engine)
        harness.controller.handleHotKeyPress()
        let model = try #require(harness.controller.model)
        #expect(engine.startCount == 0, "A press alone opens the panel")
        await harness.fixture.waitUntil("the hold starts dictation") { engine.startCount == 1 }
        #expect(model.dictationPhase == .starting)
        #expect(model.dictationStatus == "Starting dictation…")

        engine.send(.listening)
        #expect(model.dictationPhase == .listening)
        #expect(model.dictationStatus == "Listening…")
        // The words in progress show on the status line, not in the text.
        engine.send(.volatile("The unread dot"))
        engine.send(.volatile("The unread dot stays on"))
        #expect(model.dictationStatus == "The unread dot stays on")
        #expect(model.text.isEmpty)
        #expect(model.canSubmit, "Send is on while words are on their way")
        // A finished sentence goes into the text.
        engine.send(.final("The unread dot stays on."))
        #expect(model.text == "The unread dot stays on.")
        #expect(model.dictationStatus == "Listening…")
        engine.send(.volatile(" Check the"))

        // The release turns the microphone off. The last words still come.
        engine.eventsAfterStop = [.final(" Check the dock.")]
        harness.controller.handleHotKeyRelease()
        #expect(engine.stopCount == 1)
        #expect(model.isDictating == false)
        #expect(model.text == "The unread dot stays on. Check the dock.")
        #expect(harness.controller.isPresented, "The text stays for the user to correct")
        harness.controller.dismiss()
    }

    @Test func aHeldKeyThatRepeatsDoesNotStartAgain() async throws {
        let engine = FakeDictationEngine()
        let harness = try harness(engine)
        harness.controller.handleHotKeyPress()
        await harness.fixture.waitUntil("the hold starts dictation") { engine.startCount == 1 }
        engine.send(.listening)
        harness.controller.handleHotKeyPress()
        harness.controller.handleHotKeyPress()
        try await Task.sleep(for: Self.hold * 2)
        #expect(engine.startCount == 1)
        #expect(engine.stopCount == 0)
        harness.controller.handleHotKeyRelease()
        #expect(engine.stopCount == 1)
        harness.controller.dismiss()
    }

    @Test func afterALostReleaseTheNextPressAndReleaseStillStopTheMicrophone() async throws {
        let engine = FakeDictationEngine()
        let harness = try harness(engine)
        harness.controller.handleHotKeyPress()
        await harness.fixture.waitUntil("the hold starts dictation") { engine.startCount == 1 }
        engine.send(.listening)
        // The release never arrives. Later the user holds the key again.
        try await Task.sleep(for: .milliseconds(1100))
        harness.controller.handleHotKeyPress()
        try await Task.sleep(for: Self.hold * 3)
        #expect(engine.startCount == 1)
        #expect(engine.stopCount == 0)
        harness.controller.handleHotKeyRelease()
        #expect(engine.stopCount == 1, "The key that started dictation stops it")
        #expect(harness.controller.model?.isDictating == false)
        harness.controller.dismiss()
    }

    @Test func holdingTheShortcutLeavesTheButtonsDictationAlone() async throws {
        let engine = FakeDictationEngine()
        let harness = try harness(engine)
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        model.toggleDictation()
        engine.send(.listening)

        harness.controller.handleHotKeyPress()
        try await Task.sleep(for: Self.hold * 3)
        harness.controller.handleHotKeyRelease()
        #expect(engine.startCount == 1)
        #expect(engine.stopCount == 0, "The button started it, so the button stops it")
        #expect(model.dictationPhase == .listening)
        model.toggleDictation()
        #expect(engine.stopCount == 1)
        #expect(model.isDictating == false)
        harness.controller.dismiss()
    }

    // MARK: - Dictate on open is on: press to talk, press to stop

    @Test func withDictateOnOpenTheShortcutOpensListeningAndThenStopsAndStarts() async throws {
        let (defaults, suite) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: QuickEntryDictation.dictatesOnOpenDefaultsKey)
        let engine = FakeDictationEngine()
        let harness = try harness(engine, defaults: defaults)
        #expect(harness.controller.dictatesOnOpen)

        harness.controller.handleHotKeyPress()
        harness.controller.handleHotKeyRelease()
        let model = try #require(harness.controller.model)
        #expect(model.dictatesOnOpen)
        #expect(engine.startCount == 1, "No hold is needed")
        engine.send(.listening)
        engine.send(.final("Fix the unread dot."))
        #expect(model.text == "Fix the unread dot.")

        // The shortcut again stops, with the panel and its text in place.
        harness.controller.handleHotKeyPress()
        harness.controller.handleHotKeyRelease()
        #expect(engine.stopCount == 1)
        #expect(model.isDictating == false)
        #expect(harness.controller.model === model)
        #expect(model.text == "Fix the unread dot.")

        // And once more starts again: the new words follow the old ones.
        harness.controller.handleHotKeyPress()
        harness.controller.handleHotKeyRelease()
        #expect(engine.startCount == 2)
        engine.send(.listening)
        engine.send(.final("It is in the dock."))
        #expect(model.text == "Fix the unread dot. It is in the dock.")
        harness.controller.dismiss()
        #expect(engine.cancelCount == 1, "Closing the panel turns the microphone off")
    }

    @Test func thePanelsSettingIsSavedAndTheNextPanelFollowsIt() async throws {
        let (defaults, suite) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = FakeDictationEngine()
        let first = try harness(engine, defaults: defaults)
        first.controller.present(prefill: .empty)
        let model = try #require(first.controller.model)
        #expect(model.dictatesOnOpen == false)
        #expect(engine.startCount == 0)
        // The user turns "on open" on in the panel.
        model.dictatesOnOpen = true
        #expect(defaults.bool(forKey: QuickEntryDictation.dictatesOnOpenDefaultsKey))
        first.controller.dismiss()

        // The same app, next panel: opened from the menu, it listens.
        first.controller.present(prefill: .empty)
        #expect(engine.startCount == 1)
        first.controller.dismiss()

        // After a relaunch the setting is still on.
        let second = try harness(FakeDictationEngine(), defaults: defaults)
        #expect(second.controller.dictatesOnOpen)
    }

    // MARK: - Sending, errors and closing

    @Test func commandReturnWhileListeningWaitsForTheLastWordsAndCreatesOneTask() async throws {
        let engine = FakeDictationEngine()
        engine.finishesOnStop = false
        let harness = try harness(engine)
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        model.toggleDictation()
        engine.send(.listening)
        engine.send(.final("Fix the unread dot."))
        engine.send(.volatile(" It is in the"))

        try harness.pressCommandReturn()
        #expect(engine.stopCount == 1)
        #expect(model.dictationPhase == .finishing)
        #expect(model.dictationStatus == "It is in the")
        #expect(harness.fixture.coordinator.records.records.isEmpty, "Nothing is created before the last words")
        // A second ⌘↩ while the words are on their way adds nothing.
        try harness.pressCommandReturn()
        #expect(engine.stopCount == 1)

        engine.eventsAfterStop = [.final(" It is in the dock.")]
        engine.finish()
        await harness.fixture.waitUntil("the panel closes") { harness.controller.isPresented == false }
        let records = harness.fixture.coordinator.records.records
        #expect(records.count == 1)
        #expect(records.first?.text == "Fix the unread dot. It is in the dock.")
    }

    @Test func anErrorShowsInThePanelKeepsTheTextAndDoesNotSend() async throws {
        let engine = FakeDictationEngine()
        engine.finishesOnStop = false
        let harness = try harness(engine)
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        try harness.type("Typed first.")
        model.toggleDictation()
        engine.send(.listening)
        engine.send(.volatile("and then spoken"))
        try harness.pressCommandReturn()

        engine.finish(error: "Toastty found no microphone.")
        #expect(model.errorMessage == "Toastty found no microphone.")
        #expect(model.isDictating == false)
        // The words that were on screen are kept, and nothing was sent.
        #expect(model.text == "Typed first. and then spoken")
        #expect(harness.controller.isPresented)
        #expect(harness.fixture.coordinator.records.records.isEmpty)

        // The microphone button starts again, and the error goes.
        model.toggleDictation()
        #expect(engine.startCount == 2)
        #expect(model.errorMessage == nil)
        harness.controller.dismiss()
    }

    @Test func escapeWhileListeningTurnsTheMicrophoneOffAndClosesThePanel() async throws {
        let engine = FakeDictationEngine()
        let harness = try harness(engine)
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        model.toggleDictation()
        engine.send(.listening)
        engine.send(.volatile("never mind"))

        model.cancel()
        #expect(harness.controller.isPresented == false)
        #expect(engine.cancelCount == 1)
        #expect(engine.isRunning == false)
        #expect(harness.fixture.coordinator.records.records.isEmpty)
    }

    // MARK: - Where the words go

    @Test func dictatedWordsGoInAtTheCaretWithTheSpacesTheyNeed() async throws {
        let engine = FakeDictationEngine()
        let harness = try harness(engine)
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        try harness.type("Fix the dot today.")
        let textView = try harness.textView()
        // The typing's undo step ends with its event, as in the app.
        textView.undoManager?.endUndoGrouping()
        textView.undoManager?.beginUndoGrouping()
        // The caret goes between "the" and "dot".
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        model.toggleDictation()
        engine.send(.listening)
        engine.send(.final("unread"))
        #expect(model.text == "Fix the unread dot today.")
        // One undo takes the dictated words out again, as it does typing.
        textView.undoManager?.undo()
        #expect(model.text == "Fix the dot today.")
        textView.undoManager?.redo()
        #expect(model.text == "Fix the unread dot today.")

        // Typing while it listens still works, and the next words follow.
        try harness.type("red ")
        engine.send(.final(" and sticky"))
        #expect(model.text == "Fix the unread red and sticky dot today.")
        // A selection is replaced, as by typing.
        textView.setSelectedRange((textView.string as NSString).range(of: "today"))
        engine.send(.final(" tomorrow"))
        #expect(model.text == "Fix the unread red and sticky dot tomorrow.")
        harness.controller.dismiss()
    }

    @Test func insertionAddsOnlyTheSpacesThatAreMissing() {
        func insertion(_ words: String, _ before: Character?, _ after: Character?) -> String {
            QuickEntryDictation.insertion(of: words, before: before, after: after)
        }
        #expect(insertion("Hello.", nil, nil) == "Hello.")
        #expect(insertion(" How are you?", ".", nil) == " How are you?")
        #expect(insertion("How are you?", ".", nil) == " How are you?")
        #expect(insertion(" Next line.", "\n", nil) == "Next line.")
        #expect(insertion(" middle", " ", "w") == "middle ")
        #expect(insertion("middle", "a", ".") == " middle")
        #expect(insertion("   ", "a", "b") == "")
    }

    // MARK: - A Mac that cannot dictate

    @Test func withoutASpeechEngineThePanelHasNoMicrophoneAndAHoldOnlyOpensIt() async throws {
        let harness = try harness(nil)
        harness.controller.handleHotKeyPress()
        let model = try #require(harness.controller.model)
        #expect(model.canDictate == false)
        try await Task.sleep(for: Self.hold * 3)
        harness.controller.handleHotKeyRelease()
        #expect(model.isDictating == false)
        model.toggleDictation()
        #expect(model.isDictating == false)
        harness.controller.dismiss()
    }
}
