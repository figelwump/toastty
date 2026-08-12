import Foundation
import RemoteProtocol

struct ToasttySettingsPresentation: Equatable, Sendable {
    let host: String
    let reachability: LiveProjectionFreshness
    let protocolVersion: String
    let projectionRunID: String?
    let projectionGeneration: UInt64?
    let activeConversationCursor: UInt64?
    let device: RemoteGatewayDeviceSummary?
    let credentialCreatedAt: Date?

    init(
        gatewayURL: URL,
        reachability: LiveProjectionFreshness,
        protocolVersion: String = RemoteGatewayProtocol.version,
        projectionRunID: String? = nil,
        projectionGeneration: UInt64? = nil,
        activeConversationCursor: UInt64? = nil,
        device: RemoteGatewayDeviceSummary? = nil,
        credentialCreatedAt: Date? = nil
    ) {
        // Deliberately discard user info, paths, queries, and fragments. The
        // Settings surface and screenshots must never expose credentials.
        host = gatewayURL.host ?? "Unknown Toastty Mac"
        self.reachability = reachability
        self.protocolVersion = protocolVersion
        self.projectionRunID = projectionRunID
        self.projectionGeneration = projectionGeneration
        self.activeConversationCursor = activeConversationCursor
        self.device = device
        self.credentialCreatedAt = credentialCreatedAt
    }
}
