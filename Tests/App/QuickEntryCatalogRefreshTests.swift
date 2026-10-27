import CoreState
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
        await harness.fixture.waitUntil("a later draft refreshes the provider catalog") { lookup.calls == 3 }
        try lookup.finish(.success(["new-catalog-model"]))
        await harness.controller.modelLoadTask?.value
        #expect(harness.controller.model?.agentProfiles.first { $0.id == "codex" }?.models == ["new-catalog-model"])
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
