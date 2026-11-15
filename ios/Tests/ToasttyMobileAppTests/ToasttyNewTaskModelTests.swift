import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

@MainActor
final class ToasttyNewTaskModelTests: XCTestCase {
    private let toastty = RemoteTaskCreateWorkspace(id: UUID(), title: "toastty")
    private let emptyos = RemoteTaskCreateWorkspace(id: UUID(), title: "emptyos")
    private let opus = RemoteTaskPreset(profileID: "claude", model: "claude-opus-5-5", effort: "xhigh")
    private let sol = RemoteTaskPreset(profileID: "codex", model: "gpt-6.1-sol", effort: "high")

    // MARK: - Options

    func testStartsOnTheMacsQuickEntryChoices() async {
        let host = FakeNewTaskHost(options: options(defaultWorkspaceID: emptyos.id, defaultPreset: sol))
        let model = ToasttyNewTaskModel(host: host)
        XCTAssertEqual(model.phase, .loading)
        await model.loadOptions()

        XCTAssertEqual(model.phase, .form)
        XCTAssertEqual(model.workspaceID, emptyos.id)
        XCTAssertEqual(model.workspaceTitle, "emptyos")
        XCTAssertEqual(model.preset, sol)
        XCTAssertEqual([model.agentTitle, model.modelTitle, model.effortTitle], ["Codex", "gpt-6.1-sol", "high"])
        XCTAssertEqual(model.frequentPresets.map(ToasttyNewTaskModel.title), [
            "claude · opus-5.5 · xhigh",
            "codex · gpt-6.1-sol · high",
        ])
        XCTAssertNil(model.blockingMessage)
        // A task needs its text; the title comes from it.
        XCTAssertFalse(model.canCreate)
        model.updateText("  \n ")
        XCTAssertFalse(model.canCreate)
        model.updateText("Fix the composer")
        XCTAssertTrue(model.canCreate)
    }

    func testFallsBackWhenTheMacsDefaultsCannotBeUsed() async {
        // The default workspace closed, and the default preset names an
        // agent the Mac no longer offers.
        let host = FakeNewTaskHost(options: options(
            defaultWorkspaceID: UUID(),
            frequent: [RemoteTaskPreset(profileID: "grok"), opus],
            defaultPreset: RemoteTaskPreset(profileID: "grok")
        ))
        let model = ToasttyNewTaskModel(host: host)
        await model.loadOptions()
        XCTAssertEqual(model.workspaceID, toastty.id)
        XCTAssertEqual(model.preset, opus)
        XCTAssertEqual(model.frequentPresets, [opus], "A preset this phone cannot send is not offered")

        let noFrequent = ToasttyNewTaskModel(host: FakeNewTaskHost(options: options(frequent: [], defaultPreset: nil)))
        await noFrequent.loadOptions()
        XCTAssertEqual(noFrequent.preset, RemoteTaskPreset(profileID: "claude"))
        XCTAssertEqual([noFrequent.agentTitle, noFrequent.modelTitle, noFrequent.effortTitle], ["Claude", "Default", "Default"])
    }

    func testPermissionAndEmptyMacStatesExplainThemselvesAndBlockCreate() async {
        let cases: [RemoteTaskCreateOptionsResponse] = [
            RemoteTaskCreateOptionsResponse(permission: .startDisabled, workspaces: [toastty], agents: agents()),
            RemoteTaskCreateOptionsResponse(permission: .sendDisabled, workspaces: [toastty], agents: agents()),
            RemoteTaskCreateOptionsResponse(permission: .unknown, workspaces: [toastty], agents: agents()),
            RemoteTaskCreateOptionsResponse(permission: .allowed, workspaces: [], agents: agents()),
            RemoteTaskCreateOptionsResponse(permission: .allowed, workspaces: [toastty], agents: []),
        ]
        for response in cases {
            let host = FakeNewTaskHost(options: .loaded(response))
            let model = ToasttyNewTaskModel(host: host)
            await model.loadOptions()
            model.updateText("Fix the composer")
            XCTAssertNotNil(model.blockingMessage, "\(response)")
            XCTAssertFalse(model.canCreate)
            await model.create()
            XCTAssertTrue(host.requests.isEmpty)
        }
    }

    /// A sheet blocked by the Mac's state, such as no open project, can ask
    /// again once that is fixed, keeping a shared draft.
    func testABlockedSheetReloadsTheMacsOptionsAndKeepsTheDraft() async {
        // The Mac has no project open; its agents and presets are known.
        let host = FakeNewTaskHost(options: .loaded(RemoteTaskCreateOptionsResponse(
            permission: .allowed, workspaces: [], agents: agents(),
            frequentPresets: [opus, sol], defaultPreset: sol, supportsAttachments: true
        )))
        let file = RemoteMessageAttachment(filename: "screen.png", data: Data([137, 80, 78, 71, 13, 10, 26, 10]))
        let model = ToasttyNewTaskModel(host: host, text: "Fix the composer", attachments: [file])
        await model.loadOptions()
        XCTAssertNotNil(model.blockingMessage)
        XCTAssertFalse(model.canCreate)

        host.options = .unreachable
        await model.reloadOptions()
        XCTAssertEqual(model.errorMessage, ToasttyNewTaskModel.unreachableMessage)
        host.options = options(defaultPreset: sol)
        await model.reloadOptions()
        XCTAssertNil(model.blockingMessage)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.workspaceID, toastty.id)
        XCTAssertEqual(model.preset, sol)
        XCTAssertEqual(model.text, "Fix the composer")
        XCTAssertEqual(model.attachments, [file])
        XCTAssertTrue(model.canCreate)
    }

    /// After the Mac says the project closed, the picker lists what it
    /// has now.
    func testAClosedWorkspaceRefusalReloadsThePickers() async {
        let host = FakeNewTaskHost(options: options(defaultWorkspaceID: emptyos.id))
        let model = ToasttyNewTaskModel(host: host, text: "Fix the composer")
        await model.loadOptions()
        XCTAssertEqual(model.workspaceID, emptyos.id)
        host.options = .loaded(RemoteTaskCreateOptionsResponse(
            permission: .allowed, workspaces: [toastty], agents: agents(), supportsAttachments: true
        ))
        host.outcomes = [.answered(.rejected(reason: .workspaceNotFound, message: nil))]
        await model.create()
        XCTAssertEqual(model.workspaces, [toastty])
        XCTAssertEqual(model.workspaceID, toastty.id)
        XCTAssertEqual(model.errorMessage, ToasttyNewTaskModel.message(for: .workspaceNotFound, macMessage: nil, agentName: "Codex"))
    }

    func testUnreachableOptionsCanBeRetried() async {
        let host = FakeNewTaskHost(options: .unreachable)
        let model = ToasttyNewTaskModel(host: host)
        await model.loadOptions()
        XCTAssertEqual(model.phase, .unreachable)
        host.options = options()
        await model.loadOptions()
        XCTAssertEqual(model.phase, .form)
    }

    // MARK: - Editing

    func testAgentModelAndEffortPillsEditThePreset() async throws {
        let model = ToasttyNewTaskModel(host: FakeNewTaskHost(options: options(defaultPreset: sol)))
        await model.loadOptions()
        let claude = try XCTUnwrap(model.agents.first { $0.profileID == "claude" })
        let codex = try XCTUnwrap(model.agents.first { $0.profileID == "codex" })

        model.selectPreset(opus)
        XCTAssertEqual(model.preset, opus)
        model.selectEffort("max")
        XCTAssertEqual(model.preset, RemoteTaskPreset(profileID: "claude", model: "claude-opus-5-5", effort: "max"))
        XCTAssertEqual(model.effortTitle, "max")
        // As in the Mac's Agent column, a new agent drops a model or
        // effort it does not list: Codex has neither opus nor "max".
        model.selectAgent(codex)
        XCTAssertEqual(model.preset, RemoteTaskPreset(profileID: "codex", model: nil, effort: nil))
        XCTAssertEqual([model.modelTitle, model.effortTitle], ["Default", "Default"])
        model.selectModel("gpt-6.1-sol")
        model.selectEffort("low")
        XCTAssertEqual(model.preset, RemoteTaskPreset(profileID: "codex", model: "gpt-6.1-sol", effort: "low"))
        model.selectEffort("max")
        XCTAssertEqual(model.preset?.effort, "low", "Codex does not take max")
        // Claude takes "low", so the effort stays.
        model.selectAgent(claude)
        XCTAssertEqual(model.preset, RemoteTaskPreset(profileID: "claude", model: nil, effort: "low"))
        model.selectAgent(codex)
        model.selectModel(nil)
        XCTAssertEqual(model.preset, RemoteTaskPreset(profileID: "codex", model: nil, effort: "low"))

        XCTAssertFalse(model.useCustomModel("--yolo", for: "codex"))
        XCTAssertEqual(model.errorMessage, ToasttyNewTaskModel.invalidModelMessage)
        XCTAssertTrue(model.useCustomModel(" gpt-7 ", for: "codex"))
        XCTAssertEqual(model.preset?.model, "gpt-7")
        XCTAssertEqual(model.modelChoices, ["gpt-7", "gpt-6.1-sol"], "A typed model is listed first")
        XCTAssertNil(model.errorMessage)
        // A prompt opened for Claude does nothing once Codex is selected,
        // as when a reload changed the agent while it showed.
        XCTAssertFalse(model.useCustomModel("claude-sonnet-5-5", for: "claude"))
        XCTAssertEqual(model.preset, RemoteTaskPreset(profileID: "codex", model: "gpt-7", effort: "low"))
        model.selectModel("gpt-6.1-sol")
        XCTAssertEqual(model.modelChoices, ["gpt-6.1-sol"], "A listed model keeps the Mac's order")
        model.selectEffort(nil)
        XCTAssertEqual(model.preset, RemoteTaskPreset(profileID: "codex", model: "gpt-6.1-sol", effort: nil))

        model.selectWorkspace(emptyos.id)
        XCTAssertEqual(model.workspaceTitle, "emptyos")
        model.selectWorkspace(UUID())
        XCTAssertEqual(model.workspaceID, emptyos.id, "Only a listed workspace can be chosen")
    }

    /// The sheet hides the Model and Effort pills for an agent that takes
    /// neither, so switching to it must leave neither behind.
    func testAnAgentWithoutModelOrEffortClearsBoth() async throws {
        let plain = RemoteSessionStartAgent(
            profileID: "opencode", displayName: "OpenCode", availability: .available,
            supportsModel: false, recentModels: [], reasoningEfforts: []
        )
        let model = ToasttyNewTaskModel(host: FakeNewTaskHost(options: .loaded(RemoteTaskCreateOptionsResponse(
            permission: .allowed, workspaces: [toastty], agents: agents() + [plain],
            defaultPreset: opus, supportsAttachments: true
        ))))
        await model.loadOptions()
        XCTAssertEqual(model.preset, opus)
        model.selectAgent(plain)
        XCTAssertEqual(model.preset, RemoteTaskPreset(profileID: "opencode"))
        XCTAssertEqual(model.modelChoices, [])
        model.selectModel("claude-opus-5-5")
        model.selectEffort("high")
        XCTAssertEqual(model.preset, RemoteTaskPreset(profileID: "opencode"), "OpenCode takes no model or effort")
    }

    func testSharedContentStartsTheDraftAndAttachmentsNeedMacSupport() async {
        let file = RemoteMessageAttachment(filename: "screen.png", data: Data([137, 80, 78, 71, 13, 10, 26, 10]))
        let shared = ToasttyNewTaskModel(
            host: FakeNewTaskHost(options: options(supportsAttachments: false)),
            text: "Composer keeps a blank line",
            attachments: [file],
            notice: "1 item could not be added."
        )
        XCTAssertEqual(shared.errorMessage, "1 item could not be added.")
        await shared.loadOptions()
        XCTAssertEqual(shared.text, "Composer keeps a blank line")
        XCTAssertFalse(shared.canCreate, "The Mac cannot take the shared file")
        shared.removeAttachment(file.id)
        XCTAssertTrue(shared.canCreate)
        XCTAssertEqual(shared.addAttachments([file]), ToasttyNewTaskModel.attachmentsUnsupportedMessage)

        let supported = ToasttyNewTaskModel(host: FakeNewTaskHost(options: options()))
        await supported.loadOptions()
        XCTAssertNil(supported.addAttachments([file]))
        XCTAssertEqual(supported.attachments, [file])
        XCTAssertTrue(supported.preventsInteractiveDismissal)
        supported.discardDraft()
        XCTAssertTrue(supported.attachments.isEmpty)
        XCTAssertFalse(supported.allowsEditing)
    }

    // MARK: - Creating

    func testCreateSendsTheDraftAndFinishes() async {
        let host = FakeNewTaskHost(options: options(defaultPreset: sol))
        host.outcomes = [.answered(.created(taskID: UUID()))]
        let file = RemoteMessageAttachment(filename: "notes.txt", data: Data("steps".utf8))
        let model = ToasttyNewTaskModel(host: host, text: "  Fix the composer\n", attachments: [file], makeRequestID: { "request-1" })
        await model.loadOptions()
        await model.create()

        XCTAssertEqual(model.phase, .created)
        XCTAssertEqual(host.requests, [RemoteTaskCreateRequest(
            clientRequestID: "request-1",
            workspaceID: toastty.id,
            profileID: "codex",
            model: "gpt-6.1-sol",
            effort: "high",
            text: "Fix the composer",
            attachments: [file]
        )])
    }

    func testARetryAfterNoAnswerReusesTheRequestIDUntilTheDraftChanges() async {
        let host = FakeNewTaskHost(options: options())
        var nextID = 0
        let model = ToasttyNewTaskModel(host: host, text: "Fix the composer", makeRequestID: {
            nextID += 1
            return "request-\(nextID)"
        })
        await model.loadOptions()

        host.outcomes = [.unconfirmed, .answered(.unrecognized), .unconfirmed, .answered(.created(taskID: UUID()))]
        await model.create()
        XCTAssertEqual(model.phase, .form)
        XCTAssertEqual(model.errorMessage, ToasttyNewTaskModel.unreachableMessage)
        await model.create()
        XCTAssertEqual(model.errorMessage, ToasttyNewTaskModel.unrecognizedAnswerMessage)
        // An edit is a different request, so it gets a new key.
        model.updateText("Fix the composer on iPad")
        await model.create()
        await model.create()
        XCTAssertEqual(host.requests.map(\.clientRequestID), ["request-1", "request-1", "request-2", "request-2"])
        XCTAssertEqual(model.phase, .created)
    }

    func testARefusalExplainsItselfAndTheUnchangedDraftKeepsItsRequestID() async {
        let host = FakeNewTaskHost(options: options())
        var nextID = 0
        let model = ToasttyNewTaskModel(host: host, text: "Fix the composer", makeRequestID: {
            nextID += 1
            return "request-\(nextID)"
        })
        await model.loadOptions()
        host.outcomes = [
            .answered(.rejected(reason: .createFailed, message: "tasks.toml: line 3: unknown key")),
            .answered(.rejected(reason: .busy, message: nil)),
        ]
        await model.create()
        XCTAssertEqual(model.phase, .form)
        XCTAssertEqual(model.errorMessage, "Your Mac couldn't create the task: tasks.toml: line 3: unknown key")
        await model.create()
        XCTAssertEqual(model.errorMessage, "Your Mac is still saving another task from this iPhone. Try again in a moment.")
        // An earlier attempt may have saved the task before its answer was
        // lost, so only an edit makes a new request.
        model.updateText("Fix the composer on iPad")
        host.outcomes = [.answered(.created(taskID: UUID()))]
        await model.create()
        XCTAssertEqual(host.requests.map(\.clientRequestID), ["request-1", "request-1", "request-2"])

        for reason in [RemoteTaskCreateRejectionReason.permissionDenied, .workspaceNotFound, .agentUnavailable,
                       .invalidRequest, .invalidAttachments, .attachmentStorageUnavailable, .unknown] {
            XCTAssertFalse(ToasttyNewTaskModel.message(for: reason, macMessage: nil, agentName: "Codex").isEmpty)
        }
    }

    func testAnOversizedTaskIsRefusedBeforeSending() async {
        let host = FakeNewTaskHost(options: options())
        let model = ToasttyNewTaskModel(
            host: host,
            text: String(repeating: "a", count: RemoteGatewayProtocol.maximumRequestBodyBytes + 1)
        )
        await model.loadOptions()
        await model.create()
        XCTAssertEqual(model.errorMessage, ToasttyNewTaskModel.textTooLongMessage)
        XCTAssertTrue(host.requests.isEmpty)
    }

    func testShortModelNamesFollowTheMacsQuickEntry() {
        XCTAssertEqual(ToasttyNewTaskModel.shortModelName("claude-opus-5-5"), "opus-5.5")
        XCTAssertEqual(ToasttyNewTaskModel.shortModelName("claude-sonnet-5-5-20261001"), "sonnet-5.5")
        XCTAssertEqual(ToasttyNewTaskModel.shortModelName("gpt-6.1-sol"), "gpt-6.1-sol")
    }

    // MARK: - Helpers

    private func agents() -> [RemoteSessionStartAgent] {
        [
            RemoteSessionStartAgent(
                profileID: "claude", displayName: "Claude", availability: .available, supportsModel: true,
                recentModels: ["claude-opus-5-5"], reasoningEfforts: ["low", "medium", "high", "xhigh", "max"]
            ),
            RemoteSessionStartAgent(
                profileID: "codex", displayName: "Codex", availability: .available, supportsModel: true,
                recentModels: ["gpt-6.1-sol"], reasoningEfforts: ["low", "medium", "high", "xhigh"]
            ),
        ]
    }

    private func options(
        defaultWorkspaceID: UUID? = nil,
        frequent: [RemoteTaskPreset]? = nil,
        defaultPreset: RemoteTaskPreset? = nil,
        supportsAttachments: Bool = true,
        coordinator: RemoteCoordinatorSendState? = nil
    ) -> ToasttyTaskCreateOptionsOutcome {
        .loaded(RemoteTaskCreateOptionsResponse(
            permission: .allowed,
            workspaces: [toastty, emptyos],
            defaultWorkspaceID: defaultWorkspaceID,
            agents: agents(),
            frequentPresets: frequent ?? [opus, sol],
            defaultPreset: defaultPreset,
            supportsAttachments: supportsAttachments,
            coordinator: coordinator
        ))
    }

    // MARK: - To the coordinator

    private let running = RemoteCoordinatorSendState(agent: .running)

    /// A sheet on a Mac with a running coordinator, whose quick entry
    /// would start on emptyos and Codex · gpt-6.1-sol · high.
    private func coordinatorSheet(
        _ state: RemoteCoordinatorSendState? = nil
    ) async -> (ToasttyNewTaskModel, FakeNewTaskHost) {
        let host = FakeNewTaskHost(
            options: options(defaultWorkspaceID: emptyos.id, defaultPreset: sol, coordinator: state ?? running),
            supportsCoordinatorSend: true
        )
        var requestIDs = (1...20).map { "request-\($0)" }
        let model = ToasttyNewTaskModel(host: host, makeRequestID: { requestIDs.removeFirst() })
        await model.loadOptions()
        return (model, host)
    }

    func testTheSheetSendsToTheCoordinatorOnlyWhileTheMacOffersOne() async {
        let (model, _) = await coordinatorSheet()
        XCTAssertTrue(model.sendsToCoordinator)
        XCTAssertEqual([model.workspacePillTitle, model.agentPillTitle], ["Auto", "Auto"])
        XCTAssertTrue(model.workspaceIsAuto && model.agentIsAuto)
        XCTAssertFalse(model.showsModelAndEffort, "Model and Effort belong to a chosen agent")
        XCTAssertFalse(model.canSend, "Nothing to send yet")
        model.updateText("Unread dot stays on")
        XCTAssertTrue(model.canSend)
        XCTAssertTrue(model.canCreate, "Create uses the values the pills started on")

        // An older Mac: a coordinator in the options, but no capability.
        let older = ToasttyNewTaskModel(host: FakeNewTaskHost(options: options(coordinator: running)))
        await older.loadOptions()
        XCTAssertFalse(older.sendsToCoordinator)
        XCTAssertEqual(older.workspacePillTitle, "toastty")
        XCTAssertTrue(older.showsModelAndEffort)

        // A Mac that takes messages for a coordinator, but has none now.
        let none = ToasttyNewTaskModel(host: FakeNewTaskHost(options: options(), supportsCoordinatorSend: true))
        await none.loadOptions()
        none.updateText("Fix it")
        XCTAssertFalse(none.sendsToCoordinator)
        XCTAssertFalse(none.canSend)
        XCTAssertEqual(none.agentPillTitle, "Claude")
    }

    func testAutoSendsNoChoiceAndAPillTheUserSetsGoesAsTheirChoice() async {
        let (model, host) = await coordinatorSheet()
        model.updateText("  Unread dot stays on\n")
        let screenshot = RemoteMessageAttachment(filename: "screen.png", data: Data([137, 80, 78, 71]))
        XCTAssertNil(model.addAttachments([screenshot]))
        host.sendOutcomes = [.answered(.sent)]
        await model.send()
        let auto = host.sendRequests.last
        XCTAssertNil(auto?.workspaceID)
        XCTAssertNil(auto?.profileID)
        XCTAssertNil(auto?.model)
        XCTAssertNil(auto?.effort)
        XCTAssertEqual(auto?.text, "Unread dot stays on")
        XCTAssertEqual(auto?.attachments, [screenshot])
        XCTAssertEqual(model.phase, .sent(.sent))
        XCTAssertTrue(host.requests.isEmpty, "Send makes no task itself")

        // A chosen agent starts on Default: only what the user sets goes.
        let (chosen, chosenHost) = await coordinatorSheet()
        chosen.updateText("Fix the computer update")
        chosen.selectWorkspace(emptyos.id)
        XCTAssertEqual(chosen.workspacePillTitle, "emptyos", "Choosing the value it started on is still a choice")
        chosen.selectAgent(chosen.agents[1])
        XCTAssertEqual([chosen.agentPillTitle, chosen.modelTitle, chosen.effortTitle], ["Codex", "Default", "Default"])
        XCTAssertTrue(chosen.showsModelAndEffort)
        chosen.selectEffort("high")
        chosenHost.sendOutcomes = [.answered(.waiting(reason: .working))]
        await chosen.send()
        let request = chosenHost.sendRequests.last
        XCTAssertEqual(request?.workspaceID, emptyos.id)
        XCTAssertEqual(request?.profileID, "codex")
        XCTAssertNil(request?.model)
        XCTAssertEqual(request?.effort, "high")
        XCTAssertEqual(chosen.phase, .sent(.waiting(reason: .working)))

        // A Frequent preset sets all three; Auto takes the choices back.
        let (frequent, frequentHost) = await coordinatorSheet()
        frequent.updateText("Fix it")
        frequent.selectPreset(opus)
        frequent.selectWorkspace(toastty.id)
        frequent.selectAutoWorkspace()
        XCTAssertEqual(frequent.workspacePillTitle, "Auto")
        XCTAssertEqual(frequent.workspaceID, emptyos.id, "Auto goes back to the value the sheet started on")
        frequentHost.sendOutcomes = [.answered(.sent)]
        await frequent.send()
        XCTAssertNil(frequentHost.sendRequests.last?.workspaceID)
        XCTAssertEqual(frequentHost.sendRequests.last?.profileID, "claude")
        XCTAssertEqual(frequentHost.sendRequests.last?.model, "claude-opus-5-5")
        XCTAssertEqual(frequentHost.sendRequests.last?.effort, "xhigh")
    }

    func testCreateMakesTheTaskDirectlyWithTheStartingValuesForAutoPills() async {
        let (model, host) = await coordinatorSheet()
        model.updateText("Fix the composer")
        host.outcomes = [.answered(.created(taskID: UUID()))]
        await model.create()
        XCTAssertEqual(host.requests.last?.workspaceID, emptyos.id)
        XCTAssertEqual(host.requests.last?.profileID, "codex")
        XCTAssertEqual(host.requests.last?.model, "gpt-6.1-sol")
        XCTAssertEqual(host.requests.last?.effort, "high")
        XCTAssertTrue(host.sendRequests.isEmpty, "Create sends nothing to the coordinator")
        XCTAssertEqual(model.phase, .created)

        // A pill the user set is used.
        let (chosen, chosenHost) = await coordinatorSheet()
        chosen.updateText("Fix the composer")
        chosen.selectWorkspace(toastty.id)
        chosen.selectAutoAgent()
        chosenHost.outcomes = [.answered(.created(taskID: UUID()))]
        await chosen.create()
        XCTAssertEqual(chosenHost.requests.last?.workspaceID, toastty.id)
        XCTAssertEqual(chosenHost.requests.last?.profileID, "codex")
    }

    func testTheSheetSaysWhenTheMessageWillWait() async {
        let (notRunning, _) = await coordinatorSheet(RemoteCoordinatorSendState(agent: .notRunning))
        XCTAssertEqual(notRunning.coordinatorNote, "The coordinator is not running. Your message waits on your Mac until it starts.")
        XCTAssertTrue(notRunning.coordinatorNoteIsWarning)
        notRunning.updateText("Fix it")
        XCTAssertTrue(notRunning.canSend, "The message waits; the send is not blocked")

        let (starting, _) = await coordinatorSheet(RemoteCoordinatorSendState(agent: .starting))
        XCTAssertEqual(starting.coordinatorNote, "The coordinator is starting. Your message waits on your Mac until it is ready.")
        XCTAssertTrue(starting.coordinatorNoteIsWarning)

        let (queued, _) = await coordinatorSheet(RemoteCoordinatorSendState(agent: .running, waitingCount: 2))
        XCTAssertEqual(queued.coordinatorNote, "2 messages wait for the coordinator.")
        XCTAssertFalse(queued.coordinatorNoteIsWarning)

        let (atRest, _) = await coordinatorSheet()
        XCTAssertNil(atRest.coordinatorNote)
    }

    func testOnlyAMissingPermissionBlocksASend() async {
        for permission in [RemoteSessionStartPermission.startDisabled, .sendDisabled] {
            let host = FakeNewTaskHost(
                options: .loaded(RemoteTaskCreateOptionsResponse(
                    permission: permission, workspaces: [toastty], agents: agents(), coordinator: running
                )),
                supportsCoordinatorSend: true
            )
            let model = ToasttyNewTaskModel(host: host)
            await model.loadOptions()
            model.updateText("Fix it")
            XCTAssertNotNil(model.blockingMessage)
            XCTAssertFalse(model.canSend)
            await model.send()
            XCTAssertTrue(host.sendRequests.isEmpty)
        }
        // The coordinator can answer without a project or an agent; only
        // Create needs them.
        let host = FakeNewTaskHost(
            options: .loaded(RemoteTaskCreateOptionsResponse(permission: .allowed, coordinator: running)),
            supportsCoordinatorSend: true
        )
        let model = ToasttyNewTaskModel(host: host)
        await model.loadOptions()
        model.updateText("Which project has the flaky test?")
        XCTAssertNil(model.blockingMessage)
        XCTAssertTrue(model.canSend)
        XCTAssertFalse(model.canCreate)
    }

    func testARetryReusesTheRequestIDUntilTheDraftChanges() async {
        let (model, host) = await coordinatorSheet()
        model.updateText("Fix it")
        host.sendOutcomes = [.unconfirmed, .answered(.unrecognized), .answered(.rejected(reason: .busy, message: nil))]
        await model.send()
        XCTAssertEqual(model.errorMessage, ToasttyNewTaskModel.sendUnreachableMessage)
        XCTAssertEqual(model.phase, .form)
        await model.send()
        XCTAssertEqual(model.errorMessage, ToasttyNewTaskModel.unrecognizedSendAnswerMessage)
        await model.send()
        XCTAssertEqual(host.sendRequests.map(\.clientRequestID), ["request-1", "request-1", "request-1"])

        model.updateText("Fix it now")
        host.sendOutcomes = [.answered(.sent)]
        await model.send()
        XCTAssertEqual(host.sendRequests.last?.clientRequestID, "request-2", "An edit makes a new message")
    }

    func testWithoutACoordinatorTheSheetReloadsAndCreatesTheTaskItself() async {
        let (model, host) = await coordinatorSheet()
        model.updateText("Fix it")
        host.sendOutcomes = [.answered(.rejected(reason: .noCoordinator, message: nil))]
        host.options = options(defaultWorkspaceID: emptyos.id, defaultPreset: sol)
        await model.send()
        XCTAssertEqual(model.errorMessage, "Your Mac has no coordinator now. Nothing was sent. Tap Create to make the task yourself.")
        XCTAssertFalse(model.sendsToCoordinator)
        XCTAssertEqual(model.workspacePillTitle, "emptyos")
        XCTAssertEqual(model.text, "Fix it", "The draft stays")
        XCTAssertTrue(model.canCreate)
    }

    func testTheNoticeSaysWhereTheMessageWent() {
        XCTAssertEqual(ToasttyNewTaskModel.sentNotice(.sent), "Sent to the coordinator")
        XCTAssertEqual(
            ToasttyNewTaskModel.sentNotice(.waiting(reason: .working)),
            "Waits on your Mac: the coordinator is working"
        )
        XCTAssertEqual(
            ToasttyNewTaskModel.sentNotice(.waiting(reason: .notRunning)),
            "Waits on your Mac: the coordinator is not running"
        )
    }
}

@MainActor
private final class FakeNewTaskHost: ToasttyNewTaskHost {
    var options: ToasttyTaskCreateOptionsOutcome
    var outcomes: [ToasttyTaskCreateOutcome] = []
    private(set) var requests: [RemoteTaskCreateRequest] = []
    var supportsCoordinatorSend: Bool
    var sendOutcomes: [ToasttyCoordinatorSendOutcome] = []
    private(set) var sendRequests: [RemoteCoordinatorSendRequest] = []

    init(options: ToasttyTaskCreateOptionsOutcome, supportsCoordinatorSend: Bool = false) {
        self.options = options
        self.supportsCoordinatorSend = supportsCoordinatorSend
    }

    func taskCreateOptions() async -> ToasttyTaskCreateOptionsOutcome {
        options
    }

    func createTask(_ request: RemoteTaskCreateRequest) async -> ToasttyTaskCreateOutcome {
        requests.append(request)
        return outcomes.isEmpty ? .unconfirmed : outcomes.removeFirst()
    }

    func sendToCoordinator(_ request: RemoteCoordinatorSendRequest) async -> ToasttyCoordinatorSendOutcome {
        sendRequests.append(request)
        return sendOutcomes.isEmpty ? .unconfirmed : sendOutcomes.removeFirst()
    }
}
