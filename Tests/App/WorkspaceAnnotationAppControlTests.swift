import CoreState
import Foundation
import Testing
@testable import ToasttyApp

private enum WorkspaceAnnotationFixtureError: Error {
    case inactiveUsageUnavailable
}

@MainActor
private final class WorkspaceAnnotationAppControlFixture {
    let store: AppStore
    let executor: AppControlExecutor
    let annotationStyleStore: AnnotationStyleStore
    let sessionRuntimeStore: SessionRuntimeStore
    let workspaceID: UUID
    private let runtimeHomeURL: URL

    init(
        brokenStyleStore: Bool = false,
        includeStyleStore: Bool = true,
        inactiveAnnotationUsageCounts: [String: Int] = [:],
        inactiveAnnotationUsageUnavailable: Bool = false
    ) throws {
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
        sessionRuntimeStore = SessionRuntimeStore()
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
            annotationStyleStore: includeStyleStore ? annotationStyleStore : nil,
            inactiveAnnotationUsageCountsProvider: {
                if inactiveAnnotationUsageUnavailable {
                    throw WorkspaceAnnotationFixtureError.inactiveUsageUnavailable
                }
                return inactiveAnnotationUsageCounts
            },
            reloadConfigurationAction: nil
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: runtimeHomeURL)
    }

    func annotations() -> [String: WorkspaceAnnotation] {
        store.state.workspacesByID[workspaceID]?.annotations ?? [:]
    }

    func primaryAnnotationKey() -> String? {
        store.state.workspacesByID[workspaceID]?.primaryAnnotationKey
    }

    func runSetAnnotation(
        key: String,
        text: String,
        url: String? = nil,
        color: String? = nil,
        primary: AutomationJSONValue? = nil,
        workspaceID targetWorkspaceID: UUID? = nil
    ) throws -> AppControlActionOutcome {
        var args: [String: AutomationJSONValue] = [
            "workspaceID": .string((targetWorkspaceID ?? workspaceID).uuidString),
            "key": .string(key),
            "text": .string(text),
        ]
        if let url {
            args["url"] = .string(url)
        }
        if let color {
            args["color"] = .string(color)
        }
        if let primary {
            args["primary"] = primary
        }
        return try executor.runAction(id: "workspace.set-annotation", args: args)
    }

    func createWorkspace() throws -> UUID {
        let windowID = try #require(store.state.windows.first?.id)
        let existingWorkspaceIDs = Set(store.state.workspacesByID.keys)
        #expect(store.send(.createWorkspace(windowID: windowID, title: nil, activate: false)))
        return try #require(store.state.workspacesByID.keys.first(where: {
            existingWorkspaceIDs.contains($0) == false
        }))
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
    func annotationKeysDescriptorExplainsRuntimeGlobalHistory() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }

        let descriptor = try #require(
            fixture.executor.listQueryDescriptors().first(where: {
                $0.id == AppControlQueryID.annotationKeys.rawValue
            })
        )

        #expect(descriptor.selectors.isEmpty)
        #expect(descriptor.summary.contains("runtime-global"))
        #expect(descriptor.summary.contains("previously registered"))
    }

    @Test
    func annotationKeysQueryReturnsSortedHistoricalKeysOnly() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }
        _ = try fixture.runSetAnnotation(key: "zeta", text: "last", color: "red")
        _ = try fixture.runSetAnnotation(key: "alpha", text: "first", color: "green")
        _ = try fixture.runClearAnnotation(key: "alpha")

        let snapshot = try fixture.executor.runQuery(
            id: AppControlQueryID.annotationKeys.rawValue,
            args: [:]
        )

        #expect(snapshot.keys.sorted() == ["keys"])
        guard case .array(let keys)? = snapshot["keys"] else {
            Issue.record("annotation.keys did not return a keys array")
            return
        }
        #expect(keys == [.string("alpha"), .string("zeta")])
    }

    @Test
    func annotationKeysQueryReturnsEmptyArrayForFreshRegistry() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }

        let snapshot = try fixture.executor.runQuery(
            id: AppControlQueryID.annotationKeys.rawValue,
            args: [:]
        )

        #expect(snapshot["keys"] == .array([]))
    }

    @Test
    func annotationKeysQueryIsRuntimeIsolated() throws {
        let firstFixture = try WorkspaceAnnotationAppControlFixture()
        let secondFixture = try WorkspaceAnnotationAppControlFixture()
        defer {
            firstFixture.cleanup()
            secondFixture.cleanup()
        }
        _ = try firstFixture.runSetAnnotation(key: "linear", text: "LIN-030")

        let firstSnapshot = try firstFixture.executor.runQuery(
            id: AppControlQueryID.annotationKeys.rawValue,
            args: [:]
        )
        let secondSnapshot = try secondFixture.executor.runQuery(
            id: AppControlQueryID.annotationKeys.rawValue,
            args: [:]
        )

        #expect(firstSnapshot["keys"] == .array([.string("linear")]))
        #expect(secondSnapshot["keys"] == .array([]))
    }

    @Test
    func scopedCallerCanReadRuntimeGlobalAnnotationKeys() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }
        let otherWorkspaceID = try fixture.createWorkspace()
        _ = try fixture.runSetAnnotation(
            key: "github-pr",
            text: "PR #4512",
            workspaceID: otherWorkspaceID
        )
        let selection = try #require(fixture.store.state.selectedWorkspaceSelection())
        let panelID = try #require(selection.workspace.focusedPanelID)
        fixture.sessionRuntimeStore.startSession(
            sessionID: "annotation-keys-scoped-caller",
            agent: .codex,
            panelID: panelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: nil,
            repoRoot: nil,
            scopedWorkspaceIDs: [],
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let snapshot = try fixture.executor.runQuery(
            id: AppControlQueryID.annotationKeys.rawValue,
            args: [:],
            context: AutomationRequestContext(
                callerSessionID: "annotation-keys-scoped-caller",
                commandName: "app_control.run_query"
            )
        )

        #expect(snapshot["keys"] == .array([.string("github-pr")]))
    }

    @Test
    func annotationKeysQueryRejectsUnavailableStyleStore() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture(includeStyleStore: false)
        defer { fixture.cleanup() }

        #expect(throws: AutomationSocketError.self) {
            try fixture.executor.runQuery(
                id: AppControlQueryID.annotationKeys.rawValue,
                args: [:]
            )
        }
    }

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
        #expect(fixture.annotationStyleStore.colorTokensByKey["pr"] != nil)
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
    func liveAnnotationRejectsAConflictingColorWithoutMutatingEitherStore() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }
        _ = try fixture.runSetAnnotation(key: "pr", text: "PR #1", color: "green")

        do {
            _ = try fixture.runSetAnnotation(key: "pr", text: "PR #2", color: "blue")
            Issue.record("expected a conflicting live color to be rejected")
        } catch let error as AutomationSocketError {
            #expect(error.errorBody.code == "ANNOTATION_COLOR_LOCKED")
            #expect(error.errorBody.message.contains("green"))
        }

        #expect(fixture.annotationStyleStore.effectiveColorToken(forKey: "pr") == .named(.green))
        #expect(fixture.annotations()["pr"]?.text == "PR #1")
    }

    @Test
    func thirdWorkspaceCannotRecolorTwoExistingGitBranchAnnotations() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }
        let secondWorkspaceID = try fixture.createWorkspace()
        let thirdWorkspaceID = try fixture.createWorkspace()

        _ = try fixture.runSetAnnotation(
            key: "git-branch",
            text: "first",
            color: "green"
        )
        _ = try fixture.runSetAnnotation(
            key: "git-branch",
            text: "second",
            workspaceID: secondWorkspaceID
        )

        #expect(throws: AutomationSocketError.self) {
            try fixture.runSetAnnotation(
                key: "git-branch",
                text: "third",
                color: "blue",
                workspaceID: thirdWorkspaceID
            )
        }

        #expect(fixture.annotationStyleStore.colorTokensByKey["git-branch"] == .named(.green))
        #expect(fixture.store.state.workspacesByID[fixture.workspaceID]?.annotations["git-branch"]?.text == "first")
        #expect(fixture.store.state.workspacesByID[secondWorkspaceID]?.annotations["git-branch"]?.text == "second")
        #expect(fixture.store.state.workspacesByID[thirdWorkspaceID]?.annotations["git-branch"] == nil)
    }

    @Test
    func liveAnnotationAcceptsMatchingVisualColorWithoutRewritingClaim() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }
        _ = try fixture.runSetAnnotation(key: "pr", text: "PR #1", color: "blue")

        let outcome = try fixture.runSetAnnotation(
            key: "pr",
            text: "PR #2",
            color: "#7AA2F7"
        )

        #expect(outcome.didMutateState)
        #expect(fixture.annotationStyleStore.colorTokensByKey["pr"] == .named(.blue))
        #expect(fixture.annotations()["pr"]?.text == "PR #2")
    }

    @Test
    func finalClearUnlocksClaimForExplicitReplacement() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }
        _ = try fixture.runSetAnnotation(key: "pr", text: "PR #1", color: "green")
        _ = try fixture.runClearAnnotation(key: "pr")

        let outcome = try fixture.runSetAnnotation(key: "pr", text: "PR #2", color: "blue")

        #expect(outcome.didMutateState)
        #expect(fixture.annotationStyleStore.colorTokensByKey["pr"] == .named(.blue))
    }

    @Test
    func inactiveProfileUsageKeepsClaimLockedAfterLocalClear() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture(
            inactiveAnnotationUsageCounts: ["pr": 1]
        )
        defer { fixture.cleanup() }
        _ = try fixture.runSetAnnotation(key: "pr", text: "PR #1")
        let claimedColor = try #require(fixture.annotationStyleStore.colorTokensByKey["pr"])
        _ = try fixture.runClearAnnotation(key: "pr")

        #expect(throws: AutomationSocketError.self) {
            try fixture.runSetAnnotation(key: "pr", text: "PR #2", color: "red")
        }
        #expect(fixture.annotations().isEmpty)
        #expect(fixture.annotationStyleStore.colorTokensByKey["pr"] == claimedColor)
    }

    @Test
    func unreadableInactiveProfilesFailClosedWithoutChangingUnlockedClaim() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture(
            inactiveAnnotationUsageUnavailable: true
        )
        defer { fixture.cleanup() }
        _ = try fixture.runSetAnnotation(key: "pr", text: "PR #1", color: "green")
        _ = try fixture.runClearAnnotation(key: "pr")

        do {
            _ = try fixture.runSetAnnotation(key: "pr", text: "PR #2", color: "blue")
            Issue.record("expected unavailable inactive usage to reject replacement")
        } catch let error as AutomationSocketError {
            #expect(error.errorBody.code == "ANNOTATION_USAGE_UNAVAILABLE")
        }

        #expect(fixture.annotations().isEmpty)
        #expect(fixture.annotationStyleStore.colorTokensByKey["pr"] == .named(.green))
    }

    @Test
    func legacyAnnotationWithoutRecordedClaimAdoptsFirstExplicitColor() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }
        #expect(fixture.store.send(.setWorkspaceAnnotation(
            workspaceID: fixture.workspaceID,
            key: "pr",
            annotation: WorkspaceAnnotation(text: "legacy")
        )))
        #expect(fixture.annotationStyleStore.colorTokensByKey["pr"] == nil)

        let outcome = try fixture.runSetAnnotation(key: "pr", text: "updated", color: "blue")

        #expect(outcome.didMutateState)
        #expect(fixture.annotationStyleStore.colorTokensByKey["pr"] == .named(.blue))
        #expect(fixture.annotations()["pr"]?.text == "updated")
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

        // Automatic first-use claims are also durable, so an unwritable style
        // store rejects colorless requests before adding an annotation.
        #expect(throws: (any Error).self) {
            try fixture.runSetAnnotation(key: "pr", text: "PR #1")
        }
        #expect(fixture.annotations().isEmpty)
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
    func primaryRoleMovesBetweenKeysAndClearsWithItsAnnotation() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }

        _ = try fixture.runSetAnnotation(key: "github-pr", text: "#12")
        #expect(fixture.primaryAnnotationKey() == nil)

        #expect(try fixture.runSetAnnotation(key: "linear", text: "ENG-5", primary: .bool(true)).didMutateState)
        #expect(fixture.primaryAnnotationKey() == "linear")

        // Omitting primary on an update keeps the role; string booleans from
        // the CLI parse like JSON ones.
        _ = try fixture.runSetAnnotation(key: "linear", text: "ENG-6")
        #expect(fixture.primaryAnnotationKey() == "linear")
        #expect(try fixture.runSetAnnotation(key: "github-pr", text: "#12", primary: .string("true")).didMutateState)
        #expect(fixture.primaryAnnotationKey() == "github-pr")

        // false only removes the role from the key that holds it.
        #expect(try fixture.runSetAnnotation(key: "linear", text: "ENG-6", primary: .bool(false)).didMutateState == false)
        #expect(fixture.primaryAnnotationKey() == "github-pr")
        #expect(try fixture.runSetAnnotation(key: "github-pr", text: "#12", primary: .bool(false)).didMutateState)
        #expect(fixture.primaryAnnotationKey() == nil)

        _ = try fixture.runSetAnnotation(key: "linear", text: "ENG-6", primary: .bool(true))
        _ = try fixture.runClearAnnotation(key: "linear")
        #expect(fixture.primaryAnnotationKey() == nil)

        #expect(throws: AutomationSocketError.self) {
            try fixture.runSetAnnotation(key: "linear", text: "ENG-6", primary: .string("maybe"))
        }
        #expect(fixture.annotations()["linear"] == nil)
    }

    @Test
    func workspaceSnapshotListsAnnotationsInBytewiseOrderWithEffectiveColors() throws {
        let fixture = try WorkspaceAnnotationAppControlFixture()
        defer { fixture.cleanup() }
        _ = try fixture.runSetAnnotation(key: "zeta", text: "last", color: "red")
        _ = try fixture.runSetAnnotation(key: "alpha", text: "first", url: "https://example.com/a")
        _ = try fixture.runSetAnnotation(key: "beta.1", text: "middle", primary: .bool(true))

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
        let primaryFlags: [AutomationJSONValue?] = annotations.map { entry in
            guard case .object(let object) = entry else { return nil }
            return object["primary"]
        }
        #expect(primaryFlags == [.bool(false), .bool(true), .bool(false)])
    }
}
