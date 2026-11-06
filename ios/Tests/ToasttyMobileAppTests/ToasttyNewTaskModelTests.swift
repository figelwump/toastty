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
        XCTAssertEqual(model.agentTitle, "codex · gpt-6.1-sol · high")
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
        XCTAssertEqual(noFrequent.agentTitle, "claude")
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

    func testFrequentModelAndEffortChoicesEditThePreset() async throws {
        let model = ToasttyNewTaskModel(host: FakeNewTaskHost(options: options(defaultPreset: sol)))
        await model.loadOptions()
        let claude = try XCTUnwrap(model.agents.first { $0.profileID == "claude" })
        let codex = try XCTUnwrap(model.agents.first { $0.profileID == "codex" })

        model.selectPreset(opus)
        XCTAssertEqual(model.preset, opus)
        // A Codex model keeps an effort Codex takes; "max" is not one.
        model.selectEffort("max", for: claude)
        XCTAssertEqual(model.preset, RemoteTaskPreset(profileID: "claude", model: "claude-opus-5-5", effort: "max"))
        model.selectModel("gpt-6.1-sol", for: codex)
        XCTAssertEqual(model.preset, RemoteTaskPreset(profileID: "codex", model: "gpt-6.1-sol", effort: nil))
        model.selectEffort("low", for: codex)
        model.selectModel(nil, for: codex)
        XCTAssertEqual(model.preset, RemoteTaskPreset(profileID: "codex", model: nil, effort: "low"))

        XCTAssertFalse(model.useCustomModel("--yolo", for: codex))
        XCTAssertEqual(model.errorMessage, ToasttyNewTaskModel.invalidModelMessage)
        XCTAssertTrue(model.useCustomModel(" gpt-7 ", for: codex))
        XCTAssertEqual(model.preset?.model, "gpt-7")
        XCTAssertEqual(model.modelChoices(for: codex), ["gpt-7", "gpt-6.1-sol"])
        XCTAssertNil(model.errorMessage)

        model.selectWorkspace(emptyos.id)
        XCTAssertEqual(model.workspaceTitle, "emptyos")
        model.selectWorkspace(UUID())
        XCTAssertEqual(model.workspaceID, emptyos.id, "Only a listed workspace can be chosen")
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
        supportsAttachments: Bool = true
    ) -> ToasttyTaskCreateOptionsOutcome {
        .loaded(RemoteTaskCreateOptionsResponse(
            permission: .allowed,
            workspaces: [toastty, emptyos],
            defaultWorkspaceID: defaultWorkspaceID,
            agents: agents(),
            frequentPresets: frequent ?? [opus, sol],
            defaultPreset: defaultPreset,
            supportsAttachments: supportsAttachments
        ))
    }
}

@MainActor
private final class FakeNewTaskHost: ToasttyNewTaskHost {
    var options: ToasttyTaskCreateOptionsOutcome
    var outcomes: [ToasttyTaskCreateOutcome] = []
    private(set) var requests: [RemoteTaskCreateRequest] = []

    init(options: ToasttyTaskCreateOptionsOutcome) {
        self.options = options
    }

    func taskCreateOptions() async -> ToasttyTaskCreateOptionsOutcome {
        options
    }

    func createTask(_ request: RemoteTaskCreateRequest) async -> ToasttyTaskCreateOutcome {
        requests.append(request)
        return outcomes.isEmpty ? .unconfirmed : outcomes.removeFirst()
    }
}
