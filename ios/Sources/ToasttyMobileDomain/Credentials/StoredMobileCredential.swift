import Foundation
import RemoteProtocol

public struct StoredMobileCredential: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let gatewayURL: URL
    public let device: RemoteGatewayDeviceSummary
    public let credentialCreatedAt: Date
    public let bearerToken: String

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        gatewayURL: URL,
        device: RemoteGatewayDeviceSummary,
        credentialCreatedAt: Date,
        bearerToken: String
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw StoredMobileCredentialError.incompatibleSchema(schemaVersion)
        }
        let canonicalURL: URL
        do {
            canonicalURL = try PairingInputParser.canonicalGatewayURL(gatewayURL.absoluteString)
        } catch {
            throw StoredMobileCredentialError.invalidGateway
        }
        guard PairingInputParser.isValidCredentialMaterial(bearerToken),
              !device.name.isEmpty,
              device.name == device.name.trimmingCharacters(in: .whitespacesAndNewlines),
              device.name.count <= RemoteGatewayProtocol.maximumDeviceNameLength,
              device.name.utf8.count <= RemoteGatewayProtocol.maximumDeviceNameLength * 4,
              device.name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              (0...4_102_444_800).contains(credentialCreatedAt.timeIntervalSince1970) else {
            throw StoredMobileCredentialError.invalidCredential
        }
        self.schemaVersion = schemaVersion
        self.gatewayURL = canonicalURL
        self.device = device
        self.credentialCreatedAt = credentialCreatedAt
        self.bearerToken = bearerToken
    }

    public init(
        gatewayURL: URL,
        exchangeResponse: RemoteGatewayNativePairingExchangeResponse
    ) throws {
        try self.init(
            gatewayURL: gatewayURL,
            device: exchangeResponse.device,
            credentialCreatedAt: exchangeResponse.credentialCreatedAt,
            bearerToken: exchangeResponse.credential
        )
    }

    public var description: String {
        "<redacted mobile credential>"
    }
    public var debugDescription: String { description }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case gatewayURL
        case device
        case credentialCreatedAt
        case bearerToken
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw StoredMobileCredentialError.incompatibleSchema(schemaVersion)
        }
        try self.init(
            schemaVersion: schemaVersion,
            gatewayURL: container.decode(URL.self, forKey: .gatewayURL),
            device: container.decode(RemoteGatewayDeviceSummary.self, forKey: .device),
            credentialCreatedAt: container.decode(Date.self, forKey: .credentialCreatedAt),
            bearerToken: container.decode(String.self, forKey: .bearerToken)
        )
    }
}

public enum StoredMobileCredentialError: Error, Equatable, Sendable {
    case incompatibleSchema(Int)
    case invalidGateway
    case invalidCredential
}
