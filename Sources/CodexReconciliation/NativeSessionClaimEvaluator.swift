import Foundation

public struct AcceptedNativeSessionBinding: Equatable, Hashable, Sendable {
    public let managedSessionID: ManagedSessionID
    public let nativeSessionID: NativeSessionID
    public let rolloutPath: RolloutPath?

    public init(
        managedSessionID: ManagedSessionID,
        nativeSessionID: NativeSessionID,
        rolloutPath: RolloutPath?
    ) {
        self.managedSessionID = managedSessionID
        self.nativeSessionID = nativeSessionID
        self.rolloutPath = rolloutPath
    }
}

public enum NativeSessionClaimRejectionReason: Equatable, Sendable {
    case expectationMismatch
    case managedSessionOfferedMultipleNativeSessions
    case nativeSessionOfferedToMultipleManagedSessions
    case conflictingSimultaneousRolloutPaths
    case conflictingSnapshotOwners
    case ownedByDifferentActiveManagedSession
    case inactiveOwnerRequiresMatchingResumeExpectation
}

public enum NativeSessionClaimDecision: Equatable, Sendable {
    case accepted(AcceptedNativeSessionBinding)
    case rejected(NativeSessionClaimRejectionReason)
}

public enum NativeSessionClaimEvaluator {
    /// Evaluates one atomic provider-scoped batch. Results are index-aligned
    /// with `claims`; source labels are intentionally excluded from all keys.
    public static func evaluate(
        claims: [NativeSessionClaim],
        snapshot: NativeSessionOwnershipSnapshot
    ) -> [NativeSessionClaimDecision] {
        guard claims.isEmpty == false else { return [] }

        let expectationMismatchIndexes = Set(claims.indices.filter { index in
            guard let expected = snapshot.expectedNativeSessionIDByManagedSessionID[
                claims[index].managedSessionID
            ] else {
                return false
            }
            return expected != claims[index].nativeSessionID
        })

        let eligibleIndexes = claims.indices.filter { expectationMismatchIndexes.contains($0) == false }
        let exactGroups = Dictionary(grouping: eligibleIndexes) { index in
            ExactClaimKey(claim: claims[index])
        }
        let representativeIndexes = exactGroups.values.compactMap(\.first)

        let nativeIDsByManagedSession = Dictionary(grouping: representativeIndexes) { index in
            claims[index].managedSessionID
        }.mapValues { indexes in
            Set(indexes.map { claims[$0].nativeSessionID })
        }
        let ambiguousManagedSessions = Set(nativeIDsByManagedSession.compactMap { entry in
            entry.value.count > 1 ? entry.key : nil
        })

        let managedIDsByNativeSession = Dictionary(grouping: representativeIndexes) { index in
            claims[index].nativeSessionID
        }.mapValues { indexes in
            Set(indexes.map { claims[$0].managedSessionID })
        }
        let ambiguousNativeSessions = Set(managedIDsByNativeSession.compactMap { entry in
            entry.value.count > 1 ? entry.key : nil
        })

        let indexesByBinding = Dictionary(grouping: representativeIndexes) { index in
            BindingKey(claim: claims[index])
        }
        let conflictingPathBindings = Set(indexesByBinding.compactMap { entry in
            let distinctPaths = Set(entry.value.compactMap { claims[$0].rolloutPath })
            return distinctPaths.count > 1 ? entry.key : nil
        })
        let resolvedPathByBinding = indexesByBinding.mapValues { indexes in
            indexes.compactMap { claims[$0].rolloutPath }.first
        }

        return claims.indices.map { index in
            let claim = claims[index]
            if expectationMismatchIndexes.contains(index) {
                return .rejected(.expectationMismatch)
            }
            if ambiguousManagedSessions.contains(claim.managedSessionID) {
                return .rejected(.managedSessionOfferedMultipleNativeSessions)
            }
            if ambiguousNativeSessions.contains(claim.nativeSessionID) {
                return .rejected(.nativeSessionOfferedToMultipleManagedSessions)
            }

            let bindingKey = BindingKey(claim: claim)
            if conflictingPathBindings.contains(bindingKey) {
                return .rejected(.conflictingSimultaneousRolloutPaths)
            }
            if snapshot.conflictedNativeSessionIDs.contains(claim.nativeSessionID) {
                return .rejected(.conflictingSnapshotOwners)
            }

            let observedPath = resolvedPathByBinding[bindingKey] ?? nil
            let owner = snapshot.ownerByNativeSessionID[claim.nativeSessionID]
            let resolvedPath = observedPath ?? owner?.rolloutPath
            let binding = AcceptedNativeSessionBinding(
                managedSessionID: claim.managedSessionID,
                nativeSessionID: claim.nativeSessionID,
                rolloutPath: resolvedPath
            )

            guard let owner else {
                return .accepted(binding)
            }
            switch owner {
            case .activeManaged(let ownerManagedSessionID, _):
                return ownerManagedSessionID == claim.managedSessionID
                    ? .accepted(binding)
                    : .rejected(.ownedByDifferentActiveManagedSession)
            case .inactivePreviousManaged, .inactivePersistedClaim:
                let expected = snapshot.expectedNativeSessionIDByManagedSessionID[
                    claim.managedSessionID
                ]
                return expected == claim.nativeSessionID
                    ? .accepted(binding)
                    : .rejected(.inactiveOwnerRequiresMatchingResumeExpectation)
            }
        }
    }
}

private struct ExactClaimKey: Hashable {
    let managedSessionID: ManagedSessionID
    let nativeSessionID: NativeSessionID
    let rolloutPath: RolloutPath?

    init(claim: NativeSessionClaim) {
        managedSessionID = claim.managedSessionID
        nativeSessionID = claim.nativeSessionID
        rolloutPath = claim.rolloutPath
    }
}

private struct BindingKey: Hashable {
    let managedSessionID: ManagedSessionID
    let nativeSessionID: NativeSessionID

    init(claim: NativeSessionClaim) {
        managedSessionID = claim.managedSessionID
        nativeSessionID = claim.nativeSessionID
    }
}
