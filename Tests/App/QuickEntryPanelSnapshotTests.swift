import AppKit
import CoreState
import RemoteProtocol
import XCTest
@testable import ToasttyApp

/// Renders the quick entry panel as a user sees it, and keeps the images on
/// the test result for visual review against "Task Inbox Mockups" panel 1,
/// and its pickers against "Task Keyboard Flow" revision 3, sections 1–2.
@MainActor
final class QuickEntryPanelSnapshotTests: XCTestCase {
    private static let designText = "Sidebar unread pill doesn't clear when I read the session from the phone, see screenshot. Probably the read-receipt path skips the desktop store"

    /// The profiles in the design: Claude Code and Codex take a model and
    /// an effort, Cursor only a model, and Shipper, a Codex command under
    /// another name, neither.
    static let agentProfiles: [AgentLaunchProfileSummary] = [
        ("claude", "Claude Code", true, true),
        ("codex", "Codex", true, true),
        ("pi", "Pi", true, true),
        ("cursor", "Cursor", true, false),
        ("shipper", "Shipper (Codex, release authority)", false, false),
    ].map { id, name, model, effort in
        AgentLaunchProfileSummary(
            profileID: id,
            displayName: name,
            agent: AgentKind(rawValue: id)!,
            isInstalled: true,
            acceptsInitialPrompt: true,
            acceptsLeadingDashPrompt: true,
            supportsModel: model,
            supportsReasoningEffort: effort
        )
    }

    private var stagingRoot: URL!
    private var store: AppStore!
    private var controller: QuickEntryController!
    /// The agent pill starts on this preset until one is used twice.
    private var config = TasksConfig(defaults: .init(agent: "claude", model: "claude-opus-5-5", effort: "high"))
    private var presetUsage: QuickEntryPresetUsage!
    /// Set before the panel opens, for a panel on a Mac that can dictate.
    private var dictationEngine: FakeDictationEngine?

    override func setUp() async throws {
        store = AppStore(persistTerminalFontPreference: false)
        let workspace = try XCTUnwrap(store.selectedWorkspace)
        _ = store.send(.renameWorkspace(workspaceID: workspace.id, title: "toastty"))
        stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-quick-entry-snapshot-\(UUID().uuidString)", isDirectory: true)
        presetUsage = QuickEntryPresetUsage(runtimePaths: .resolve(homeDirectoryPath: stagingRoot.path, environment: [:]))
        controller = QuickEntryController(
            store: store,
            agentProfiles: { Self.agentProfiles },
            presetUsage: presetUsage,
            create: { _ in throw TaskError("not used") },
            configLoader: { [unowned self] in config },
            stagingRootURL: stagingRoot,
            registersGlobalHotKey: false,
            frontmostApplication: { nil },
            makeDictationEngine: { [unowned self] in dictationEngine }
        )
    }

    override func tearDown() async throws {
        controller.dismiss()
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    func testEmptyPanelIsCompactWithCreateTaskQuiet() throws {
        controller.present(prefill: .empty)
        let model = try XCTUnwrap(controller.model)
        XCTAssertFalse(model.canSubmit)
        XCTAssertEqual(model.workspaceTitle, "toastty", "The selected workspace")
        XCTAssertEqual(model.agentTitle, "opus-5.5 · high", "The [defaults] preset")
        let empty = try render("quick-entry-empty")

        model.text = Self.designText
        let typed = try render("quick-entry-typed")
        XCTAssertEqual(typed.size.height, empty.size.height, "Two lines fit the text area's minimum height")
    }

    func testSavedCustomCodexModelStaysInColumnsAfterUsingAnotherAgent() throws {
        presetUsage.record(QuickEntryPreset(agent: "codex", model: "custom-codex-model", effort: "high"))
        presetUsage.record(QuickEntryPreset(agent: "claude", model: "claude-opus-5-5", effort: "high"))
        controller.present(prefill: .empty)
        controller.model?.text = "Choose the custom Codex model used in an earlier task"
        controller.openPicker(.agent)
        controller.picker?.openColumns(agent: "codex")
        try renderWithPicker("quick-entry-saved-custom-codex-model")
        XCTAssertTrue(controller.picker?.columns?.cells(in: .model).contains { $0.title == "custom-codex-model" } == true)
    }

    func testDesignStateWithScreenshotAttached() throws {
        controller.present(prefill: .empty)
        let model = try XCTUnwrap(controller.model)
        model.text = Self.designText
        model.attachImageData(try Self.screenshotData(), named: "Screenshot 4.11.52 PM.png")
        XCTAssertEqual(model.attachments.first?.displayName, "Screenshot 4.11.52 PM.png")
        XCTAssertNotNil(model.attachments.first?.thumbnail)
        XCTAssertTrue(model.canSubmit)
        try render("quick-entry-design-state")
    }

    func testPinnedWorkspaceWithSelectionAndScreenshot() throws {
        let workspace = try XCTUnwrap(store.selectedWorkspace)
        controller.present(prefill: QuickEntryPrefill(workspaceID: workspace.id, selectionText: "error: socket closed (POSIX 53)"))
        let model = try XCTUnwrap(controller.model)
        model.text = Self.designText
        model.attachImageData(try Self.screenshotData(), named: "Screenshot 4.11.52 PM.png")
        XCTAssertEqual(model.attachments.map(\.displayName), ["selection.txt", "Screenshot 4.11.52 PM.png"])
        XCTAssertEqual(model.workspaceTitle, "toastty")
        XCTAssertEqual(model.agentTitle, "opus-5.5 · high")
        try render("quick-entry-pinned-workspace")
    }

    func testNoWorkspaceDisablesCreateWithAHint() throws {
        controller.present(prefill: .empty)
        let model = try XCTUnwrap(controller.model)
        model.text = Self.designText
        model.workspaceID = nil
        XCTAssertEqual(model.workspaceTitle, "None")
        XCTAssertEqual(model.missingChoiceHint, "Pick a workspace with ⌘1")
        XCTAssertFalse(model.canSubmit)
        try render("quick-entry-no-workspace")
    }

    func testDropHighlightAndError() throws {
        controller.present(prefill: .empty)
        let model = try XCTUnwrap(controller.model)
        model.isDropTargeted = true
        try render("quick-entry-drop-highlight")
        model.isDropTargeted = false

        model.attachFiles([URL(fileURLWithPath: "/nonexistent/Report.pdf")])
        let deadline = Date().addingTimeInterval(5)
        while model.pendingAttachmentCount > 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNotNil(model.errorMessage)
        try render("quick-entry-error")
    }

    func testLongTextGrowsThePanelUpToItsLimit() throws {
        controller.present(prefill: .empty)
        let model = try XCTUnwrap(controller.model)
        let short = try render("quick-entry-before-long-text")
        model.text = Array(repeating: Self.designText, count: 8).joined(separator: "\n\n")
        let long = try render("quick-entry-long-text")
        XCTAssertGreaterThan(long.size.height, short.size.height)
        XCTAssertLessThanOrEqual(
            long.size.height - short.size.height,
            QuickEntryTextEditor.maximumHeight - QuickEntryTextEditor.minimumHeight + 1
        )
    }

    func testFooterStaysOneRowWithLongNames() throws {
        controller.present(prefill: .empty)
        let short = try render("quick-entry-footer-preselected")
        controller.dismiss()

        let workspace = try XCTUnwrap(store.selectedWorkspace)
        _ = store.send(.renameWorkspace(workspaceID: workspace.id, title: "toastty-quick-entry-pickers-and-presets"))
        controller.present(prefill: QuickEntryPrefill(workspaceID: workspace.id))
        let model = try XCTUnwrap(controller.model)
        model.text = Self.designText
        model.preset = QuickEntryPreset(agent: "codex", model: "gpt-6.1-sol-long-context-preview", effort: "xhigh")
        let long = try render("quick-entry-footer-long-names")
        XCTAssertEqual(long.size.height, short.size.height, "The footer stays one row")

        model.preset = QuickEntryPreset(agent: "shipper")
        try render("quick-entry-footer-profile-name")
    }

    /// A usual workspace name and Claude model show whole.
    func testFooterShowsUsualNamesWhole() throws {
        let workspace = try XCTUnwrap(store.selectedWorkspace)
        _ = store.send(.renameWorkspace(workspaceID: workspace.id, title: "toastty task-system"))
        controller.present(prefill: QuickEntryPrefill(workspaceID: workspace.id))
        let model = try XCTUnwrap(controller.model)
        model.text = Self.designText
        model.preset = QuickEntryPreset(agent: "claude", model: "claude-opus-5-5", effort: "xhigh")
        XCTAssertEqual(model.agentTitle, "opus-5.5 · xhigh")
        try render("quick-entry-footer-usual-names")
    }

    // MARK: - With a coordinator

    /// A coordinator on this store. With `running`, an agent session is in
    /// its terminal; without, the panel says that the message will wait.
    private func makeCoordinator(running: Bool) throws -> CoordinatorController {
        let sessions = SessionRuntimeStore()
        let coordinator = CoordinatorController(
            store: store,
            sessionRuntimeStore: sessions,
            launcher: nil,
            directoryURL: stagingRoot.appendingPathComponent("coordinator", isDirectory: true),
            configLoader: { TasksConfig() },
            deliverText: { _, _ in .unavailable },
            promptState: { _ in .idleAtPrompt }
        )
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        XCTAssertTrue(store.send(.createCoordinatorWorkspace(
            windowID: windowID, workspaceID: UUID(), panelID: UUID(), terminalCWD: stagingRoot.path
        )))
        let location = try XCTUnwrap(store.state.coordinator)
        if running {
            sessions.startSession(
                sessionID: "coordinator-\(UUID().uuidString)",
                agent: .claude,
                panelID: try XCTUnwrap(location.panelID),
                windowID: location.windowID,
                workspaceID: location.workspaceID,
                usesSessionStatusNotifications: false,
                codexStatusTrackingSource: .externallyReported,
                cwd: stagingRoot.path,
                repoRoot: nil,
                at: Date()
            )
        }
        controller.coordinatorController = coordinator
        return coordinator
    }

    // MARK: - Dictation

    /// The microphone and "on open" in the Attach row, and the line that shows
    /// the words in progress while dictation runs. The line takes one row
    /// for the whole session, so the panel does not jump with each word.
    func testDictationShowsItsControlAndTheWordsInProgress() throws {
        let engine = FakeDictationEngine()
        dictationEngine = engine
        controller.present(prefill: .empty)
        let model = try XCTUnwrap(controller.model)
        XCTAssertTrue(model.canDictate)
        let idle = try render("quick-entry-dictation-idle")

        model.toggleDictation()
        engine.send(.listening)
        let listening = try render("quick-entry-dictation-listening")
        XCTAssertGreaterThan(listening.size.height, idle.size.height, "The status line adds a row")

        engine.send(.final("The unread dot stays on after I read the session on the phone."))
        engine.send(.volatile(" Check whether the coordinator dock counts"))
        let words = try render("quick-entry-dictation-words")
        XCTAssertEqual(words.size.height, listening.size.height)
        // A long sentence in progress stays on its one row.
        engine.send(.volatile(" Check whether the coordinator dock counts it as read when the chat is on screen and the window is behind another app or on another display"))
        let long = try render("quick-entry-dictation-long-sentence")
        XCTAssertEqual(long.size.height, listening.size.height)

        model.dictatesOnOpen = true
        engine.send(.final(" Check whether the coordinator dock counts it as read."))
        model.toggleDictation()
        let done = try render("quick-entry-dictation-done-on-open")
        XCTAssertEqual(done.size.height, idle.size.height, "The row goes when dictation ends")
        XCTAssertEqual(
            model.text,
            "The unread dot stays on after I read the session on the phone. Check whether the coordinator dock counts it as read."
        )
    }

    /// With a coordinator the footer also holds Create and Send. The
    /// dictation control is not in it, so usual names still show whole.
    func testDictationControlLeavesTheCoordinatorFooterItsRoom() throws {
        let engine = FakeDictationEngine()
        dictationEngine = engine
        let coordinator = try makeCoordinator(running: true)
        controller.present(prefill: .empty)
        let model = try XCTUnwrap(controller.model)
        XCTAssertTrue(model.sendsToCoordinator)
        let auto = try render("quick-entry-dictation-coordinator-auto")

        let usual = try XCTUnwrap(store.state.workspacesByID.values.first { $0.isCoordinator == false })
        _ = store.send(.renameWorkspace(workspaceID: usual.id, title: "docs-site"))
        model.workspaceOptions = [QuickEntryModel.Option(id: usual.id.uuidString, title: "docs-site")]
        model.chooseWorkspace(usual.id)
        model.choosePreset(QuickEntryPreset(agent: "claude", model: "claude-sonnet-5-5", effort: "high"))
        model.dictatesOnOpen = true
        model.toggleDictation()
        engine.send(.listening)
        engine.send(.volatile("What is the state of the dock pull request"))
        try render("quick-entry-dictation-coordinator-listening")

        model.toggleDictation()
        let chosen = try render("quick-entry-dictation-coordinator-usual-names")
        XCTAssertEqual(chosen.size.height, auto.size.height, "The footer stays one row")
        withExtendedLifetime(coordinator) {}
    }

    /// "Coordinator design" revision 15, section 4: quick entry is a
    /// composer that sends to the coordinator. The pills are optional, Send
    /// is the main button, and Create Task stays as the second one.
    func testCoordinatorPanelSendsWithOptionalPills() throws {
        let coordinator = try makeCoordinator(running: true)
        controller.present(prefill: .empty)
        let model = try XCTUnwrap(controller.model)
        XCTAssertTrue(model.sendsToCoordinator)
        XCTAssertNil(model.coordinator?.hint)
        let empty = try render("quick-entry-coordinator-empty")
        XCTAssertFalse(model.canSubmit)

        model.text = Self.designText
        XCTAssertEqual(model.workspacePillTitle, "Auto")
        XCTAssertEqual(model.agentPillTitle, "Auto")
        XCTAssertTrue(model.canSubmit)
        XCTAssertTrue(model.canCreateTask, "The second key uses the workspace and preset of a panel without a coordinator")
        let auto = try render("quick-entry-coordinator-auto")
        XCTAssertEqual(auto.size.height, empty.size.height)

        // The user's choices with usual names, for the visual review: both
        // show whole next to the two buttons.
        let usual = try XCTUnwrap(store.state.workspacesByID.values.first { $0.isCoordinator == false })
        _ = store.send(.renameWorkspace(workspaceID: usual.id, title: "docs-site"))
        model.workspaceOptions = [QuickEntryModel.Option(id: usual.id.uuidString, title: "docs-site")]
        model.chooseWorkspace(usual.id)
        model.choosePreset(QuickEntryPreset(agent: "claude", model: "claude-sonnet-5-5", effort: "high"))
        try render("quick-entry-coordinator-usual-names")

        // The user's choices, with long names: the footer stays one row
        // with both buttons whole.
        let workspace = try XCTUnwrap(store.state.workspacesByID.values.first { $0.isCoordinator == false })
        _ = store.send(.renameWorkspace(workspaceID: workspace.id, title: "toastty-quick-entry-pickers-and-presets"))
        model.workspaceOptions = [QuickEntryModel.Option(id: workspace.id.uuidString, title: "toastty-quick-entry-pickers-and-presets")]
        model.chooseWorkspace(workspace.id)
        model.choosePreset(QuickEntryPreset(agent: "codex", model: "gpt-6.1-sol-long-context-preview", effort: "xhigh"))
        let chosen = try render("quick-entry-coordinator-chosen")
        XCTAssertEqual(chosen.size.height, auto.size.height, "The footer stays one row")
        model.attachImageData(try Self.screenshotData(), named: "Screenshot 4.11.52 PM.png")
        try render("quick-entry-coordinator-chosen-attached")
        withExtendedLifetime(coordinator) {}
    }

    /// Without files the attachments row is only as tall as the Attach
    /// chip, so the panel is short; the first file makes the row as tall as
    /// a thumbnail, and more files keep that height.
    func testAttachmentsRowGrowsOnlyWithFiles() throws {
        let coordinator = try makeCoordinator(running: true)
        controller.present(prefill: .empty)
        let model = try XCTUnwrap(controller.model)
        model.text = "what would be involved in adding"
        let oneLine = try render("quick-entry-attach-one-line")

        model.text = Array(repeating: Self.designText, count: 3).joined(separator: "\n\n")
        let longText = try render("quick-entry-attach-long-text")
        XCTAssertGreaterThan(longText.size.height, oneLine.size.height)

        model.text = "what would be involved in adding"
        model.attachImageData(try Self.screenshotData(), named: "Screenshot 1.png")
        let oneImage = try render("quick-entry-attach-one-image")
        XCTAssertGreaterThan(oneImage.size.height, oneLine.size.height, "The row grows to show the thumbnail")

        for index in 2...5 {
            model.attachImageData(try Self.screenshotData(), named: "Screenshot \(index).png")
        }
        model.attachFiles([URL(fileURLWithPath: #filePath)])
        let deadline = Date().addingTimeInterval(5)
        while model.pendingAttachmentCount > 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(model.attachments.count, 6)
        let several = try render("quick-entry-attach-several")
        XCTAssertEqual(several.size.height, oneImage.size.height, "More files scroll in the same row")

        while let attachment = model.attachments.first {
            model.removeAttachment(id: attachment.id)
        }
        let removed = try render("quick-entry-attach-removed")
        XCTAssertEqual(removed.size.height, oneLine.size.height, "The panel shrinks again without files")
        withExtendedLifetime(coordinator) {}
    }

    func testCoordinatorPanelSaysWhenTheMessageWillWait() throws {
        let coordinator = try makeCoordinator(running: false)
        controller.present(prefill: .empty)
        let model = try XCTUnwrap(controller.model)
        XCTAssertEqual(model.coordinator?.hint, "Coordinator is not running · your message waits")
        model.text = Self.designText
        try render("quick-entry-coordinator-not-running")
        withExtendedLifetime(coordinator) {}
    }

    func testCoordinatorPickersOfferAuto() throws {
        let coordinator = try makeCoordinator(running: true)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        for title in ["emptyos", "toastty-ios"] {
            XCTAssertTrue(store.send(.createWorkspace(windowID: windowID, title: title, activate: false)))
        }
        controller.present(prefill: .empty)
        controller.model?.text = Self.designText
        controller.togglePicker(.workspace)
        XCTAssertEqual(controller.picker?.rows.first?.id, QuickEntryPicker.coordinatorDecidesRowID)
        XCTAssertFalse(controller.picker?.rows.contains { $0.title == "Coordinator" } ?? true, "Its own workspace is not a project")
        try renderWithPicker("quick-entry-coordinator-workspace-picker")
        controller.togglePicker(.agent)
        XCTAssertEqual(controller.picker?.rows.first?.id, QuickEntryPicker.coordinatorDecidesRowID)
        try renderWithPicker("quick-entry-coordinator-agent-picker")
        withExtendedLifetime(coordinator) {}
    }

    func testWorkspacePicker() throws {
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        for title in ["emptyos", "toastty-ios", "ghostty-fork"] {
            XCTAssertTrue(store.send(.createWorkspace(windowID: windowID, title: title, activate: false)))
        }
        controller.present(prefill: .empty)
        controller.model?.text = Self.keyboardDesignText
        controller.togglePicker(.workspace)
        try renderWithPicker("quick-entry-workspace-picker")

        controller.picker?.query = "tios"
        try renderWithPicker("quick-entry-workspace-picker-search")
    }

    func testAgentPickerFrequentSearchAndColumns() throws {
        config = TasksConfig(defaults: .init(agent: "claude", model: "claude-opus-5-5", effort: "high"))
        controller.recentModels = { provider in
            switch provider {
            case .claude: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1"]
            case .codex: ["gpt-6.1-sol", "gpt-6-astra"]
            default: []
            }
        }
        // The design's Frequent list, most used first.
        for (preset, uses) in [
            (QuickEntryPreset(agent: "claude", model: "claude-opus-5-5", effort: "high"), 5),
            (QuickEntryPreset(agent: "codex", model: "gpt-6.1-sol", effort: "high"), 4),
            (QuickEntryPreset(agent: "claude", model: "claude-opus-5-5", effort: "xhigh"), 3),
            (QuickEntryPreset(agent: "codex", model: "gpt-6-astra", effort: "medium"), 2),
        ] {
            for _ in 0..<uses {
                presetUsage.record(preset)
            }
        }
        controller.present(prefill: .empty)
        let model = try XCTUnwrap(controller.model)
        XCTAssertEqual(model.frequentPresets.count, 4)
        model.text = Self.keyboardDesignText
        model.preset = QuickEntryPreset(agent: "claude", model: "claude-opus-5-5", effort: "high")
        controller.togglePicker(.agent)
        let picker = try XCTUnwrap(controller.picker)
        XCTAssertEqual(model.openPicker, .agent)
        try renderWithPicker("quick-entry-agent-picker")

        picker.query = "gpt"
        try renderWithPicker("quick-entry-agent-picker-search")

        picker.query = ""
        picker.openColumns()
        picker.tab(1)
        try renderWithPicker("quick-entry-agent-picker-columns")
    }

    func testCodexCatalogPopulatesAnAlreadyOpenPicker() async throws {
        let lookup = QuickEntryCatalogRefreshTests.Lookup()
        controller.loadCodexModels = { try await lookup.load() }
        controller.present(prefill: .empty)
        controller.togglePicker(.agent)
        let picker = try XCTUnwrap(controller.picker)
        picker.openColumns(agent: "codex")
        try renderWithPicker("quick-entry-codex-catalog-before")
        XCTAssertEqual(picker.columns?.cells(in: .model).map(\.title), ["Default", "Type a model…"])

        let deadline = Date().addingTimeInterval(2)
        while lookup.calls == 0, Date() < deadline { await Task.yield() }
        XCTAssertEqual(lookup.calls, 1, "The asynchronous catalog request started")
        try lookup.finish(.success([
            "gpt-6.1-sol", "gpt-6-astra", "gpt-6.1-terra", "gpt-6-sol",
            "gpt-6-luna",
        ] + (6...30).map { "catalog-model-\($0)" }))
        await controller.modelLoadTask?.value
        XCTAssertEqual(picker.columns?.cells(in: .model).count, 32)
        XCTAssertEqual(picker.columns?.preset.model, nil, "Loading choices must not pick one")
        try renderWithPicker("quick-entry-codex-catalog-after")
        XCTAssertLessThan(try XCTUnwrap(controller.pickerPanel).frame.height, 450, "A full catalog keeps the search and Choose button in a bounded panel")
        picker.move(-1)
        XCTAssertEqual(picker.columns?.preset.model, "catalog-model-30")
        try renderWithPicker("quick-entry-codex-catalog-scroll-selection")
    }

    func testCodexCatalogRetryKeepsTheOpenPickerAndSearchFocus() async throws {
        let lookup = QuickEntryCatalogRefreshTests.Lookup()
        controller.loadCodexModels = { try await lookup.load() }
        controller.present(prefill: .empty)
        controller.togglePicker(.agent)
        let picker = try XCTUnwrap(controller.picker)
        let pickerPanel = try XCTUnwrap(controller.pickerPanel)
        picker.openColumns(agent: "codex")
        try renderWithPicker("quick-entry-codex-loading")
        let firstDeadline = Date().addingTimeInterval(2)
        while lookup.calls == 0, Date() < firstDeadline { await Task.yield() }
        XCTAssertEqual(lookup.calls, 1)
        try lookup.finish(.failure(CodexPluginCLIError.timedOut))
        await controller.modelLoadTask?.value
        try renderWithPicker("quick-entry-codex-unavailable")
        let editor = try XCTUnwrap(pickerPanel.firstResponder as? NSTextView)
        editor.insertText("catalog", replacementRange: editor.selectedRange())
        let selection = editor.selectedRange()

        // Click the Retry control in the status strip, as an AppKit mouse
        // event. It must not dismiss the picker or take the search focus.
        let point = NSPoint(x: pickerPanel.frame.width - 25, y: pickerPanel.frame.height - 50)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            pickerPanel.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: pickerPanel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            )))
        }
        let retryDeadline = Date().addingTimeInterval(2)
        while lookup.calls < 2, Date() < retryDeadline { await Task.yield() }
        try renderWithPicker("quick-entry-codex-retry-loading")
        XCTAssertEqual(lookup.calls, 2, "The visible Retry button starts the second request")
        XCTAssertTrue(controller.picker === picker)
        XCTAssertTrue(pickerPanel.firstResponder === editor)
        XCTAssertEqual(editor.string, "catalog")
        XCTAssertEqual(editor.selectedRange(), selection)
        // Resume even if a click assertion fails, so teardown never leaves
        // a suspended test request behind.
        if lookup.calls == 2 {
            try lookup.finish(.success(["catalog-model"]))
            await controller.modelLoadTask?.value
        }
        picker.query = ""
        try renderWithPicker("quick-entry-codex-retry-success")
        XCTAssertTrue(picker.columns?.cells(in: .model).contains { $0.title == "catalog-model" } == true)
        XCTAssertNil(picker.codexCatalogStatus)
        XCTAssertTrue(pickerPanel.firstResponder === editor)
    }

    private static let keyboardDesignText = "Sidebar drops the Inbox group after a restart even though one task is still in it"

    /// Renders the panel and its open picker together, placed as on screen,
    /// on the design's page color.
    @discardableResult
    private func renderWithPicker(_ name: String) throws -> NSBitmapImageRep {
        let panelImage = try render("\(name)-panel-only", attach: false)
        let pickerPanel = try XCTUnwrap(controller.pickerPanel)
        let panel = try XCTUnwrap(controller.panel)
        let pickerView = try XCTUnwrap(pickerPanel.contentView)
        pickerView.layoutSubtreeIfNeeded()
        let pickerImage = try XCTUnwrap(pickerView.bitmapImageRepForCachingDisplay(in: pickerView.bounds))
        pickerView.cacheDisplay(in: pickerView.bounds, to: pickerImage)
        XCTAssertEqual(pickerPanel.frame.size, pickerView.bounds.size, "The picker fits its content")

        let margin: CGFloat = 24
        let union = panel.frame.union(pickerPanel.frame)
        let size = NSSize(width: union.width + margin * 2, height: union.height + margin * 2)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.08, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            for (frame, bitmap, radius) in [
                (panel.frame, panelImage, QuickEntryPanel.cornerRadius),
                (pickerPanel.frame, pickerImage, 10),
            ] {
                let rect = NSRect(
                    x: frame.minX - union.minX + margin,
                    y: frame.minY - union.minY + margin,
                    width: frame.width,
                    height: frame.height
                )
                // Each window is clipped to its rounded shape, as the
                // window server shows it.
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
                bitmap.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        let composite = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let attachment = XCTAttachment(
            data: try XCTUnwrap(composite.representation(using: .png, properties: [:])),
            uniformTypeIdentifier: "public.png"
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return composite
    }

    /// Lets SwiftUI lay out and the panel fit its content, then renders the
    /// panel and keeps the image on the test result. The window shadow is
    /// drawn by the window server and is not in the image.
    @discardableResult
    private func render(_ name: String, attach: Bool = true) throws -> NSBitmapImageRep {
        let panel = try XCTUnwrap(controller.panel)
        let contentView = try XCTUnwrap(panel.contentView)
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        contentView.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds))
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        XCTAssertEqual(bitmap.size.width, QuickEntryPanel.width)
        XCTAssertEqual(bitmap.size.height, panel.frame.height, "The panel fits its content")
        guard attach else { return bitmap }

        let attachment = XCTAttachment(
            data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
            uniformTypeIdentifier: "public.png"
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return bitmap
    }

    private static func screenshotData() throws -> Data {
        let image = NSImage(size: NSSize(width: 340, height: 260), flipped: false) { rect in
            NSColor(calibratedRed: 0.23, green: 0.27, blue: 0.32, alpha: 1).setFill()
            rect.fill()
            NSColor(calibratedRed: 0.42, green: 0.48, blue: 0.53, alpha: 1).setFill()
            NSRect(x: 40, y: 190, width: 220, height: 24).fill()
            NSColor(calibratedRed: 0.91, green: 0.58, blue: 0.05, alpha: 0.6).setFill()
            NSRect(x: 40, y: 130, width: 160, height: 24).fill()
            return true
        }
        return try XCTUnwrap(image.tiffRepresentation)
    }
}
