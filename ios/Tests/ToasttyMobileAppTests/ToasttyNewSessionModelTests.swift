import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

@MainActor
final class ToasttyNewSessionModelTests: XCTestCase {
    private let workspaceID = UUID()
    /// XCTest makes a new instance per test, so each test has its own suite.
    private let suiteName = "ToasttyNewSessionModelTests-\(UUID().uuidString)"
    private lazy var defaults: UserDefaults = UserDefaults(suiteName: suiteName)!

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - Form state

    func testStartNeedsAnAvailableAgentAndANonBlankMessage() async {
        let host = FakeNewSessionHost(options: options(agents: [claude(), piNotInstalled()]))
        let model = makeModel(host: host)
        await model.loadOptions()

        XCTAssertEqual(model.phase, .form)
        XCTAssertEqual(model.selectedAgentID, "claude")
        // An unavailable agent is quiet until it is tapped.
        XCTAssertEqual(model.unavailableAgentNotes, [])
        XCTAssertFalse(model.canStart)
        model.updateMessage("  \n ")
        XCTAssertFalse(model.canStart)
        model.updateMessage("Fix the flaky test")
        XCTAssertTrue(model.canStart)

        // An agent that cannot start is never the selection.
        model.selectAgent("pi")
        XCTAssertEqual(model.selectedAgentID, "claude")
        XCTAssertEqual(model.unavailableAgentNotes, ["Pi isn't installed on your Mac."])
        XCTAssertTrue(model.canStart)
        model.selectAgent("claude")
        XCTAssertEqual(model.unavailableAgentNotes, [])

        let noneAvailable = makeModel(host: FakeNewSessionHost(options: options(agents: [piNotInstalled()])))
        await noneAvailable.loadOptions()
        noneAvailable.updateMessage("Fix the flaky test")
        XCTAssertNil(noneAvailable.selectedAgent)
        XCTAssertFalse(noneAvailable.canStart)
        // With nothing to start, the reason shows without a tap.
        XCTAssertEqual(noneAvailable.unavailableAgentNotes, ["Pi isn't installed on your Mac."])
    }

    func testPermissionAndWorkspaceStatesExplainThemselvesAndBlockStart() async {
        let cases: [(RemoteSessionStartPermission, RemoteSessionStartWorkspaceState)] = [
            (.startDisabled, .available),
            (.sendDisabled, .available),
            (.unknown, .available),
            (.allowed, .notFound),
            (.allowed, .noDirectory),
            (.allowed, .unknown),
        ]
        for (permission, workspace) in cases {
            let host = FakeNewSessionHost(options: .loaded(RemoteSessionStartOptionsResponse(
                permission: permission, workspace: workspace, agents: [claude()]
            )))
            let model = makeModel(host: host)
            await model.loadOptions()
            model.updateMessage("Fix the flaky test")

            XCTAssertNotNil(model.blockingMessage, "\(permission) \(workspace)")
            XCTAssertFalse(model.canStart, "\(permission) \(workspace)")
            await model.start()
            XCTAssertTrue(host.startRequests.isEmpty)
        }

        let disabled = makeModel(host: FakeNewSessionHost(options: .loaded(RemoteSessionStartOptionsResponse(
            permission: .startDisabled, workspace: .available, agents: [claude()]
        ))))
        await disabled.loadOptions()
        XCTAssertEqual(
            disabled.blockingMessage,
            "Starting sessions was turned off for this iPhone. Turn it back on in Toastty → Settings → Remote Access on your Mac."
        )
    }

    func testOptionsThatCouldNotLoadCanBeRetried() async {
        let host = FakeNewSessionHost(options: .unreachable)
        let model = makeModel(host: host)
        await model.loadOptions()
        XCTAssertEqual(model.phase, .unreachable)

        host.options = options(agents: [claude()])
        await model.loadOptions()
        XCTAssertEqual(model.phase, .form)
        XCTAssertEqual(model.selectedAgentID, "claude")
    }

    // MARK: - Request IDs

    func testUnansweredStartRetriesWithTheSameRequestIDUntilAnEdit() async {
        let host = FakeNewSessionHost(options: options(agents: [claude()]))
        host.startOutcomes = [.unconfirmed, .unconfirmed, .unconfirmed]
        let model = makeModel(host: host)
        await model.loadOptions()
        model.updateMessage("Fix the flaky test")

        await model.start()
        XCTAssertEqual(model.phase, .form)
        XCTAssertEqual(model.message, "Fix the flaky test")
        XCTAssertEqual(model.errorMessage, ToasttyNewSessionModel.unreachableMessage)
        await model.start()
        model.updateMessage("Fix the flaky test and open a PR")
        XCTAssertNil(model.errorMessage)
        await model.start()

        XCTAssertEqual(host.startRequests.map(\.clientRequestID), ["request-1", "request-1", "request-2"])
        XCTAssertEqual(host.startRequests.last?.text, "Fix the flaky test and open a PR")
    }

    func testEveryKindOfEditRenewsAnUnansweredRequestID() async {
        let host = FakeNewSessionHost(options: options(agents: [claude(), codex()]))
        host.startOutcomes = Array(repeating: .unconfirmed, count: 4)
        let model = makeModel(host: host)
        await model.loadOptions()
        model.updateMessage("Fix the flaky test")

        await model.start()
        model.selectModel("claude-opus-5-5")
        await model.start()
        model.selectEffort("high")
        await model.start()
        model.selectAgent("codex")
        await model.start()

        XCTAssertEqual(
            host.startRequests.map(\.clientRequestID),
            ["request-1", "request-2", "request-3", "request-4"]
        )
    }

    func testUnansweredRequestIDIsRenewedOnceTheMacHasForgottenIt() async {
        let host = FakeNewSessionHost(options: options(agents: [claude()]))
        host.startOutcomes = [.unconfirmed, .unconfirmed]
        var now = Date(timeIntervalSince1970: 1_000)
        let model = makeModel(host: host, now: { now })
        await model.loadOptions()
        model.updateMessage("Fix the flaky test")

        await model.start()
        now += RemoteSessionStartPolicy.duplicateRequestWindow
        await model.start()

        XCTAssertEqual(host.startRequests.map(\.clientRequestID), ["request-1", "request-2"])
    }

    func testRejectionKeepsTheDraftExplainsAndTheNextStartIsANewRequest() async {
        let host = FakeNewSessionHost(options: options(agents: [claude()]))
        host.startOutcomes = [
            .answered(.rejected(reason: .launchFailed)),
            .answered(.rejected(reason: .unknown)),
        ]
        let model = makeModel(host: host)
        await model.loadOptions()
        model.updateMessage("Fix the flaky test")

        await model.start()
        XCTAssertEqual(model.phase, .form)
        XCTAssertEqual(model.message, "Fix the flaky test")
        XCTAssertEqual(
            model.errorMessage,
            "Claude didn't start on your Mac. Try again."
        )
        await model.start()
        XCTAssertEqual(model.errorMessage, "Your Mac didn't start the session. Try again.")

        XCTAssertEqual(host.startRequests.map(\.clientRequestID), ["request-1", "request-2"])
    }

    func testAnAnswerTheAppDoesNotUnderstandKeepsTheRequestID() async {
        let host = FakeNewSessionHost(options: options(agents: [claude()]))
        host.startOutcomes = [.answered(.unrecognized), .answered(.unrecognized)]
        let model = makeModel(host: host)
        await model.loadOptions()
        model.updateMessage("Fix the flaky test")

        await model.start()
        XCTAssertEqual(model.phase, .form)
        XCTAssertEqual(model.message, "Fix the flaky test")
        XCTAssertEqual(model.errorMessage, ToasttyNewSessionModel.unrecognizedAnswerMessage)
        await model.start()

        // A session may have started, so a second Start must not be new.
        XCTAssertEqual(host.startRequests.map(\.clientRequestID), ["request-1", "request-1"])
    }

    func testAMessageTooLongForTheMacIsNotSentAndStaysInTheDraft() async {
        let host = FakeNewSessionHost(options: options(agents: [claude()]))
        let model = makeModel(host: host)
        await model.loadOptions()
        // Multibyte text: the limit applies to the encoded request.
        let long = String(repeating: "é", count: RemoteGatewayProtocol.maximumRequestBodyBytes / 2)
        model.updateMessage(long)

        await model.start()

        XCTAssertTrue(host.startRequests.isEmpty)
        XCTAssertEqual(model.phase, .form)
        XCTAssertEqual(model.message, long)
        XCTAssertEqual(model.errorMessage, ToasttyNewSessionModel.messageTooLongMessage)
    }

    func testEveryRejectionReasonHasItsOwnExplanation() {
        let reasons: [RemoteSessionStartRejectionReason] = [
            .permissionDenied, .workspaceNotFound, .workspaceUnavailable, .agentUnavailable,
            .invalidRequest, .launchFailed, .busy, .unknown,
        ]
        let messages = reasons.map { ToasttyNewSessionModel.message(for: $0, agentName: "Claude") }
        XCTAssertEqual(Set(messages).count, reasons.count)
    }

    // MARK: - Model and effort

    func testModelChoicesListThePhonesPicksThenTheMacsWithoutDuplicatesOrInvalidValues() async {
        let preferences = ToasttyNewSessionPreferences(defaults: defaults)
        preferences.recordStart(agentID: "claude", model: "claude-sonnet-5-5", effort: nil)
        preferences.recordStart(agentID: "claude", model: "claude-opus-5-5", effort: nil)
        let host = FakeNewSessionHost(options: options(agents: [
            claude(recentModels: ["claude-opus-5-5", "Opus 5.5", "claude-haiku-4-5"]),
        ]))
        let model = makeModel(host: host)
        await model.loadOptions()

        // Starts on the last model used with the agent.
        XCTAssertEqual(model.model, "claude-opus-5-5")
        XCTAssertEqual(model.modelChoices, ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5"])

        XCTAssertFalse(model.useCustomModel("claude next"))
        XCTAssertFalse(model.useCustomModel("--dangerously-skip"))
        XCTAssertEqual(model.errorMessage, ToasttyNewSessionModel.invalidModelMessage)
        XCTAssertEqual(model.model, "claude-opus-5-5")
        XCTAssertTrue(model.useCustomModel(" claude-next "))
        XCTAssertEqual(model.model, "claude-next")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.modelChoices.first, "claude-next")
    }

    func testPhoneRemembersOnlyItsFiveMostRecentModels() {
        let preferences = ToasttyNewSessionPreferences(defaults: defaults)
        for index in 1...7 {
            preferences.recordStart(agentID: "codex", model: "model-\(index)", effort: nil)
        }
        preferences.recordStart(agentID: "codex", model: "model-4", effort: nil)

        XCTAssertEqual(
            preferences.recentModels(forAgent: "codex"),
            ["model-4", "model-7", "model-6", "model-5", "model-3"]
        )
        XCTAssertEqual(preferences.recentModels(forAgent: "claude"), [])
    }

    func testEffortStartsOnTheLastEffortOnlyWhileTheAgentStillOffersIt() async {
        let preferences = ToasttyNewSessionPreferences(defaults: defaults)
        preferences.recordStart(agentID: "claude", model: nil, effort: "xhigh")

        let offered = makeModel(host: FakeNewSessionHost(options: options(agents: [
            claude(efforts: ["low", "xhigh"]),
        ])))
        await offered.loadOptions()
        XCTAssertEqual(offered.effort, "xhigh")
        XCTAssertNil(offered.model)

        let withdrawn = makeModel(host: FakeNewSessionHost(options: options(agents: [
            claude(efforts: ["low", "high"]),
        ])))
        await withdrawn.loadOptions()
        XCTAssertNil(withdrawn.effort)

        let host = FakeNewSessionHost(options: options(agents: [claude(efforts: [])]))
        host.startOutcomes = [.unconfirmed]
        let none = makeModel(host: host)
        await none.loadOptions()
        XCTAssertFalse(none.showsEffort)
        none.updateMessage("Hi")
        await none.start()
        XCTAssertNil(host.startRequests.first?.reasoningEffort)
    }

    func testLastAgentUsedIsSelectedAgain() async {
        ToasttyNewSessionPreferences(defaults: defaults).recordStart(agentID: "codex", model: nil, effort: nil)
        let model = makeModel(host: FakeNewSessionHost(options: options(agents: [claude(), codex()])))
        await model.loadOptions()
        XCTAssertEqual(model.selectedAgentID, "codex")
    }

    // MARK: - Started

    func testStartedSessionOpensOnceItReachesTheListAndRemembersThePicks() async throws {
        let conversationID = UUID()
        let host = FakeNewSessionHost(options: options(agents: [claude(), codex()]))
        host.startOutcomes = [.answered(.started(conversationID: RemoteConversationID(rawValue: conversationID)))]
        // The app's own request IDs, which the Mac must accept.
        let model = makeModel(host: host, makeRequestID: nil)
        await model.loadOptions()
        model.selectAgent("codex")
        model.selectModel("gpt-6.1-sol")
        model.selectEffort("xhigh")
        model.updateMessage("  Fix the flaky test\n")

        let start = Task { await model.start() }
        try await waitUntil { host.startRequests.count == 1 }
        XCTAssertEqual(model.phase, .starting)
        XCTAssertEqual(model.sheetTitle, "New Codex session")
        host.conversations.insert(conversationID)
        await start.value

        XCTAssertEqual(model.phase, .finished(.open(conversationID: conversationID)))
        let request = try XCTUnwrap(host.startRequests.first)
        XCTAssertEqual(request.workspaceID, workspaceID)
        XCTAssertEqual(request.profileID, "codex")
        XCTAssertEqual(request.model, "gpt-6.1-sol")
        XCTAssertEqual(request.reasoningEffort, "xhigh")
        XCTAssertEqual(request.text, "Fix the flaky test")
        XCTAssertTrue(RemoteSessionStartPolicy.isValidClientRequestID(request.clientRequestID))

        let preferences = ToasttyNewSessionPreferences(defaults: defaults)
        XCTAssertEqual(preferences.lastAgentID, "codex")
        XCTAssertEqual(preferences.lastModel(forAgent: "codex"), "gpt-6.1-sol")
        XCTAssertEqual(preferences.lastEffort(forAgent: "codex"), "xhigh")
        XCTAssertEqual(preferences.recentModels(forAgent: "codex"), ["gpt-6.1-sol"])
    }

    func testStartedSessionThatNeverReachesTheListFinishesWithANotice() async {
        let host = FakeNewSessionHost(options: options(agents: [claude()]))
        host.startOutcomes = [.answered(.started(conversationID: RemoteConversationID()))]
        let model = makeModel(host: host, startedSessionTimeout: .milliseconds(100))
        await model.loadOptions()
        model.updateMessage("Fix the flaky test")

        await model.start()

        XCTAssertEqual(model.phase, .finished(.startedPending(agentName: "Claude")))
    }

    // MARK: - Helpers

    private func makeModel(
        host: FakeNewSessionHost,
        now: @escaping () -> Date = Date.init,
        makeRequestID: (() -> String)? = ToasttyNewSessionModelTests.sequentialRequestIDs(),
        startedSessionTimeout: Duration = .seconds(5)
    ) -> ToasttyNewSessionModel {
        if let makeRequestID {
            return ToasttyNewSessionModel(
                workspaceID: workspaceID,
                workspaceTitle: "toastty",
                host: host,
                preferences: ToasttyNewSessionPreferences(defaults: defaults),
                now: now,
                makeRequestID: makeRequestID,
                startedSessionTimeout: startedSessionTimeout,
                pollInterval: .milliseconds(10)
            )
        }
        return ToasttyNewSessionModel(
            workspaceID: workspaceID,
            workspaceTitle: "toastty",
            host: host,
            preferences: ToasttyNewSessionPreferences(defaults: defaults),
            now: now,
            startedSessionTimeout: startedSessionTimeout,
            pollInterval: .milliseconds(10)
        )
    }

    private static func sequentialRequestIDs() -> () -> String {
        var next = 0
        return {
            next += 1
            return "request-\(next)"
        }
    }

    private func options(agents: [RemoteSessionStartAgent]) -> ToasttySessionStartOptionsOutcome {
        .loaded(RemoteSessionStartOptionsResponse(
            permission: .allowed,
            workspace: .available,
            launchDirectory: "~/repos/toastty",
            agents: agents
        ))
    }

    private func claude(
        recentModels: [String] = ["claude-opus-5-5"],
        efforts: [String] = ["low", "high", "xhigh"]
    ) -> RemoteSessionStartAgent {
        RemoteSessionStartAgent(
            profileID: "claude", displayName: "Claude", availability: .available,
            supportsModel: true, recentModels: recentModels, reasoningEfforts: efforts
        )
    }

    private func codex() -> RemoteSessionStartAgent {
        RemoteSessionStartAgent(
            profileID: "codex", displayName: "Codex", availability: .available,
            supportsModel: true, recentModels: ["gpt-6.1-sol"], reasoningEfforts: ["high", "xhigh"]
        )
    }

    private func piNotInstalled() -> RemoteSessionStartAgent {
        RemoteSessionStartAgent(
            profileID: "pi", displayName: "Pi", availability: .notInstalled, supportsModel: true
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met in time", file: file, line: line)
    }
}

@MainActor
private final class FakeNewSessionHost: ToasttyNewSessionHost {
    var options: ToasttySessionStartOptionsOutcome
    var startOutcomes: [ToasttySessionStartOutcome] = []
    var conversations: Set<UUID> = []
    private(set) var startRequests: [RemoteSessionStartRequest] = []

    init(options: ToasttySessionStartOptionsOutcome) {
        self.options = options
    }

    func sessionStartOptions(workspaceID: UUID) async -> ToasttySessionStartOptionsOutcome {
        options
    }

    func startSession(_ request: RemoteSessionStartRequest) async -> ToasttySessionStartOutcome {
        startRequests.append(request)
        return startOutcomes.isEmpty ? .unconfirmed : startOutcomes.removeFirst()
    }

    func conversation(id: UUID) -> MobileConversation? {
        guard conversations.contains(id) else { return nil }
        return MobileConversation(
            id: id, workspaceID: UUID(), workspaceTitle: "toastty", cwd: nil,
            agent: .claude, title: "New session", state: MobileSessionStatus.working,
            inputAvailability: .unavailable(reason: "working"), age: "now", lastActivity: ""
        )
    }
}
