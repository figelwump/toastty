# Agent Session Reconciliation Contract

Status: implementation gate

Initial provider: Codex

Scope: managed-session identity, provider observations, status, approval/completion, and subagent reconciliation

## Purpose

Toastty currently receives related Codex facts through hooks, notify callbacks, a launch-scoped TUI recording, a canonical rollout file, and native-session discovery. The sources are associated with the right Toastty managed session, but source authority and cross-source correlation are spread across `ManagedAgentLaunchPlanner`, `SessionRuntimeStore`, and the log parser. This contract defines the boundary that must exist before those paths are migrated.

The goal is one deterministic owner for provider-specific reconciliation policy. It must:

- preserve the existing exact managed-session association;
- reject ambiguous native-session ownership rather than guessing;
- distinguish exact identifiers from non-unique bridges and unjoinable observations;
- decide state changes and effect intents without performing AppKit, filesystem, timer, focus, or notification work;
- allow one fact class at a time to migrate and roll back;
- bound all retained correlation and deduplication state.

This is not a request to replace `SessionRegistry`, create a generic event bus, or unify every agent provider.

## Current ingress and association

`ManagedAgentLaunchPlanner` creates a new managed session ID, starts its `SessionRecord`, and injects the managed session and panel into the launched process (`Sources/App/Agents/ManagedAgentLaunchPlanner.swift:103-167`). All current observation paths derive association from that launch context; none may fall back to cwd-only association.

| Source | Managed-session association | Fields retained today | Ordering and replay | Current use |
| --- | --- | --- | --- | --- |
| Codex hook callback | `TOASTTY_SESSION_ID` and `TOASTTY_PANEL_ID` inherited by the provider; the CLI forwards both and the socket resolves the active session/panel before applying the event (`Sources/CLIKit/ToasttyCLI.swift:269-319`, `Sources/App/Automation/AutomationSocketServer.swift:1923-1941`) | hook event name, source, permission mode, native/thread ID, turn ID, prompt fingerprint, derived status, transcript path, cwd, subagent ID/type, and spawn tool-use ID plus bounded task/message metadata (`Sources/Core/Agents/CodexHookEvent.swift:19-61`) | Separate hook invocations reach the socket independently. There is no source sequence or provider timestamp in the normalized event, so arrival order is not a provider ordering guarantee. No replay. | When hooks were installed at launch, hooks own progress, approval, and completion. |
| Codex notify callback | Same inherited managed session/panel, through the launch-specific notify forwarder | completion type, thread ID, turn ID, last-input fingerprint, input count, bounded detail (`Sources/Core/Agents/CodexNotifyCompletion.swift:4-27`) | Callback arrival order only; no timestamp or sequence; no replay. Notify is only injected for session-log fallback launches (`Sources/App/Agents/AgentLaunchInstrumentation.swift:194-238`). | Completion fallback when hooks were unavailable at launch. |
| Launch-scoped TUI recording | A unique file is created for the managed launch; the watcher closure captures its managed session ID (`Sources/App/Agents/ManagedAgentLaunchPlanner.swift:386-431`) | session-configured native ID/path; root fingerprint/thread/turn; approval policy/reviewer; approval, completion, abort; collaboration call/agent/path IDs | JSONL file order within one watcher. A watcher starts at byte zero, retains in-memory dedupe keys, resets to zero after truncation, and drains once on cancellation (`Sources/App/Agents/CodexSessionLogWatcher.swift:248-443`). It therefore replays the file after a watcher restart. | Identity and turn context in both modes; status/approval/completion in fallback mode; background activity in both modes. |
| Canonical rollout watcher | Attaches only after a fresh `ManagedAgentResumeRecord` has identified a rollout path. Its closure captures managed session ID and verifies that the path is still the registered path (`Sources/App/Agents/ManagedAgentLaunchPlanner.swift:814-849`). | The same parser can decode all event kinds, including collaboration call IDs and agent IDs. | Starts at byte zero. Collaboration entries older than the managed session start are filtered; other parser state and dedupe are watcher-local. | **The canonical watcher currently forwards only background-activity start/finish.** It does not currently feed turn, approval, completion, or identity observations to runtime reconciliation. |
| Native-session observer | Starts with managed session ID, panel ID, agent, cwd, launch time, and an expected native ID for resume-shaped commands. Codex candidates must come from a shell snapshot containing the same managed session and panel, then match canonical session metadata (`Sources/App/Agents/ManagedAgentNativeSessionObserver.swift:103-179`, `Sources/App/Agents/ManagedAgentNativeSessionObserver.swift:546-624`, `Sources/App/Agents/ManagedAgentNativeSessionObserver.swift:685-722`). | provider, native session ID, canonical file path, cwd, update time | Polls current filesystem state; no provider event order. Multiple candidates or one candidate matching multiple observers fail closed. The observation expires after a bounded window. | Identity/path fallback and resume confirmation. There is deliberately no cwd-only Codex claim. |

### Current authority selection

Hook availability is checked once while the launch plan is built. The session is recorded as either `.hooks` or `.sessionLogFallback` (`Sources/App/Agents/ManagedAgentLaunchPlanner.swift:337-342`, `Sources/App/Agents/ManagedAgentLaunchPlanner.swift:908-917`). `SessionRuntimeStore` then rejects the other status source for the lifetime of that managed session (`Sources/App/Sessions/SessionRuntimeStore.swift:2549-2570`).

The launch log still contributes native identity and turn approval context in hook mode, and rollout parsing still enriches subagent metadata. However, **there is no dynamic delivery failover if hooks were installed at launch but later stop delivering**. The existence of the log watcher does not change that authority decision.

## Join classification

Every normalized field used for correlation must be classified. A bridge may narrow candidates but cannot establish identity, deduplicate an effect, or override an exact claim by itself.

### Exact keys

| Key | Valid scope and use |
| --- | --- |
| managed session ID + validated panel at ingress | Exact association of a live callback with the active managed session. Panel validation is a transport safety check, not part of immutable agent identity. |
| provider + native thread/session ID | Exact provider identity claim, subject to the cross-session uniqueness rule below. |
| native thread ID + turn ID | Exact root-turn correlation when both sources supply both fields. A turn ID without provider identity is scoped to one already-associated managed session. |
| approval ID / provider call ID / tool-use ID | Exact operation correlation only after the parser and transport preserve the same provider identifier from every participating source. |
| spawn call/tool-use ID | Exact hook spawn metadata to rollout function-call/event correlation when the values match. |
| provider subagent/agent ID | Exact lifecycle identity after a spawn result or lifecycle event establishes it. |
| canonical rollout path from an accepted identity claim | Exact file attachment for that claim generation; a path alone does not establish ownership. |

### Bridge keys

| Key | Permitted use |
| --- | --- |
| prompt fingerprint | A non-unique bridge within one managed session and a bounded active-turn window. Repeated prompts can produce the same fingerprint. It may corroborate a thread/turn claim, but must not establish provider identity, approval identity, or cross-session ownership. |
| thread-only completion | May complete the current root turn only when that thread is already the accepted native identity and there is exactly one compatible open turn. It is not sufficient to choose among turns. |
| event time | Staleness and replay cutoff only. It must never order observations from different clocks or override ingest order. |

### Unjoinable or heuristic observations

- Multiple approval requests without a preserved approval/call ID are distinct but cannot be reliably correlated across hook and log sources.
- An unidentified `Stop` or `task_complete` is session-scoped and cannot prove which turn or operation it closes.
- Generic progress is a source-local latest-arrival projection, not a cross-source entity.
- Reviewer inference from textual/substr matching is context evidence, not identity.
- rollout `NEW_TASK`/`FINAL_ANSWER` text and parent/child path inference are fallback lifecycle evidence, not exact cross-source keys.

`CodexSessionLogWatcher` currently reads `call_id`/`approval_id` while constructing a source-local dedupe identifier, but drops that identifier from `CodexSessionLogEvent` (`Sources/App/Agents/CodexSessionLogWatcher.swift:63-137`, `Sources/App/Agents/CodexSessionLogWatcher.swift:1036-1047`, `Sources/App/Agents/CodexSessionLogWatcher.swift:1294-1305`). `CodexHookEventParser` preserves `tool_use_id` only for spawn metadata (`Sources/CLIKit/CodexHookEventParser.swift:49-78`). **Approval/call IDs must be added to the normalized models and transported end-to-end before cross-source approval deduplication or dynamic approval failover is enabled.** Prompt fingerprints are not an acceptable substitute.

## Target boundary

Add a provider-specific pure module, provisionally `AgentReconciliation`, with its own tests. `ToasttyApp` depends on it; it may depend on `CoreState`; it must not import AppKit, SwiftUI, filesystem APIs, notification APIs, or app-owned stores.

The module contains:

- a Codex-specific `CodexObservation` enum with typed source and provenance;
- a `CodexReconciliationState` keyed by immutable managed identity;
- a pure `CodexObservationReducer` that returns state plus decisions;
- a `NativeIdentityIndex` that enforces provider/native-session uniqueness across active managed sessions;
- typed decisions for identity/path claims, status, background activity, resume discovery, notification intent, ignored/conflicting observations, and diagnostics.

It is explicitly not a generic event bus. Other providers may adopt their own reconciler later only if their evidence model warrants it.

### Identity and ownership

Immutable reconciliation identity consists of:

- Toastty managed session ID;
- provider/agent kind;
- a launch generation created when that managed session starts.

Discovered claims attach native provider session ID and canonical rollout path, each with provenance. Panel ID, window ID, workspace ID, and panel-to-session binding are mutable App ownership and are not part of immutable identity. Moving or closing a panel must not silently produce a different provider identity.

### Observation envelope

Every observation entering the reducer has:

- managed identity and provider;
- observation source;
- App-assigned monotonically increasing ingest sequence;
- App receive time;
- optional provider event time, used only for staleness;
- provider-specific payload with preserved native, turn, approval/call/tool, and subagent identifiers where available;
- replay phase: `.live` or `.bootstrap`.

The App assigns ingest sequence at one ingestion point before asynchronous handling can reorder observations. The reducer uses this sequence for deterministic same-process order. Provider time never wins an ordering dispute.

### Effects boundary

The pure module may emit intent, not effects. `SessionRuntimeStore` or a smaller App coordinator remains responsible for:

- applying mutations to `SessionRegistry` and `AppStore`;
- starting, cancelling, and expiring approval/reaper timers;
- reading visible terminal text;
- checking application focus and panel visibility;
- suppressing or delivering desktop notifications;
- attaching/stopping filesystem watchers;
- structured logging and debug capture.

Timers return a tokenized observation to the reducer. A cancelled or superseded token is a no-op. Notification intent is emitted only for live observations; bootstrap replay must not produce desktop notifications.

### Bounded state

There must be no session-lifetime-growing array or set. Initial bounds are:

- current active turn plus one immediately previous terminal turn;
- an LRU of at most 256 exact observation/dedup keys per managed session;
- at most 128 active/recent subagent correlations per managed session, evicting terminal entries before active entries;
- at most 32 recent auto-review/approval tombstones per managed session;
- immediate removal of all reducer state and pending App effects when a managed session stops.

Tests must demonstrate bounded size after a stream substantially larger than every limit. If real traces show these limits can evict live correlations, stop migration and revise the model rather than silently raising them.

## Fact authority and conflict policy

Authority is per fact, not a global “hooks always win” flag.

| Fact | Preferred authority | Fallback | Conflict / duplicate behavior |
| --- | --- | --- | --- |
| managed-session association | App launch context and socket active-session/panel validation | none | Reject an event not associated with the active generation. Never infer association from cwd, prompt, path, or time. |
| native provider identity | expected resume ID corroborated by hook/session-configured/snapshot evidence; otherwise exact hook or launch-log `session_configured` claim | shell snapshot + matching session metadata | Same-owner repeats are idempotent. A different active owner is rejected and diagnosed. An ambiguous scan makes no claim. |
| canonical rollout path | path resolved as part of an accepted native claim and validated for expected cwd/provider metadata | later exact claim for the same native owner | A new path may replace an older path for the same owner/generation. A path naming a different native ID is a conflict, not a rename. |
| root turn identity/start | exact native thread + turn from hook or log; launch log supplies turn context | prompt fingerprint bridge only within the current managed session | Exact mismatches are diagnosed. A bridge cannot replace an exact active turn. Duplicate starts merge provenance. |
| approval policy/reviewer | structured launch-log turn context | hook permission mode as partial evidence | Preserve `unspecified`, explicit `null`, and value. Heuristic reviewer parsing cannot override structured context. |
| working/progress status | hooks while matching hook observations are delivered | launch log for a turn that has no matching hook after the fact-specific grace rule | Generic progress is latest-by-ingest only within the selected source epoch. It cannot switch source authority by itself. |
| approval request | exact hook request with approval/call ID and resolved policy/reviewer context | exact log request with the same ID after bounded hook grace; source-local fallback if only one source is enabled | Matching IDs dedupe. Different IDs are different approvals even in the same turn. Without preserved IDs, do not cross-source dedupe or dynamically promote the log event. Auto-reviewed requests update a tombstone but do not show approval UI/notification. |
| completion/abort | exact hook turn completion/abort | exact log/notify completion after bounded hook grace; thread-only completion only for one unambiguous open turn | One terminal decision per turn. Later duplicates only add provenance. An unidentified terminal event cannot close a newer exact turn. |
| subagent spawn metadata | hook `spawnToolUseID` metadata | rollout function-call arguments with the same call ID | Exact call ID merges metadata. Prompt/message text never joins agents. Ciphertext-like labels remain suppressed. |
| subagent lifecycle | canonical rollout provider agent ID and lifecycle entries | hook subagent ID; text/path inference only as source-local fallback | Exact agent ID owns lifecycle. Finish-before-start creates a bounded tombstone so replay cannot resurrect the activity. |
| background activity projection | reconciled subagent/tool decisions | current source-local activity fallback | Stable provider ID is the activity ID. Replays rebuild active activities but do not notify. |
| notification intent | reducer terminal/approval decision for a live observation | none | App focus/visibility policy decides delivery. Duplicate observations cannot create duplicate intent. |

### Dynamic fallback rule

Do not declare a source unhealthy merely because no event arrived. Dynamic failover is event-specific:

1. A fallback source produces an observation containing an exact key for an open fact.
2. If the preferred-source observation with that key has not arrived, the App schedules a bounded grace token appropriate to that fact.
3. A matching preferred observation cancels the token and reconciles as a duplicate.
4. Expiry re-enters the reducer with the same key; the reducer may accept the fallback fact.
5. Later preferred duplicates add provenance but do not repeat state or effects.

Generic progress and unidentified terminal events cannot satisfy this rule. Delivery-failure telemetry may improve diagnostics, but is not itself permission to associate or apply an ambiguous event. Grace durations remain App configuration and require trace-backed tests; they are not part of the pure policy.

## Cross-session native claims

The identity index key is `(provider, normalized native session ID)`.

- No owner: accept an exact claim and bind it to the active managed generation.
- Same owner and generation: merge stronger provenance/path information idempotently.
- Different active managed owner: reject the new claim, retain the existing owner, emit a structured conflict, and do not prune or rewrite either panel's resume record.
- Previous owner inactive: an expected-ID resume launch may reclaim the identity after the App verifies the previous managed session is inactive. A fresh claim is recorded for the new generation before the old persisted panel projection is changed.
- Same candidate observed simultaneously for multiple unmanaged observers: fail all ambiguous claims, matching current observer behavior.
- Expected-ID evidence never steals from a live same-provider owner.

First arrival must not be used to break a simultaneously known ambiguity. Panel closure/move changes the App projection; it does not mutate the identity key. The App may clear or move a persisted resume record only after the identity decision is accepted.

## Launch, resume, and restore

### New managed launch

- Create a new managed ID/generation and initial idle status.
- Start hook/notify forwarding and the launch-scoped log watcher with that exact managed association.
- Start native observation when launch cwd is available; accept a Codex claim only when the scan later supplies matching snapshot evidence. Cwd remains validation, never association.
- Treat observations as live after the managed session has started.

### Resume-shaped launch

- Create a new managed ID/generation even though the native provider ID is known from argv.
- Store the native ID as an expected claim, not an accepted owner, until hook, `session_configured`, or matching snapshot/session metadata corroborates it.
- Refuse the claim while another active same-provider managed session owns that native ID.

### Workspace restore / watcher attachment

- Runtime reconciliation state is not restored from the previous app process.
- A persisted panel resume record supplies an expected native ID/path, but a fresh capture for the current managed generation is required before canonical attachment. The existing `capturedAt >= startedAt` safeguard remains (`Sources/App/Agents/ManagedAgentLaunchPlanner.swift:747-765`).
- Canonical rollout replay starts at zero to reconstruct current collaboration state. Entries older than the managed-session start are stale for collaboration lifecycle.
- During `.bootstrap`, identity/context and active collaboration may be reconstructed, but approval/completion notification effects are suppressed and old terminal status is not replayed onto the new live session.
- After bootstrap reaches the watcher tail, subsequent observations are `.live`.

Persisting reducer watermarks or correlation state is deferred. Add persistence only if a tested restore scenario cannot be handled by bootstrap replay plus a fresh claim.

## Incremental migration

Each step is independently revertible. Never let the legacy handler and the new reducer both mutate the same fact.

1. **Preserve identifiers and characterize behavior.** Add approval/call IDs to hook, notify/log observation models and CLI/socket transport. Split parsing from file polling enough to test normalized observations. Add sequence-based characterization tests for the current behavior.
2. **Introduce the pure target in shadow mode.** Add `AgentReconciliation` and reducer tests. Feed copies of observations to it, record sanitized old/new decision divergence, and keep legacy code as the only writer.
3. **Migrate identity and rollout claims.** Make the identity index the sole decision maker for native ownership; App code continues applying accepted resume-record mutations and watcher attachment.
4. **Migrate subagent correlation.** Move call/tool-use/agent-ID joins, finish tombstones, and bounded state into the reducer. Keep watcher lifecycle in the App.
5. **Migrate status and background projection.** Move root-turn identity and progress decisions. Preserve current fixed source behavior first; enable per-event fallback only for fact shapes proven to share exact keys.
6. **Migrate approval, completion, and notification intent last.** Enable cross-source dedupe/fallback only after identifier capture experiments pass. App-owned timers and notification suppression consume reducer intents.
7. **Delete legacy reconciliation.** Remove old per-session notify state, approval deferral maps, auto-review arrays, duplicate source gates, subagent correlation maps, and temporary routing flags after every fact class has one owner.

### Shadow and rollback strategy

- Use a temporary per-fact routing enum (`legacy`, `shadow`, `reconciler`) rather than one global feature flag.
- Shadow mode compares normalized decisions and bounded state summaries, never user content.
- Promotion changes exactly one fact class to `reconciler`; the legacy path may still compute for comparison but must not mutate or emit effects.
- A fact can return to `legacy` without changing stored data schemas. Remove its flag after it passes targeted tests, the full gate, and live scenarios.
- Do not carry both implementations indefinitely. Cleanup is part of each fact-class migration, with a final sweep for shared obsolete state.

## Sanitized fixture capture

A debug-only capture harness may write normalized observation sequences under ignored `artifacts/`. It must operate after parsing and before reconciliation.

- Replace managed, native, turn, approval/call/tool, and agent IDs with stable per-fixture tokens.
- Remove prompt text, assistant output, commands, file paths, cwd, repo names, environment values, and raw provider payloads.
- Retain source, event kind, identifier presence/equality relationships, ingest order, relative timing, replay phase, and structured policy enum values.
- Commit only minimal hand-reviewed fixtures needed for regression tests. Never commit raw rollout or hook payloads.
- Include a test proving the sanitizer removes representative paths, commands, prompt strings, and UUID-like original IDs.

## Affected files and intended responsibilities

| Path | Intended change |
| --- | --- |
| `Project.swift` | Add the pure reconciliation target and tests; keep generated Xcode projects untouched. |
| `Sources/AgentReconciliation/` | New Codex observation, state, reducer, identity index, and decisions. |
| `Tests/AgentReconciliation/` | Sequence, conflict, fallback, replay, and bounds tests. |
| `Sources/Core/Agents/CodexHookEvent.swift` | Preserve operation/approval/call IDs at the transport boundary; no provider reconciliation policy. |
| `Sources/Core/Agents/CodexNotifyCompletion.swift` | Preserve any stable completion operation ID exposed by notify. |
| `Sources/CLIKit/CodexHookEventParser.swift` and `Sources/CLIKit/CodexNotifyEventParser.swift` | Decode identifiers without choosing authority. |
| `Sources/CLIKit/ToasttyCLI.swift` and `Sources/App/Automation/AutomationSocketServer.swift` | Transport and validate normalized fields; assign no provider policy. |
| `Sources/App/Agents/CodexSessionLogWatcher.swift` | Separate pure decoding from polling; emit preserved IDs and replay phase. |
| `Sources/App/Agents/ManagedAgentNativeSessionObserver.swift` | Supply exact claim evidence; keep scanning/polling in the App. |
| `Sources/App/Agents/ManagedAgentLaunchPlanner.swift` | Orchestrate ingress, watcher attachment, and accepted identity application. |
| `Sources/App/Sessions/SessionRuntimeStore.swift` | Ingest sequencing, apply reducer decisions, own timers/focus/notifications, and delete legacy Codex policy as facts migrate. |
| `Tests/App/SessionRuntimeStoreTests.swift` and focused successor suites | Characterize App effects and validate integration without re-testing the pure reducer exhaustively. |

## Verification contract

### Pure reducer tests

- duplicate and reordered exact observations;
- hook/log disagreement on native, thread, turn, and operation IDs;
- two active managed sessions claiming one native session;
- stale-owner reclaim versus live-owner refusal;
- repeated identical prompts proving fingerprints do not dedupe distinct turns/approvals;
- two approvals in one turn with different approval IDs;
- fallback exact event, preferred event within grace, grace expiry, and late preferred duplicate;
- approval followed by completion, abort, timeout, and cancelled timer token;
- subagent spawn hook metadata joined to rollout call and provider agent ID;
- finish-before-start and replay without resurrection;
- bootstrap suppression of notification intent;
- long synthetic streams proving every state bound.

### Parser and transport tests

- hook and log approval/call IDs survive parser -> CLI envelope -> socket decoding;
- missing/malformed optional IDs do not make an otherwise valid event fail;
- exact session/panel validation rejects stale or cross-panel callbacks;
- event times never influence ingest ordering;
- canonical watcher still ignores non-background mutations until the relevant fact migration deliberately changes it.

### App integration tests

- one writer per migrated fact;
- timers cancel on matching events, session stop, and generation replacement;
- identity decisions update resume records without duplicate pruning damage;
- watcher replacement cannot deliver from the old path;
- focus/visibility suppresses desktop delivery without changing reducer status decisions;
- bootstrap replay reconstructs active subagents and sends no old notifications;
- process-watch and non-Codex managed sessions remain unchanged.

### Live validation

- fresh Codex launch with hooks installed;
- forced session-log fallback launch;
- hooks installed but one exactly joinable hook withheld, demonstrating per-event fallback;
- approve, deny, auto-review, timeout, completion, and abort;
- two approvals during one turn;
- subagent start/finish from different sources;
- resume, app relaunch, and workspace restore;
- panel move/close while an approval timer is pending;
- conflicting native-session claim from a second active panel;
- session stop while watchers and timers are active.

Use the repository `toastty-verify` workflow at each implementation phase boundary, including Tuist regeneration, targeted tests, a clean app build, and the full automation gate for the completed migration.

## Non-goals

- A provider-neutral event bus or immediate Claude/OpenCode/Pi migration.
- Replacing `SessionRegistry`, `AppState`, panel ownership, or workspace persistence.
- Adding native identity to panel identity or making panel ID immutable.
- Using cwd, timestamps, prompt text, or fingerprints to guess cross-session ownership.
- Replaying historical approval/completion notifications.
- Persisting the reducer, offsets, or source-health state before a failing restore case requires it.
- Rewriting visible-text status inference, UI projections, or unrelated large files as part of this migration.
- Guaranteeing cross-source correlation for provider events that expose no stable common identifier.

## Stop conditions and unresolved experiments

Stop the affected migration step, leave that fact on the legacy path, and gather evidence if any of these occur:

- Supported Codex hook and rollout versions do not expose the same stable approval/call identifier. Cross-source approval dedupe and dynamic approval failover must remain disabled.
- Notify and rollout completions cannot be joined by native thread + turn across supported versions. Keep completion fallback source-local rather than adding a heuristic.
- A claimed exact identifier changes meaning or is reused within one native session.
- Sanitized real traces show the canonical rollout path can change native identity without a new managed generation.
- Shadow decisions diverge from characterization tests without an intentional, separately approved behavior change.
- State bounds evict an active turn, approval, or subagent correlation.
- Bootstrap cannot distinguish replay from live tail reliably. Do not enable notification-producing facts on that watcher.
- An identity claim requires cwd-only, prompt-only, or time-only selection. Fail closed instead.

The following code experiments remain required before approval/completion migration:

1. Capture sanitized hook and launch/canonical-log shapes for two approvals in one turn across the minimum and current supported Codex versions; verify approval/call ID equality and stability.
2. Capture completion shapes from hook, notify, and both log formats; verify which combinations consistently share native thread and turn IDs.
3. Verify whether hook callbacks for one turn can arrive concurrently/out of order and confirm the single App ingest sequencer removes actor/task scheduling as an additional ordering source.
4. Verify watcher bootstrap-to-live transition at a partially written line and after truncation/rotation; define a reliable tail-reached signal before any effect-producing canonical events are enabled.
5. Replay a high-subagent-count sanitized trace against the proposed bounds and adjust only if a live correlation would be evicted.

These experiments constrain implementation; they are not permission to introduce fuzzy joins if the evidence fails.
