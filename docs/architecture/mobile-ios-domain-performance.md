# Mobile iOS Domain Performance

## Status

The native domain performance budget is provisional until it has repeatable evidence from the remote iOS Simulator used by Toastty's agent-driven test workflow. Budget changes require recorded target, toolchain, and measurement evidence; a noisy or isolated run is not sufficient justification by itself.

## Budget

`ios/Tests/ToasttyMobileDomainTests/Performance/ConversationRuntimePerformanceTests.swift` enforces these initial budgets for one 5,000-event snapshot:

- Decode and reduce elapsed time: at most 1 second.
- Incremental resident memory: at most 100 × 1,024 × 1,024 bytes.

The fixture is generated deterministically in memory as a canonical, sorted-key REST events-response envelope. It has fixed conversation and projection identifiers, contiguous sequences 1 through 5,000, fixed timestamps, compact assistant-message payloads, and one unknown optional event at sequence 2,501. The unknown event verifies that the compatibility decoder and runtime still advance the cursor through forward-compatible input while retaining only the 4,999 renderable events.

## Measurement scope

Fixture construction and JSON serialization happen before measurement. The measured operation includes:

1. `GatewayCompatibilityDecoder.decodeEventsResponse(_:)` parsing and tolerant event decoding.
2. `ConversationRuntime.beginCatchUp(connectionGeneration:)`.
3. `ConversationRuntime.applyREST(_:connectionGeneration:)` reducing the full page.
4. `ConversationRuntime.finishCatchUp(connectionGeneration:)` and final state retrieval.

Elapsed time uses `ContinuousClock`, so wall-clock adjustments cannot affect the result. Resident memory uses `task_info` with `MACH_TASK_BASIC_INFO` and subtracts the current process resident size sampled immediately before decoding from the size sampled after final state retrieval. If the process resident size falls, the incremental value is clamped to zero to avoid unsigned underflow.

This memory value is net incremental resident memory, not peak memory. It includes allocations still resident in the XCTest process at the end of the measured operation and can be influenced by allocator reuse or unrelated test-runner activity. Together with simulator load affecting elapsed time, that makes these thresholds regression tripwires rather than portable product guarantees.

Network transport, file I/O, fixture creation, JSON serialization, SwiftUI rendering, transcript layout, scrolling, and physical-device behavior are outside this test's scope. Device rendering and scroll-position performance remain separate Phase 3 validation.

## Reference evidence

Run this test through the repository's remote iOS path, not a local simulator. The first recorded gate passed on 2026-08-11; later calibration runs should keep the input and measurement boundaries stable.

| Evidence | Recorded value |
| --- | --- |
| Git revision | `43b65c70` plus the working-tree domain runtime changes measured by this test |
| Remote host hardware | `toastty-mini`, Mac mini (Mac16,10), Apple M4 (10 cores), 16 GB |
| iOS Simulator device | iPhone 16e, arm64, identifier `F57E8A8D-C669-4BF9-8A26-C680D0DFA168` |
| iOS runtime / SDK | iOS Simulator 26.3.1 (23D8133); iPhoneSimulator 26.2 SDK |
| Xcode / Swift version | Xcode 26.3 (17C529); Apple Swift 6.2.4 |
| Elapsed time | 0.115550542 seconds |
| Incremental resident memory | 27,099,136 bytes |
| Result / artifact path | `artifacts/remote-tests/phase1-domain-performance-1/` (`result.json` pass; xcresult 1/1) |

The hardware and toolchain records were captured separately through the required remote-only validation path at `artifacts/remote-gui/phase1-domain-performance-hardware/` and `artifacts/remote-gui/phase1-domain-toolchain/`; both report remote execution with no local fallback. No local simulator or GUI validation was used.

Use repeated clean remote runs when calibrating this provisional gate. Keep the input and measurement boundaries stable so later results remain comparable.
