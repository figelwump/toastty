import Testing
@testable import CodexReconciliation

struct CodexRootProgressReconciliationTests {
    private let allKinds: [CodexRootProgressRegistryKind] = [
        .none,
        .idle,
        .working,
        .needsApproval,
        .ready,
        .error,
    ]

    @Test
    func hookWorkingUsesFixedAuthorityAndCanOverwriteEveryRegistryKind() {
        for kind in allKinds {
            #expect(evaluate(
                authority: .hooks,
                kind: kind,
                observation: .hookWorking(summary: "Hook summary", detail: "Hook detail")
            ) == .projectWorking(summary: "Hook summary", detail: "Hook detail"))

            #expect(evaluate(
                authority: .sessionLogFallback,
                kind: kind,
                observation: .hookWorking(summary: "Hook summary", detail: "Hook detail")
            ) == .ignored(.incompatibleWithAuthority))
        }
    }

    @Test
    func sessionLogWorkingUsesFixedAuthorityAndCanOverwriteEveryRegistryKind() {
        for kind in allKinds {
            #expect(evaluate(
                authority: .sessionLogFallback,
                kind: kind,
                observation: .sessionLogWorking(detail: "Turn started")
            ) == .projectWorking(summary: "Working", detail: "Turn started"))

            #expect(evaluate(
                authority: .hooks,
                kind: kind,
                observation: .sessionLogWorking(detail: "Turn started")
            ) == .ignored(.incompatibleWithAuthority))
        }
    }

    @Test
    func turnAbortedOnlyIdlesEligibleFallbackStates() {
        for kind in allKinds {
            let expected: CodexRootProgressDecision
            switch kind {
            case .working, .needsApproval:
                expected = .projectIdle(detail: "Aborted detail")
            case .none, .idle, .ready, .error:
                expected = .ignored(.currentRegistryKindDoesNotPermitTransition)
            }

            #expect(evaluate(
                authority: .sessionLogFallback,
                kind: kind,
                observation: .sessionLogTurnAborted(detail: "Aborted detail")
            ) == expected)

            #expect(evaluate(
                authority: .hooks,
                kind: kind,
                observation: .sessionLogTurnAborted(detail: "Aborted detail")
            ) == .ignored(.incompatibleWithAuthority))
        }
    }

    @Test
    func visibleTextOnlyRefinesWorkingRegardlessOfAuthority() {
        for authority in [CodexRootProgressAuthority.hooks, .sessionLogFallback] {
            for kind in allKinds {
                let expected: CodexRootProgressDecision
                switch kind {
                case .working:
                    expected = .projectWorking(summary: "Working", detail: "Reading a file")
                case .none, .idle, .needsApproval, .ready, .error:
                    expected = .ignored(.currentRegistryKindDoesNotPermitTransition)
                }

                #expect(evaluate(
                    authority: authority,
                    kind: kind,
                    observation: .visibleTextWorking(detail: "Reading a file")
                ) == expected)
            }
        }
    }

    @Test
    func escapeOnlyIdlesEligibleHookStates() {
        for kind in allKinds {
            let hookExpected: CodexRootProgressDecision
            switch kind {
            case .working, .needsApproval:
                hookExpected = .projectIdle(detail: "Ready for prompt")
            case .none, .idle, .ready, .error:
                hookExpected = .ignored(.currentRegistryKindDoesNotPermitTransition)
            }

            #expect(evaluate(
                authority: .hooks,
                kind: kind,
                observation: .localInterrupt(.escape)
            ) == hookExpected)

            #expect(evaluate(
                authority: .sessionLogFallback,
                kind: kind,
                observation: .localInterrupt(.escape)
            ) == fallbackEscapeExpected(for: kind))
        }
    }

    @Test
    func controlCIdlesEligibleStatesForBothAuthorities() {
        for authority in [CodexRootProgressAuthority.hooks, .sessionLogFallback] {
            for kind in allKinds {
                let expected: CodexRootProgressDecision
                switch kind {
                case .working, .needsApproval:
                    expected = .projectIdle(detail: "Ready for prompt")
                case .none, .idle, .ready, .error:
                    expected = .ignored(.currentRegistryKindDoesNotPermitTransition)
                }

                #expect(evaluate(
                    authority: authority,
                    kind: kind,
                    observation: .localInterrupt(.controlC)
                ) == expected)
            }
        }
    }

    @Test
    func projectionPreservesExactSuppliedSummaryAndDetails() {
        #expect(evaluate(
            authority: .hooks,
            kind: .error,
            observation: .hookWorking(summary: "  custom summary  ", detail: "  custom detail  ")
        ) == .projectWorking(summary: "  custom summary  ", detail: "  custom detail  "))

        #expect(evaluate(
            authority: .sessionLogFallback,
            kind: .none,
            observation: .sessionLogWorking(detail: nil)
        ) == .projectWorking(summary: "Working", detail: nil))

        #expect(evaluate(
            authority: .sessionLogFallback,
            kind: .needsApproval,
            observation: .sessionLogTurnAborted(detail: "  exact abort  ")
        ) == .projectIdle(detail: "  exact abort  "))

        #expect(evaluate(
            authority: .hooks,
            kind: .working,
            observation: .visibleTextWorking(detail: "  exact visible text  ")
        ) == .projectWorking(summary: "Working", detail: "  exact visible text  "))
    }

    @Test
    func evaluationIsDeterministicAndHasNoHiddenState() {
        let observations: [CodexRootProgressObservation] = [
            .hookWorking(summary: "Working", detail: "Prompt submitted"),
            .sessionLogWorking(detail: "Turn started"),
            .sessionLogTurnAborted(detail: "Ready for prompt"),
            .visibleTextWorking(detail: "Running tests"),
            .localInterrupt(.escape),
            .localInterrupt(.controlC),
        ]

        for authority in [CodexRootProgressAuthority.hooks, .sessionLogFallback] {
            for kind in allKinds {
                for observation in observations {
                    let first = evaluate(
                        authority: authority,
                        kind: kind,
                        observation: observation
                    )
                    let second = evaluate(
                        authority: authority,
                        kind: kind,
                        observation: observation
                    )
                    #expect(first == second)
                }
            }
        }
    }

    @Test
    func decisionSurfaceOnlyProjectsWorkingOrIdle() {
        let decisions: [CodexRootProgressDecision] = [
            .projectWorking(summary: "Working", detail: nil),
            .projectIdle(detail: nil),
            .ignored(.incompatibleWithAuthority),
            .ignored(.currentRegistryKindDoesNotPermitTransition),
            .ignored(.fallbackEscapeSuppressed),
        ]

        #expect(decisions.compactMap(projectedKind) == [.working, .idle])
    }

    private func evaluate(
        authority: CodexRootProgressAuthority,
        kind: CodexRootProgressRegistryKind,
        observation: CodexRootProgressObservation
    ) -> CodexRootProgressDecision {
        CodexRootProgressEvaluator.evaluate(
            authority: authority,
            currentRegistryKind: kind,
            observation: observation
        )
    }

    private func fallbackEscapeExpected(
        for kind: CodexRootProgressRegistryKind
    ) -> CodexRootProgressDecision {
        switch kind {
        case .working, .needsApproval:
            return .ignored(.fallbackEscapeSuppressed)
        case .none, .idle, .ready, .error:
            return .ignored(.currentRegistryKindDoesNotPermitTransition)
        }
    }

    /// This exhaustive switch is a compile-time guard: adding an approval,
    /// ready, error, or notification decision requires changing this test.
    private func projectedKind(
        _ decision: CodexRootProgressDecision
    ) -> CodexRootProgressRegistryKind? {
        switch decision {
        case .projectWorking:
            return .working
        case .projectIdle:
            return .idle
        case .ignored:
            return nil
        }
    }
}
