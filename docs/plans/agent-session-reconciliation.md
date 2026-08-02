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
| canonical rollout path from an accepted identity claim | Exact file attachment for that managed session claim; a path alone does not establish ownership. |

### Bridge keys

| Key | Permitted use |
| --- | --- |
| prompt fingerprint | A non-unique bridge within one managed session and a bounded active-turn window. Repeated prompts can produce the same fingerprint. It may corroborate a thread/turn claim, but must not establish provider identity, approval identity, or cross-session ownership. |
| thread-only completion | May complete the current root turn only when that thread is already the accepted native identity and there is exactly one compatible open turn. It is not sufficient to choose among turns. |
| source timestamp, when present | Staleness and replay cutoff within that source only. It must never order observations from different clocks or override source-specific causal evidence. |

### Unjoinable or heuristic observations

- Multiple approval requests without a preserved approval/call ID are distinct but cannot be reliably correlated across hook and log sources.
- An unidentified `Stop` or `task_complete` is session-scoped and cannot prove which turn or operation it closes.
- Generic progress is a source-local latest-arrival projection, not a cross-source entity.
- Reviewer inference from textual/substr matching is context evidence, not identity.
- rollout `NEW_TASK`/`FINAL_ANSWER` text and parent/child path inference are fallback lifecycle evidence, not exact cross-source keys.

`CodexSessionLogWatcher` currently reads `call_id`/`approval_id` while constructing a source-local dedupe identifier, but drops both from `CodexSessionLogEvent` (`Sources/App/Agents/CodexSessionLogWatcher.swift:63-137`, `Sources/App/Agents/CodexSessionLogWatcher.swift:1036-1047`, `Sources/App/Agents/CodexSessionLogWatcher.swift:1294-1305`). Its generic identifier preference checks `call_id` before `approval_id`, which can collapse two subcommand approvals that share one call ID. The bounded first slice preserves both fields and changes approval-event source-local dedupe only to `approvalID ?? callID`. These log identifiers are not cross-source keys.

### Experiment result — 2026-08-01: approval identifier scope

An audit of installed Codex 0.146.0 and current `openai/codex` main found that the `PermissionRequest` hook schema requires session, turn, and tool fields but serializes no `tool_use_id`, `call_id`, `approval_id`, or `request_id`. `PreToolUse` separately requires `tool_use_id`. Codex has an effective internal approval/call identifier, but the `PermissionRequest` serialization omits it.

Launch logs do expose `call_id` and may expose a more-specific `approval_id`, yielding the source-local approval key `approvalID ?? callID`. Because the current hook shape exposes no corresponding ID, **exact hook↔log approval correlation and dynamic approval failover are unavailable and remain disabled**. Fixed launch-selected authority remains the contract. Source-local log IDs improve log replay/dedupe only; they are not permission for cross-source matching. Recheck this conclusion only after a supported Codex hook schema changes.

## Target boundary

Add a provider-specific pure module named `CodexReconciliation`, with its own tests. `ToasttyApp` depends on it. The landed native-claim slice is Foundation-only; add a `CoreState` dependency later only if a migrated fact genuinely needs shared status types and an App-owned adapter would be less clear. The module must not import AppKit, SwiftUI, filesystem APIs, notification APIs, or app-owned stores.

The module contains:

- a Codex-specific `CodexObservation` enum with typed source and provenance;
- a `CodexReconciliationState` keyed by immutable managed identity;
- a pure `CodexObservationReducer` that returns state plus decisions;
- pure native-claim evaluation against an App-supplied ownership snapshot;
- typed decisions for identity/path claims, status, background activity, resume discovery, notification intent, ignored/conflicting observations, and diagnostics.

It is explicitly not a generic event bus and introduces no speculative provider protocol.

The first landed slice contains typed native-claim values and the pure batch evaluator. `ManagedAgentNativeSessionObserver` routes Codex claims through it against one complete App-supplied ownership snapshot, then applies accepted decisions synchronously on `MainActor`. Claude remains on its pre-existing observer policy during the provider-by-provider migration; importing `CodexReconciliation` must not silently change another provider's claim semantics.

Identifiers added to normalized event contracts are ephemeral and non-`Codable`. Each source preserves only identifiers it actually exposes; Toastty does not synthesize a hook approval ID. These fields are not a persisted workspace schema or a promise to restore reconciliation state across app launches.

### Identity and ownership

Immutable reconciliation identity consists of:

- Toastty managed session ID;
- provider/agent kind.

`ManagedAgentLaunchPlanner` creates a new managed session ID for every launch, so a second launch-generation token is redundant. Stable effect IDs use the managed session ID directly. Discovered claims attach native provider session ID and canonical rollout path, each with provenance. Panel ID, window ID, workspace ID, and panel-to-session binding are mutable App ownership and are not part of immutable identity. Moving or closing a panel must not silently produce a different provider identity.

### Observation envelope

Every observation entering the reducer has:

- managed identity and provider;
- observation source;
- typed App-assigned `ReceiveSequence`;
- App receive time;
- source-specific causal position when the source supplies one: native thread/turn/operation identity, watcher file position, or a source-local counter;
- provider-specific payload with preserved native, turn, approval/call/tool, and subagent identifiers where available.

The App assigns process-monotonic `ReceiveSequence` synchronously at ingress, before an actor/task hop where possible. It records deterministic receipt order and breaks ties only; it does **not** establish provider causality or prove which provider event happened first. The reducer prefers exact causal identity and source-local position over receipt order. A source timestamp is attached only to the source payload that actually has one and is used only for cutoff/staleness within that source.

Socket observations are live by construction and do not carry a universal replay phase. Bootstrap/live is watcher-stream context.

### Watcher stream cursor

Each launch-log or canonical-rollout stream owns a runtime cursor:

- file identity, using device + inode where the platform supplies them;
- byte offset after the last complete consumed line;
- hash of that last complete line.

The App retains this cursor when recreating a watcher for the same file stream and managed session, so a mid-session watcher restart resumes rather than replaying from byte zero. A newly created managed session, including an app/workspace restore, may intentionally bootstrap from zero with effects suppressed.

File replacement, identity change, truncation below the cursor, or a last-line-hash mismatch invalidates the cursor and re-enters bootstrap. A watcher reaches the live tail heuristically after consuming through complete-line EOF and observing a bounded quiescence interval. This is not a causality guarantee: bootstrap/live interleaving is expected, and state/effect idempotency must absorb a mistaken boundary classification. Incomplete trailing bytes stay buffered and do not advance the complete-line cursor.

The cursor is runtime state, not reducer state. Disk persistence is deferred until a concrete cross-process restore failure demonstrates that bootstrap from zero is insufficient.

### Effects boundary

The pure module may emit intent, not effects. `SessionRuntimeStore` or a smaller App coordinator remains responsible for:

- applying mutations to `SessionRegistry` and `AppStore`;
- starting, cancelling, and expiring approval/reaper timers;
- reading visible terminal text;
- checking application focus and panel visibility;
- suppressing or delivering desktop notifications;
- attaching/stopping filesystem watchers;
- structured logging and debug capture.

Timers return a tokenized observation to the reducer. A cancelled or superseded token is a no-op. Every user-visible effect intent has a stable idempotency key derived from managed session ID, effect kind, and the accepted root-turn/operation identity. An otherwise accepted unidentified terminal event is effect-eligible only when it can bind unambiguously to a current turn with a stable key. The App effect executor coalesces pending and delivered instances of that key while the fact can still replay. If it cannot safely retain an effect key, it suppresses the effect and emits a degraded diagnostic rather than risk duplicate user-visible behavior.

Watcher bootstrap never produces a desktop notification. It may reconstruct state, including a terminal state, only when the terminal fact is proven to belong to the current managed launch or a verified resume boundary. An old terminal observation that cannot pass that boundary check is ignored. Focus and visibility remain App-owned delivery policy.

### Bounded state

There must be no session-lifetime-growing array or set. Bounds apply to exact decision/correlation keys, not to a lossy cache that correctness depends on. Initial units and overflow behavior are:

- one current active turn plus one immediately previous terminal turn per managed session; older terminal observations cannot affect the current turn;
- at most 256 closed exact decision keys per managed session for duplicate/provenance diagnostics; active fact keys live in typed turn/approval/subagent state outside this quota and never evict, while overflow drops only extra closed-fact enrichment;
- at most 128 enriched subagent correlations per managed session; terminal entries evict before active entries, and overflow records an aggregate/degraded diagnostic instead of guessing or evicting an active identity;
- at most 32 recent auto-review/approval correlation tombstones per managed session; a still-replayable user effect key is retained separately until its turn boundary is closed;
- immediate removal of all reducer state and pending App effects when a managed session stops.

Bounds overflow may reduce diagnostics, labels, or enrichment, but must never change identity ownership, apply an ambiguous transition, or duplicate a user-visible effect. Tests must demonstrate that behavior after streams substantially larger than every limit. If real traces show a bound can evict an active correctness or effect key, stop migration and revise the model rather than silently raising it.

## Fact authority and conflict policy

Authority is per fact, not a global “hooks always win” flag.

| Fact | Preferred authority | Fallback | Conflict / duplicate behavior |
| --- | --- | --- | --- |
| managed-session association | App launch context and socket active-session/panel validation | none | Reject an event not associated with the active managed session. Never infer association from cwd, prompt, path, or time. |
| native provider identity | expected resume ID corroborated by hook/session-configured/snapshot evidence; otherwise exact hook or launch-log `session_configured` claim | shell snapshot + matching session metadata | Same-owner repeats are idempotent. A different active owner is rejected and diagnosed. An ambiguous scan makes no claim. |
| canonical rollout path | path resolved as part of an accepted native claim and validated for expected cwd/provider metadata | later exact claim for the same native owner | A new path may replace an older path for the same managed owner. A path naming a different native ID is a conflict, not a rename. |
| root turn identity/start | exact native thread + turn from hook or log; launch log supplies turn context | prompt fingerprint bridge only within the current managed session | Exact mismatches are diagnosed. A bridge cannot replace an exact active turn. Duplicate starts merge provenance. |
| approval policy/reviewer | structured launch-log turn context | hook permission mode as partial evidence | Preserve `unspecified`, explicit `null`, and value. Heuristic reviewer parsing cannot override structured context. |
| working/progress status | launch-selected source: hooks when installed, otherwise launch log | no dynamic fallback in the first migrations | Generic progress is latest-by-receipt only within the selected source. Receipt order does not imply provider causality and cannot switch authority. |
| approval request | launch-selected source with resolved policy/reviewer context | no dynamic cross-source fallback for current hook schemas | Launch-log approval events dedupe source-locally by `approvalID ?? callID`; different approval IDs remain distinct even when they share a call ID. Hook and log approvals do not cross-source dedupe. Auto-reviewed requests update a tombstone but do not show approval UI/notification. |
| completion/abort | launch-selected hook or log/notify source | thread-only completion only for one unambiguous open turn in the selected fallback mode | One terminal decision per turn. Later duplicates only add provenance. An unidentified or older terminal event cannot close a newer exact turn. |
| subagent spawn metadata | hook `spawnToolUseID` metadata | rollout function-call arguments with the same call ID | Exact call ID merges metadata. Prompt/message text never joins agents. Ciphertext-like labels remain suppressed. |
| subagent lifecycle | canonical rollout provider agent ID and lifecycle entries | hook subagent ID; text/path inference only as source-local fallback | Exact agent ID owns lifecycle. Finish-before-start creates a bounded tombstone so replay cannot resurrect the activity. |
| background activity projection | reconciled subagent/tool decisions | current source-local activity fallback | Stable provider ID is the activity ID. Replays rebuild active activities but do not notify. |
| notification intent | reducer terminal/approval decision from live socket input or effect-eligible watcher context | none | App focus/visibility policy decides delivery. Stable effect ID makes duplicates idempotent; bootstrap never notifies. |

### Gated future dynamic fallback

The first migrations preserve today's fixed-at-launch authority. They do not add a session hook-liveness latch, a per-turn approval boolean, or a new fallback behavior. The 2026-08-01 schema audit establishes that dynamic approval fallback cannot be implemented exactly with current supported hook shapes.

If a future supported hook schema exposes an approval identifier that is proven equal to a launch-log identifier—and completion experiments separately prove common exact keys and delivery behavior—a separately reviewed change may introduce event-specific fallback:

1. A fallback source produces an observation containing an exact key for an open fact.
2. If the preferred-source observation with that key has not arrived, the App schedules a bounded grace token appropriate to that fact.
3. A matching preferred observation cancels the token and reconciles as a duplicate.
4. Expiry re-enters the reducer with the same key; the reducer may accept the fallback fact.
5. Later preferred duplicates add provenance but do not repeat state or effects.

Generic progress and unidentified terminal events cannot satisfy this rule. Delivery-failure telemetry may improve diagnostics, but is not itself permission to associate or apply an ambiguous event. Grace durations remain App configuration and require trace-backed tests; they are not part of the pure policy.

## Cross-session native claims

`AppState` resume records and the runtime session registry remain the sole ownership source. Before evaluating a claim, the App supplies a read-only ownership snapshot keyed by `(provider, normalized native session ID)`. The pure module returns a claim decision; it does not own or mutate an authoritative index.

- No owner in the snapshot: accept an exact claim and bind it to the active managed session.
- Same managed owner: merge stronger provenance/path information idempotently.
- Different active managed owner: reject the new claim, retain the existing owner, emit a structured conflict, and do not prune or rewrite either panel's resume record.
- Previous owner inactive: an expected-ID resume launch may reclaim the identity after the App verifies the previous managed session is inactive. A fresh claim is recorded for the new managed session before the old persisted panel projection is changed.
- Same candidate observed simultaneously for multiple managed-session observers: fail all ambiguous claims, matching current observer behavior.
- Expected-ID evidence never steals from a live same-provider owner.

First arrival must not be used to break a simultaneously known ambiguity; claims discovered by one observation scan are evaluated as a batch against one ownership snapshot. Panel closure/move changes the App projection; it does not mutate the identity key. The App may clear or move a persisted resume record only after the identity decision is accepted.

Ambiguous, conflicting, or overflowed evaluation produces a structured degraded diagnostic with reason, affected fact, and recovery trigger. Recovery may occur after a new exact observation, owner inactivity, or a successful rescan. A user-visible degraded UI is a separate product behavior and requires explicit approval; this contract adds diagnostics only.

## Launch, resume, and restore

### New managed launch

- Create a new managed ID and initial idle status.
- Start hook/notify forwarding and the launch-scoped log watcher with that exact managed association.
- Start native observation when launch cwd is available; accept a Codex claim only when the scan later supplies matching snapshot evidence. Cwd remains validation, never association.
- Treat observations as live after the managed session has started.

### Resume-shaped launch

- Create a new managed ID even though the native provider ID is known from argv.
- Store the native ID as an expected claim, not an accepted owner, until hook, `session_configured`, or matching snapshot/session metadata corroborates it.
- Refuse the claim while another active same-provider managed session owns that native ID.

### Workspace restore / watcher attachment

- Runtime reconciliation state is not restored from the previous app process.
- A persisted panel resume record supplies an expected native ID/path, but a fresh capture for the current managed session is required before canonical attachment. The existing `capturedAt >= startedAt` safeguard remains (`Sources/App/Agents/ManagedAgentLaunchPlanner.swift:747-765`).
- Canonical rollout bootstrap may start at zero to reconstruct current collaboration state. Entries older than the managed-session start are stale for collaboration lifecycle.
- Bootstrap may reconstruct a terminal state only when exact identity/turn evidence places it inside the current launch or verified resume boundary. A completion written while Toastty was down is therefore applied only if it belongs to the resumed boundary, and it never emits a notification.
- Complete-line EOF plus quiescence moves the stream heuristically to live handling. Interleaving around that boundary remains safe through state and effect idempotency.

Persisting reducer state or the runtime cursor to disk is deferred. Add persistence only if a tested cross-process restore scenario cannot be handled by bootstrap replay plus a fresh claim.

## Incremental migration

Each step is independently revertible. Never let the legacy handler and the new reducer both mutate the same fact.

1. **Preserve source-exposed identifiers and characterize behavior.** Add ephemeral, non-`Codable` log `approvalID` and `callID` fields without inventing a hook equivalent. Use `approvalID ?? callID` for launch-log approval dedupe only. Split parsing from file polling enough to test normalized observations. Capture sanitized traces and characterize current behavior under receipt-order permutations.
2. **Introduce the pure target with trace replay.** Add `CodexReconciliation` and reducer tests. The first implementation contains the Foundation-only native-claim evaluator and synthetic batch/permutation tests; fact-specific observation state and sanitized trace replay are added with the fact that needs them rather than as placeholder abstractions.
3. **Migrate identity and rollout claims.** Route Codex claims through pure evaluation against an App ownership snapshot; App code remains the sole owner and continues applying accepted resume-record mutations and watcher attachment. This slice is landed. Claude deliberately remains on the legacy observer branch until it receives its own reviewed migration.
4. **Migrate subagent correlation.** Move call/tool-use/agent-ID joins, finish tombstones, and bounded state into the reducer. Keep watcher lifecycle in the App.
5. **Migrate status and background projection.** Move root-turn identity and progress decisions while preserving current fixed-at-launch source behavior. Add the runtime cursor before relying on watcher restart replay.
6. **Migrate approval, completion, and notification intent last.** Preserve fixed launch-selected authority, introduce stable effect IDs, and keep App-owned timers and notification suppression. Approval cross-source dedupe/fallback remains disabled until a future schema recheck finds a common exact ID; completion fallback remains gated by its identifier/delivery experiments and separate review.
7. **Delete legacy reconciliation.** Remove old per-session notify state, approval deferral maps, auto-review arrays, duplicate source gates, subagent correlation maps, and temporary routing flags after every fact class has one owner.

### Trace replay, canary, and rollback

- Sanitized trace replay is the primary equivalence tool. Expected equivalence is fact-specific: identity claim result, status transition, activity projection, or effect intent/key. There is no global “states are equal” assertion.
- Use a temporary per-fact runtime route (`legacy` or `reconciler`) rather than one global feature flag. Enable a fact for a narrow test/canary cohort only after trace replay passes.
- Keep a fast per-fact rollback to `legacy` that does not require a stored-data migration. Never route one fact to both mutating implementations.
- Shadow comparison is optional only where an existing pure comparable seam makes it cheap. It must not duplicate timers, state writes, notifications, or provider parsing.
- Remove the route after targeted tests, the full gate, live scenarios, and an agreed canary interval. A structured degraded diagnostic is a rollback signal.
- Do not carry both implementations indefinitely. Cleanup is part of each fact-class migration, with a final sweep for shared obsolete state.

## Sanitized fixture capture

A debug-only capture harness may write normalized observation sequences under ignored `artifacts/`. It must operate after parsing and before reconciliation.

- Replace managed, native, turn, approval/call/tool, and agent IDs with stable per-fixture tokens.
- Remove prompt text, assistant output, commands, file paths, cwd, repo names, environment values, and raw provider payloads.
- Retain source, event kind, identifier presence/equality relationships, receipt order, source causal position, relative timing where available, watcher context, and structured policy enum values.
- Commit only minimal hand-reviewed fixtures needed for regression tests. Never commit raw rollout or hook payloads.
- Use adversarial sanitizer tests with tokens hidden in nested metadata, escaped strings, multiline content, and identifier-shaped text.
- Build sanitizer tests with synthetic home directories and paths so the test itself never embeds a real user home.
- Scan every committed fixture for known secret patterns, environment assignments, absolute/home paths, raw UUID-like IDs, commands, and prompt fragments; fail the test if any survive.

## Affected files and intended responsibilities

| Path | Intended change |
| --- | --- |
| `Project.swift` | Add the pure reconciliation target and tests; keep generated Xcode projects untouched. |
| `Sources/CodexReconciliation/` | New Codex observation, state, reducer, pure claim evaluation, and decisions. |
| `Tests/CodexReconciliation/` | Receipt-order, causal-position, conflict, replay, effect-idempotency, and bounds tests. |
| `Sources/Core/Agents/CodexHookEvent.swift` | Carry optional ephemeral `approvalID`/`callID` when the originating source exposes them; current `PermissionRequest` hook parsing leaves both nil. Do not synthesize IDs or add persisted schema. |
| `Sources/Core/Agents/CodexNotifyCompletion.swift` | Preserve any stable ephemeral completion operation ID exposed by notify. |
| `Sources/CLIKit/CodexHookEventParser.swift` and `Sources/CLIKit/CodexNotifyEventParser.swift` | Decode identifiers without choosing authority. |
| `Sources/CLIKit/ToasttyCLI.swift` and `Sources/App/Automation/AutomationSocketServer.swift` | Transport and validate normalized fields; assign no provider policy. |
| `Sources/App/Agents/CodexSessionLogWatcher.swift` | Separate pure decoding from polling; preserve IDs and own runtime file identity/offset/complete-line cursor plus bootstrap/live stream context. |
| `Sources/App/Agents/ManagedAgentNativeSessionObserver.swift` | Supply exact claim evidence; keep scanning/polling in the App. |
| `Sources/App/Agents/ManagedAgentLaunchPlanner.swift` | Orchestrate ingress, watcher/cursor attachment, App ownership snapshots, and accepted identity application. |
| `Sources/App/Sessions/SessionRuntimeStore.swift` | Assign typed receive sequence, apply reducer decisions, execute stable effect IDs, own timers/focus/notifications, and delete legacy Codex policy as facts migrate. |
| `Tests/App/SessionRuntimeStoreTests.swift` and focused successor suites | Characterize App effects and validate integration without re-testing the pure reducer exhaustively. |

## Verification contract

### Pure reducer tests

- duplicate and reordered exact observations;
- all supported hook receipt-order permutations for one causal turn;
- hook/log disagreement on native, thread, turn, and operation IDs;
- two active managed sessions claiming one native session;
- stale-owner reclaim versus live-owner refusal;
- the same prompt submitted twice, proving fingerprints do not dedupe distinct turns/approvals;
- two launch-log approvals in one turn sharing a call ID but carrying different approval IDs;
- approval followed by completion, abort, timeout, and cancelled timer token;
- an old terminal observation arriving after a newer exact turn has started;
- subagent spawn hook metadata joined to rollout call and provider agent ID;
- finish-before-start and replay without resurrection;
- bootstrap suppression of notification intent;
- bootstrap/live interleaving with the same terminal fact and stable effect ID;
- long synthetic streams proving every state bound and diagnostic/enrichment-only overflow degradation.

Dynamic-fallback tests—fallback exact event, preferred event within grace, grace expiry, and late preferred duplicate—are added only if the gated future behavior is approved.

### Parser and transport tests

- launch-log `approvalID` and `callID` both survive parsing, while hook parsing explicitly remains nil for identifiers absent from its schema;
- missing/malformed optional IDs do not make an otherwise valid event fail;
- exact session/panel validation rejects stale or cross-panel callbacks;
- `ReceiveSequence` reflects synchronous receipt, while source causal position wins causality decisions;
- canonical watcher still ignores non-background mutations until the relevant fact migration deliberately changes it;
- sanitizer adversarial cases and a committed-fixture secret/home/path scan.

### App integration tests

- one writer per migrated fact;
- timers cancel on matching events and managed-session stop;
- stop with pending approval, watcher, notification, and subagent work leaves no later effects;
- identity decisions update resume records without duplicate pruning damage;
- a mid-session watcher restart resumes its runtime cursor without replay;
- file rotation/truncation re-enters bootstrap, a partial final line is processed once after completion, and replacement cannot deliver from the old path;
- focus/visibility suppresses desktop delivery without changing reducer status decisions;
- bootstrap replay reconstructs active subagents and sends no old notifications;
- a completion written while the app was down applies state only across a verified resume boundary and never notifies;
- bootstrap/live interleaving cannot duplicate state transitions or effect execution;
- process-watch and non-Codex managed sessions remain unchanged.

### Live validation

- fresh Codex launch with hooks installed;
- forced session-log fallback launch;
- approve, deny, auto-review, timeout, completion, and abort;
- two approvals during one turn;
- subagent start/finish from different sources;
- resume, app relaunch, and workspace restore;
- panel move/close while an approval timer is pending;
- conflicting native-session claim from a second active panel;
- session stop while watchers and timers are active.

Withholding an exactly joinable hook to demonstrate per-event fallback is a future validation scenario, not part of the initial fixed-authority migration.

Use the repository `toastty-verify` workflow at each implementation phase boundary, including Tuist regeneration, targeted tests, a clean app build, and the full automation gate for the completed migration.

## Non-goals

- A provider-neutral event bus or immediate Claude/OpenCode/Pi migration.
- Replacing `SessionRegistry`, `AppState`, panel ownership, or workspace persistence.
- Adding native identity to panel identity or making panel ID immutable.
- Using cwd, timestamps, prompt text, or fingerprints to guess cross-session ownership.
- Replaying historical approval/completion notifications.
- Persisting reducer state, file cursors, or source-health state before a failing cross-process restore case requires it.
- Dynamic source failover in the initial migrations; it remains gated by common-ID and delivery evidence plus separate review.
- A session-wide hook-liveness latch or a per-turn approval boolean.
- Rewriting visible-text status inference, UI projections, or unrelated large files as part of this migration.
- Guaranteeing cross-source correlation for provider events that expose no stable common identifier.

## Stop conditions and unresolved experiments

Stop the affected migration step, leave that fact on the legacy path, and gather evidence if any of these occur:

- A future supported Codex hook schema still does not expose an approval identifier proven equal to a log identifier. This is the known current state, so cross-source approval dedupe and dynamic approval failover remain disabled; it does not block source-local log dedupe.
- Notify and rollout completions cannot be joined by native thread + turn across supported versions. Keep completion fallback source-local rather than adding a heuristic.
- A claimed exact identifier changes meaning or is reused within one native session.
- Sanitized real traces show the canonical rollout path can change native identity without a new managed session.
- Trace replay or a per-fact canary diverges from its explicit equivalence contract without an intentional, separately approved behavior change.
- State bounds evict an active correctness/effect key or overflow changes identity, state correctness, or user-visible effects instead of degrading diagnostics/enrichment.
- A stable effect ID cannot prevent bootstrap/live boundary uncertainty from duplicating an effect. Do not enable effect-producing watcher facts.
- A runtime cursor cannot distinguish same-file resume from truncation/rotation using file identity, offset, and last-complete-line evidence. Keep watcher restart on the legacy path.
- An identity claim requires cwd-only, prompt-only, or time-only selection. Fail closed instead.

The following code experiments remain for later fact migrations or future fallback work:

1. On a supported Codex hook-schema change, repeat the approval identifier audit before reconsidering cross-source approval correlation; do not infer compatibility from internal provider IDs.
2. Capture completion shapes from hook, notify, and both log formats; verify which combinations consistently share native thread and turn IDs.
3. Verify whether hook callbacks for one turn can arrive concurrently/out of order. Confirm synchronous `ReceiveSequence` assignment records receipt order without being used as provider causality.
4. Verify watcher cursor resume and bootstrap/live interleaving at a partially written line and after truncation/rotation. Calibrate the complete-line EOF + quiescence heuristic and prove stable effect IDs absorb boundary error.
5. Replay a high-subagent-count sanitized trace against the proposed bounds and adjust only if a live correlation would be evicted.

These experiments constrain implementation; they are not permission to introduce fuzzy joins if the evidence fails.
