import Foundation

/// The coordinator's quiet wake turns, as the Mac shares them with paired
/// devices: the digests whose turn the coordinator marked quiet with
/// `coordinator wake --quiet`. A chat folds such a turn whole under the
/// digest's line, and its New line does not count it.
///
/// A digest is named by its key: the SHA-256, in hex, of its text without
/// leading and trailing white space (`CoordinatorWakeState.digestKey` on
/// the Mac). The Mac keeps the keys, and a device computes a digest's key
/// from the text of the user message that the Mac's conversation reader
/// sends, which is the text that the Mac's own chat reads. This module
/// stays Foundation-only, so the hashing lives with each side.
///
/// The Mac keeps up to 200 keys, too many for every session snapshot. The
/// coordinator's workspace carries only `revision`, which changes when the
/// set changes, and a device reads the keys from
/// `RemoteCoordinatorQuietDigestsPolicy.path` when the revision is new.
public struct RemoteCoordinatorQuietDigests: Codable, Equatable, Sendable {
    public var protocolVersion: String
    /// Names the set of `keys`. The Mac makes it from the keys, so the same
    /// keys give the same revision, also after a relaunch.
    public var revision: String
    /// The key of each quiet digest, oldest first.
    public var keys: [String]

    public init(protocolVersion: String = RemoteGatewayProtocol.version, revision: String, keys: [String]) {
        self.protocolVersion = protocolVersion
        self.revision = revision
        self.keys = keys
    }
}

/// Wire contract for reading the coordinator's quiet digests.
public enum RemoteCoordinatorQuietDigestsPolicy {
    public static let path = "/api/coordinator.quiet_digests"
}
