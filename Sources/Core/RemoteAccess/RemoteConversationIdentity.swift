import Foundation

/// Toastty-owned durable identity for one user-visible agent conversation.
///
/// A conversation is not a provider session: a native resume may create a new
/// runtime, PTY, or provider session file while remaining the same user-visible
/// conversation. Remote clients must never key on provider session IDs.
public struct RemoteConversationID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Identity of one in-memory projection build.
///
/// Event sequences are monotonic only within a single projection run. A Toastty
/// relaunch rebuilds every projection under a fresh run ID; a client that
/// presents a sequence from a different run must receive `resnapshotRequired`
/// instead of a page, because its cursor belongs to a discarded sequence space.
/// A single conversation rebuilt mid-run (unreconcilable provider rewrite)
/// keeps the run ID but bumps its own `projectionGeneration`, so only that
/// conversation's cursors invalidate.
public struct RemoteProjectionRunID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
