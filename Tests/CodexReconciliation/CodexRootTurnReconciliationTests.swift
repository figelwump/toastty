import Testing
@testable import CodexReconciliation

struct CodexRootTurnReconciliationTests {
    @Test
    func launchInputAndHookPromptConvergeInEitherOrder() {
        let expectedContext = context(policy: .string("on-request"), reviewer: .null)

        var launchFirst = CodexRootTurnReconciler(authority: .hooks)
        _ = launchFirst.reduce(rootInput(
            fingerprint: "fp",
            thread: "thread",
            turn: "turn",
            context: expectedContext
        ))
        let launchFirstHook = launchFirst.reduce(hook(
            .userPromptSubmit,
            thread: "thread",
            turn: "turn",
            fingerprint: "fp"
        ))

        var hookFirst = CodexRootTurnReconciler(authority: .hooks)
        _ = hookFirst.reduce(hook(
            .userPromptSubmit,
            thread: "thread",
            turn: "turn",
            fingerprint: "fp"
        ))
        #expect(hookFirst.snapshot.isAwaitingSessionLogContext)
        let hookFirstLaunch = hookFirst.reduce(rootInput(
            fingerprint: "fp",
            thread: "thread",
            turn: "turn",
            context: expectedContext
        ))

        #expect(launchFirst.snapshot == hookFirst.snapshot)
        #expect(launchFirst.snapshot.rootThreadID == "thread")
        #expect(launchFirst.snapshot.rootTurnID == "turn")
        #expect(launchFirst.snapshot.rootTurnInputFingerprint == "fp")
        #expect(launchFirst.snapshot.pendingRootInputFingerprint == "fp")
        #expect(launchFirst.snapshot.currentApprovalContext == expectedContext)
        #expect(launchFirst.snapshot.isAwaitingSessionLogContext == false)
        #expect(launchFirstHook.didMutateRootState == false)
        #expect(hookFirstLaunch.didMutateRootState)
        assertValid(launchFirstHook)
        assertValid(hookFirstLaunch)
    }

    @Test
    func canonicalContextWinsAcrossLaunchAndHookOrdering() {
        let canonical = context(
            policy: .string("on-request"),
            reviewer: .string("auto_review")
        )

        var canonicalFirst = CodexRootTurnReconciler(authority: .hooks)
        _ = canonicalFirst.reduce(.canonicalTurnContext(turnID: "turn", context: canonical))
        _ = canonicalFirst.reduce(rootInput(
            fingerprint: "fp",
            thread: "thread",
            turn: "turn",
            context: context(policy: .string("on-request"), reviewer: .null)
        ))
        _ = canonicalFirst.reduce(hook(
            .userPromptSubmit,
            thread: "thread",
            turn: "turn",
            fingerprint: "fp"
        ))

        var hookFirst = CodexRootTurnReconciler(authority: .hooks)
        _ = hookFirst.reduce(hook(
            .userPromptSubmit,
            thread: "thread",
            turn: "turn",
            fingerprint: "fp"
        ))
        _ = hookFirst.reduce(.canonicalTurnContext(turnID: "turn", context: canonical))
        _ = hookFirst.reduce(rootInput(
            fingerprint: "fp",
            thread: "thread",
            turn: "turn",
            context: context(policy: .string("on-request"), reviewer: .null)
        ))
        _ = hookFirst.reduce(.launchLogOverrideContext(context(
            reviewer: .null
        )))

        #expect(canonicalFirst.snapshot.currentApprovalContext == canonical)
        #expect(hookFirst.snapshot.currentApprovalContext == canonical)
        #expect(canonicalFirst.snapshot.isAwaitingSessionLogContext == false)
        #expect(hookFirst.snapshot.isAwaitingSessionLogContext == false)
    }

    @Test
    func partialCanonicalUpdatesMergeWithinTheSameTurn() {
        var reconciler = CodexRootTurnReconciler(authority: .hooks)
        _ = reconciler.reduce(hook(
            .userPromptSubmit,
            thread: "thread",
            turn: "turn",
            fingerprint: "fp"
        ))
        _ = reconciler.reduce(.canonicalTurnContext(
            turnID: "turn",
            context: context(reviewer: .string("auto_review"))
        ))
        _ = reconciler.reduce(.canonicalTurnContext(
            turnID: "turn",
            context: context(policy: .string("on-request"))
        ))

        let expected = context(
            policy: .string("on-request"),
            reviewer: .string("auto_review")
        )
        #expect(reconciler.snapshot.latestCanonicalApprovalContext == expected)
        #expect(reconciler.snapshot.currentApprovalContext == expected)
    }

    @Test
    func canonicalContextIsTurnScopedAcrossReviewerTransitions() {
        var reconciler = CodexRootTurnReconciler(authority: .hooks)
        _ = reconciler.reduce(hook(
            .userPromptSubmit,
            thread: "thread",
            turn: "turn-auto",
            fingerprint: "auto"
        ))
        _ = reconciler.reduce(.canonicalTurnContext(
            turnID: "turn-auto",
            context: context(
                policy: .string("on-request"),
                reviewer: .string("auto_review")
            )
        ))

        _ = reconciler.reduce(hook(
            .userPromptSubmit,
            thread: "thread",
            turn: "turn-human",
            fingerprint: "human"
        ))
        #expect(reconciler.snapshot.currentApprovalContext == nil)
        #expect(reconciler.snapshot.isAwaitingSessionLogContext)

        let humanContext = context(
            policy: .string("on-request"),
            reviewer: .string("user")
        )
        _ = reconciler.reduce(.canonicalTurnContext(
            turnID: "turn-human",
            context: humanContext
        ))

        #expect(reconciler.snapshot.currentApprovalContext == humanContext)
        #expect(reconciler.snapshot.isAwaitingSessionLogContext == false)
    }

    @Test
    func triStateMergeRetainsClearsAndOverwritesEachField() {
        let fields: [CodexRootTurnContextField] = [
            .unspecified,
            .null,
            .string("replacement"),
        ]

        for policyPatch in fields {
            for reviewerPatch in fields {
                var reconciler = CodexRootTurnReconciler(authority: .hooks)
                _ = reconciler.reduce(.launchLogOverrideContext(context(
                    policy: .string("active-policy"),
                    reviewer: .string("active-reviewer")
                )))
                _ = reconciler.reduce(rootInput(
                    fingerprint: "fp",
                    thread: "thread",
                    turn: "turn",
                    context: context(policy: policyPatch, reviewer: reviewerPatch)
                ))

                #expect(reconciler.snapshot.currentApprovalContext == context(
                    policy: expectedField(patch: policyPatch, inherited: "active-policy"),
                    reviewer: expectedField(patch: reviewerPatch, inherited: "active-reviewer")
                ))
            }
        }
    }

    @Test
    func fingerprintWithoutTurnCreatesPendingThenMatchingHookPromotesOldPendingContext() {
        var reconciler = CodexRootTurnReconciler(authority: .hooks)
        let pending = context(policy: .string("on-request"), reviewer: .string("guardian"))

        _ = reconciler.reduce(rootInput(
            fingerprint: "old-pending-fingerprint",
            thread: "thread",
            context: pending
        ))
        #expect(reconciler.snapshot.pendingApprovalContext == pending)
        #expect(reconciler.snapshot.currentApprovalContext == nil)

        let result = reconciler.reduce(hook(
            .userPromptSubmit,
            thread: "thread",
            turn: "turn",
            fingerprint: "old-pending-fingerprint"
        ))

        #expect(result.snapshot.rootTurnID == "turn")
        #expect(result.snapshot.currentApprovalContext == pending)
        #expect(result.snapshot.pendingApprovalContext == nil)
        #expect(result.snapshot.isAwaitingSessionLogContext == false)
        #expect(result.snapshot.pendingRootInputFingerprint == "old-pending-fingerprint")
        assertValid(result)
    }

    @Test
    func unmatchedHookAwaitsContextAndFingerprintOnlyLaunchPromotesIt() {
        var reconciler = CodexRootTurnReconciler(authority: .hooks)
        _ = reconciler.reduce(.launchLogOverrideContext(context(
            policy: .string("active-policy"),
            reviewer: .string("active-reviewer")
        )))
        _ = reconciler.reduce(rootInput(
            fingerprint: "old",
            thread: "thread",
            context: context(policy: .string("old-policy"), reviewer: .null)
        ))

        _ = reconciler.reduce(hook(
            .userPromptSubmit,
            thread: "thread",
            turn: "turn",
            fingerprint: "new"
        ))
        #expect(reconciler.snapshot.rootTurnID == "turn")
        #expect(reconciler.snapshot.rootTurnInputFingerprint == "new")
        #expect(reconciler.snapshot.currentApprovalContext == nil)
        #expect(reconciler.snapshot.pendingApprovalContext == nil)
        #expect(reconciler.snapshot.isAwaitingSessionLogContext)

        let promoted = reconciler.reduce(rootInput(
            fingerprint: "new",
            thread: "thread",
            context: context(policy: .null, reviewer: .string("new-reviewer"))
        ))
        #expect(promoted.snapshot.rootTurnID == "turn")
        #expect(promoted.snapshot.currentApprovalContext == context(
            policy: .null,
            reviewer: .string("new-reviewer")
        ))
        #expect(promoted.snapshot.isAwaitingSessionLogContext == false)
        assertValid(promoted)
    }

    @Test
    func matchingLaunchInputWithoutContextKeepsHookWaitingForCanonicalContext() {
        var reconciler = CodexRootTurnReconciler(authority: .hooks)
        _ = reconciler.reduce(hook(
            .userPromptSubmit,
            thread: "thread",
            turn: "turn",
            fingerprint: "fp"
        ))

        let launch = reconciler.reduce(rootInput(
            fingerprint: "fp",
            context: context()
        ))

        #expect(launch.snapshot.rootTurnID == "turn")
        #expect(launch.snapshot.rootTurnInputFingerprint == "fp")
        #expect(launch.snapshot.isAwaitingSessionLogContext)
        #expect(launch.snapshot.currentApprovalContext == nil)
    }

    @Test
    func explicitContextWithoutTurnOrFingerprintClearsCurrentAndPendingButRetainsActive() {
        var reconciler = CodexRootTurnReconciler(authority: .hooks)
        let active = context(policy: .string("active"), reviewer: .string("guardian"))
        _ = reconciler.reduce(.launchLogOverrideContext(active))
        _ = reconciler.reduce(rootInput(
            fingerprint: "fp",
            thread: "thread",
            turn: "turn",
            context: context(policy: .string("turn-policy"), reviewer: .null)
        ))

        let result = reconciler.reduce(rootInput(
            thread: "thread",
            context: context(policy: .null)
        ))

        #expect(result.snapshot.rootThreadID == "thread")
        #expect(result.snapshot.rootTurnID == nil)
        #expect(result.snapshot.rootTurnInputFingerprint == nil)
        #expect(result.snapshot.pendingRootInputFingerprint == nil)
        #expect(result.snapshot.pendingApprovalContext == nil)
        #expect(result.snapshot.currentApprovalContext == nil)
        #expect(result.snapshot.activeApprovalContext == active)
        assertValid(result)
    }

    @Test
    func overridePatchesActiveBeforePendingAndCurrentFallback() {
        var pendingReconciler = CodexRootTurnReconciler(authority: .hooks)
        _ = pendingReconciler.reduce(.launchLogOverrideContext(context(
            policy: .string("active-policy"),
            reviewer: .string("old-reviewer")
        )))
        _ = pendingReconciler.reduce(rootInput(
            fingerprint: "pending",
            thread: "thread",
            context: context(policy: .string("pending-policy"))
        ))
        _ = pendingReconciler.reduce(.launchLogOverrideContext(context(
            policy: .null,
            reviewer: .string("new-reviewer")
        )))

        #expect(pendingReconciler.snapshot.activeApprovalContext == context(
            policy: .null,
            reviewer: .string("new-reviewer")
        ))
        #expect(pendingReconciler.snapshot.pendingApprovalContext == context(
            policy: .null,
            reviewer: .string("new-reviewer")
        ))

        _ = pendingReconciler.reduce(hook(
            .userPromptSubmit,
            thread: "thread",
            turn: "turn",
            fingerprint: "pending"
        ))
        _ = pendingReconciler.reduce(.launchLogOverrideContext(context(
            policy: .string("current-policy")
        )))
        #expect(pendingReconciler.snapshot.currentApprovalContext == context(
            policy: .string("current-policy"),
            reviewer: .string("new-reviewer")
        ))
        #expect(pendingReconciler.snapshot.activeApprovalContext == context(
            policy: .string("current-policy"),
            reviewer: .string("new-reviewer")
        ))
    }

    @Test
    func launchThreadReplacementResetsTurnContextsAndRequestsLegacyClear() {
        var reconciler = populatedReconciler(authority: .hooks)
        _ = reconciler.reduce(rootInput(
            fingerprint: "pending-old",
            thread: "old-thread",
            context: context(policy: .string("pending"), reviewer: .string("old-reviewer"))
        ))

        let result = reconciler.reduce(rootInput(
            fingerprint: "new-pending",
            thread: "new-thread"
        ))

        #expect(result.qualification == .proceed)
        #expect(result.reason == .launchLogRootInput)
        #expect(result.didMutateRootState)
        #expect(result.shouldResetApprovalHistory)
        #expect(result.snapshot.rootThreadID == "new-thread")
        #expect(result.snapshot.rootTurnID == nil)
        #expect(result.snapshot.rootTurnInputFingerprint == nil)
        #expect(result.snapshot.pendingRootInputFingerprint == "new-pending")
        #expect(result.snapshot.pendingApprovalContext == nil)
        #expect(result.snapshot.activeApprovalContext == nil)
        #expect(result.snapshot.currentApprovalContext == nil)
        assertValid(result)
    }

    @Test
    func clearSessionStartAlwaysRequestsLegacyClearAndMismatchResetsRootState() {
        var sameThread = populatedReconciler(authority: .hooks)
        let sameResult = sameThread.reduce(hook(
            .sessionStart(isClear: true),
            thread: "thread"
        ))
        #expect(sameResult.qualification == .proceed)
        #expect(sameResult.didMutateRootState == false)
        #expect(sameResult.shouldResetApprovalHistory)
        #expect(sameResult.snapshot.rootTurnID == "turn")

        var replacement = populatedReconciler(authority: .hooks)
        let replacementResult = replacement.reduce(hook(
            .sessionStart(isClear: true),
            thread: "replacement-thread"
        ))
        #expect(replacementResult.snapshot.rootThreadID == "replacement-thread")
        #expect(replacementResult.snapshot.rootTurnID == nil)
        #expect(replacementResult.snapshot.rootTurnInputFingerprint == nil)
        #expect(replacementResult.snapshot.pendingRootInputFingerprint == nil)
        #expect(replacementResult.snapshot.pendingApprovalContext == nil)
        #expect(replacementResult.snapshot.activeApprovalContext == nil)
        #expect(replacementResult.snapshot.currentApprovalContext == nil)
        #expect(replacementResult.shouldResetApprovalHistory)
        assertValid(sameResult)
        assertValid(replacementResult)
    }

    @Test
    func hookSessionIdentityIsIndependentOfStatusAuthorityAndRejectsChildReplacement() {
        var reconciler = CodexRootTurnReconciler(authority: .sessionLogFallback)

        let root = reconciler.reduce(.hookSessionIdentity(
            threadID: "root-thread",
            isClear: false
        ))
        let child = reconciler.reduce(.hookSessionIdentity(
            threadID: "child-thread",
            isClear: false
        ))
        let status = reconciler.reduce(hook(
            .sessionStart(isClear: false),
            thread: "root-thread"
        ))

        #expect(root.qualification == .proceed)
        #expect(root.reason == .hookSessionIdentity)
        #expect(root.snapshot.rootThreadID == "root-thread")
        #expect(child.qualification == .rejectEvent)
        #expect(child.reason == .threadMismatch)
        #expect(child.snapshot.rootThreadID == "root-thread")
        #expect(status.qualification == .rejectEvent)
        #expect(status.reason == .incompatibleWithAuthority)
        #expect(status.snapshot.rootThreadID == "root-thread")
        assertValid(root)
        assertValid(child)
        assertValid(status)
    }

    @Test
    func clearHookSessionIdentityReplacesRootAndClearsTurnState() {
        var reconciler = populatedReconciler(authority: .sessionLogFallback)

        let result = reconciler.reduce(.hookSessionIdentity(
            threadID: "replacement-thread",
            isClear: true
        ))

        #expect(result.qualification == .proceed)
        #expect(result.reason == .hookSessionIdentity)
        #expect(result.shouldResetApprovalHistory)
        #expect(result.snapshot.rootThreadID == "replacement-thread")
        #expect(result.snapshot.rootTurnID == nil)
        #expect(result.snapshot.rootTurnInputFingerprint == nil)
        #expect(result.snapshot.pendingRootInputFingerprint == nil)
        #expect(result.snapshot.pendingApprovalContext == nil)
        #expect(result.snapshot.activeApprovalContext == nil)
        #expect(result.snapshot.currentApprovalContext == nil)
        assertValid(result)
    }

    @Test
    func duplicateClearIdentityDoesNotResetStateAfterAuthoritativeHookHandledIt() {
        var reconciler = populatedReconciler(authority: .hooks)
        let before = reconciler.snapshot

        let result = reconciler.reduce(.hookSessionIdentity(
            threadID: "thread",
            isClear: true
        ))

        #expect(result.qualification == .proceed)
        #expect(result.didMutateRootState == false)
        #expect(result.shouldResetApprovalHistory == false)
        #expect(result.snapshot == before)
        assertValid(result)
    }

    @Test
    func authorityMatrixAllowsOnlySelectedLifecycleSignal() {
        for authority in allAuthorities {
            var launch = CodexRootTurnReconciler(authority: authority)
            #expect(launch.reduce(rootInput(
                fingerprint: "fp",
                thread: "thread",
                turn: "turn"
            )).qualification == .proceed)
            #expect(launch.reduce(.launchLogOverrideContext(context(
                policy: .string("on-request")
            ))).qualification == .proceed)

            var identity = CodexRootTurnReconciler(authority: authority)
            let identityResult = identity.reduce(.hookSessionIdentity(
                threadID: "thread",
                isClear: false
            ))
            #expect(identityResult.qualification == .proceed)
            #expect(identityResult.reason == .hookSessionIdentity)

            var hookReconciler = CodexRootTurnReconciler(authority: authority)
            let other = hookReconciler.reduce(hook(.other, thread: "unlatched"))
            if authority == .sessionLogFallback {
                #expect(other.qualification == .rejectEvent)
                #expect(other.reason == .incompatibleWithAuthority)
            } else {
                #expect(other.qualification == .proceed)
                #expect(other.reason == .hookOther)
                #expect(other.didMutateRootState == false)
            }

            var notify = CodexRootTurnReconciler(authority: authority)
            _ = notify.reduce(rootInput(fingerprint: "fp"))
            let notifyResult = notify.reduce(.fallbackNotifyThreadCandidate(
                threadID: "thread",
                inputFingerprint: "fp"
            ))
            if authority == .hooks {
                #expect(notifyResult.qualification == .rejectEvent)
                #expect(notifyResult.reason == .incompatibleWithAuthority)
            } else {
                #expect(notifyResult.qualification == .proceed)
                #expect(notifyResult.reason == .fallbackNotifyThreadLatched)
            }
        }
    }

    @Test
    func fallbackAuthorityRejectsRootMutatingPromptBeforeStateMutation() {
        var reconciler = CodexRootTurnReconciler(authority: .sessionLogFallback)

        let result = reconciler.reduce(hook(
            .userPromptSubmit,
            thread: "must-not-latch",
            turn: "must-not-become-root",
            fingerprint: "must-not-become-pending"
        ))

        #expect(result.qualification == .rejectEvent)
        #expect(result.reason == .incompatibleWithAuthority)
        #expect(result.didMutateRootState == false)
        #expect(result.shouldResetApprovalHistory == false)
        #expect(result.snapshot == .empty)
        #expect(reconciler.snapshot == .empty)
        assertValid(result)
    }

    @Test
    func nilCompatibilityAuthorityAcceptsBothHookAndFallbackNotify() {
        var hookRoute = CodexRootTurnReconciler(authority: .legacyPermissive)
        #expect(hookRoute.reduce(hook(
            .userPromptSubmit,
            thread: "hook-thread",
            turn: "turn",
            fingerprint: "fp"
        )).qualification == .proceed)

        var notifyRoute = CodexRootTurnReconciler(authority: .legacyPermissive)
        _ = notifyRoute.reduce(rootInput(fingerprint: "fp"))
        let notify = notifyRoute.reduce(.fallbackNotifyThreadCandidate(
            threadID: "notify-thread",
            inputFingerprint: "fp"
        ))
        #expect(notify.qualification == .proceed)
        #expect(notify.snapshot.rootThreadID == "notify-thread")
    }

    @Test
    func stopQualificationMatchesKnownAndUnknownIdentityRules() {
        var known = populatedReconciler(authority: .hooks)
        #expect(known.reduce(hook(
            .stop,
            thread: "thread",
            turn: "different-turn"
        )).qualification == .proceed)
        let threadMismatch = known.reduce(hook(
            .stop,
            thread: "different-thread",
            turn: "turn"
        ))
        #expect(threadMismatch.qualification == .rejectEvent)
        #expect(threadMismatch.reason == .threadMismatch)
        #expect(known.reduce(hook(.stop, turn: "turn")).qualification == .proceed)
        let turnMismatch = known.reduce(hook(.stop, turn: "different-turn"))
        #expect(turnMismatch.qualification == .rejectEvent)
        #expect(turnMismatch.reason == .turnMismatch)
        #expect(known.reduce(hook(.stop)).qualification == .proceed)

        var unknownThreadKnownTurn = CodexRootTurnReconciler(authority: .hooks)
        _ = unknownThreadKnownTurn.reduce(rootInput(
            fingerprint: "fp",
            turn: "turn"
        ))
        let matchingTurn = unknownThreadKnownTurn.reduce(hook(
            .stop,
            thread: "unlatched-thread",
            turn: "turn"
        ))
        #expect(matchingTurn.qualification == .proceed)
        #expect(matchingTurn.didMutateRootState == false)

        let wrongTurn = unknownThreadKnownTurn.reduce(hook(
            .stop,
            thread: "unlatched-thread",
            turn: "wrong"
        ))
        #expect(wrongTurn.qualification == .rejectEvent)
        #expect(wrongTurn.reason == .missingRootThread)

        var fullyUnknown = CodexRootTurnReconciler(authority: .hooks)
        #expect(fullyUnknown.reduce(hook(
            .stop,
            thread: "unlatched-thread"
        )).reason == .missingRootThread)
        #expect(fullyUnknown.reduce(hook(.stop)).qualification == .proceed)
    }

    @Test
    func fallbackNotifyRequiresExactPendingFingerprintOnlyWhileThreadUnknown() {
        var known = CodexRootTurnReconciler(authority: .sessionLogFallback)
        _ = known.reduce(rootInput(fingerprint: "fp", thread: "thread"))
        let exact = known.reduce(.fallbackNotifyThreadCandidate(
            threadID: "thread",
            inputFingerprint: "irrelevant-after-thread-is-known"
        ))
        #expect(exact.qualification == .proceed)
        #expect(exact.reason == .fallbackNotifyThreadMatched)
        #expect(exact.didMutateRootState == false)
        let mismatch = known.reduce(.fallbackNotifyThreadCandidate(
            threadID: "other-thread",
            inputFingerprint: "fp"
        ))
        #expect(mismatch.qualification == .rejectEvent)
        #expect(mismatch.reason == .threadMismatch)

        var missingRootInput = CodexRootTurnReconciler(authority: .sessionLogFallback)
        #expect(missingRootInput.reduce(.fallbackNotifyThreadCandidate(
            threadID: "thread",
            inputFingerprint: "fp"
        )).reason == .missingRootInputFingerprint)

        var missingNotifyInput = CodexRootTurnReconciler(authority: .sessionLogFallback)
        _ = missingNotifyInput.reduce(rootInput(fingerprint: "fp"))
        #expect(missingNotifyInput.reduce(.fallbackNotifyThreadCandidate(
            threadID: "thread",
            inputFingerprint: nil
        )).reason == .missingNotifyInputFingerprint)

        var fingerprintMismatch = CodexRootTurnReconciler(authority: .sessionLogFallback)
        _ = fingerprintMismatch.reduce(rootInput(fingerprint: "fp"))
        #expect(fingerprintMismatch.reduce(.fallbackNotifyThreadCandidate(
            threadID: "thread",
            inputFingerprint: "other"
        )).reason == .inputFingerprintMismatch)

        var latch = CodexRootTurnReconciler(authority: .sessionLogFallback)
        _ = latch.reduce(rootInput(fingerprint: "fp"))
        let latched = latch.reduce(.fallbackNotifyThreadCandidate(
            threadID: "thread",
            inputFingerprint: "fp"
        ))
        #expect(latched.qualification == .proceed)
        #expect(latched.reason == .fallbackNotifyThreadLatched)
        #expect(latched.didMutateRootState)
        #expect(latched.snapshot.rootThreadID == "thread")
    }

    @Test
    func identicalFingerprintDoesNotAliasDistinctExactTurnIDs() {
        var reconciler = CodexRootTurnReconciler(authority: .hooks)
        _ = reconciler.reduce(rootInput(
            fingerprint: "same",
            thread: "thread",
            turn: "turn-one",
            context: context(policy: .string("on-request"), reviewer: .string("guardian"))
        ))
        let first = reconciler.snapshot

        let second = reconciler.reduce(rootInput(
            fingerprint: "same",
            thread: "thread",
            turn: "turn-two",
            context: context(policy: .string("on-request"), reviewer: .null)
        ))

        #expect(first.rootTurnID == "turn-one")
        #expect(second.snapshot.rootTurnID == "turn-two")
        #expect(second.snapshot.currentApprovalContext == context(
            policy: .string("on-request"),
            reviewer: .null
        ))
        #expect(second.didMutateRootState)
    }

    @Test
    func duplicateObservationsAreStateIdempotentButStillProceed() {
        var reconciler = CodexRootTurnReconciler(authority: .hooks)
        let input = rootInput(
            fingerprint: "fp",
            thread: "thread",
            turn: "turn",
            context: context(policy: .string("on-request"), reviewer: .null)
        )
        _ = reconciler.reduce(input)
        let duplicateInput = reconciler.reduce(input)
        #expect(duplicateInput.qualification == .proceed)
        #expect(duplicateInput.didMutateRootState == false)

        let override = CodexRootTurnObservation.launchLogOverrideContext(context(
            policy: .string("on-request"),
            reviewer: .null
        ))
        _ = reconciler.reduce(override)
        let duplicateOverride = reconciler.reduce(override)
        #expect(duplicateOverride.qualification == .proceed)
        #expect(duplicateOverride.didMutateRootState == false)

        let prompt = hook(
            .userPromptSubmit,
            thread: "thread",
            turn: "turn",
            fingerprint: "fp"
        )
        _ = reconciler.reduce(prompt)
        let duplicatePrompt = reconciler.reduce(prompt)
        #expect(duplicatePrompt.qualification == .proceed)
        #expect(duplicatePrompt.didMutateRootState == false)

        var fallback = CodexRootTurnReconciler(authority: .sessionLogFallback)
        _ = fallback.reduce(rootInput(fingerprint: "fp"))
        _ = fallback.reduce(.fallbackNotifyThreadCandidate(
            threadID: "thread",
            inputFingerprint: "fp"
        ))
        let duplicateNotify = fallback.reduce(.fallbackNotifyThreadCandidate(
            threadID: "thread",
            inputFingerprint: nil
        ))
        #expect(duplicateNotify.qualification == .proceed)
        #expect(duplicateNotify.didMutateRootState == false)
    }

    @Test
    func resultCombinationsStayLegalAcrossProceedingAndRejectedEvents() {
        var hooks = CodexRootTurnReconciler(authority: .hooks)
        let results = [
            hooks.reduce(rootInput(fingerprint: "fp", thread: "thread", turn: "turn")),
            hooks.reduce(hook(.sessionStart(isClear: true), thread: "thread")),
            hooks.reduce(hook(.other, thread: "thread")),
            hooks.reduce(hook(.stop, thread: "other-thread")),
            hooks.reduce(.fallbackNotifyThreadCandidate(threadID: "thread", inputFingerprint: "fp")),
        ]

        var fallback = CodexRootTurnReconciler(authority: .sessionLogFallback)
        let fallbackResults = [
            fallback.reduce(rootInput(fingerprint: "fp")),
            fallback.reduce(.hookSessionIdentity(threadID: "thread", isClear: false)),
            fallback.reduce(hook(.other)),
            fallback.reduce(.fallbackNotifyThreadCandidate(threadID: "thread", inputFingerprint: "fp")),
        ]

        for result in results + fallbackResults {
            assertValid(result)
        }
    }

    @Test
    func unspecifiedOverrideIsAProceedingNoOp() {
        var reconciler = populatedReconciler(authority: .hooks)
        let before = reconciler.snapshot
        let result = reconciler.reduce(.launchLogOverrideContext(context()))

        #expect(result.qualification == .proceed)
        #expect(result.reason == .launchLogOverrideContext)
        #expect(result.didMutateRootState == false)
        #expect(result.snapshot == before)
        assertValid(result)
    }
}

private let allAuthorities: [CodexRootTurnAuthority] = [
    .hooks,
    .sessionLogFallback,
    .legacyPermissive,
]

private func context(
    policy: CodexRootTurnContextField = .unspecified,
    reviewer: CodexRootTurnContextField = .unspecified
) -> CodexRootTurnApprovalContext {
    CodexRootTurnApprovalContext(
        approvalPolicy: policy,
        approvalsReviewer: reviewer
    )
}

private func rootInput(
    fingerprint: String? = nil,
    thread: String? = nil,
    turn: String? = nil,
    context: CodexRootTurnApprovalContext = .init()
) -> CodexRootTurnObservation {
    .launchLogRootInput(
        fingerprint: fingerprint,
        threadID: thread,
        turnID: turn,
        context: context
    )
}

private func hook(
    _ kind: CodexRootTurnHookKind,
    thread: String? = nil,
    turn: String? = nil,
    fingerprint: String? = nil
) -> CodexRootTurnObservation {
    .hook(
        kind: kind,
        threadID: thread,
        turnID: turn,
        promptFingerprint: fingerprint
    )
}

private func expectedField(
    patch: CodexRootTurnContextField,
    inherited: String
) -> CodexRootTurnContextField {
    switch patch {
    case .unspecified:
        return .string(inherited)
    case .null:
        return .null
    case .string(let value):
        return .string(value)
    }
}

private func populatedReconciler(
    authority: CodexRootTurnAuthority
) -> CodexRootTurnReconciler {
    var reconciler = CodexRootTurnReconciler(authority: authority)
    _ = reconciler.reduce(.launchLogOverrideContext(context(
        policy: .string("active-policy"),
        reviewer: .string("active-reviewer")
    )))
    _ = reconciler.reduce(rootInput(
        fingerprint: "fp",
        thread: "thread",
        turn: "turn",
        context: context(policy: .string("turn-policy"), reviewer: .null)
    ))
    return reconciler
}

private func assertValid(
    _ result: CodexRootTurnReduction,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    if result.qualification == .rejectEvent {
        #expect(result.didMutateRootState == false, sourceLocation: sourceLocation)
        #expect(result.shouldResetApprovalHistory == false, sourceLocation: sourceLocation)
    }
    if result.shouldResetApprovalHistory {
        #expect(result.qualification == .proceed, sourceLocation: sourceLocation)
    }
    if result.snapshot.isAwaitingSessionLogContext {
        #expect(result.snapshot.pendingApprovalContext == nil, sourceLocation: sourceLocation)
        #expect(result.snapshot.currentApprovalContext == nil, sourceLocation: sourceLocation)
    }
    if result.snapshot.pendingApprovalContext != nil {
        #expect(result.snapshot.rootTurnID == nil, sourceLocation: sourceLocation)
        #expect(result.snapshot.rootTurnInputFingerprint == nil, sourceLocation: sourceLocation)
        #expect(result.snapshot.currentApprovalContext == nil, sourceLocation: sourceLocation)
    }
}
