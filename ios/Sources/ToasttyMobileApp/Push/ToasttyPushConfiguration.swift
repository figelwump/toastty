import Foundation
import RemoteProtocol
import ToasttyMobileDomain

struct ToasttyPushConfiguration: Equatable, Sendable {
    let relayURL: URL
    let relayID: String
    let apnsEnvironment: RemotePushAPNsEnvironment

    init(relayURL: URL, relayID: String, apnsEnvironment: RemotePushAPNsEnvironment) {
        self.relayURL = relayURL; self.relayID = relayID; self.apnsEnvironment = apnsEnvironment
    }

    init?(infoDictionary: [String: Any]) {
        guard let rawURL = infoDictionary["ToasttyMobilePushRelayURL"] as? String,
              let relayURL = URL(string: rawURL), PushRelayClient.isValidOrigin(relayURL),
              let relayID = infoDictionary["ToasttyMobilePushRelayID"] as? String,
              !relayID.isEmpty, relayID.utf8.count <= 128,
              let rawEnvironment = infoDictionary["ToasttyMobilePushEnvironment"] as? String,
              let environment = RemotePushAPNsEnvironment(rawValue: rawEnvironment),
              let bundleID = infoDictionary["CFBundleIdentifier"] as? String else { return nil }
        switch environment {
        case .development:
            guard bundleID == "com.giantthings.toastty.mobile.dev", relayID == "toastty-push-dev-v1" else { return nil }
        case .production:
            guard bundleID == "com.giantthings.toastty.mobile", relayID != "toastty-push-dev-v1" else { return nil }
        }
        self.init(relayURL: relayURL, relayID: relayID, apnsEnvironment: environment)
    }
}
