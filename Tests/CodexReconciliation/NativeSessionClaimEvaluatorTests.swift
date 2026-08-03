import Foundation
import Testing
@testable import CodexReconciliation

struct NativeSessionClaimEvaluatorTests {
    @Test
    func typedValuesEnforceBoundaryNormalization() throws {
        #expect(ManagedSessionID("  managed-1\n")?.rawValue == "managed-1")
        #expect(ManagedSessionID(" \n") == nil)

        let native = try #require(NativeSessionID("  Provider-ID  "))
        let equivalentNative = try #require(NativeSessionID("provider-id"))
        #expect(native.rawValue == "  Provider-ID  ")
        #expect(native == equivalentNative)
        #expect(Set([native, equivalentNative]).count == 1)

        #expect(RolloutPath("") == nil)
        #expect(RolloutPath(" \n") == nil)
        #expect(RolloutPath("/tmp/Session.JSONL") != RolloutPath("/tmp/session.jsonl"))
        #expect(NativeSessionClaimSource("  file-scan ")?.diagnosticLabel == "file-scan")
    }

    @Test
    func unownedNativeSessionIsAccepted() throws {
        let claim = try makeClaim(managed: "managed-1", native: "native-1", path: "/tmp/one")

        #expect(evaluate([claim]) == [
            .accepted(try binding(managed: "managed-1", native: "native-1", path: "/tmp/one")),
        ])
    }

    @Test
    func sameActiveOwnerIsAcceptedAndMergesMissingPath() throws {
        let managed = try managedID("managed-1")
        let native = try nativeID("native-1")
        let snapshot = NativeSessionOwnershipSnapshot(
            ownerByNativeSessionID: [
                native: .activeManaged(
                    managedSessionID: managed,
                    rolloutPath: try path("/tmp/existing")
                ),
            ],
            expectedNativeSessionIDByManagedSessionID: [:]
        )

        #expect(evaluate([
            try makeClaim(managed: "managed-1", native: "native-1", path: nil),
        ], snapshot: snapshot) == [
            .accepted(try binding(managed: "managed-1", native: "native-1", path: "/tmp/existing")),
        ])
    }

    @Test
    func differentActiveOwnerIsRejected() throws {
        let snapshot = NativeSessionOwnershipSnapshot(
            ownerByNativeSessionID: [
                try nativeID("native-1"): .activeManaged(
                    managedSessionID: try managedID("managed-other"),
                    rolloutPath: nil
                ),
            ],
            expectedNativeSessionIDByManagedSessionID: [:]
        )

        #expect(evaluate([
            try makeClaim(managed: "managed-1", native: "native-1"),
        ], snapshot: snapshot) == [
            .rejected(.ownedByDifferentActiveManagedSession),
        ])
    }

    @Test
    func expectedResumeCanReclaimInactivePreviousManagedOwner() throws {
        let claimant = try managedID("managed-1")
        let native = try nativeID("native-1")
        let snapshot = NativeSessionOwnershipSnapshot(
            ownerByNativeSessionID: [
                native: .inactivePreviousManaged(
                    managedSessionID: try managedID("managed-old"),
                    rolloutPath: try path("/tmp/old")
                ),
            ],
            expectedNativeSessionIDByManagedSessionID: [claimant: native]
        )

        #expect(evaluate([
            try makeClaim(managed: "managed-1", native: "native-1", path: "/tmp/new"),
        ], snapshot: snapshot) == [
            .accepted(try binding(managed: "managed-1", native: "native-1", path: "/tmp/new")),
        ])
    }

    @Test
    func expectedResumeCanReclaimInactivePersistedClaimWithoutManagedOwner() throws {
        let claimant = try managedID("managed-1")
        let native = try nativeID("native-1")
        let snapshot = NativeSessionOwnershipSnapshot(
            ownerByNativeSessionID: [
                native: .inactivePersistedClaim(rolloutPath: try path("/tmp/persisted")),
            ],
            expectedNativeSessionIDByManagedSessionID: [claimant: native]
        )

        #expect(evaluate([
            try makeClaim(managed: "managed-1", native: "native-1", path: nil),
        ], snapshot: snapshot) == [
            .accepted(try binding(managed: "managed-1", native: "native-1", path: "/tmp/persisted")),
        ])
    }

    @Test
    func freshClaimCannotReclaimInactiveOwner() throws {
        let native = try nativeID("native-1")
        let snapshots = [
            NativeSessionOwnershipSnapshot(
                ownerByNativeSessionID: [
                    native: .inactivePreviousManaged(
                        managedSessionID: try managedID("managed-old"),
                        rolloutPath: nil
                    ),
                ],
                expectedNativeSessionIDByManagedSessionID: [:]
            ),
            NativeSessionOwnershipSnapshot(
                ownerByNativeSessionID: [native: .inactivePersistedClaim(rolloutPath: nil)],
                expectedNativeSessionIDByManagedSessionID: [:]
            ),
        ]

        for snapshot in snapshots {
            #expect(evaluate([
                try makeClaim(managed: "managed-1", native: "native-1"),
            ], snapshot: snapshot) == [
                .rejected(.inactiveOwnerRequiresMatchingResumeExpectation),
            ])
        }
    }

    @Test
    func expectationMismatchRejectsOnlyMismatchingClaimBeforeAmbiguityChecks() throws {
        let claimant = try managedID("managed-1")
        let expected = try nativeID("native-expected")
        let snapshot = NativeSessionOwnershipSnapshot(
            ownerByNativeSessionID: [:],
            expectedNativeSessionIDByManagedSessionID: [claimant: expected]
        )
        let claims = [
            try makeClaim(managed: "managed-1", native: "native-other"),
            try makeClaim(managed: "managed-1", native: "NATIVE-EXPECTED"),
        ]

        #expect(evaluate(claims, snapshot: snapshot) == [
            .rejected(.expectationMismatch),
            .accepted(try binding(managed: "managed-1", native: "native-expected")),
        ])
    }

    @Test
    func oneManagedSessionOfferingMultipleNativeSessionsRejectsAllOffers() throws {
        let claims = [
            try makeClaim(managed: "managed-1", native: "native-1"),
            try makeClaim(managed: "managed-1", native: "native-2"),
        ]

        #expect(evaluate(claims) == [
            .rejected(.managedSessionOfferedMultipleNativeSessions),
            .rejected(.managedSessionOfferedMultipleNativeSessions),
        ])
    }

    @Test
    func oneNativeSessionOfferedToMultipleManagedSessionsRejectsAllOffers() throws {
        let claims = [
            try makeClaim(managed: "managed-1", native: "native-1"),
            try makeClaim(managed: "managed-2", native: "NATIVE-1"),
        ]

        #expect(evaluate(claims) == [
            .rejected(.nativeSessionOfferedToMultipleManagedSessions),
            .rejected(.nativeSessionOfferedToMultipleManagedSessions),
        ])
    }

    @Test
    func overlappingAmbiguitiesAreComputedFromOneEligibleSet() throws {
        let claims = [
            try makeClaim(managed: "managed-1", native: "native-1"),
            try makeClaim(managed: "managed-1", native: "native-2"),
            try makeClaim(managed: "managed-2", native: "native-1"),
        ]

        #expect(evaluate(claims) == [
            .rejected(.managedSessionOfferedMultipleNativeSessions),
            .rejected(.managedSessionOfferedMultipleNativeSessions),
            .rejected(.nativeSessionOfferedToMultipleManagedSessions),
        ])
    }

    @Test
    func exactDuplicateFromTwoSourcesDoesNotCreateAmbiguity() throws {
        let claims = [
            try makeClaim(
                managed: "managed-1",
                native: "native-1",
                path: "/tmp/one",
                source: "file-scan"
            ),
            try makeClaim(
                managed: "managed-1",
                native: "NATIVE-1",
                path: "/tmp/one",
                source: "hook"
            ),
        ]
        let accepted = NativeSessionClaimDecision.accepted(
            try binding(managed: "managed-1", native: "native-1", path: "/tmp/one")
        )

        #expect(evaluate(claims) == [accepted, accepted])
    }

    @Test
    func nilAndNonNilPathMergeToObservedPath() throws {
        let claims = [
            try makeClaim(managed: "managed-1", native: "native-1", path: nil),
            try makeClaim(managed: "managed-1", native: "native-1", path: "/tmp/one"),
        ]
        let accepted = NativeSessionClaimDecision.accepted(
            try binding(managed: "managed-1", native: "native-1", path: "/tmp/one")
        )

        #expect(evaluate(claims) == [accepted, accepted])
    }

    @Test
    func conflictingSimultaneousPathsRejectEveryOfferForTheBinding() throws {
        let claims = [
            try makeClaim(managed: "managed-1", native: "native-1", path: "/tmp/one"),
            try makeClaim(managed: "managed-1", native: "native-1", path: "/tmp/two"),
        ]

        #expect(evaluate(claims) == [
            .rejected(.conflictingSimultaneousRolloutPaths),
            .rejected(.conflictingSimultaneousRolloutPaths),
        ])
    }

    @Test
    func conflictingPersistedOwnersFailClosed() throws {
        let native = try nativeID("native-1")
        let snapshot = NativeSessionOwnershipSnapshot(
            ownerByNativeSessionID: [
                native: .activeManaged(
                    managedSessionID: try managedID("managed-1"),
                    rolloutPath: nil
                ),
            ],
            expectedNativeSessionIDByManagedSessionID: [:],
            conflictedNativeSessionIDs: [native]
        )

        #expect(snapshot.ownerByNativeSessionID[native] == nil)
        #expect(evaluate([
            try makeClaim(managed: "managed-1", native: "native-1"),
        ], snapshot: snapshot) == [
            .rejected(.conflictingSnapshotOwners),
        ])
    }

    @Test
    func observedPathWinsOverSameOwnersPersistedPathForCompatibility() throws {
        let managed = try managedID("managed-1")
        let native = try nativeID("native-1")
        let snapshot = NativeSessionOwnershipSnapshot(
            ownerByNativeSessionID: [
                native: .activeManaged(
                    managedSessionID: managed,
                    rolloutPath: try path("/tmp/persisted")
                ),
            ],
            expectedNativeSessionIDByManagedSessionID: [:]
        )

        #expect(evaluate([
            try makeClaim(managed: "managed-1", native: "native-1", path: "/tmp/observed"),
        ], snapshot: snapshot) == [
            .accepted(try binding(managed: "managed-1", native: "native-1", path: "/tmp/observed")),
        ])
    }

    @Test
    func sourceDoesNotChangeDecision() throws {
        let first = try makeClaim(
            managed: "managed-1",
            native: "native-1",
            path: "/tmp/one",
            source: "file-scan"
        )
        let second = try makeClaim(
            managed: "managed-1",
            native: "native-1",
            path: "/tmp/one",
            source: "future-source"
        )

        #expect(evaluate([first]) == evaluate([second]))
    }

    @Test
    func decisionsRemainAttachedToInputClaimsAcrossPermutations() throws {
        let acceptedClaim = try makeClaim(managed: "managed-a", native: "native-a")
        let mismatchedClaim = try makeClaim(managed: "managed-b", native: "native-wrong")
        let snapshot = NativeSessionOwnershipSnapshot(
            ownerByNativeSessionID: [:],
            expectedNativeSessionIDByManagedSessionID: [
                try managedID("managed-b"): try nativeID("native-expected"),
            ]
        )
        let forward = [acceptedClaim, mismatchedClaim]
        let reverse = Array(forward.reversed())

        let forwardResults = Dictionary(uniqueKeysWithValues: zip(forward, evaluate(forward, snapshot: snapshot)))
        let reverseResults = Dictionary(uniqueKeysWithValues: zip(reverse, evaluate(reverse, snapshot: snapshot)))
        #expect(forwardResults == reverseResults)
    }

    @Test
    func evaluationDoesNotMutateSnapshot() throws {
        let native = try nativeID("native-1")
        let snapshot = NativeSessionOwnershipSnapshot(
            ownerByNativeSessionID: [native: .inactivePersistedClaim(rolloutPath: nil)],
            expectedNativeSessionIDByManagedSessionID: [
                try managedID("managed-1"): native,
            ]
        )
        let before = snapshot

        _ = evaluate([
            try makeClaim(managed: "managed-1", native: "native-1"),
        ], snapshot: snapshot)

        #expect(snapshot == before)
    }

    @Test
    func managedSessionMayReplacePriorNativeBindingForObserverCompatibility() throws {
        // The current observer replaces a panel's resume record when a fresh
        // candidate appears. Tightening this into a multi-native rejection is
        // intentionally deferred until product semantics require it.
        let managed = try managedID("managed-1")
        let snapshot = NativeSessionOwnershipSnapshot(
            ownerByNativeSessionID: [
                try nativeID("native-old"): .activeManaged(
                    managedSessionID: managed,
                    rolloutPath: nil
                ),
            ],
            expectedNativeSessionIDByManagedSessionID: [:]
        )

        #expect(evaluate([
            try makeClaim(managed: "managed-1", native: "native-new"),
        ], snapshot: snapshot) == [
            .accepted(try binding(managed: "managed-1", native: "native-new")),
        ])
    }
}

private func evaluate(
    _ claims: [NativeSessionClaim],
    snapshot: NativeSessionOwnershipSnapshot = .empty
) -> [NativeSessionClaimDecision] {
    NativeSessionClaimEvaluator.evaluate(claims: claims, snapshot: snapshot)
}

private func makeClaim(
    managed: String,
    native: String,
    path rawPath: String? = nil,
    source: String = "test"
) throws -> NativeSessionClaim {
    NativeSessionClaim(
        managedSessionID: try managedID(managed),
        nativeSessionID: try nativeID(native),
        rolloutPath: try rawPath.map(path),
        source: try #require(NativeSessionClaimSource(source))
    )
}

private func binding(
    managed: String,
    native: String,
    path rawPath: String? = nil
) throws -> AcceptedNativeSessionBinding {
    AcceptedNativeSessionBinding(
        managedSessionID: try managedID(managed),
        nativeSessionID: try nativeID(native),
        rolloutPath: try rawPath.map(path)
    )
}

private func managedID(_ rawValue: String) throws -> ManagedSessionID {
    try #require(ManagedSessionID(rawValue))
}

private func nativeID(_ rawValue: String) throws -> NativeSessionID {
    try #require(NativeSessionID(rawValue))
}

private func path(_ rawValue: String) throws -> RolloutPath {
    try #require(RolloutPath(rawValue))
}
