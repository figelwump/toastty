import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// The question whether to start the coordinator, with the real controller,
/// store and saved preferences. A test answers in place of the sheet.
@MainActor
struct CoordinatorStartOfferTests {
    /// Stands in for the sheet: it records each time the question shows,
    /// and a test answers or sees it taken down.
    @MainActor
    final class Sheet {
        private(set) var shownOverWindowIDs: [UUID] = []
        private(set) var takenDownCount = 0
        /// The window cannot show a sheet now.
        var cannotShow = false
        private var answer: (@MainActor (CoordinatorStartOffer.Answer?) -> Void)?

        var isUp: Bool { answer != nil }

        func present(
            windowID: UUID,
            answer: @escaping @MainActor (CoordinatorStartOffer.Answer?) -> Void
        ) -> (@MainActor () -> Void)? {
            guard cannotShow == false else { return nil }
            shownOverWindowIDs.append(windowID)
            self.answer = answer
            return { [weak self] in
                self?.takenDownCount += 1
                self?.end(with: nil)
            }
        }

        func choose(_ choice: CoordinatorStartOffer.Answer) {
            end(with: choice)
        }

        /// The sheet went away with no button pressed, as when its window
        /// closes.
        func closeWithoutAnAnswer() {
            end(with: nil)
        }

        /// A sheet reports its end once, as AppKit does.
        private func end(with choice: CoordinatorStartOffer.Answer?) {
            let answer = answer
            self.answer = nil
            answer?(choice)
        }
    }

    /// One launch of the app over the same saved preferences and the same
    /// runtime home.
    @MainActor
    final class Launch {
        let fixture: CoordinatorControllerTests.Fixture
        let sheet = Sheet()
        let offer: CoordinatorStartOffer
        /// Quick entry, with its key tied to the question as the app ties
        /// it.
        let quickEntry: QuickEntryController
        let defaults: UserDefaults?
        private(set) var shortcutMessages: [String] = []
        private let failureLog = FailureLog()
        /// The titles of the failures that the offer showed.
        var failures: [String] { failureLog.titles }

        @MainActor
        final class FailureLog {
            var titles: [String] = []
        }

        init(_ fixture: CoordinatorControllerTests.Fixture, defaultsSuite: String?) throws {
            self.fixture = fixture
            let sheet = sheet
            let failureLog = failureLog
            // A new object each launch, as a new process has.
            let defaults = try defaultsSuite.map { try #require(UserDefaults(suiteName: $0)) }
            self.defaults = defaults
            offer = CoordinatorStartOffer(
                controller: fixture.controller,
                store: fixture.store,
                defaults: defaults,
                coordinatorDirectoryURL: fixture.directory,
                present: { windowID, answer in sheet.present(windowID: windowID, answer: answer) },
                presentFailure: { title, _ in failureLog.titles.append(title) }
            )
            quickEntry = QuickEntryController(
                store: fixture.store,
                agentProfiles: { [] },
                create: { _ in throw TaskError("Not used") },
                configLoader: { .empty },
                registersGlobalHotKey: false
            )
            QuickEntryShortcutAnswer.connect(quickEntry, to: offer, defaults: defaults) { [weak self] message in
                self?.shortcutMessages.append(message)
            }
            // As at launch.
            quickEntry.reloadShortcut()
        }

        /// The sheet saves the state of "Use ⌥⇧T in every app" before it
        /// answers.
        func choose(_ answer: CoordinatorStartOffer.Answer, allowingTheKey allowed: Bool) {
            QuickEntryShortcutAnswer.save(allowed, in: defaults)
            sheet.choose(answer)
        }

        var windowID: UUID {
            get throws { try #require(fixture.store.state.windows.first?.id) }
        }

        /// A window got the keyboard, as at launch.
        func windowBecameKey() throws {
            offer.offerIfNeeded(windowID: try windowID)
        }
    }

    private static func suite() -> String {
        "toastty-start-offer-tests-\(UUID().uuidString)"
    }

    private static func removeSuite(_ name: String) {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    }

    // MARK: - Asking

    @Test func aFirstLaunchAsksOnceAndStartOpensTheCoordinator() async throws {
        let suite = Self.suite()
        defer { Self.removeSuite(suite) }
        let fixture = try CoordinatorControllerTests.Fixture()
        let launch = try Launch(fixture, defaultsSuite: suite)
        #expect(launch.offer.shouldOffer)

        try launch.windowBecameKey()
        #expect(launch.sheet.shownOverWindowIDs == [try launch.windowID])
        // The window gets the keyboard again while the question shows.
        try launch.windowBecameKey()
        #expect(launch.sheet.shownOverWindowIDs.count == 1)
        #expect(fixture.controller.status == nil, "Nothing starts before the answer")

        launch.sheet.choose(.start)
        // The same path as Open Coordinator: the workspace, selected, with
        // its agent.
        await fixture.waitUntil("the coordinator's agent") { fixture.controller.session != nil }
        let location = try #require(fixture.controller.location)
        #expect(fixture.store.selectedWorkspaceID(in: location.windowID) == location.workspaceID)
        #expect(try fixture.status().agentState == .running)
        #expect(launch.failures.isEmpty)
        // The open is the answer's own: the question is not taken down a
        // second time.
        #expect(launch.sheet.takenDownCount == 0)
        #expect(launch.offer.shouldOffer == false)
        try launch.windowBecameKey()
        #expect(launch.sheet.shownOverWindowIDs.count == 1)

        // The next launch restores the coordinator and asks nothing. Nor
        // does a launch after the user closed the coordinator.
        let relaunch = try Launch(fixture, defaultsSuite: suite)
        try relaunch.windowBecameKey()
        #expect(relaunch.sheet.shownOverWindowIDs.isEmpty)
        #expect(fixture.store.send(.closeWorkspace(workspaceID: location.workspaceID)))
        #expect(fixture.controller.location == nil)
        let afterClose = try Launch(fixture, defaultsSuite: suite)
        try afterClose.windowBecameKey()
        #expect(afterClose.sheet.shownOverWindowIDs.isEmpty)
    }

    @Test func notNowIsSavedAndOpenCoordinatorStillWorks() async throws {
        let suite = Self.suite()
        defer { Self.removeSuite(suite) }
        let fixture = try CoordinatorControllerTests.Fixture()
        let launch = try Launch(fixture, defaultsSuite: suite)
        try launch.windowBecameKey()
        launch.sheet.choose(.notNow)
        #expect(fixture.controller.status == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.directory.path) == false)
        #expect(launch.offer.shouldOffer == false)

        // The next launch does not ask again.
        let relaunch = try Launch(fixture, defaultsSuite: suite)
        #expect(relaunch.offer.shouldOffer == false)
        try relaunch.windowBecameKey()
        #expect(relaunch.sheet.shownOverWindowIDs.isEmpty)

        // The menu and the command palette open it as before.
        fixture.controller.perform(.open, windowID: try relaunch.windowID) { title, message in
            Issue.record("\(title): \(message)")
        }
        await fixture.waitUntil("the coordinator's agent") { fixture.controller.session != nil }
        #expect(try fixture.status().agentState == .running)
    }

    @Test func aCoordinatorThatWasEverOpenedIsNotAskedFor() async throws {
        let suite = Self.suite()
        defer { Self.removeSuite(suite) }
        // The user opened the coordinator before Toastty had the question,
        // and closed its workspace. Its folder remains.
        let fixture = try CoordinatorControllerTests.Fixture()
        let opened = try await fixture.controller.open()
        #expect(fixture.store.send(.closeWorkspace(workspaceID: opened.location.workspaceID)))
        let launch = try Launch(fixture, defaultsSuite: suite)
        #expect(launch.offer.shouldOffer == false)
        try launch.windowBecameKey()
        #expect(launch.sheet.shownOverWindowIDs.isEmpty)
    }

    @Test func aRunWithoutSavedPreferencesAsksNothing() throws {
        // An automation run: nothing would remember the answer.
        let fixture = try CoordinatorControllerTests.Fixture()
        let launch = try Launch(fixture, defaultsSuite: nil)
        #expect(launch.offer.shouldOffer == false)
        try launch.windowBecameKey()
        #expect(launch.sheet.shownOverWindowIDs.isEmpty)
    }

    // MARK: - While the question shows

    @Test func aCoordinatorOpenedAnotherWayTakesTheQuestionDown() async throws {
        let suite = Self.suite()
        defer { Self.removeSuite(suite) }
        let fixture = try CoordinatorControllerTests.Fixture()
        let launch = try Launch(fixture, defaultsSuite: suite)
        try launch.windowBecameKey()
        #expect(launch.sheet.isUp)

        // `toastty coordinator open`, or the command palette of another
        // window.
        try await fixture.controller.open()
        #expect(launch.sheet.takenDownCount == 1)
        #expect(launch.offer.isShowing == false)
        // A coordinator exists now, so no launch asks.
        let relaunch = try Launch(fixture, defaultsSuite: suite)
        try relaunch.windowBecameKey()
        #expect(relaunch.sheet.shownOverWindowIDs.isEmpty)
    }

    @Test func aWindowThatCannotShowTheQuestionLeavesItForTheNextOne() throws {
        let suite = Self.suite()
        defer { Self.removeSuite(suite) }
        let fixture = try CoordinatorControllerTests.Fixture()
        let launch = try Launch(fixture, defaultsSuite: suite)
        launch.sheet.cannotShow = true
        try launch.windowBecameKey()
        #expect(launch.offer.isShowing == false)
        #expect(launch.offer.shouldOffer)
        launch.sheet.cannotShow = false
        try launch.windowBecameKey()
        #expect(launch.sheet.shownOverWindowIDs.count == 1)
    }

    @Test func aQuestionThatWentAwayWithoutAnAnswerIsAskedAgain() throws {
        let suite = Self.suite()
        defer { Self.removeSuite(suite) }
        let fixture = try CoordinatorControllerTests.Fixture()
        let launch = try Launch(fixture, defaultsSuite: suite)
        try launch.windowBecameKey()
        launch.sheet.closeWithoutAnAnswer()
        #expect(launch.offer.isShowing == false)
        #expect(launch.offer.shouldOffer)
        #expect(fixture.controller.status == nil)
        // Another window gets the keyboard, in this launch or the next.
        try launch.windowBecameKey()
        #expect(launch.sheet.shownOverWindowIDs.count == 2)
        launch.sheet.closeWithoutAnAnswer()
        let relaunch = try Launch(fixture, defaultsSuite: suite)
        try relaunch.windowBecameKey()
        #expect(relaunch.sheet.shownOverWindowIDs.count == 1)
    }

    @Test func aStartThatFailsSaysWhyAndIsNotAskedAgain() async throws {
        let suite = Self.suite()
        defer { Self.removeSuite(suite) }
        let fixture = try CoordinatorControllerTests.Fixture()
        // This Toastty cannot read the coordinator's instructions.
        fixture.instructions.text = nil
        let launch = try Launch(fixture, defaultsSuite: suite)
        try launch.windowBecameKey()
        launch.sheet.choose(.start)
        await fixture.waitUntil("the failure") { launch.failures.isEmpty == false }
        #expect(launch.failures == [CoordinatorController.UserCommand.open.failureTitle])
        #expect(fixture.controller.location == nil)
        let relaunch = try Launch(fixture, defaultsSuite: suite)
        try relaunch.windowBecameKey()
        #expect(relaunch.sheet.shownOverWindowIDs.isEmpty)
    }

    // MARK: - The quick entry key

    /// Toastty takes ⌥⇧T from every app only after the user allowed it in
    /// the sheet.
    @Test func theQuickEntryKeyWaitsForTheAnswerAndFollowsIt() throws {
        let suite = Self.suite()
        defer { Self.removeSuite(suite) }
        let fixture = try CoordinatorControllerTests.Fixture()
        let launch = try Launch(fixture, defaultsSuite: suite)
        #expect(launch.quickEntry.shortcut == nil, "No key while the question waits")
        try launch.windowBecameKey()
        // A window closed under the question leaves it waiting.
        launch.sheet.closeWithoutAnAnswer()
        #expect(launch.quickEntry.shortcut == nil)

        try launch.windowBecameKey()
        launch.choose(.notNow, allowingTheKey: false)
        #expect(launch.quickEntry.shortcut == nil)
        let relaunch = try Launch(fixture, defaultsSuite: suite)
        #expect(relaunch.quickEntry.shortcut == nil, "The no is saved")
        #expect(relaunch.shortcutMessages.isEmpty)
    }

    @Test func allowingTheKeyRegistersItAtOnceAndAtTheNextLaunch() throws {
        let suite = Self.suite()
        defer { Self.removeSuite(suite) }
        let fixture = try CoordinatorControllerTests.Fixture()
        let launch = try Launch(fixture, defaultsSuite: suite)
        try launch.windowBecameKey()
        launch.choose(.notNow, allowingTheKey: true)
        #expect(launch.quickEntry.shortcut == .default)
        #expect(try Launch(fixture, defaultsSuite: suite).quickEntry.shortcut == .default)
    }

    /// With a key written in tasks.toml the sheet asks nothing about the
    /// key. If the file loses that key while the sheet shows, the answer
    /// still ends the wait: the key is read after the answer counts.
    @Test func anAnswerWithNoKeyChoiceEndsTheWait() throws {
        let suite = Self.suite()
        defer { Self.removeSuite(suite) }
        let fixture = try CoordinatorControllerTests.Fixture()
        let launch = try Launch(fixture, defaultsSuite: suite)
        try launch.windowBecameKey()
        launch.sheet.choose(.notNow)
        #expect(launch.quickEntry.shortcut == .default)
    }

    @Test func aUserWhoWillNotSeeTheQuestionKeepsTheKey() async throws {
        // A user who answered the earlier coordinator question.
        let suite = Self.suite()
        defer { Self.removeSuite(suite) }
        let fixture = try CoordinatorControllerTests.Fixture()
        try #require(UserDefaults(suiteName: suite)).set(true, forKey: CoordinatorStartOffer.answeredKey)
        #expect(try Launch(fixture, defaultsSuite: suite).quickEntry.shortcut == .default)
        // An automation run, which never asks.
        #expect(try Launch(fixture, defaultsSuite: nil).quickEntry.shortcut == .default)

        // A coordinator opened another way while the question shows.
        let otherSuite = Self.suite()
        defer { Self.removeSuite(otherSuite) }
        let other = try CoordinatorControllerTests.Fixture()
        let launch = try Launch(other, defaultsSuite: otherSuite)
        try launch.windowBecameKey()
        #expect(launch.quickEntry.shortcut == nil)
        try await other.controller.open()
        #expect(launch.offer.isShowing == false)
        #expect(launch.quickEntry.shortcut == .default)
    }

    // MARK: - The words

    @Test func theSheetNamesTasksQuickEntryAndWhatTheCoordinatorDoes() {
        typealias Words = WhatsNewSheet.Words
        #expect(Words.tasks.contains("git worktree"))
        #expect(Words.useEverywhere(QuickEntryShortcut.default.symbolLabel) == "Use ⌥⇧T in every app")
        #expect(Words.coordinator.contains("follows your tasks"))
        #expect(Words.coordinator.contains("asks you a few questions"))
        #expect(Words.coordinator.contains("run by itself"))
        #expect(Words.startLater.contains(ToasttyCommandMenus.openCoordinatorTitle))
        // The names of the groups that the sidebar shows in each card.
        for bucket in SidebarBucket.allCases {
            #expect(Words.sidebar.contains(bucket.title))
        }
    }
}
