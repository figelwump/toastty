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

Network transport, file I/O, fixture creation, JSON serialization, SwiftUI rendering, transcript layout, scrolling, and physical-device behavior are outside this test's scope. Device rendering and scroll-position performance require separate simulator UI and physical-device validation.

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

During the September 2026 CI investigation, one GitHub Release run measured
1.0715 seconds while another run of the same commit passed. The failing test
took 3.492 seconds overall, including fixture preparation outside the measured
operation. The benchmark's event decoding and reduction path was unchanged from
the task baseline, so this did not establish a performance regression.

A targeted remote iOS Simulator check of `910abfe8` plus test/build fixes ran the
unchanged Release benchmark three times, relaunching the test process for each
iteration. It measured 0.0771, 0.0782, and 0.0780 seconds, with 31,588,352 bytes
of incremental resident memory in each iteration. Evidence is retained under
`artifacts/remote-tests/ios-ci-performance-repeat/`. The one-second and 100 MiB
budgets remain unchanged; these simulator measurements do not establish timing
on every GitHub runner or physical device.

```bash
sv exec -- scripts/remote/test.sh --platform ios --scope working-tree \
  --run-label ios-ci-performance-repeat -- \
  -configuration Release ENABLE_TESTABILITY=YES \
  -only-testing:ToasttyMobileDomainTests/ConversationRuntimePerformanceTests \
  -test-iterations 3 -test-repetition-relaunch-enabled YES
```

This command builds and tests a disposable remote checkout and simulator. It
does not connect to a production host or run a local simulator.

## Transcript preparation

`LiveConversationController` shares immutable rows, Markdown blocks, and turns across connection and send-delivery metadata updates. A regression test applies these updates to 5,000 events and verifies that the prepared transcript is reused; an appended event requires new preparation. Long messages are parsed as one Markdown document before attributed blocks are split for layout, preserving code fences and reference links across cells. Markdown tables retain their header, row, column alignment, and inline attributes from Foundation’s parser. Wide tables scroll horizontally; long tables split only between rows and repeat their header, with at most 24 body rows per table section. A single oversized row stays intact even when it exceeds the soft chunk budget. Foundation omits entirely empty trailing table rows, so those rows cannot be reconstructed from attributed content.

The fixture UI readiness measurement starts before opening the conversation and ends when the 5,000-row readiness marker appears. It includes fixture navigation and presentation preparation, but does not measure frame timing, sustained streaming, or peak memory. Conversation history remains in memory for the open runtime; these changes do not impose a retention limit or establish a physical-device performance budget.

`LiveConversationControllerTests.testSustainedSmallAppendsPreserveAllRowsAndReportPreparationTime` starts with 5,000 events, then applies 200 updates of five events each. It verifies that all 6,000 rows remain ordered and records elapsed time, including fixture-state construction and main-actor preparation. This measurement excludes SwiftUI rendering and network transport and has no calibrated timing threshold yet.

A remote Debug run on 2026-09-05 recorded 1.9807 seconds for those 200 updates in `artifacts/remote-tests/ios-audit-final-debug/`, with the timing attachment exported under `artifacts/reviews/ios-audit-append-measurement/`. This is one simulator observation, not a physical-device frame-time guarantee.


## Transcript send scrolling

Submitting acquires the transcript’s bottom immediately without animation, including when the user was reading older messages. SwiftUI’s size-change anchor then keeps that bottom fixed through keyboard dismissal, composer collapse, and appended content. Bottom detection excludes the keyboard, composer, and navigation insets from the usable viewport. A direct user drag cancels following so older history remains readable. Initial positioning and history restoration still use the existing layout-settling coordinator.

The opt-in Debug fixture environment value `TOASTTY_MOBILE_FIXTURE_SCROLL_TRACE=1` exposes coherent scroll geometry samples to UI tests. Send regression tests inspect every recorded geometry change after reaching the bottom, rather than comparing accessibility frames captured at different points during a keyboard animation. This is simulator layout evidence; it does not measure physical-device frame timing.
