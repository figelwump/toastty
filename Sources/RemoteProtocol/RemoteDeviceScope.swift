import Foundation

/// What a paired remote device is allowed to do. Successful pairings grant
/// read and send explicitly; later scope changes happen only on the Mac.
public enum RemoteDeviceScope: String, Codable, Equatable, Sendable, CaseIterable {
    case read
    case send
    case approve
}
