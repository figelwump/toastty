import Foundation

public struct ManagedSessionID: Hashable, Sendable {
    public let rawValue: String

    public init?(_ rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return nil }
        self.rawValue = normalized
    }
}

/// Preserves the provider spelling for diagnostics while treating surrounding
/// whitespace and case as insignificant for identity comparisons.
public struct NativeSessionID: Hashable, Sendable {
    public let rawValue: String
    public let canonicalValue: String

    public init?(_ rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return nil }
        self.rawValue = rawValue
        canonicalValue = normalized.lowercased()
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canonicalValue == rhs.canonicalValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(canonicalValue)
    }
}

/// A non-empty path that the application has already expanded and
/// standardized. Reconciliation deliberately compares paths byte-for-byte;
/// it does not perform filesystem or URL normalization.
public struct RolloutPath: Hashable, Sendable {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        self.rawValue = rawValue
    }
}

/// Diagnostic provenance only. Claim source must never affect acceptance.
public struct NativeSessionClaimSource: Hashable, Sendable {
    public let diagnosticLabel: String

    public init?(_ diagnosticLabel: String) {
        let normalized = diagnosticLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return nil }
        self.diagnosticLabel = normalized
    }
}

public struct NativeSessionClaim: Equatable, Hashable, Sendable {
    public let managedSessionID: ManagedSessionID
    public let nativeSessionID: NativeSessionID
    public let rolloutPath: RolloutPath?
    public let source: NativeSessionClaimSource

    public init(
        managedSessionID: ManagedSessionID,
        nativeSessionID: NativeSessionID,
        rolloutPath: RolloutPath?,
        source: NativeSessionClaimSource
    ) {
        self.managedSessionID = managedSessionID
        self.nativeSessionID = nativeSessionID
        self.rolloutPath = rolloutPath
        self.source = source
    }
}

public enum NativeSessionOwnerSnapshot: Equatable, Sendable {
    case activeManaged(managedSessionID: ManagedSessionID, rolloutPath: RolloutPath?)
    case inactivePreviousManaged(managedSessionID: ManagedSessionID, rolloutPath: RolloutPath?)
    /// A persisted resume claim whose former managed session is no longer
    /// present in runtime history. This is stale ownership, not an unowned ID.
    case inactivePersistedClaim(rolloutPath: RolloutPath?)

    var rolloutPath: RolloutPath? {
        switch self {
        case .activeManaged(_, let rolloutPath),
             .inactivePreviousManaged(_, let rolloutPath),
             .inactivePersistedClaim(let rolloutPath):
            rolloutPath
        }
    }
}

/// A complete, point-in-time ownership view for one provider namespace.
///
/// `ownerByNativeSessionID` must include every persisted claim, including
/// inactive claims with no retained managed-session record. The expectation
/// map must include every managed session currently being evaluated that has
/// an expected resume ID; absence means a fresh claim. Callers must create the
/// snapshot, evaluate, and apply accepted bindings on the same serialized
/// context (Toastty uses MainActor) so ownership cannot change between them.
public struct NativeSessionOwnershipSnapshot: Equatable, Sendable {
    public let ownerByNativeSessionID: [NativeSessionID: NativeSessionOwnerSnapshot]
    public let expectedNativeSessionIDByManagedSessionID: [ManagedSessionID: NativeSessionID]
    /// IDs with more than one persisted owner. They remain explicitly
    /// unclaimable rather than allowing dictionary insertion order to choose.
    public let conflictedNativeSessionIDs: Set<NativeSessionID>

    public init(
        ownerByNativeSessionID: [NativeSessionID: NativeSessionOwnerSnapshot],
        expectedNativeSessionIDByManagedSessionID: [ManagedSessionID: NativeSessionID],
        conflictedNativeSessionIDs: Set<NativeSessionID> = []
    ) {
        self.ownerByNativeSessionID = ownerByNativeSessionID.filter { nativeSessionID, _ in
            conflictedNativeSessionIDs.contains(nativeSessionID) == false
        }
        self.expectedNativeSessionIDByManagedSessionID = expectedNativeSessionIDByManagedSessionID
        self.conflictedNativeSessionIDs = conflictedNativeSessionIDs
    }

    public static let empty = NativeSessionOwnershipSnapshot(
        ownerByNativeSessionID: [:],
        expectedNativeSessionIDByManagedSessionID: [:],
        conflictedNativeSessionIDs: []
    )
}
