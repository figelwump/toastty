import Foundation
import RemoteProtocol

/// A build-selected relay origin. Native requests can select neither the
/// destination nor its APNs environment.
public struct RemotePushConfiguration: Equatable, Sendable {
    public let relayURL: URL
    public let relayID: String
    public let apnsEnvironment: RemotePushAPNsEnvironment

    public init?(
        relayURL: URL,
        relayID: String = RemotePushPolicy.developmentRelayID,
        apnsEnvironment: RemotePushAPNsEnvironment = .development
    ) {
        guard Self.isValidRelayURL(relayURL), Self.isValidRelayID(relayID),
              (apnsEnvironment == .development && relayID == RemotePushPolicy.developmentRelayID)
                || (apnsEnvironment == .production && relayID != RemotePushPolicy.developmentRelayID) else { return nil }
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)!
        components.path = ""
        self.relayURL = components.url!
        self.relayID = relayID
        self.apnsEnvironment = apnsEnvironment
    }

    public static func isValidRelayURL(_ url: URL) -> Bool {
        url.absoluteString.utf8.count <= 512 && url.scheme == "https" && url.host?.isEmpty == false
            && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
            && url.port == nil && (url.path.isEmpty || url.path == "/")
    }

    public static func isValidRelayID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {
            switch $0.value {
            case 45, 46, 48...57, 65...90, 95, 97...122: true
            default: false
            }
        }
    }
}

/// Private send authority, stored only in the protected device file. Cleanup
/// retains the same record until its relay confirms deletion.
public struct RemoteDevicePushRegistration: Codable, Equatable, Sendable {
    public let deviceID: UUID
    public let registrationID: UUID
    public let sendToken: String
    public let relayURL: URL
    public let relayID: String

    public init(deviceID: UUID, registration: RemoteGatewayPushRegistration, configuration: RemotePushConfiguration) {
        self.deviceID = deviceID
        registrationID = registration.registrationID
        sendToken = registration.sendToken
        relayURL = configuration.relayURL
        relayID = configuration.relayID
    }

    private enum CodingKeys: String, CodingKey { case deviceID, registrationID, sendToken, relayURL, relayID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decode(UUID.self, forKey: .deviceID)
        registrationID = try container.decode(UUID.self, forKey: .registrationID)
        sendToken = try container.decode(String.self, forKey: .sendToken)
        relayURL = try container.decode(URL.self, forKey: .relayURL)
        relayID = try container.decode(String.self, forKey: .relayID)
        guard RemotePushPolicy.isValidCapabilityToken(sendToken),
              RemotePushConfiguration.isValidRelayURL(relayURL),
              RemotePushConfiguration.isValidRelayID(relayID) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid private push registration"))
        }
    }
}

public enum RemoteDevicePushRegistrationError: Error, Equatable, Sendable {
    case deviceUnavailable
    case invalidRegistration
    case cleanupPending
    case registrationLimitReached
}
