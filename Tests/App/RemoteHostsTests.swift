import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp
import ToasttyMobileDomain

struct RemoteHostsFileTests {
    @Test func templateParsesAsNoRemotes() throws {
        #expect(try RemoteHostsFile.parse(contents: RemoteHostsFile.templateContents()).isEmpty)
    }

    @Test func parsesRemotesInFileOrderWithCanonicalGatewayAndDefaultName() throws {
        let hosts = try RemoteHostsFile.parse(contents: """
        # comment
        [mini]
        displayName = "Mini" # trailing comment
        gatewayURL = "https://Mini.Example-Tailnet.ts.net/"
        sshDestination = "vishal@mini"

        [studio]
        gatewayURL = "studio.example-tailnet.ts.net"
        sshDestination = "studio"
        """)

        #expect(hosts == [
            RemoteHostConfiguration(
                id: "mini",
                displayName: "Mini",
                gatewayURL: URL(string: "https://mini.example-tailnet.ts.net")!,
                sshDestination: "vishal@mini"
            ),
            RemoteHostConfiguration(
                id: "studio",
                displayName: "studio",
                gatewayURL: URL(string: "https://studio.example-tailnet.ts.net")!,
                sshDestination: "studio"
            ),
        ])
    }

    /// The remote ID is typed into a local shell and the destination is an
    /// `ssh` argument, so neither may carry shell syntax or look like an
    /// option. The gateway must be an address pairing accepts.
    @Test(arguments: [
        "[mini box]\ngatewayURL = \"https://mini.example.ts.net\"\nsshDestination = \"mini\"",
        "[mini;rm]\ngatewayURL = \"https://mini.example.ts.net\"\nsshDestination = \"mini\"",
        "[-mini]\ngatewayURL = \"https://mini.example.ts.net\"\nsshDestination = \"mini\"",
        "[mini]\ngatewayURL = \"https://mini.example.ts.net\"\nsshDestination = \"-oProxyCommand=x\"",
        "[mini]\ngatewayURL = \"https://mini.example.ts.net\"\nsshDestination = \"mini box\"",
        "[mini]\ngatewayURL = \"http://mini.example.ts.net\"\nsshDestination = \"mini\"",
        "[mini]\ngatewayURL = \"https://mini.example.com\"\nsshDestination = \"mini\"",
        "[mini]\ngatewayURL = \"https://mini.example.ts.net:8443\"\nsshDestination = \"mini\"",
        "[mini]\nsshDestination = \"mini\"",
        "[mini]\ngatewayURL = \"https://mini.example.ts.net\"",
        "[mini]\ngatewayURL = \"https://mini.example.ts.net\"\nsshDestination = \"mini\"\nconnectCommand = \"mosh\"",
        "[mini]\ngatewayURL = \"https://a.example.ts.net\"\nsshDestination = \"a\"\n[mini]\ngatewayURL = \"https://b.example.ts.net\"\nsshDestination = \"b\"",
        "gatewayURL = \"https://mini.example.ts.net\"",
    ])
    func rejectsUnsafeOrIncompleteTables(contents: String) {
        #expect(throws: RemoteHostsParseError.self) {
            try RemoteHostsFile.parse(contents: contents)
        }
    }
}

struct RemoteHostAttachTests {
    @Test func resolvesTheHostCommandForALiveAttachableSession() throws {
        let target = try RemoteHostAttach.target(
            host: RemoteHostsFixtures.host(),
            conversationID: RemoteHostsFixtures.attachableID
        ).get()

        #expect(target == RemoteHostAttachTarget(
            remoteID: "mini",
            displayName: "Mini",
            sshDestination: "mini",
            command: RemoteHostsFixtures.attachCommand,
            conversationTitle: "Fix sidebar hover"
        ))
    }

    /// A session list kept from an earlier connection never yields a command:
    /// the remote may have been unpaired or revoked since.
    @Test(arguments: [
        RemoteHostConnectionStatus.reconnecting, .notPaired, .accessDenied, .connecting, .failed,
    ])
    func refusesWhileTheRemoteIsNotConnected(status: RemoteHostConnectionStatus) {
        #expect(RemoteHostAttach.target(
            host: RemoteHostsFixtures.host(status: status),
            conversationID: RemoteHostsFixtures.attachableID
        ) == .failure(.notConnected))
    }

    @Test func refusesUnknownRemotesSessionsAndSessionsWithoutATerminal() {
        #expect(RemoteHostAttach.target(host: nil, conversationID: RemoteHostsFixtures.attachableID)
            == .failure(.unknownRemote))
        #expect(RemoteHostAttach.target(host: RemoteHostsFixtures.host(), conversationID: UUID())
            == .failure(.unknownConversation))
        #expect(RemoteHostAttach.target(
            host: RemoteHostsFixtures.host(), conversationID: RemoteHostsFixtures.plainID
        ) == .failure(.noAttachCommand))
        #expect(RemoteHostAttach.target(
            host: RemoteHostsFixtures.host(supportsTerminalAttach: false),
            conversationID: RemoteHostsFixtures.attachableID
        ) == .failure(.hostDoesNotSupportAttach))
    }

    /// The typed line carries no host text, only the remote ID and a UUID.
    @Test func typedLineHoldsOnlyTheCLIVariableTheRemoteIDAndTheConversationID() {
        #expect(RemoteHostAttach.shellCommandLine(
            remoteID: "mini", conversationID: RemoteHostsFixtures.attachableID
        ) == "\"$TOASTTY_CLI_PATH\" remote attach mini 00000000-0000-0000-0000-0000000000A1")
        #expect(RemoteHostAttach.shellCommandLine(
            remoteID: "mini; rm -rf ~", conversationID: RemoteHostsFixtures.attachableID
        ) == nil)
    }
}

struct RemoteHostSidebarPresentationTests {
    @Test func listsWorkspacesWithSessionsAndNestsSubspacesUnderTheirParent() {
        let presentation = RemoteHostSidebarPresentation(host: RemoteHostsFixtures.host())

        #expect(presentation.isLive)
        #expect(presentation.statusLabel == nil)
        // The workspace that only holds panels is left out.
        #expect(presentation.workspaces.map(\.title) == ["toastty", "ios-new-session"])
        #expect(presentation.workspaces.map(\.isSubspace) == [false, true])
        #expect(presentation.sessionCount == 3)

        let sessions = presentation.workspaces[0].sessions
        let attachable = sessions.first { $0.id == RemoteHostsFixtures.attachableID }
        #expect(attachable?.title == "Fix sidebar hover")
        #expect(attachable?.agentName == "Claude Code")
        #expect(attachable?.statusKind == .needsApproval)
        #expect(attachable?.detail == "Running tests")
        #expect(attachable?.canAttach == true)

        // A session whose host pane has no multiplexer recipe is listed, and
        // says why it cannot open.
        let plain = sessions.first { $0.id == RemoteHostsFixtures.plainID }
        #expect(plain?.canAttach == false)
        #expect(plain?.attachUnavailableReason?.contains("remoteAttachCommand") == true)
    }

    @Test func aDisconnectedRemoteKeepsItsRowsButNoneCanOpen() {
        let presentation = RemoteHostSidebarPresentation(host: RemoteHostsFixtures.host(status: .reconnecting))

        #expect(presentation.isLive == false)
        #expect(presentation.statusLabel == "reconnecting")
        #expect(presentation.sessionCount == 3)
        #expect(presentation.workspaces.flatMap(\.sessions).allSatisfy { $0.canAttach == false })
    }

    @Test func anUnpairedRemoteOffersPairing() {
        let presentation = RemoteHostSidebarPresentation(
            host: RemoteHostState(configuration: RemoteHostsFixtures.mini, status: .notPaired)
        )

        #expect(presentation.offersPairing)
        #expect(presentation.statusLabel == "not paired")
        #expect(presentation.workspaces.isEmpty)
    }
}

struct RemoteHostPairingInputTests {
    private static func offer(gateway: String) throws -> RemoteNativePairingOffer {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-remote-hosts-pairing-\(UUID().uuidString)", isDirectory: true)
        let devices = RemoteDeviceStore(fileURL: directory.appendingPathComponent("devices.json"))
        return try devices.issueNativePairingOffer(gatewayURL: URL(string: gateway)!, at: Date())
    }

    @Test func aFallbackCodeIsBoundToTheConfiguredGateway() throws {
        let offer = try Self.offer(gateway: "https://mini.example-tailnet.ts.net")

        let candidate = try RemoteHostsStore.pairingCandidate(
            input: " \(offer.fallbackCode) ",
            configuration: RemoteHostsFixtures.mini
        ).get()

        #expect(candidate.gatewayURL == RemoteHostsFixtures.mini.gatewayURL)
        #expect(candidate.proof == .manual(fallbackCode: offer.fallbackCode))
    }

    @Test func pairingTextForTheConfiguredGatewayIsAccepted() throws {
        let offer = try Self.offer(gateway: "https://mini.example-tailnet.ts.net")

        let candidate = try RemoteHostsStore.pairingCandidate(
            input: try offer.qrPayload.encodedString(),
            configuration: RemoteHostsFixtures.mini
        ).get()

        #expect(candidate.gatewayURL == RemoteHostsFixtures.mini.gatewayURL)
    }

    /// The offer's secret must not go to a gateway other than the one this
    /// remote is configured for.
    @Test func pairingTextForAnotherGatewayIsRefused() throws {
        let offer = try Self.offer(gateway: "https://other.example-tailnet.ts.net")

        #expect(RemoteHostsStore.pairingCandidate(
            input: try offer.qrPayload.encodedString(),
            configuration: RemoteHostsFixtures.mini
        ) == .failure(.gatewayMismatch(expectedHost: "mini.example-tailnet.ts.net")))
    }

    @Test func malformedInputIsRefused() {
        #expect(RemoteHostsStore.pairingCandidate(input: "nope", configuration: RemoteHostsFixtures.mini)
            == .failure(.invalidCode))
        #expect(RemoteHostsStore.pairingCandidate(input: "toastty-pairing:v1:xx", configuration: RemoteHostsFixtures.mini)
            == .failure(.invalidCode))
    }
}

// MARK: - Store against a fake gateway

@MainActor
struct RemoteHostsStoreTests {
    private static func exchangeResponse() -> RemoteGatewayNativePairingExchangeResponse {
        RemoteHostsFixtures.exchangeResponse()
    }

    private static func storedCredential(
        gateway: URL = RemoteHostsFixtures.mini.gatewayURL
    ) throws -> StoredMobileCredential {
        try RemoteHostsFixtures.storedCredential(gateway: gateway)
    }

    /// Mutable so a test can change `remotes.toml` between reloads.
    private final class Configurations {
        var value: [RemoteHostConfiguration]
        init(_ value: [RemoteHostConfiguration]) { self.value = value }
    }

    private static func makeStore(
        configurations: Configurations,
        credentialStore: RemoteHostsInMemoryCredentialStore,
        gateway: RemoteHostsFakeGateway = RemoteHostsFakeGateway(),
        pairing: Result<RemoteGatewayNativePairingExchangeResponse, NativeGatewayFailure> = .success(exchangeResponse()),
        revoked: @escaping @Sendable () -> Void = {}
    ) -> RemoteHostsStore {
        RemoteHostsStore(dependencies: .init(
            loadConfigurations: { configurations.value },
            credentialStore: { _ in credentialStore },
            makeCoordinator: { _, _, scopes in
                ConnectionCoordinator(
                    gateway: gateway,
                    eventStream: RemoteHostsFakeEventStream(snapshot: RemoteHostsFixtures.snapshot()),
                    deviceScopes: scopes
                )
            },
            pairingClient: RemoteHostsFakePairingClient(result: pairing),
            revokeDevice: { _, _ in revoked() },
            deviceName: { "Laptop" }
        ))
    }

    private static func waitFor(
        _ store: RemoteHostsStore,
        _ condition: (RemoteHostState?) -> Bool
    ) async throws -> RemoteHostState? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let host = store.host(id: "mini")
            if condition(host) { return host }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out; last status \(String(describing: store.host(id: "mini")?.status))")
        return store.host(id: "mini")
    }

    @Test func aPairedRemoteConnectsAndListsItsSessions() async throws {
        let store = Self.makeStore(
            configurations: Configurations([RemoteHostsFixtures.mini]),
            credentialStore: RemoteHostsInMemoryCredentialStore(credential: try Self.storedCredential())
        )

        #expect(store.reload().failure == nil)
        let host = try await Self.waitFor(store) { $0?.status == .live && $0?.supportsTerminalAttach == true }

        #expect(host?.snapshot?.conversations.count == 3)
        #expect(try RemoteHostAttach.target(host: host, conversationID: RemoteHostsFixtures.attachableID)
            .get().command == RemoteHostsFixtures.attachCommand)
    }

    @Test func anOlderHostListsSessionsButOffersNoTerminal() async throws {
        let store = Self.makeStore(
            configurations: Configurations([RemoteHostsFixtures.mini]),
            credentialStore: RemoteHostsInMemoryCredentialStore(credential: try Self.storedCredential()),
            gateway: RemoteHostsFakeGateway(capabilities: [.nativeBearerPairing, .workspacePanels])
        )

        store.reload()
        let host = try await Self.waitFor(store) { $0?.status == .live }

        #expect(host?.supportsTerminalAttach == false)
        #expect(RemoteHostAttach.target(host: host, conversationID: RemoteHostsFixtures.attachableID)
            == .failure(.hostDoesNotSupportAttach))
    }

    @Test func aRemoteWithoutACredentialWaitsForPairingAndConnectsAfterIt() async throws {
        let credentials = RemoteHostsInMemoryCredentialStore()
        let store = Self.makeStore(
            configurations: Configurations([RemoteHostsFixtures.mini]),
            credentialStore: credentials
        )
        store.reload()
        _ = try await Self.waitFor(store) { $0?.status == .notPaired }
        let offerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-remote-hosts-store-\(UUID().uuidString)", isDirectory: true)
        let offer = try RemoteDeviceStore(fileURL: offerDirectory.appendingPathComponent("devices.json"))
            .issueNativePairingOffer(gatewayURL: RemoteHostsFixtures.mini.gatewayURL, at: Date())

        #expect(await store.pair(remoteID: "mini", input: offer.fallbackCode).failure == nil)
        let host = try await Self.waitFor(store) { $0?.status == .live }

        #expect(host?.snapshot != nil)
        #expect(credentials.current?.gatewayURL == RemoteHostsFixtures.mini.gatewayURL)
    }

    @Test func aRejectedCodeLeavesTheRemoteUnpaired() async throws {
        let credentials = RemoteHostsInMemoryCredentialStore()
        let store = Self.makeStore(
            configurations: Configurations([RemoteHostsFixtures.mini]),
            credentialStore: credentials,
            pairing: .failure(.pairingRejected(.invalidOrExpiredOffer))
        )
        store.reload()
        _ = try await Self.waitFor(store) { $0?.status == .notPaired }
        let offerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-remote-hosts-store-\(UUID().uuidString)", isDirectory: true)
        let offer = try RemoteDeviceStore(fileURL: offerDirectory.appendingPathComponent("devices.json"))
            .issueNativePairingOffer(gatewayURL: RemoteHostsFixtures.mini.gatewayURL, at: Date())

        #expect(await store.pair(remoteID: "mini", input: offer.fallbackCode).failure == .rejected)
        #expect(store.host(id: "mini")?.status == .notPaired)
        #expect(credentials.current == nil)
    }

    /// Tailscale Serve forwarding to the wrong port answers 502. The message
    /// must point at the gateway address, not say only that pairing failed.
    @Test func aProxyErrorFromTheGatewayAddressIsReportedAsNotServingToastty() async throws {
        let store = Self.makeStore(
            configurations: Configurations([RemoteHostsFixtures.mini]),
            credentialStore: RemoteHostsInMemoryCredentialStore(),
            pairing: .failure(.server(operation: .pairingExchange, statusCode: 502))
        )
        store.reload()
        _ = try await Self.waitFor(store) { $0?.status == .notPaired }
        let offerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-remote-hosts-store-\(UUID().uuidString)", isDirectory: true)
        let offer = try RemoteDeviceStore(fileURL: offerDirectory.appendingPathComponent("devices.json"))
            .issueNativePairingOffer(gatewayURL: RemoteHostsFixtures.mini.gatewayURL, at: Date())

        let failure = await store.pair(remoteID: "mini", input: offer.fallbackCode).failure

        #expect(failure == .gatewayNotServing(statusCode: 502))
        #expect(failure?.localizedDescription.contains("HTTP 502") == true)
        #expect(failure?.localizedDescription.contains("tailscale serve") == true)
    }

    /// A credential issued by one gateway is never sent to another, even
    /// when both are stored under the same remote ID.
    @Test func aCredentialForAnotherGatewayIsNotUsed() async throws {
        let store = Self.makeStore(
            configurations: Configurations([RemoteHostsFixtures.mini]),
            credentialStore: RemoteHostsInMemoryCredentialStore(
                credential: try Self.storedCredential(gateway: URL(string: "https://old.example-tailnet.ts.net")!)
            )
        )

        store.reload()
        let host = try await Self.waitFor(store) { $0?.status != .connecting }

        #expect(host?.status == .notPaired)
        #expect(host?.snapshot == nil)
    }

    @Test func aHostThatRejectsTheCredentialReturnsToUnpairedAndForgetsIt() async throws {
        let credentials = RemoteHostsInMemoryCredentialStore(credential: try Self.storedCredential())
        let store = Self.makeStore(
            configurations: Configurations([RemoteHostsFixtures.mini]),
            credentialStore: credentials,
            gateway: RemoteHostsFakeGateway(helloFailure: .unauthenticated(code: nil, message: nil))
        )

        store.reload()
        let host = try await Self.waitFor(store) { $0?.status == .notPaired }

        #expect(host?.snapshot == nil)
        #expect(credentials.current == nil)
    }

    @Test func unpairRevokesOnTheHostForgetsTheCredentialAndDropsTheSessionList() async throws {
        let credentials = RemoteHostsInMemoryCredentialStore(credential: try Self.storedCredential())
        let revokeCount = LockedCounter()
        let store = Self.makeStore(
            configurations: Configurations([RemoteHostsFixtures.mini]),
            credentialStore: credentials,
            revoked: { revokeCount.increment() }
        )
        store.reload()
        _ = try await Self.waitFor(store) { $0?.status == .live }

        #expect(await store.unpair(remoteID: "mini").failure == nil)

        let host = store.host(id: "mini")
        #expect(host?.status == .notPaired)
        #expect(host?.snapshot == nil)
        #expect(credentials.current == nil)
        #expect(revokeCount.value == 1)
        #expect(RemoteHostAttach.target(host: host, conversationID: RemoteHostsFixtures.attachableID)
            == .failure(.notConnected))
    }

    /// The host could not be told, and the keychain kept the credential. It
    /// would connect again on the next launch, so the remote must not show
    /// as unpaired.
    @Test func unpairThatCannotRemoveTheCredentialSaysSoAndStaysRepairable() async throws {
        let credentials = RemoteHostsInMemoryCredentialStore(credential: try Self.storedCredential())
        let store = Self.makeStore(
            configurations: Configurations([RemoteHostsFixtures.mini]),
            credentialStore: credentials
        )
        store.reload()
        _ = try await Self.waitFor(store) { $0?.status == .live }
        credentials.failsDeletion = true

        #expect(await store.unpair(remoteID: "mini").failure == .keychain)

        let host = store.host(id: "mini")
        #expect(host?.status == .credentialUnavailable)
        #expect(host?.snapshot == nil)
        #expect(credentials.current != nil)

        credentials.failsDeletion = false
        #expect(await store.unpair(remoteID: "mini").failure == nil)
        #expect(store.host(id: "mini")?.status == .notPaired)
        #expect(credentials.current == nil)
    }

    /// Pairing again while connected retires the old connection before the
    /// new credential is stored, so nothing the old connection reports
    /// afterward can remove it.
    @Test func pairingAgainWhileConnectedReplacesTheConnectionAndKeepsTheNewCredential() async throws {
        let credentials = RemoteHostsInMemoryCredentialStore(credential: try Self.storedCredential())
        let gateway = RemoteHostsFakeGateway()
        let store = Self.makeStore(
            configurations: Configurations([RemoteHostsFixtures.mini]),
            credentialStore: credentials,
            gateway: gateway
        )
        store.reload()
        _ = try await Self.waitFor(store) { $0?.status == .live }
        let offerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-remote-hosts-store-\(UUID().uuidString)", isDirectory: true)
        let offer = try RemoteDeviceStore(fileURL: offerDirectory.appendingPathComponent("devices.json"))
            .issueNativePairingOffer(gatewayURL: RemoteHostsFixtures.mini.gatewayURL, at: Date())

        #expect(await store.pair(remoteID: "mini", input: offer.fallbackCode).failure == nil)
        _ = try await Self.waitFor(store) { $0?.status == .live }
        let pairedCredential = try #require(credentials.current)

        // The stored credential is still the one pairing installed.
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.host(id: "mini")?.status == .live)
        #expect(credentials.current == pairedCredential)
    }

    @Test func aFailedPairAgainKeepsTheExistingConnection() async throws {
        let credentials = RemoteHostsInMemoryCredentialStore(credential: try Self.storedCredential())
        let store = Self.makeStore(
            configurations: Configurations([RemoteHostsFixtures.mini]),
            credentialStore: credentials,
            pairing: .failure(.pairingRejected(.invalidOrExpiredOffer))
        )
        store.reload()
        _ = try await Self.waitFor(store) { $0?.status == .live }
        let offerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-remote-hosts-store-\(UUID().uuidString)", isDirectory: true)
        let offer = try RemoteDeviceStore(fileURL: offerDirectory.appendingPathComponent("devices.json"))
            .issueNativePairingOffer(gatewayURL: RemoteHostsFixtures.mini.gatewayURL, at: Date())

        #expect(await store.pair(remoteID: "mini", input: offer.fallbackCode).failure == .rejected)

        #expect(store.host(id: "mini")?.status == .live)
        #expect(credentials.current != nil)
    }

    @Test func removingATableDropsTheRemoteAndChangingItsGatewayStartsOver() async throws {
        let configurations = Configurations([RemoteHostsFixtures.mini])
        let store = Self.makeStore(
            configurations: configurations,
            credentialStore: RemoteHostsInMemoryCredentialStore(credential: try Self.storedCredential())
        )
        store.reload()
        _ = try await Self.waitFor(store) { $0?.status == .live }

        // The stored credential belongs to the old gateway, so the changed
        // table does not connect with it.
        configurations.value = [RemoteHostConfiguration(
            id: "mini",
            displayName: "Mini",
            gatewayURL: URL(string: "https://moved.example-tailnet.ts.net")!,
            sshDestination: "mini"
        )]
        store.reload()
        let moved = try await Self.waitFor(store) { $0?.status == .notPaired }
        #expect(moved?.snapshot == nil)

        configurations.value = []
        store.reload()
        #expect(store.hosts.isEmpty)
    }
}

private extension Result where Success == Void {
    /// `Result<Void, _>` is not Equatable, so tests compare the failure.
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

// MARK: - Opening a terminal

@MainActor
struct RemoteHostTerminalOpenerTests {
    private static func liveHostsStore() async throws -> RemoteHostsStore {
        let store = RemoteHostsFixtures.makeStore()
        store.reload()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.host(id: "mini")?.status != .live, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.host(id: "mini")?.status == .live)
        return store
    }

    @Test func openingASessionAddsATabThatRunsTheAttachCommandAndReusesItAfterward() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try #require(store.state.windows.first?.id)
        let localWorkspaceID = try #require(store.state.windows.first?.selectedWorkspaceID)
        let registry = TerminalRuntimeRegistry()
        let opener = RemoteHostTerminalOpener(
            store: store,
            terminalRuntimeRegistry: registry,
            hostsStore: try await Self.liveHostsStore(),
            homeDirectoryPath: "/tmp"
        )

        #expect(opener.open(
            remoteID: "mini", conversationID: RemoteHostsFixtures.attachableID, windowID: windowID
        ).failure == nil)

        // The first session gets a workspace named after the remote.
        let window = try #require(store.state.windows.first)
        #expect(window.workspaceIDs.count == 2)
        let remoteWorkspaceID = try #require(window.workspaceIDs.last)
        #expect(window.selectedWorkspaceID == remoteWorkspaceID)
        let remoteWorkspace = try #require(store.state.workspacesByID[remoteWorkspaceID])
        #expect(remoteWorkspace.title == "Mini")
        let firstTabID = try #require(remoteWorkspace.tabIDs.first)
        let firstPanelID = try #require(remoteWorkspace.tab(id: firstTabID)?.panels.keys.first)
        let attachLine = "\"$TOASTTY_CLI_PATH\" remote attach mini 00000000-0000-0000-0000-0000000000A1"
        // The command stays available until the surface has launched, so a
        // failed surface creation can try again. After that it is typed
        // never again: a later surface for the panel is a plain shell.
        #expect(registry.pendingInitialInput(forPanelID: firstPanelID) == attachLine)
        #if TOASTTY_HAS_GHOSTTY_KIT
        #expect(registry.surfaceLaunchConfiguration(for: firstPanelID).initialInput == attachLine)
        #expect(registry.surfaceLaunchConfiguration(for: firstPanelID).initialInput == attachLine)
        registry.markInitialSurfaceLaunchCompleted(for: firstPanelID)
        #expect(registry.surfaceLaunchConfiguration(for: firstPanelID).initialInput == nil)
        #endif

        // A second session goes to the same workspace as another tab.
        #expect(opener.open(
            remoteID: "mini", conversationID: RemoteHostsFixtures.subspaceSessionID, windowID: windowID
        ).failure == nil)
        let afterSecond = try #require(store.state.workspacesByID[remoteWorkspaceID])
        #expect(store.state.windows.first?.workspaceIDs.count == 2)
        #expect(afterSecond.tabIDs.count == 2)
        #expect(afterSecond.resolvedSelectedTabID == afterSecond.tabIDs.last)

        // Opening the first session again shows its tab and adds nothing.
        #expect(store.send(.selectWorkspace(windowID: windowID, workspaceID: localWorkspaceID)))
        #expect(opener.open(
            remoteID: "mini", conversationID: RemoteHostsFixtures.attachableID, windowID: windowID
        ).failure == nil)
        let afterReopen = try #require(store.state.workspacesByID[remoteWorkspaceID])
        #expect(afterReopen.tabIDs.count == 2)
        #expect(afterReopen.resolvedSelectedTabID == firstTabID)
        #expect(store.state.windows.first?.selectedWorkspaceID == remoteWorkspaceID)
    }

    @Test func aSessionWithoutATerminalOpensNothing() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try #require(store.state.windows.first?.id)
        let opener = RemoteHostTerminalOpener(
            store: store,
            terminalRuntimeRegistry: TerminalRuntimeRegistry(),
            hostsStore: try await Self.liveHostsStore(),
            homeDirectoryPath: "/tmp"
        )

        #expect(opener.open(
            remoteID: "mini", conversationID: RemoteHostsFixtures.plainID, windowID: windowID
        ).failure == .noAttachCommand)
        #expect(store.state.windows.first?.workspaceIDs.count == 1)
    }
}

// MARK: - Host side

@MainActor
struct RemoteAccessTerminalAttachTests {
    private static let catalog = TerminalProfileCatalog(profiles: [
        TerminalProfile(
            id: "zmx", displayName: "ZMX", badgeLabel: "ZMX",
            startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID",
            remoteAttachCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
        ),
        TerminalProfile(id: "plain", displayName: "Plain", badgeLabel: "Plain", startupCommand: "ls"),
    ])

    private static func terminalState(profileID: String?) -> TerminalPanelState {
        TerminalPanelState(
            title: "Terminal", shell: "zsh", cwd: "/repo",
            profileBinding: profileID.map(TerminalProfileBinding.init(profileID:))
        )
    }

    @Test func aPaneWhoseProfileHasARecipeGetsACommandForItsOwnPanel() {
        let panelID = UUID(uuidString: "3F2A0C6E-8B1D-4E57-9A40-1C2D3E4F5A6B")!

        #expect(RemoteAccessService.terminalAttachCommand(
            panelID: panelID, terminalState: Self.terminalState(profileID: "zmx"), catalog: Self.catalog
        ) == "env TOASTTY_PANEL_ID=3F2A0C6E-8B1D-4E57-9A40-1C2D3E4F5A6B TOASTTY_TERMINAL_PROFILE_ID=zmx"
            + " \"$SHELL\" -lc 'zmx attach toastty.$TOASTTY_PANEL_ID'")
    }

    @Test func panesWithoutARecipeGetNoCommand() {
        for profileID in ["plain", "removed-profile", nil] as [String?] {
            #expect(RemoteAccessService.terminalAttachCommand(
                panelID: UUID(), terminalState: Self.terminalState(profileID: profileID), catalog: Self.catalog
            ) == nil)
        }
    }
}
