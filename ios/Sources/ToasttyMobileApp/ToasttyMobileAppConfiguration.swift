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
        if runtimeMode == .fixture {
            fixtureScenario = environment["TOASTTY_MOBILE_FIXTURE_SCENARIO"]
                .flatMap(ToasttyMobileFixtureScenario.init(rawValue:)) ?? .home
        } else {
            fixtureScenario = nil
        }
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
             .interactionAnswer:
            .live
        case .connecting, .reconnecting:
            .reconnecting
        case .unpaired, .cameraDenied, .scannerUnsupported, .scannerFailure, .credentialCorrupt,
             .pairingFailure, .pairingPrivacy, nil:
            .offline
        }
    }

    @MainActor
    func makeSessionController() -> AppSessionController {
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
                 .gatedSend, .gatedSendReceipt, .interactionAnswer,
                 .unpaired, .credentialCorrupt, .pairingFailure, .pairingPrivacy:
                scanner = FixturePairingScanner()
            }
            let usesPairedFixture: Bool
            switch fixtureScenario {
            case .home, .connecting, .reconnecting, .transcriptPerformance,
                 .transcriptResyncing, .transcriptStale, .transcriptTruncated,
                 .transcriptPaging, .transcriptLongMessage, .transcriptTables, .toolActivity,
                 .gatedSend, .gatedSendReceipt, .interactionAnswer:
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
                 .interactionAnswer,
                 .unpaired, .cameraDenied, .scannerUnsupported, .scannerFailure, .credentialCorrupt,
                 .pairingFailure, .pairingPrivacy:
                .live
            }
            let initialCredential = usesPairedFixture ? Self.fixtureCredential : nil
            let vault = FixtureAppCredentialVault(initialCredential: initialCredential)
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
                initialConnectionState: initialConnectionState
            )
            if fixtureScenario == .pairingPrivacy {
                controller.beginPairing()
                controller.sceneBecameInactive()
            }
            return controller
        }
#endif
        let vault = MobileCredentialVault()
        return AppSessionController(
            runtimeMode: runtimeMode,
            credentialVault: vault,
            pairingClient: NativePairingClient(),
            scanner: LivePairingCodeScanner(),
            deviceName: { UIDevice.current.name },
            initialSnapshot: initialSnapshot,
            initialConnectionState: initialConnectionState
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
