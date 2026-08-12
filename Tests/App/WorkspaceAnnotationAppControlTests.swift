import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
private final class WorkspaceAnnotationAppControlFixture {
    let store: AppStore
    let executor: AppControlExecutor
    let annotationStyleStore: AnnotationStyleStore
    let workspaceID: UUID
    private let runtimeHomeURL: URL

    init(brokenStyleStore: Bool = false) throws {
        store = AppStore(persistTerminalFontPreference: false)
        let selection = try #require(store.state.selectedWorkspaceSelection())
        workspaceID = selection.workspaceID

        runtimeHomeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-annotation-control-tests-\(UUID().uuidString)", isDirectory: true)
        if brokenStyleStore {
            // A regular file where the runtime home should be makes every
            // style persist fail while leaving construction valid.
            FileManager.default.createFile(atPath: runtimeHomeURL.path, contents: Data())
        }
        annotationStyleStore = AnnotationStyleStore(
            runtimePaths: ToasttyRuntimePaths.resolve(
                homeDirectoryPath: runtimeHomeURL.path,
                environment: [ToasttyRuntimePaths.environmentKey: runtimeHomeURL.path]
            )
        )

        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        webPanelRuntimeRegistry.bind(store: store)
        executor = AppControlExecutor(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: FocusedPanelCommandController(
                store: store,
                runtimeRegistry: terminalRuntimeRegistry,
                slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
            ),
            agentLaunchService: AgentLaunchService(
                store: store,
                terminalCommandRouter: terminalRuntimeRegistry,
                sessionRuntimeStore: sessionRuntimeStore,
                agentCatalogProvider: TestAgentCatalogProvider(),
                cliExecutablePathProvider: { "/bin/sh" },
                socketPathProvider: { "/tmp/toastty-annotation-test.sock" }
            ),
            annotationStyleStore: annotationStyleStore,
            reloadConfigurationAction: nil
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: runtimeHomeURL)
    }

    func annotations() -> [String: WorkspaceAnnotation] {
        store.state.workspacesByID[workspaceID]?.annotations ?? [:]
    }

    func runSetAnnotation(
        key: String,
        text: String,
        url: String? = nil,
        color: String? = nil
    ) throws -> AppControlActionOutcome {
        var args: [String: AutomationJSONValue] = [
            "workspaceID": .string(workspaceID.uuidString),
            "key": .string(key),
            "text": .string(text),
        ]
        if let url {
            args["url"] = .string(url)
        }
        if let color {
            args["color"] = .string(color)
        }
        return try executor.runAction(id: "workspace.set-annotation", args: args)
    }

    func runClearAnnotation(key: String) throws -> AppControlActionOutcome {
        try executor.runAction(
            id: "workspace.clear-annotation",
            args: [
                "workspaceID": .string(workspaceID.uuidString),
                "key": .string(key),
            ]
        )
    }
}

@MainActor
struct WorkspaceAnnotationAppControlTests {
    @Test
    func annotationKeyDescriptorExplainsStableSemanticIdentity() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }

        let descriptor = try #require(
            fixture.executor.listActionDescriptors().first(where: {
                $0.id == "workspace.set-annotation"
            })
        )
        let keyParameter = try #require(
            descriptor.parameters.first(where: { $0.name == "key" })
        )

        #expect(keyParameter.summary.contains("Stable semantic identity"))
        #expect(keyParameter.summary.contains("same key updates one workspace chip"))
        #expect(keyParameter.summary.contains("github-pr"))
    }

    @Test
    func setAnnotationCanonicalizesStoresAndReportsMutation() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }

        let outcome = try fixture.runSetAnnotation(
            key: " PR ",
            text: "  PR #4512 ",
            url: "https://example.com/pr/4512"
        )

        #expect(outcome.didMutateState)
        #expect(outcome.result?["key"] == .string("pr"))
        #expect(fixture.annotations()["pr"] == WorkspaceAnnotation(
            text: "PR #4512",
            url: "https://example.com/pr/4512"
        ))
    }

    @Test
    func duplicateSetReportsNoMutationAndOverwriteReplacesValue() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }

        #expect(try fixture.runSetAnnotation(key: "pr", text: "PR #1").didMutateState)
        #expect(try fixture.runSetAnnotation(key: "pr", text: "PR #1").didMutateState == false)

        #expect(try fixture.runSetAnnotation(key: "pr", text: "PR #2").didMutateState)
        #expect(fixture.annotations()["pr"]?.text == "PR #2")
        #expect(fixture.annotations().count == 1)
    }

    @Test
    func invalidRequestsAreRejectedWithoutMutatingEitherStore() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }

        #expect(throws: (any Error).self) {
            try fixture.runSetAnnotation(key: "bad key", text: "x")
        }
        #expect(throws: (any Error).self) {
            try fixture.runSetAnnotation(key: "k", text: String(repeating: "x", count: 81))
        }
        #expect(throws: (any Error).self) {
            try fixture.runSetAnnotation(key: "k", text: "bidi\u{202E}")
        }
        #expect(throws: (any Error).self) {
            try fixture.runSetAnnotation(key: "k", text: "ok", url: "file:///etc/passwd")
        }
        // An invalid annotation request must not create a global style entry
        // even when the color token itself is valid.
        #expect(throws: (any Error).self) {
            try fixture.runSetAnnotation(key: "k", text: "ok", url: "ftp://x", color: "green")
        }
        #expect(throws: (any Error).self) {
            try fixture.runSetAnnotation(key: "k", text: "ok", color: "chartreuse")
        }

        #expect(fixture.annotations().isEmpty)
        #expect(fixture.annotationStyleStore.colorTokensByKey.isEmpty)
    }

    @Test
    func textIsNFCNormalizedBeforeStorage() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }

        _ = try fixture.runSetAnnotation(key: "k", text: "cafe\u{0301}")

        #expect(fixture.annotations()["k"]?.text == "café")
        #expect(fixture.annotations()["k"]?.text.unicodeScalars.count == 4)
    }

    @Test
    func countCapRejectsNewKeysButAllowsUpdatesAtCap() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }

        for index in 0..<WorkspaceAnnotation.maximumAnnotationsPerWorkspace {
            #expect(try fixture.runSetAnnotation(key: "key-\(index)", text: "v\(index)").didMutateState)
        }

        #expect(throws: (any Error).self) {
            try fixture.runSetAnnotation(key: "overflow", text: "nope")
        }
        #expect(try fixture.runSetAnnotation(key: "key-3", text: "updated").didMutateState)
        #expect(fixture.annotations().count == WorkspaceAnnotation.maximumAnnotationsPerWorkspace)
    }

    @Test
    func clearRemovesAnnotationButKeepsGlobalStyle() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }
        _ = try fixture.runSetAnnotation(key: "pr", text: "PR #1", color: "violet")

        #expect(try fixture.runClearAnnotation(key: "PR").didMutateState)
        #expect(fixture.annotations().isEmpty)
        // A later annotation with the same key reuses the persisted color.
        #expect(fixture.annotationStyleStore.effectiveColorToken(forKey: "pr") == .named(.violet))

        #expect(try fixture.runClearAnnotation(key: "pr").didMutateState == false)
    }

    @Test
    func colorOnlyChangeMutatesGlobalStyleEvenWhenAnnotationIsUnchanged() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }
        _ = try fixture.runSetAnnotation(key: "pr", text: "PR #1", color: "green")

        let outcome = try fixture.runSetAnnotation(key: "pr", text: "PR #1", color: "#123456")

        #expect(outcome.didMutateState)
        #expect(fixture.annotationStyleStore.effectiveColorToken(forKey: "pr") == .hex("#123456"))
        #expect(fixture.annotations()["pr"]?.text == "PR #1")
    }

    @Test
    func styleWriteFailureAbortsBeforeAnnotationMutation() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture(brokenStyleStore: true)
        defer { fixture.cleanup() }

        #expect(throws: (any Error).self) {
            try fixture.runSetAnnotation(key: "pr", text: "PR #1", color: "green")
        }
        #expect(fixture.annotations().isEmpty)
        #expect(fixture.annotationStyleStore.colorTokensByKey.isEmpty)

        // Without a color the same request needs no style write and succeeds.
        #expect(try fixture.runSetAnnotation(key: "pr", text: "PR #1").didMutateState)
    }

    @Test
    func unknownWorkspaceIsRejected() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }

        #expect(throws: (any Error).self) {
            try fixture.executor.runAction(
                id: "workspace.set-annotation",
                args: [
                    "workspaceID": .string(UUID().uuidString),
                    "key": .string("pr"),
                    "text": .string("PR #1"),
                ]
            )
        }
    }

    @Test
    func workspaceSnapshotListsAnnotationsInBytewiseOrderWithEffectiveColors() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }
        _ = try fixture.runSetAnnotation(key: "zeta", text: "last", color: "red")
        _ = try fixture.runSetAnnotation(key: "alpha", text: "first", url: "https://example.com/a")
        _ = try fixture.runSetAnnotation(key: "beta.1", text: "middle")

        let snapshot = try fixture.executor.runQuery(
            id: "workspace.snapshot",
            args: ["workspaceID": .string(fixture.workspaceID.uuidString)]
        )

        guard case .array(let annotations)? = snapshot["annotations"] else {
            Issue.record("workspace.snapshot did not return an annotations array")
            return
        }
        let keys: [AutomationJSONValue?] = annotations.map { entry in
            guard case .object(let object) = entry else { return nil }
            return object["key"]
        }
        #expect(keys == [.string("alpha"), .string("beta.1"), .string("zeta")])

        guard case .object(let zeta) = annotations[2],
              case .object(let alpha) = annotations[0] else {
            Issue.record("unexpected annotation entry shape")
            return
        }
        #expect(zeta["color"] == .string("red"))
        #expect(zeta["url"] == .null)
        #expect(alpha["url"] == .string("https://example.com/a"))
        #expect(alpha["color"] == .string(
            AnnotationStyleStore.fallbackColorToken(forKey: "alpha").storageValue
        ))
    }
}
