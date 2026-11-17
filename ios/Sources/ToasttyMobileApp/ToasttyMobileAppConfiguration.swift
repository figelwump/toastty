import Foundation
import RemoteProtocol
import ToasttyMobileDomain
import UIKit

enum ToasttyMobileFixtureScenario: String, Equatable, Sendable {
    case home
    case connecting
    case reconnecting
    case transcriptPerformance = "transcript-performance"
    case transcriptResyncing = "transcript-resyncing"
    case transcriptStale = "transcript-stale"
    case transcriptTruncated = "transcript-truncated"
    case transcriptPaging = "transcript-paging"
    case transcriptLongMessage = "transcript-long-message"
    case transcriptTables = "transcript-tables"
    case toolActivity = "tool-activity"
    case gatedSend = "gated-send"
    case gatedSendReceipt = "gated-send-receipt"
    case queueSteer = "queue-steer"
    /// "Smoke test triage" is paused by a Mac draft. The first Release is
    /// refused as if the Mac was typed on again; the second reopens it.
    case localDraftRelease = "local-draft-release"
    case interactionAnswer = "interaction-answer"
    case unpaired
    case cameraDenied = "camera-denied"
    case scannerUnsupported = "scanner-unsupported"
    case scannerFailure = "scanner-failure"
    case credentialCorrupt = "credential-corrupt"
    case pairingFailure = "pairing-failure"
    case pairingPrivacy = "pairing-privacy"
}

struct ToasttyMobileAppConfiguration: Equatable, Sendable {
    let runtimeMode: ToasttyMobileRuntimeMode
    let fixtureScenario: ToasttyMobileFixtureScenario?
    let urlScheme: String?
    /// Where the share extension leaves drafts; `nil` in builds without it.
    let sharedDraftStore: ToasttySharedDraftStore?
    let pushConfiguration: ToasttyPushConfiguration?
#if DEBUG
    let pushFixtureMode: ToasttyPushFixtureMode?
    let entryLoadFixture: ToasttyConversationFixture.EntryLoad?
    /// The fixture Mac sends a task board, as one with the task system does:
    /// "1" for one with work in every state, "quiet" for one where nothing
    /// needs the user, "long-names" for one whose names are long.
    let taskFixture: String?
    /// The fixture Mac has a coordinator workspace, and its session is in
    /// this state: "quiet", "working", "unread", "approval", "error", or
    /// "not-running" for a workspace without a session.
    let coordinatorFixture: String?
    /// Buttons that deliver a notification tap, for the coordinator's
    /// session and for a Home session.
    let showsNotificationTapButtons: Bool
#endif
    let enablesSystemAppIconBadge: Bool

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) {
        let bundledURL = (infoDictionary["ToasttyMobileGatewayURL"] as? String)
            .flatMap(URL.init(string:))
        runtimeMode = ToasttyMobileRuntimeMode(
            environment: environment,
            bundledGatewayURL: bundledURL
        )
        urlScheme = Self.routingURLScheme(in: infoDictionary)
        let appGroupStore = ToasttySharedDraftStore(appGroupID: infoDictionary["ToasttyMobileAppGroup"] as? String)
        // Fixtures use the App Group too, so a UI test can share through the
        // real extension, and fall back to a temporary folder without one.
        sharedDraftStore = runtimeMode == .fixture
            ? appGroupStore ?? ToasttySharedDraftStore(directory: FileManager.default.temporaryDirectory
                .appending(path: "ToasttyFixtureSharedDrafts", directoryHint: .isDirectory))
            : appGroupStore
        pushConfiguration = ToasttyPushConfiguration(infoDictionary: infoDictionary)
#if DEBUG
        pushFixtureMode = runtimeMode == .fixture
            ? environment["TOASTTY_MOBILE_FIXTURE_NOTIFICATIONS"].flatMap(ToasttyPushFixtureMode.init(rawValue:)) : nil
        entryLoadFixture = runtimeMode == .fixture
            ? environment["TOASTTY_MOBILE_FIXTURE_ENTRY_LOAD"].flatMap(ToasttyConversationFixture.EntryLoad.init(rawValue:)) : nil
        taskFixture = runtimeMode == .fixture ? environment["TOASTTY_MOBILE_FIXTURE_TASKS"] : nil
        coordinatorFixture = runtimeMode == .fixture ? environment["TOASTTY_MOBILE_FIXTURE_COORDINATOR"] : nil
        showsNotificationTapButtons = runtimeMode == .fixture
            && environment["TOASTTY_MOBILE_FIXTURE_NOTIFICATION_TAPS"] == "1"
#endif
        if runtimeMode == .fixture {
            fixtureScenario = environment["TOASTTY_MOBILE_FIXTURE_SCENARIO"]
                .flatMap(ToasttyMobileFixtureScenario.init(rawValue:)) ?? .home
        } else {
            fixtureScenario = nil
        }
        let isTestOrPreview = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        enablesSystemAppIconBadge = (fixtureScenario == nil && !isTestOrPreview)
            || (fixtureScenario != nil && environment["TOASTTY_MOBILE_FIXTURE_APP_BADGE"] == "1")
    }

    private static func routingURLScheme(in infoDictionary: [String: Any]) -> String? {
        guard let urlTypes = infoDictionary["CFBundleURLTypes"] as? [[String: Any]],
              let routingType = urlTypes.first(where: {
                  $0["CFBundleURLName"] as? String == "com.giantthings.toastty.mobile.routing"
              }),
              let schemes = routingType["CFBundleURLSchemes"] as? [String]
        else {
            return nil
        }
        return schemes.first
    }

    var initialSnapshot: MobileHomeSnapshot {
#if DEBUG
        if entryLoadFixture != nil { return ToasttyConversationFixture.entryLoadHome() }
        if let coordinatorFixture, let base = fixtureSnapshot {
            let status: RemoteSessionPresentationStatus? = switch coordinatorFixture {
            case "working": .working
            case "unread": .ready
            case "approval": .needsApproval
            case "error": .error
            case "not-running": nil
            default: .idle
            }
            return ToasttyMobileFixture.withCoordinator(base, status: status, chatRead: fixtureCoordinatorChatRead)
        }
        if let fixtureSnapshot { return fixtureSnapshot }
#endif
        return switch runtimeMode {
        case .fixture:
            ToasttyMobileFixture.home
        case .unconfigured:
            MobileHomeSnapshot(hostName: "Toastty Mac", workspaces: [])
        case .local(let url), .live(let url):
            MobileHomeSnapshot(hostName: url.host ?? "Toastty Mac", workspaces: [])
        }
    }

#if DEBUG
    /// The fixture Mac's read point of the coordinator's chat:
    /// `TOASTTY_MOBILE_FIXTURE_COORDINATOR_READ_THROUGH=<n>` reads through
    /// the fixture chat's event `n`, or with a negative `n`, through the
    /// event `-n` before the chat's end.
    private var fixtureCoordinatorChatRead: RemoteCoordinatorChatReadPoint? {
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["TOASTTY_MOBILE_FIXTURE_COORDINATOR_READ_THROUGH"],
              var sequence = Int(value) else { return nil }
        // The chat as the fixture shows it, so that the end is its end.
        let events = ToasttyConversationFixture.coordinatorEvents(
            for: ToasttyMobileFixture.coordinatorConversationID,
            hasLongMessage: environment["TOASTTY_MOBILE_FIXTURE_COORDINATOR_LONG_MESSAGE"] == "1",
            quietTurns: ["1", "unsupported"].contains(environment["TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUIET_TURNS"] ?? "")
                ? .shared : .none,
            wakeTurns: Int(environment["TOASTTY_MOBILE_FIXTURE_COORDINATOR_WAKE_TURNS"] ?? "") ?? 0
        )
        // A negative value counts from the chat's end.
        if sequence < 0 { sequence += events.count }
        guard events.indices.contains(sequence - 1) else { return nil }
        let event = events[sequence - 1]
        return RemoteCoordinatorChatReadPoint(eventID: event.eventID, timestamp: event.timestamp)
    }

    /// The fixture Mac's snapshot before any coordinator: with the task
    /// system when `taskFixture` names a board, otherwise `home`.
    private var fixtureSnapshot: MobileHomeSnapshot? {
        if taskFixture == "1" { return ToasttyMobileFixture.taskHome }
        if taskFixture == "quiet" { return ToasttyMobileFixture.quietTaskHome }
        if taskFixture == "pick-workspace" { return ToasttyMobileFixture.pickWorkspaceTaskHome }
        if taskFixture == "long-names" { return ToasttyMobileFixture.longNamesTaskHome }
        return runtimeMode == .fixture && coordinatorFixture != nil ? ToasttyMobileFixture.home : nil
    }
#endif

    var initialConnectionState: MobileConnectionState {
        switch fixtureScenario {
        case .home, .transcriptPerformance, .transcriptResyncing,
             .transcriptStale, .transcriptTruncated, .transcriptPaging,
             .transcriptLongMessage, .transcriptTables, .toolActivity, .gatedSend, .gatedSendReceipt,
             .queueSteer, .localDraftRelease, .interactionAnswer:
            .live
        case .connecting, .reconnecting:
            .reconnecting
        case .unpaired, .cameraDenied, .scannerUnsupported, .scannerFailure, .credentialCorrupt,
             .pairingFailure, .pairingPrivacy, nil:
            .offline
        }
    }

    @MainActor
    func makeSessionController(pushBridge: ToasttyPushNotificationBridge? = nil) -> AppSessionController {
#if DEBUG
        if let fixtureScenario {
            let scanner: FixturePairingScanner
            switch fixtureScenario {
            case .cameraDenied:
                scanner = FixturePairingScanner(availability: .unavailable, authorization: .denied)
            case .scannerUnsupported:
                scanner = FixturePairingScanner(availability: .unsupported)
            case .scannerFailure:
                scanner = FixturePairingScanner(failure: .couldNotStart)
            case .home, .connecting, .reconnecting, .transcriptPerformance,
                 .transcriptResyncing, .transcriptStale, .transcriptTruncated,
                 .transcriptPaging, .transcriptLongMessage, .transcriptTables, .toolActivity,
                 .gatedSend, .gatedSendReceipt, .queueSteer, .localDraftRelease, .interactionAnswer,
                 .unpaired, .credentialCorrupt, .pairingFailure, .pairingPrivacy:
                scanner = FixturePairingScanner()
            }
            let usesPairedFixture: Bool
            switch fixtureScenario {
            case .home, .connecting, .reconnecting, .transcriptPerformance,
                 .transcriptResyncing, .transcriptStale, .transcriptTruncated,
                 .transcriptPaging, .transcriptLongMessage, .transcriptTables, .toolActivity,
                 .gatedSend, .gatedSendReceipt, .queueSteer, .localDraftRelease, .interactionAnswer:
                usesPairedFixture = true
            case .unpaired, .cameraDenied, .scannerUnsupported, .scannerFailure, .credentialCorrupt,
                 .pairingFailure, .pairingPrivacy:
                usesPairedFixture = false
            }
            let pairedPresentation: PairedConnectionPresentation = switch fixtureScenario {
            case .connecting: .connecting
            case .reconnecting: .reconnecting
            case .home, .transcriptPerformance, .transcriptResyncing,
                 .transcriptStale, .transcriptTruncated, .transcriptPaging,
                 .transcriptLongMessage, .transcriptTables, .toolActivity, .gatedSend, .gatedSendReceipt,
                 .queueSteer, .localDraftRelease, .interactionAnswer,
                 .unpaired, .cameraDenied, .scannerUnsupported, .scannerFailure, .credentialCorrupt,
                 .pairingFailure, .pairingPrivacy:
                .live
            }
            let initialCredential = usesPairedFixture ? Self.fixtureCredential : nil
            let vault = FixtureAppCredentialVault(initialCredential: initialCredential)
            let push = initialCredential.flatMap { credential in
                pushFixtureMode.map { ToasttyPushFixtures.make(mode: $0, credential: credential, vault: vault) }
            }
            let controller = AppSessionController(
                runtimeMode: runtimeMode,
                usesFixtureHarness: true,
                credentialVault: vault,
                pairingClient: FixturePairingClient(
                    behavior: fixtureScenario == .pairingFailure ? .expiredOffer : .success
                ),
                scanner: scanner,
                deviceName: { "Fixture iPhone" },
                initialState: fixtureScenario == .credentialCorrupt
                    ? .repairNeeded(.corrupt)
                    : (usesPairedFixture ? .paired(pairedPresentation) : .unpaired),
                initialPairedDevice: initialCredential.map(PairedDevicePresentation.init),
                initialSnapshot: initialSnapshot,
                initialConnectionState: initialConnectionState,
                pushController: push
            )
            if fixtureScenario == .pairingPrivacy {
                controller.beginPairing()
                controller.sceneBecameInactive()
            }
            return controller
        }
#endif
        let vault = MobileCredentialVault()
        let push = ToasttyPushController(configuration: pushConfiguration, vault: vault, bridge: pushBridge)
        return AppSessionController(
            runtimeMode: runtimeMode,
            credentialVault: vault,
            pairingClient: NativePairingClient(),
            scanner: LivePairingCodeScanner(),
            deviceName: { UIDevice.current.name },
            initialSnapshot: initialSnapshot,
            initialConnectionState: initialConnectionState,
            pushController: push,
            backgroundExecution: UIApplicationBackgroundExecutionHolder()
        )
    }

#if DEBUG
    private static var fixtureCredential: StoredMobileCredential {
        try! StoredMobileCredential(
            gatewayURL: URL(string: "https://fixture-mac.example.ts.net")!,
            device: RemoteGatewayDeviceSummary(
                id: UUID(uuidString: "C1000000-0000-0000-0000-000000000001")!,
                name: "Fixture iPhone",
                scopes: [.read, .send]
            ),
            credentialCreatedAt: Date(timeIntervalSince1970: 1_786_406_400),
            bearerToken: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )
    }

#endif
}
