import CryptoKit
import Foundation

/// The coordinator's quiet wake turns, as the Mac shares them with paired
/// devices: the digests whose turn the coordinator marked quiet with
/// `coordinator wake --quiet`. A chat folds such a turn whole under the
/// digest's line, and its New line does not count it.
///
/// A digest is named by `CoordinatorMessageHeader.digestKey` of its text.
/// The Mac keeps the keys, and a device finds a digest's key from the text
/// of the user message that the Mac's conversation reader sends, which is
/// the text that the Mac's own chat reads.
///
/// The Mac keeps up to 200 keys, too many for every session snapshot. The
/// coordinator's workspace carries only `revision`, which changes when the
/// set changes, and a device reads the keys from
/// `RemoteCoordinatorQuietDigestsPolicy.path` when the revision is new.
public struct RemoteCoordinatorQuietDigests: Codable, Equatable, Sendable {
    public var protocolVersion: String
    /// Names the set of `keys`: `revision(of:)`.
    public var revision: String
    /// The key of each quiet digest, oldest first.
    public var keys: [String]

    public init(protocolVersion: String = RemoteGatewayProtocol.version, keys: [String]) {
        self.protocolVersion = protocolVersion
        self.revision = Self.revision(of: keys)
        self.keys = keys
    }

    /// The first 16 hex digits of the SHA-256 of the keys, one per line.
    /// The same keys give the same revision, also after a relaunch of the
    /// Mac, so a device reads them again only when they change.
    public static func revision(of keys: [String]) -> String {
        let digest = SHA256.hash(data: Data(keys.joined(separator: "\n").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Wire contract for reading the coordinator's quiet digests.
public enum RemoteCoordinatorQuietDigestsPolicy {
    public static let path = "/api/coordinator.quiet_digests"
}
