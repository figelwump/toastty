import Testing
@testable import CodexReconciliation

struct CodexApprovalReconciliationTests {
    @Test
    func decisionBranchesPreserveLegacyOrder() {
        let cases: [DecisionCase] = [
            DecisionCase(
                name: "missing request thread precedes missing root",
                request: request(thread: nil, turn: "turn"),
                root: .empty,
                expected: .suppress(reason: .missingRequestThread)
            ),
            DecisionCase(
                name: "missing root thread",
                request: request(),
                root: root(thread: nil),
                expected: .deferForContext(reason: .missingRootThread)
            ),
            DecisionCase(
                name: "thread mismatch precedes missing request turn",
                request: request(thread: "other", turn: nil),
                root: root(),
                expected: .ignore(reason: .threadMismatch)
            ),
            DecisionCase(
                name: "missing request turn",
                request: request(turn: nil),
                root: root(),
                expected: .suppress(reason: .missingRequestTurn)
            ),
            DecisionCase(
                name: "missing root turn without pending fingerprint",
                request: request(),
                root: root(turn: nil),
                expected: .suppress(reason: .missingRootTurn)
            ),
            DecisionCase(
                name: "missing root turn with pending fingerprint",
                request: request(),
                root: root(turn: nil, pendingFingerprint: "pending"),
                expected: .deferForContext(reason: .missingRootTurn)
            ),
            DecisionCase(
                name: "turn mismatch with current reviewer",
                request: request(turn: "other"),
                root: root(current: context(reviewer: .string("reviewer"))),
                expected: .suppress(reason: .autoReviewContextTurnMismatch)
            ),
            DecisionCase(
                name: "turn mismatch awaiting context with active reviewer",
                request: request(turn: "other"),
                root: root(
                    awaiting: true,
                    current: nil,
                    active: context(reviewer: .string("reviewer"))
                ),
                expected: .suppress(reason: .autoReviewContextTurnMismatch)
            ),
            DecisionCase(
                name: "turn mismatch ignores inactive active reviewer",
                request: request(turn: "other"),
                root: root(
                    current: nil,
                    active: context(reviewer: .string("reviewer"))
                ),
                expected: .ignore(reason: .turnMismatch)
            ),
            DecisionCase(
                name: "turn mismatch without reviewer",
                request: request(turn: "other"),
                root: root(),
                expected: .ignore(reason: .turnMismatch)
            ),
            DecisionCase(
                name: "awaiting root context",
                request: request(),
                root: root(awaiting: true, current: nil),
                expected: .deferForContext(reason: .awaitingRootTurnContext)
            ),
            DecisionCase(
                name: "missing approval context",
                request: request(),
                root: root(current: nil),
                expected: .deferForContext(reason: .missingApprovalContext)
            ),
            DecisionCase(
                name: "unspecified reviewer",
                request: request(),
                root: root(current: context(
                    policy: .string("on-request"),
                    reviewer: .unspecified
                )),
                expected: .deferForContext(reason: .unknownApprovalsReviewer)
            ),
            DecisionCase(
                name: "null policy",
                request: request(),
                root: root(current: context(policy: .null, reviewer: .null)),
                expected: .suppress(reason: .missingHumanApprovalPolicy)
            ),
            DecisionCase(
                name: "unspecified policy",
                request: request(),
                root: root(current: context(policy: .unspecified, reviewer: .null)),
                expected: .suppress(reason: .missingHumanApprovalPolicy)
            ),
            DecisionCase(
                name: "blank policy",
                request: request(),
                root: root(current: context(policy: .string(" \n"), reviewer: .null)),
                expected: .suppress(reason: .missingHumanApprovalPolicy)
            ),
            DecisionCase(
                name: "never policy is case insensitive and trimmed",
                request: request(),
                root: root(current: context(policy: .string(" NeVeR "), reviewer: .null)),
                expected: .suppress(reason: .missingHumanApprovalPolicy)
            ),
            DecisionCase(
                name: "on-request policy",
                request: request(),
                root: root(current: context(policy: .string("on-request"), reviewer: .null)),
                expected: .accept(reason: .humanApproval)
            ),
            DecisionCase(
                name: "other nonempty policy",
                request: request(),
                root: root(current: context(policy: .string("human"), reviewer: .null)),
                expected: .accept(reason: .humanApproval)
            ),
            DecisionCase(
                name: "explicit user reviewer",
                request: request(),
                root: root(current: context(
                    policy: .string("on-request"),
                    reviewer: .string(" user ")
                )),
                expected: .accept(reason: .humanApproval)
            ),
            DecisionCase(
                name: "legacy auto reviewer",
                request: request(),
                root: root(current: context(
                    policy: .string("on-request"),
                    reviewer: .string(" reviewer ")
                )),
                expected: .suppress(reason: .autoReviewApproval)
            ),
            DecisionCase(
                name: "current auto reviewer",
                request: request(),
                root: root(current: context(
                    policy: .string("on-request"),
                    reviewer: .string("auto_review")
                )),
                expected: .suppress(reason: .autoReviewApproval)
            ),
            DecisionCase(
                name: "unknown reviewer fails open through deferral",
                request: request(),
                root: root(current: context(
                    policy: .string("on-request"),
                    reviewer: .string("future_reviewer")
                )),
                expected: .deferForContext(reason: .unknownApprovalsReviewer)
            ),
        ]

        for testCase in cases {
            var reconciler = CodexApprovalReconciler(authority: .hooks)
            let reduction = reconciler.reduce(testCase.request, root: testCase.root)
            #expect(reduction.decision == testCase.expected, Comment(rawValue: testCase.name))
        }
    }

    @Test
    func alreadyAutoReviewedMismatchedTurnIsIgnoredBeforeReviewerPolicy() {
        var reconciler = CodexApprovalReconciler(authority: .hooks)
        _ = reconciler.reduce(
            request(thread: nil, turn: "stale"),
            root: root(current: context(reviewer: .string("reviewer")))
        )

        let reduction = reconciler.reduce(
            request(turn: "stale"),
            root: root(current: context(reviewer: .string("reviewer")))
        )

        #expect(reduction.decision == .ignore(reason: .autoReviewedStaleTurn))
        #expect(reduction.didMutateHistory == false)
        #expect(reduction.snapshot.autoReviewedTurnIDs == ["stale"])
    }

    @Test
    func everySuppressionBranchRecordsOnlySourceObservedNonemptyTurn() {
        let cases: [SuppressionCase] = [
            SuppressionCase(
                name: "missing request thread",
                requestThread: nil,
                requestTurn: "missing-thread",
                root: .empty,
                reason: .missingRequestThread,
                expectedRecordedTurn: "missing-thread"
            ),
            SuppressionCase(
                name: "missing request thread with blank turn",
                requestThread: nil,
                requestTurn: " \n",
                root: .empty,
                reason: .missingRequestThread,
                expectedRecordedTurn: nil
            ),
            SuppressionCase(
                name: "missing request turn",
                requestThread: "thread",
                requestTurn: nil,
                root: root(),
                reason: .missingRequestTurn,
                expectedRecordedTurn: nil
            ),
            SuppressionCase(
                name: "missing root turn",
                requestThread: "thread",
                requestTurn: "missing-root-turn",
                root: root(turn: nil),
                reason: .missingRootTurn,
                expectedRecordedTurn: "missing-root-turn"
            ),
            SuppressionCase(
                name: "mismatched auto-review context",
                requestThread: "thread",
                requestTurn: "mismatch",
                root: root(current: context(reviewer: .string("reviewer"))),
                reason: .autoReviewContextTurnMismatch,
                expectedRecordedTurn: "mismatch"
            ),
            SuppressionCase(
                name: "mismatched active reviewer while awaiting context",
                requestThread: "thread",
                requestTurn: "active-mismatch",
                root: root(
                    awaiting: true,
                    current: nil,
                    active: context(reviewer: .string("reviewer"))
                ),
                reason: .autoReviewContextTurnMismatch,
                expectedRecordedTurn: "active-mismatch"
            ),
            SuppressionCase(
                name: "missing human approval policy",
                requestThread: "thread",
                requestTurn: "turn",
                root: root(current: context(policy: .null, reviewer: .null)),
                reason: .missingHumanApprovalPolicy,
                expectedRecordedTurn: "turn"
            ),
            SuppressionCase(
                name: "auto-review approval",
                requestThread: "thread",
                requestTurn: "turn",
                root: root(current: context(reviewer: .string("reviewer"))),
                reason: .autoReviewApproval,
                expectedRecordedTurn: "turn"
            ),
        ]

        for testCase in cases {
            var sourceObserved = CodexApprovalReconciler(authority: .hooks)
            let observed = sourceObserved.reduce(
                request(
                    thread: testCase.requestThread,
                    turn: testCase.requestTurn,
                    provenance: .sourceObserved
                ),
                root: testCase.root
            )
            #expect(
                observed.decision == .suppress(reason: testCase.reason),
                Comment(rawValue: testCase.name)
            )
            #expect(
                observed.snapshot.autoReviewedTurnIDs == testCase.expectedRecordedTurn.map { [$0] } ?? [],
                Comment(rawValue: testCase.name)
            )
            #expect(
                observed.didMutateHistory == (testCase.expectedRecordedTurn != nil),
                Comment(rawValue: testCase.name)
            )

            var rootFallback = CodexApprovalReconciler(authority: .hooks)
            let fallback = rootFallback.reduce(
                request(
                    thread: testCase.requestThread,
                    turn: testCase.requestTurn,
                    provenance: .rootFallback
                ),
                root: testCase.root
            )
            #expect(
                fallback.decision == .suppress(reason: testCase.reason),
                Comment(rawValue: testCase.name)
            )
            #expect(fallback.snapshot == .empty, Comment(rawValue: testCase.name))
            #expect(fallback.didMutateHistory == false, Comment(rawValue: testCase.name))
        }
    }

    @Test
    func historyAppendTrimsButIdentityComparisonsRemainRaw() {
        var reconciler = CodexApprovalReconciler(authority: .hooks)
        let initial = reconciler.reduce(
            request(thread: nil, turn: " stale \n"),
            root: .empty
        )
        #expect(initial.snapshot.autoReviewedTurnIDs == ["stale"])

        let rawTurn = reconciler.reduce(
            request(turn: " stale \n"),
            root: root()
        )
        #expect(rawTurn.decision == .ignore(reason: .turnMismatch))

        let normalizedTurn = reconciler.reduce(
            request(turn: "stale"),
            root: root()
        )
        #expect(normalizedTurn.decision == .ignore(reason: .autoReviewedStaleTurn))

        let rawThread = reconciler.reduce(
            request(thread: " thread ", turn: "turn"),
            root: root()
        )
        #expect(rawThread.decision == .ignore(reason: .threadMismatch))
    }

    @Test
    func duplicateHistoryIsStableAndFifoIsBoundedToSixteen() {
        var reconciler = CodexApprovalReconciler(authority: .hooks)
        for index in 0...16 {
            let reduction = reconciler.reduce(
                request(thread: nil, turn: " turn-\(index) "),
                root: .empty
            )
            #expect(reduction.decision == .suppress(reason: .missingRequestThread))
            #expect(reduction.didMutateHistory)
        }

        #expect(reconciler.snapshot.autoReviewedTurnIDs.count == 16)
        #expect(reconciler.snapshot.autoReviewedTurnIDs.first == "turn-1")
        #expect(reconciler.snapshot.autoReviewedTurnIDs.last == "turn-16")

        let duplicate = reconciler.reduce(
            request(thread: nil, turn: " turn-16 "),
            root: .empty
        )
        #expect(duplicate.decision == .suppress(reason: .missingRequestThread))
        #expect(duplicate.didMutateHistory == false)
        #expect(duplicate.snapshot.autoReviewedTurnIDs.first == "turn-1")
        #expect(duplicate.snapshot.autoReviewedTurnIDs.last == "turn-16")
    }

    @Test
    func authorityMatrixAcceptsOnlyItsFixedSource() {
        let cases: [(CodexApprovalAuthority, CodexApprovalSource, Bool)] = [
            (.hooks, .hook, true),
            (.hooks, .sessionLog, false),
            (.sessionLogFallback, .hook, false),
            (.sessionLogFallback, .sessionLog, true),
            (.legacyPermissive, .hook, true),
            (.legacyPermissive, .sessionLog, true),
        ]

        for (authority, source, isAccepted) in cases {
            var reconciler = CodexApprovalReconciler(authority: authority)
            let reduction = reconciler.reduce(
                request(source: source),
                root: root(current: context(policy: .string("on-request"), reviewer: .null))
            )
            if isAccepted {
                #expect(reduction.decision == .accept(reason: .humanApproval))
            } else {
                #expect(reduction.decision == .ignore(reason: .incompatibleWithAuthority))
            }
            #expect(reduction.didMutateHistory == false)
        }
    }

    @Test
    func incompatibleAuthorityNeverMutatesExistingHistory() {
        for (authority, incompatibleSource) in [
            (CodexApprovalAuthority.hooks, CodexApprovalSource.sessionLog),
            (.sessionLogFallback, .hook),
        ] {
            var reconciler = CodexApprovalReconciler(authority: authority)
            let compatibleSource: CodexApprovalSource = authority == .hooks ? .hook : .sessionLog
            _ = reconciler.reduce(
                request(source: compatibleSource, thread: nil, turn: "existing"),
                root: .empty
            )
            let reconcilerBefore = reconciler
            let before = reconciler.snapshot

            let reduction = reconciler.reduce(
                request(source: incompatibleSource, thread: nil, turn: "new"),
                root: .empty
            )

            #expect(reduction.decision == .ignore(reason: .incompatibleWithAuthority))
            #expect(reduction.didMutateHistory == false)
            #expect(reduction.snapshot == before)
            #expect(reconciler.snapshot == before)
            #expect(reconciler == reconcilerBefore)
        }
    }

    @Test
    func resetTurnHistoryReportsWhetherItChangedState() {
        var reconciler = CodexApprovalReconciler(authority: .hooks)
        let initialReset = reconciler.resetTurnHistory()
        #expect(initialReset == false)
        _ = reconciler.reduce(request(thread: nil, turn: "turn"), root: .empty)
        #expect(reconciler.snapshot.autoReviewedTurnIDs == ["turn"])
        let populatedReset = reconciler.resetTurnHistory()
        #expect(populatedReset)
        #expect(reconciler.snapshot == .empty)
        let repeatedReset = reconciler.resetTurnHistory()
        #expect(repeatedReset == false)
    }

    @Test
    func supersessionExhaustivelyPreservesRawCorrelationTruthTable() {
        let values: [String?] = [nil, "same", "other"]
        var evaluated = 0

        for pendingThread in values {
            for incomingThread in values {
                for pendingTurn in values {
                    for incomingTurn in values {
                        let pending = CodexApprovalCorrelation(
                            threadID: pendingThread,
                            turnID: pendingTurn
                        )
                        let incoming = CodexApprovalCorrelation(
                            threadID: incomingThread,
                            turnID: incomingTurn
                        )
                        let actual = CodexApprovalSupersession.shouldSupersede(
                            pending: pending,
                            incoming: incoming
                        )
                        let expected = expectedSupersession(
                            pending: pending,
                            incoming: incoming
                        )
                        #expect(actual == expected)
                        evaluated += 1
                    }
                }
            }
        }

        #expect(evaluated == 81)
        #expect(CodexApprovalSupersession.shouldSupersede(
            pending: CodexApprovalCorrelation(threadID: "thread", turnID: "turn"),
            incoming: CodexApprovalCorrelation(threadID: " thread ", turnID: "turn")
        ) == false)
    }

    @Test
    func publicValuesCrossSendableBoundary() async {
        let reconciler = requireSendable(CodexApprovalReconciler(authority: .hooks))
        let request = requireSendable(request())
        let root = requireSendable(root())
        let correlation = requireSendable(CodexApprovalCorrelation(
            threadID: "thread",
            turnID: "turn"
        ))

        let result = await Task.detached {
            var reconciler = reconciler
            let reduction = reconciler.reduce(request, root: root)
            return requireSendable((reduction, reconciler.snapshot, correlation))
        }.value

        #expect(result.0.decision == .suppress(reason: .missingHumanApprovalPolicy))
        #expect(result.1.autoReviewedTurnIDs == ["turn"])
        #expect(result.2.threadID == "thread")
    }
}

private struct DecisionCase {
    let name: String
    let request: CodexApprovalRequest
    let root: CodexRootTurnSnapshot
    let expected: CodexApprovalDecision
}

private struct SuppressionCase {
    let name: String
    let requestThread: String?
    let requestTurn: String?
    let root: CodexRootTurnSnapshot
    let reason: CodexApprovalReason
    let expectedRecordedTurn: String?
}

private func request(
    source: CodexApprovalSource = .hook,
    thread: String? = "thread",
    turn: String? = "turn",
    provenance: CodexApprovalTurnProvenance = .sourceObserved
) -> CodexApprovalRequest {
    CodexApprovalRequest(
        source: source,
        threadID: thread,
        turnID: turn,
        turnProvenance: provenance
    )
}

private func root(
    thread: String? = "thread",
    turn: String? = "turn",
    awaiting: Bool = false,
    pendingFingerprint: String? = nil,
    current: CodexRootTurnApprovalContext? = context(),
    active: CodexRootTurnApprovalContext? = nil
) -> CodexRootTurnSnapshot {
    CodexRootTurnSnapshot(
        rootThreadID: thread,
        rootTurnID: turn,
        isAwaitingSessionLogContext: awaiting,
        pendingRootInputFingerprint: pendingFingerprint,
        activeApprovalContext: active,
        currentApprovalContext: current
    )
}

private func context(
    policy: CodexRootTurnContextField = .null,
    reviewer: CodexRootTurnContextField = .null
) -> CodexRootTurnApprovalContext {
    CodexRootTurnApprovalContext(
        approvalPolicy: policy,
        approvalsReviewer: reviewer
    )
}

private func expectedSupersession(
    pending: CodexApprovalCorrelation,
    incoming: CodexApprovalCorrelation
) -> Bool {
    let threadsMatch: Bool
    if let pendingThread = pending.threadID,
       let incomingThread = incoming.threadID {
        guard pendingThread == incomingThread else { return false }
        threadsMatch = true
    } else {
        threadsMatch = false
    }

    if let pendingTurn = pending.turnID,
       let incomingTurn = incoming.turnID {
        return pendingTurn == incomingTurn || threadsMatch
    }
    return threadsMatch
}

private func requireSendable<Value: Sendable>(_ value: Value) -> Value {
    value
}
