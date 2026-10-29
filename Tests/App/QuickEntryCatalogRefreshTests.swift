import CoreState
import Carbon.HIToolbox
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct QuickEntryCatalogRefreshTests {
    @MainActor
    final class Lookup {
        private(set) var calls = 0
        private var pending: CheckedContinuation<[String], any Error>?

        func load() async throws -> [String] {
            calls += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        }

        func finish(_ result: Result<[String], any Error>) throws {
            let continuation = try #require(pending)
            pending = nil
            continuation.resume(with: result)
        }
    }

    @Test(arguments: ["private-model", "catalog-model"])
    func arrivingModelsPreserveTypedSelectionAndFocus(typedModel: String) async throws {
        let harness = try QuickEntryTests.Harness()
        let lookup = Lookup()
        harness.controller.loadCodexModels = { try await lookup.load() }
        harness.controller.present(prefill: .empty)
        defer { harness.controller.dismiss() }
        let model = try #require(harness.controller.model)
        let otherProfiles = model.agentProfiles.filter { $0.id != "codex" }
        model.preset = QuickEntryPreset(agent: "codex", effort: "high")
        harness.controller.openPicker(.agent)
        let picker = try #require(harness.controller.picker)
        picker.openColumns(agent: "codex")
        picker.query = typedModel
        let original = try #require(picker.columns?.preset)
        await harness.fixture.waitUntil("catalog load starts") { lookup.calls == 1 }
        try lookup.finish(.success(["other-model", "catalog-model"]))
        await harness.controller.modelLoadTask?.value

        #expect(picker.query == typedModel)
        #expect(picker.columns?.focused == .model)
        #expect(picker.columns?.preset == original)
        #expect(model.agentProfiles.filter { $0.id != "codex" } == otherProfiles)
        picker.submit()
        #expect(model.preset == original)
    }

    @Test func refreshMergesDefaultsAndRecentModelsWithoutCappingTheCatalog() async throws {
        let harness = try QuickEntryTests.Harness()
        harness.fixture.config = TasksConfig(defaults: .init(agent: "codex", model: "default-model"))
        harness.controller.recentModels = { $0 == .codex ? ["recent-model", "catalog-0"] : [] }
        let lookup = Lookup()
        harness.controller.loadCodexModels = { try await lookup.load() }
        harness.controller.present(prefill: .empty)
        defer { harness.controller.dismiss() }
        harness.controller.openPicker(.agent)
        let picker = try #require(harness.controller.picker)
        picker.query = "codex"
        picker.move(1)
        let highlighted = picker.highlightedID
        await harness.fixture.waitUntil("catalog load starts") { lookup.calls == 1 }
        try lookup.finish(.success((0..<9).map { "catalog-\($0)" } + ["default-model", "catalog-0"]))
        await harness.controller.modelLoadTask?.value

        #expect(picker.query == "codex")
        #expect(picker.highlightedID == highlighted)
        #expect(picker.profiles.first { $0.id == "codex" }?.models == ["recent-model", "catalog-0", "default-model"] + (1..<9).map { "catalog-\($0)" })
        harness.controller.closePicker(refocusText: false)
        harness.controller.openPicker(.agent)
        #expect(harness.controller.picker?.profiles == picker.profiles, "A later picker uses the same refreshed draft")
    }

    @Test func closeAndReopenCoalescesLookupAndFailureAllowsRetry() async throws {
        let harness = try QuickEntryTests.Harness()
        let lookup = Lookup()
        harness.controller.loadCodexModels = { try await lookup.load() }
        harness.controller.present(prefill: .empty)
        let dismissedModel = try #require(harness.controller.model)
        await harness.fixture.waitUntil("catalog load starts") { lookup.calls == 1 }
        harness.controller.dismiss()
        harness.controller.present(prefill: .empty)
        defer { harness.controller.dismiss() }
        #expect(lookup.calls == 1)
        try lookup.finish(.failure(TaskError("unsupported command")))
        await harness.controller.modelLoadTask?.value

        harness.controller.openPicker(.agent)
        harness.controller.picker?.openColumns(agent: "codex")
        #expect(harness.controller.picker?.columns?.cells(in: .model).map(\.title) == ["Default", "Type a model…"])
        harness.controller.picker?.query = "manual-model"
        harness.controller.picker?.submit()
        #expect(harness.controller.model?.preset?.model == "manual-model")

        harness.controller.dismiss()
        harness.controller.present(prefill: .empty)
        await harness.fixture.waitUntil("failed lookup retries on the next draft") { lookup.calls == 2 }
        try lookup.finish(.success(["catalog-model"]))
        await harness.controller.modelLoadTask?.value
        #expect(harness.controller.model?.agentProfiles.first { $0.id == "codex" }?.models == ["catalog-model"])
        #expect(dismissedModel.agentProfiles.first { $0.id == "codex" }?.models.isEmpty == true)

        harness.controller.dismiss()
        harness.controller.present(prefill: .empty)
        #expect(harness.controller.model?.agentProfiles.first { $0.id == "codex" }?.models == ["catalog-model"], "The next draft offers the last successful catalog before its refresh finishes")
        await harness.fixture.waitUntil("a later draft refreshes the provider catalog") { lookup.calls == 3 }
        try lookup.finish(.success(["new-catalog-model"]))
        await harness.controller.modelLoadTask?.value
        #expect(harness.controller.model?.agentProfiles.first { $0.id == "codex" }?.models == ["catalog-model", "new-catalog-model"])
    }

    // Failure modes: a failed first request requires closing the draft,
    // Retry starts duplicate requests, or a late result changes typed input.
    @Test func failedLookupCanBeRetriedInTheSamePicker() async throws {
        let harness = try QuickEntryTests.Harness()
        let lookup = Lookup()
        harness.controller.loadCodexModels = { try await lookup.load() }
        harness.controller.present(prefill: .empty)
        defer { harness.controller.dismiss() }
        harness.controller.openPicker(.agent)
        let picker = try #require(harness.controller.picker)
        picker.openColumns(agent: "codex")
        #expect(picker.codexCatalogStatus == .loading)
        await harness.fixture.waitUntil("first request starts") { lookup.calls == 1 }
        try lookup.finish(.failure(CodexPluginCLIError.timedOut))
        await harness.controller.modelLoadTask?.value
        #expect(picker.codexCatalogStatus == .unavailable)
        picker.query = "private-model"
        let selection = picker.columns?.preset
        let editor = try await harness.pickerEditor()
        try harness.pressCommand("r", keyCode: kVK_ANSI_R, in: harness.controller.pickerPanel)
        picker.onRetryCodexModels()
        #expect(picker.codexCatalogStatus == .loading)
        await harness.fixture.waitUntil("retry starts") { lookup.calls == 2 }
        try lookup.finish(.success(["catalog-model"]))
        await harness.controller.modelLoadTask?.value

        #expect(harness.controller.picker === picker)
        #expect(picker.codexCatalogStatus == nil)
        #expect(picker.query == "private-model")
        #expect(picker.columns?.preset == selection)
        #expect(harness.controller.pickerPanel?.firstResponder === editor)
        picker.query = "catalog"
        picker.submit()
        #expect(harness.controller.model?.preset?.model == "catalog-model")
    }

    @Test func cachedChoicesSurviveFailedRefreshAndLaterCatalogReplacesTheCache() async throws {
        let harness = try QuickEntryTests.Harness()
        let lookup = Lookup()
        harness.controller.loadCodexModels = { try await lookup.load() }
        harness.controller.present(prefill: .empty)
        await harness.fixture.waitUntil("first request starts") { lookup.calls == 1 }
        let dismissed = try #require(harness.controller.model)
        harness.controller.dismiss()
        try lookup.finish(.success(["old-model"]))
        await harness.controller.modelLoadTask?.value
        #expect(dismissed.agentProfiles.first { $0.id == "codex" }?.models.isEmpty == true)

        harness.controller.present(prefill: .empty)
        defer { harness.controller.dismiss() }
        harness.controller.openPicker(.agent)
        let picker = try #require(harness.controller.picker)
        picker.openColumns(agent: "codex")
        #expect(picker.columns?.cells(in: .model).first?.title == "old-model")
        #expect(picker.codexCatalogStatus == nil)
        await harness.fixture.waitUntil("refresh starts") { lookup.calls == 2 }
        try lookup.finish(.failure(TaskError("not available")))
        await harness.controller.modelLoadTask?.value
        #expect(picker.columns?.cells(in: .model).first?.title == "old-model")
        #expect(picker.codexCatalogStatus == nil)

        picker.onRetryCodexModels()
        await harness.fixture.waitUntil("next refresh starts") { lookup.calls == 3 }
        try lookup.finish(.success(["new-model"]))
        await harness.controller.modelLoadTask?.value
        #expect(Array(picker.columns?.cells(in: .model).map(\.title).prefix(2) ?? []) == ["old-model", "new-model"], "An open picker keeps its choices stable")
        harness.controller.dismiss()
        harness.controller.present(prefill: .empty)
        #expect(harness.controller.model?.agentProfiles.first { $0.id == "codex" }?.models == ["new-model"])
        await harness.fixture.waitUntil("final refresh starts") { lookup.calls == 4 }
        try lookup.finish(.success([]))
        await harness.controller.modelLoadTask?.value
        harness.controller.dismiss()
        harness.controller.present(prefill: .empty)
        #expect(harness.controller.model?.agentProfiles.first { $0.id == "codex" }?.models == ["new-model"], "An empty refresh keeps the last available catalog")
        await harness.fixture.waitUntil("last refresh starts") { lookup.calls == 5 }
        try lookup.finish(.success(["new-model"]))
        await harness.controller.modelLoadTask?.value
    }

    @Test func catalogStatusDoesNotEnterTheWorkspacePickerOrOtherAgentColumns() async throws {
        let harness = try QuickEntryTests.Harness()
        let lookup = Lookup()
        harness.controller.loadCodexModels = { try await lookup.load() }
        harness.controller.present(prefill: .empty)
        defer { harness.controller.dismiss() }
        harness.controller.openPicker(.workspace)
        let workspacePicker = try #require(harness.controller.picker)
        await harness.fixture.waitUntil("catalog starts") { lookup.calls == 1 }
        #expect(workspacePicker.codexCatalogStatus == nil)
        try lookup.finish(.failure(CodexPluginCLIError.timedOut))
        await harness.controller.modelLoadTask?.value
        #expect(workspacePicker.codexCatalogStatus == nil)
        #expect(workspacePicker.showsCodexCatalogStatus == false)

        harness.controller.openPicker(.agent)
        let agentPicker = try #require(harness.controller.picker)
        #expect(agentPicker.showsCodexCatalogStatus)
        agentPicker.openColumns(agent: "claude")
        #expect(agentPicker.showsCodexCatalogStatus == false)
        let codex = try #require(agentPicker.columns?.cells(in: .agent).first { $0.id == "agent:codex" })
        agentPicker.select(codex, in: .agent)
        #expect(agentPicker.showsCodexCatalogStatus)
    }

    @Test(arguments: [false, true])
    func configurationReloadRejectsOldCompletion(oldSucceeds: Bool) async throws {
        let harness = try QuickEntryTests.Harness()
        let old = Lookup()
        let current = Lookup()
        harness.controller.loadCodexModels = { try await old.load() }
        harness.controller.present(prefill: .empty)
        defer { harness.controller.dismiss() }
        await harness.fixture.waitUntil("old request starts") { old.calls == 1 }
        let oldTask = harness.controller.modelLoadTask
        harness.controller.loadCodexModels = { try await current.load() }
        harness.controller.invalidateCodexModels()
        harness.controller.openPicker(.agent)
        let picker = try #require(harness.controller.picker)
        await harness.fixture.waitUntil("new request starts") { current.calls == 1 }
        try current.finish(.success(["current-model"]))
        await harness.controller.modelLoadTask?.value
        try old.finish(oldSucceeds ? .success(["stale-model"]) : .failure(TaskError("old failure")))
        await oldTask?.value
        #expect(picker.codexCatalogStatus == nil)
        #expect(picker.profiles.first { $0.id == "codex" }?.models == ["current-model"])

        harness.controller.dismiss()
        harness.controller.invalidateCodexModels()
        harness.controller.present(prefill: .empty)
        #expect(harness.controller.model?.agentProfiles.first { $0.id == "codex" }?.models.isEmpty == true, "Reload clears the cached catalog")
        await harness.fixture.waitUntil("new draft request starts") { current.calls == 2 }
        try current.finish(.success(["current-model"]))
        await harness.controller.modelLoadTask?.value
    }

    @Test(arguments: [false, true])
    func noLookupWithoutAnOfferedModelCapableCodexProfile(hasCodex: Bool) async throws {
        let harness = try QuickEntryTests.Harness(agentProfiles: {
            QuickEntryPanelSnapshotTests.agentProfiles.compactMap { profile in
                guard profile.profileID == "codex" else { return profile }
                guard hasCodex else { return nil }
                var profile = profile
                profile.supportsModel = false
                return profile
            }
        })
        let lookup = Lookup()
        harness.controller.loadCodexModels = { try await lookup.load() }
        harness.controller.present(prefill: .empty)
        defer { harness.controller.dismiss() }
        #expect(harness.controller.modelLoadTask == nil)
        #expect(lookup.calls == 0)
    }
}
