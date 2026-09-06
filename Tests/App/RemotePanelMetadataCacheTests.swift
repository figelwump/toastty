import CoreState
import Foundation
import RemoteProtocol
import Testing

@testable import ToasttyApp

@MainActor
struct RemotePanelMetadataCacheTests {
    private actor Gate {
        struct Pending {
            var sources: [RemotePanelMetadataSource]
            var continuation:
                CheckedContinuation<
                    [RemotePanelMetadataSource: RemotePanelMetadataObservation], Never
                >
        }
        var calls = 0
        var pending: [Pending] = []
        func probe(_ sources: [RemotePanelMetadataSource]) async -> [RemotePanelMetadataSource:
            RemotePanelMetadataObservation]
        {
            calls += 1
            return await withCheckedContinuation {
                pending.append(.init(sources: sources, continuation: $0))
            }
        }
        func finish(_ observation: RemotePanelMetadataObservation) {
            let request = pending.removeFirst()
            request.continuation.resume(
                returning: Dictionary(
                    uniqueKeysWithValues: request.sources.map { ($0, observation) }))
        }
    }

    private func waitFor(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Metadata operation did not settle")
    }

    @Test func missingIsDefinitiveButSymlinksRemainUnknown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "metadata-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("doc.md")
        let source = RemotePanelMetadataSource(path: file.path, kind: .localFile)
        #expect(RemotePanelMetadataProbe.inspect(source) == .missing)
        try Data("text".utf8).write(to: file)
        guard case .present = RemotePanelMetadataProbe.inspect(source) else {
            Issue.record("Expected regular source metadata through macOS temp alias")
            return
        }
        try FileManager.default.removeItem(at: file)
        #expect(RemotePanelMetadataProbe.inspect(source) == .missing)
        try FileManager.default.createSymbolicLink(
            at: file, withDestinationURL: directory.appendingPathComponent("gone.md"))
        #expect(RemotePanelMetadataProbe.inspect(source) == .unknown)
        let link = directory.appendingPathComponent("parent")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: directory.appendingPathComponent("gone"))
        #expect(
            RemotePanelMetadataProbe.inspect(
                .init(path: link.appendingPathComponent("file.md").path, kind: .localFile))
                == .unknown)
    }

    @Test func recencyUsesMaximumAndUnknownRestoresMissingWithoutBroadcastLoop() async throws {
        let gate = Gate()
        let cache = RemotePanelMetadataCache(probe: { await gate.probe($0) })
        defer { cache.stop() }
        let id = UUID()
        let source = RemotePanelMetadataSource(path: "/file.md", kind: .localFile)
        let recent = Date(timeIntervalSince1970: 20)
        var changes = 0
        cache.onChange = { changes += 1 }
        cache.start()
        cache.updateInputs([id: .init(source: source, recentActivityAt: recent)])
        try await waitFor { await gate.calls == 1 }
        await gate.finish(.present(modifiedAt: Date(timeIntervalSince1970: 10)))
        try await waitFor { !cache.isRefreshing }
        #expect(cache.metadata[id]?.updatedAt == recent)
        #expect(changes == 1)
        cache.requestRefresh(force: true)
        try await waitFor { await gate.calls == 2 }
        await gate.finish(.missing)
        try await waitFor { cache.metadata[id]?.isConfirmedMissing == true }
        cache.requestRefresh(force: true)
        try await waitFor { await gate.calls == 3 }
        await gate.finish(.unknown)
        try await waitFor { cache.metadata[id]?.isConfirmedMissing == false }
        #expect(cache.metadata[id]?.updatedAt == recent)
        #expect(changes == 3)
        cache.requestRefresh()
        try await waitFor { !cache.isRefreshing }
        #expect(await gate.calls == 3)
    }

    @Test func activityOnlyChangesPublishWithoutForcingAnotherProbe() async throws {
        let gate = Gate()
        let cache = RemotePanelMetadataCache(probe: { await gate.probe($0) })
        defer { cache.stop() }
        let id = UUID()
        let source = RemotePanelMetadataSource(path: "/file.md", kind: .localFile)
        cache.start()
        cache.updateInputs([id: .init(source: source, recentActivityAt: nil)])
        try await waitFor { await gate.calls == 1 }
        let date = Date(timeIntervalSince1970: 30)
        cache.updateInputs([id: .init(source: source, recentActivityAt: date)])
        await gate.finish(.present(modifiedAt: Date(timeIntervalSince1970: 10)))
        try await waitFor { !cache.isRefreshing }
        #expect(cache.metadata[id]?.updatedAt == date)
        #expect(await gate.calls == 1)
        let newer = date.addingTimeInterval(1)
        cache.updateInputs([id: .init(source: source, recentActivityAt: newer)])
        #expect(cache.metadata[id]?.updatedAt == newer)
        #expect(!cache.isRefreshing)
        #expect(await gate.calls == 1)
    }

    @Test func staleSourceAndStoppedGenerationCannotPopulateNewInputs() async throws {
        let gate = Gate()
        let cache = RemotePanelMetadataCache(probe: { await gate.probe($0) })
        defer { cache.stop() }
        let id = UUID()
        let old = RemotePanelMetadataSource(path: "/old.md", kind: .localFile)
        let new = RemotePanelMetadataSource(path: "/new.md", kind: .localFile)
        cache.start()
        cache.updateInputs([id: .init(source: old, recentActivityAt: nil)])
        try await waitFor { await gate.calls == 1 }
        cache.updateInputs([id: .init(source: new, recentActivityAt: nil)])
        await gate.finish(.missing)
        try await waitFor { await gate.calls == 2 }
        #expect(cache.metadata[id]?.isConfirmedMissing == false)
        cache.stop()
        cache.start()
        cache.updateInputs([id: .init(source: new, recentActivityAt: nil)])
        await gate.finish(.present(modifiedAt: Date(timeIntervalSince1970: 100)))
        try await waitFor { await gate.calls == 3 }
        #expect(cache.metadata[id]?.updatedAt == nil)
        await gate.finish(.present(modifiedAt: Date(timeIntervalSince1970: 40)))
        try await waitFor { cache.metadata[id]?.updatedAt == Date(timeIntervalSince1970: 40) }
    }

    @Test func missingScratchpadStaysVisibleAndRecentOnlyInputNeedsNoProbe() async throws {
        let cache = RemotePanelMetadataCache(probe: { sources in
            Dictionary(uniqueKeysWithValues: sources.map { ($0, .missing) })
        })
        defer { cache.stop() }
        let id = UUID()
        cache.start()
        cache.updateInputs([
            id: .init(
                source: .init(path: "/scratch.json", kind: .scratchpad(revision: 1)),
                recentActivityAt: nil)
        ])
        try await waitFor { !cache.isRefreshing }
        #expect(cache.metadata[id]?.isConfirmedMissing == false)
        #expect(cache.metadata[id]?.updatedAt == nil)
        let date = Date(timeIntervalSince1970: 123)
        cache.updateInputs([id: .init(source: nil, recentActivityAt: date)])
        #expect(cache.metadata[id]?.updatedAt == date)
    }

    @Test func browserFileRecencyUsesSameURLNormalizationAsHistory() throws {
        var state = AppState.bootstrap()
        let workspaceID = try #require(state.windows.first?.workspaceIDs.first)
        let tabID = try #require(state.workspacesByID[workspaceID]?.selectedTabID)
        let panelID = UUID()
        let rawURL = "file:///tmp/preview/../page.html"
        let recentURL = try #require(AppStore.normalizedBrowserRecentURL(rawURL))
        state.workspacesByID[workspaceID]?.tabsByID[tabID]?.rightAuxPanel.appendTab(
            .init(
                id: UUID(), identity: .browserSession(UUID()), panelID: panelID,
                panelState: .web(.init(definition: .browser, initialURL: rawURL))))
        let date = Date(timeIntervalSince1970: 42)
        let inputs = RemoteAccessService.panelMetadataInputs(
            state: state,
            recentItems: [.init(id: .browser(url: recentURL), title: "Page", updatedAt: date)],
            scratchpadDirectory: URL(fileURLWithPath: "/scratchpads"))
        #expect(inputs[panelID]?.recentActivityAt == date)
    }

    @Test func filteringKeepsWorkspaceAndSourceInputCarriesRecentIdentity() throws {
        var state = AppState.bootstrap()
        let workspaceID = try #require(state.windows.first?.workspaceIDs.first)
        let tabID = try #require(state.workspacesByID[workspaceID]?.selectedTabID)
        let panelID = UUID()
        let path = "/file.md"
        state.workspacesByID[workspaceID]?.tabsByID[tabID]?.rightAuxPanel.appendTab(
            .init(
                id: UUID(), identity: .localDocument(path: path), panelID: panelID,
                panelState: .web(.init(definition: .localDocument, filePath: path))))
        let date = Date(timeIntervalSince1970: 12)
        let inputs = RemoteAccessService.panelMetadataInputs(
            state: state,
            recentItems: [
                .init(id: .localDocument(path: path), title: "File", updatedAt: date)
            ], scratchpadDirectory: URL(fileURLWithPath: "/scratchpads"))
        #expect(inputs[panelID]?.recentActivityAt == date)
        #expect(inputs[panelID]?.source?.kind == .localFile)
        let inventory = RemoteAccessService.workspaceInventory(
            state: state,
            metadata: [
                panelID: .init(updatedAt: date, isConfirmedMissing: true)
            ])
        #expect(inventory.count == 1)
        #expect(inventory[0].panels.isEmpty)
    }
}
