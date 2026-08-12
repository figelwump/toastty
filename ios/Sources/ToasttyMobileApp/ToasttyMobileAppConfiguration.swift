import Foundation
import RemoteProtocol
import ToasttyMobileDomain
import UIKit

enum ToasttyMobileFixtureScenario: String, Equatable, Sendable {
    case home
    case unpaired
    case cameraDenied = "camera-denied"
    case scannerUnsupported = "scanner-unsupported"
    case pairingFailure = "pairing-failure"
    case pairingPrivacy = "pairing-privacy"
}

struct ToasttyMobileAppConfiguration: Equatable, Sendable {
    let runtimeMode: ToasttyMobileRuntimeMode
    let fixtureScenario: ToasttyMobileFixtureScenario?

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
        if environment["TOASTTY_MOBILE_USE_FIXTURE"] == "1" {
            fixtureScenario = environment["TOASTTY_MOBILE_FIXTURE_SCENARIO"]
                .flatMap(ToasttyMobileFixtureScenario.init(rawValue:)) ?? .home
        } else {
            fixtureScenario = nil
        }
    }

    var initialSnapshot: MobileHomeSnapshot {
        switch runtimeMode {
        case .fixture:
            ToasttyMobileFixture.home
        case .local(let url), .live(let url):
            MobileHomeSnapshot(hostName: url.host ?? "Toastty Mac", workspaces: [])
        }
    }

    var initialConnectionState: MobileConnectionState {
        fixtureScenario == .home ? .live : .offline
    }

    @MainActor
    func makeSessionController() -> AppSessionController {
#if DEBUG
        if let fixtureScenario {
            let scanner: FixturePairingScanner
            switch fixtureScenario {
            case .cameraDenied:
                scanner = FixturePairingScanner(authorization: .denied)
            case .scannerUnsupported:
                scanner = FixturePairingScanner(availability: .unsupported)
            case .home, .unpaired, .pairingFailure, .pairingPrivacy:
                scanner = FixturePairingScanner()
            }
            let initialCredential = fixtureScenario == .home ? Self.fixtureCredential : nil
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
                initialState: fixtureScenario == .home ? .paired(.live) : .unpaired,
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
