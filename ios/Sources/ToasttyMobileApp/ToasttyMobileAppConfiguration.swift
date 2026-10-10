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
    let pushConfiguration: ToasttyPushConfiguration?
#if DEBUG
    let pushFixtureMode: ToasttyPushFixtureMode?
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
        pushConfiguration = ToasttyPushConfiguration(infoDictionary: infoDictionary)
#if DEBUG
        pushFixtureMode = runtimeMode == .fixture
            ? environment["TOASTTY_MOBILE_FIXTURE_NOTIFICATIONS"].flatMap(ToasttyPushFixtureMode.init(rawValue:)) : nil
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
        switch runtimeMode {
        case .fixture:
            ToasttyMobileFixture.home
        case .unconfigured:
            MobileHomeSnapshot(hostName: "Toastty Mac", workspaces: [])
        case .local(let url), .live(let url):
            MobileHomeSnapshot(hostName: url.host ?? "Toastty Mac", workspaces: [])
        }
    }

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
            pushController: push
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
