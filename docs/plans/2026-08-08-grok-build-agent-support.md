# Grok Build Agent Support Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add first-party Toastty support for Grok Build (`grok`) at Claude parity: managed launches, typed shims, live sidebar status, native resume, and basic subagent rows.

**Architecture:** On each managed `grok` launch, write a session-scoped hook discovery file under `$GROK_HOME/hooks/toastty-<sessionID>.json` pointing at a per-session telemetry forwarder in a temp artifacts dir. Events flow through `toastty session ingest-agent-event --source grok-hooks` into a camelCase-aware parser that drives Working / Ready / Needs approval / Error, resume records, and subagent rows. No durable Codex-style installer.

**Tech Stack:** Swift (ToasttyApp, ToasttyCLIKit, CoreState), XCTest + Swift Testing, Grok Build lifecycle hooks JSON, existing agent launch/resume plumbing.

**Design doc:** @docs/plans/2026-08-08-grok-build-agent-support-design.md

**Verification skill:** @.agents/skills/toastty-verify/SKILL.md after substantive code changes.

---

## Preconditions

- Work on branch `feat/add-grok` (or a worktree from it).
- After adding/renaming Swift sources: `tuist generate --no-open` (sources use globs under `Sources/CLIKit/**` and app targets, so new files under existing dirs are picked up after generate if needed).
- Prefer filtered tests while iterating:

```bash
ARCH="${ARCH:-$(if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == "1" ]]; then echo arm64; else uname -m; fi)}"

# Core + CLI parsers
xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug \
  -destination "platform=macOS,arch=${ARCH}" -derivedDataPath Derived \
  -only-testing:CoreStateTests/AgentKindTests \
  -only-testing:ToasttyCLITests/AgentEventParsersTests \
  test

# App instrumentation / resume
xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug \
  -destination "platform=macOS,arch=${ARCH}" -derivedDataPath Derived \
  -only-testing:ToasttyAppTests/AgentLaunchInstrumentationTests \
  -only-testing:ToasttyAppTests/ManagedAgentResumeResolverTests \
  test
```

If Xcode complains about missing schemes/targets, run `tuist generate --no-open` first.

---

### Task 0: Live hook spike (blocking for Needs approval)

**Files:**
- Create (gitignored or manual): `artifacts/manual/grok-hook-spike/` (do not commit secrets)
- Optional notes append to design doc open questions

**Step 1: Install a temporary catch-all logger**

```bash
mkdir -p ~/.grok/hooks artifacts/manual/grok-hook-spike
cat > /tmp/toastty-grok-spike-hook.sh <<'EOF'
#!/bin/sh
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
dir="${TOASTTY_GROK_SPIKE_DIR:-$HOME/src/toastty/artifacts/manual/grok-hook-spike}"
mkdir -p "$dir"
f="$dir/${ts}-$$.json"
cat > "$f"
printf 'logged %s\n' "$f" >&2
exit 0
EOF
chmod +x /tmp/toastty-grok-spike-hook.sh

cat > ~/.grok/hooks/toastty-spike.json <<EOF
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "/tmp/toastty-grok-spike-hook.sh", "timeout": 5 }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "/tmp/toastty-grok-spike-hook.sh", "timeout": 5 }] }],
    "PreToolUse": [{ "hooks": [{ "type": "command", "command": "/tmp/toastty-grok-spike-hook.sh", "timeout": 5 }] }],
    "PostToolUse": [{ "hooks": [{ "type": "command", "command": "/tmp/toastty-grok-spike-hook.sh", "timeout": 5 }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "/tmp/toastty-grok-spike-hook.sh", "timeout": 5 }] }],
    "StopFailure": [{ "hooks": [{ "type": "command", "command": "/tmp/toastty-grok-spike-hook.sh", "timeout": 5 }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "/tmp/toastty-grok-spike-hook.sh", "timeout": 5 }] }],
    "SubagentStart": [{ "hooks": [{ "type": "command", "command": "/tmp/toastty-grok-spike-hook.sh", "timeout": 5 }] }],
    "SubagentStop": [{ "hooks": [{ "type": "command", "command": "/tmp/toastty-grok-spike-hook.sh", "timeout": 5 }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "command": "/tmp/toastty-grok-spike-hook.sh", "timeout": 5 }] }],
    "PermissionDenied": [{ "hooks": [{ "type": "command", "command": "/tmp/toastty-grok-spike-hook.sh", "timeout": 5 }] }]
  }
}
EOF
```

**Step 2: Exercise Grok**

In a throwaway directory:

1. `grok` → submit a simple prompt → wait for Ready.
2. Trigger a **permission prompt** (e.g. shell command in default ask mode) → approve.
3. Optionally spawn a short subagent task.

**Step 3: Catalog payloads**

For each logged JSON, record:

- `hookEventName` (and any PascalCase variants if present)
- Fields used for session id, cwd, transcript/path
- Notification type field names/values for approval
- Stop `reason` values (`end_turn` vs session-end)
- Subagent identity fields

**Step 4: Clean up spike hooks**

```bash
rm -f ~/.grok/hooks/toastty-spike.json /tmp/toastty-grok-spike-hook.sh
```

**Step 5: Commit only durable fixtures (optional)**

If captures are clean of secrets, copy redacted fixtures into `Tests/CLI/Fixtures/grok-hooks/` later in Task 2. Do not commit raw personal session dumps.

**Step 6: Decision gate**

- If a clear Needs-approval hook exists → map it in Task 2.
- If only terminal OSC / no hook → ship Working/Ready/Error + document approval gap; keep Notification handler ready for future types.

---

### Task 1: `AgentKind.grok` + command resolver

**Files:**
- Modify: `Sources/Core/Sessions/AgentKind.swift`
- Modify: `Sources/Core/Agents/AgentProfilesFile.swift` (`builtInAgentIDsSupportingManualCommandNames`)
- Test: `Tests/Core/AgentKindTests.swift`
- Test: `Tests/Core/AgentProfilesFileTests.swift` (error strings listing built-ins)

**Step 1: Write failing tests**

In `AgentKindTests.swift`:

```swift
// displayNameUsesKnownAgentLabels
#expect(AgentKind.grok.displayName == "Grok Build")

// managedCommandResolverPrefersWrappedBuiltInExecutableForInsertion
#expect(
    ManagedAgentCommandResolver.launchInsertionIndex(
        for: .grok,
        argv: ["agent-safehouse", "grok", "--always-approve"]
    ) == 1
)

// managedCommandResolverInfersWrappedBuiltInsFromCommandNameOrPrefixArguments
#expect(
    ManagedAgentCommandResolver.inferManagedAgent(
        commandName: "grok",
        argv: ["grok"]
    ) == .grok
)
#expect(
    ManagedAgentCommandResolver.inferManagedAgent(
        commandName: "agent-safehouse",
        argv: ["agent-safehouse", "grok"]
    ) == .grok
)

// shimCommandNames includes grok for built-in catalog
// extend existing shim tests that assert "claude"/"codex" membership
```

Update any `AgentProfilesFileTests` assertion that lists supported IDs for `manualCommandNames` to include `grok`.

**Step 2: Run tests — expect FAIL**

```bash
xcodebuild ... -only-testing:CoreStateTests/AgentKindTests test
```

Expected: `AgentKind.grok` missing or displayName wrong / not inferred.

**Step 3: Minimal implementation**

In `AgentKind.swift`:

```swift
public static let grok = Self(rawValue: "grok")!

// displayName:
case .grok:
    return "Grok Build"
```

In `ManagedAgentCommandResolver`:

```swift
// isBuiltIn:
agent == .codex || agent == .claude || agent == .mimocode
    || agent == .opencode || agent == .pi || agent == .grok

// launchCommandBasenames:
case .grok:
    return ["grok"]

// exactBuiltInAgent / wrappedBuiltInAgent:
case AgentKind.grok.rawValue: // / "grok"
    return .grok

// shimCommandNames set: add AgentKind.grok.rawValue
```

In `AgentProfilesFile.swift`:

```swift
private static let builtInAgentIDsSupportingManualCommandNames: Set<String> = [
    AgentKind.codex.rawValue,
    AgentKind.claude.rawValue,
    AgentKind.opencode.rawValue,
    AgentKind.mimocode.rawValue,
    AgentKind.pi.rawValue,
    AgentKind.grok.rawValue,
]
```

**Step 4: Run tests — expect PASS**

**Step 5: Commit**

```bash
git add Sources/Core/Sessions/AgentKind.swift \
  Sources/Core/Agents/AgentProfilesFile.swift \
  Tests/Core/AgentKindTests.swift \
  Tests/Core/AgentProfilesFileTests.swift
git commit -m "feat(agents): recognize grok as a built-in AgentKind"
```

---

### Task 2: `grok-hooks` event source + parser

**Files:**
- Modify: `Sources/CLIKit/AgentEventSource.swift`
- Create: `Sources/CLIKit/GrokHookEventParser.swift`
- Modify: `Sources/CLIKit/AgentEventIngestor.swift`
- Modify: `Sources/CLIKit/ToasttyCLI.swift` (usage string + `ingestEventSummary`)
- Test: `Tests/CLI/AgentEventParsersTests.swift`
- Test: `Tests/CLI/ToasttyCLITests.swift` (source parsing if present)

**Step 1: Write failing parser tests**

Mirror Claude tests in `AgentEventParsersTests.swift` with **camelCase** fixtures from Task 0 when available. Skeleton:

```swift
@Test
func grokUserPromptSubmitMapsToWorkingStatus() throws {
    let commands = try AgentEventIngestor.commands(
        for: .grokHooks,
        sessionID: "sess-123",
        panelID: nil,
        payload: Data(#"{"hookEventName":"UserPromptSubmit","prompt":"fix the bug"}"#.utf8)
    )
    #expect(commands == [
        .sessionStatus(
            sessionID: "sess-123",
            panelID: nil,
            kind: .working,
            summary: "Working",
            detail: "fix the bug"
        )
    ])
}

@Test
func grokStopEndTurnMapsToReady() throws {
    // reason must be end_turn (or missing only if spike proves that is turn-complete)
    let payload = #"{"hookEventName":"Stop","reason":"end_turn","lastAssistantMessage":"done"}"#
    // expect Ready + detail "done"
}

@Test
func grokStopSessionEndIsIgnoredForReady() throws {
    let payload = #"{"hookEventName":"Stop","reason":"shutdown"}"#
    // expect [] or only non-Ready side effects — per spike
}

@Test
func grokStopFailureMapsToError() throws { /* ... */ }

@Test
func grokSessionStartMapsToResumeRecord() throws {
    let panelID = UUID()
    // sessionId + cwd → derive session path under ~/.grok/sessions/...
    // Use a deterministic helper; assert agent: .grok
}

@Test
func grokSubagentStartAndStopMapToBackgroundActivity() throws { /* from spike fields */ }

@Test
func grokNotificationApprovalMapsWhenKnown() throws {
    // Only if Task 0 found a type; otherwise skip or assert ignore unknown
}
```

Also accept snake_case aliases for resilience (`hook_event_name`, `session_id`) if cheap.

**Step 2: Run — expect FAIL** (unknown source / missing parser)

**Step 3: Implement**

`AgentEventSource.swift`:

```swift
case grokHooks = "grok-hooks"
```

`GrokHookEventParser.swift` — structure like `ClaudeHookEventParser`:

- Normalize event name from `hookEventName` or `hook_event_name` (support both `UserPromptSubmit` and `user_prompt_submit` if needed; prefer comparing lowercased/normalized forms).
- **SessionStart:** require `panelID`; native id from `sessionId`/`session_id`; build `sessionFilePath` via helper:

```swift
// Prefer explicit path from payload if spike shows one.
// Else: (GROK_HOME or ~/.grok)/sessions/<url-encoded-cwd>/<sessionId>/summary.json
// Store summary.json path so fileExists works (directory also works with FileManager.fileExists).
```

URL-encoding for cwd: match Grok’s layout (percent-encode path; spike/docs say URL-encoded cwd). Implement a small pure function and unit-test with a known path → known folder name from a real `~/.grok/sessions` entry on the dev machine if available.

- **UserPromptSubmit / PreToolUse:** Working
- **Stop:** if turn-complete reason → Ready; sync `backgroundTasks` when present (camelCase `backgroundTasks`, entries with `type`/`id`/`agentType`/`description`)
- **StopFailure:** Error
- **Notification:** map known types from spike; unknown → []
- **SubagentStart / SubagentStop:** background activity (use `subagentId` / `agent_id` / etc. from spike)
- **PermissionDenied:** []

Wire `AgentEventIngestor` case `.grokHooks`.

Update CLI usage error list and `ingestEventSummary` for `grokHooks` (mirror claude field names with camelCase preference).

**Step 4: Run parser tests — PASS**

**Step 5: Commit**

```bash
git commit -m "feat(cli): parse grok-hooks agent lifecycle events"
```

---

### Task 3: `prepareGrokLaunch` instrumentation

**Files:**
- Modify: `Sources/App/Agents/AgentLaunchInstrumentation.swift`
- Modify: `PreparedAgentLaunchArtifacts` to carry extra cleanup URLs
- Test: `Tests/App/AgentLaunchInstrumentationTests.swift`

**Critical concurrent-session rule:** Grok loads **all** files in `~/.grok/hooks/`. Each Toastty hook command must **no-op** unless `TOASTTY_SESSION_ID` equals the **session id embedded in that launch’s forwarder**. Do not rely on env alone for multi-file installs.

**Step 1: Write failing tests**

```swift
func testPrepareGrokLaunchWritesSessionScopedHookAndGatedForwarder() throws {
    let fm = FileManager.default
    let grokHome = fm.temporaryDirectory
        .appendingPathComponent("toastty-grok-home-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: grokHome, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: grokHome) }

    let sessionID = UUID().uuidString
    let prepared = try AgentLaunchInstrumentation.prepare(
        agent: .grok,
        argv: ["grok"],
        cliExecutablePath: "/bin/echo",
        sessionID: sessionID,
        workingDirectory: "/tmp/repo",
        fileManager: fm,
        launchEnvironment: ["GROK_HOME": grokHome.path]
    )
    defer {
        if let artifacts = prepared.artifacts {
            try? fm.removeItem(at: artifacts.directoryURL)
        }
        // also remove hook json via artifacts.additionalCleanupURLs
    }

    XCTAssertEqual(prepared.argv, ["grok"])
    let hookURL = grokHome.appendingPathComponent("hooks/toastty-\(sessionID).json")
    XCTAssertTrue(fm.fileExists(atPath: hookURL.path))

    let hookData = try Data(contentsOf: hookURL)
    let hookObject = try XCTUnwrap(JSONSerialization.jsonObject(with: hookData) as? [String: Any])
    let hooks = try XCTUnwrap(hookObject["hooks"] as? [String: Any])
    for name in ["SessionStart", "UserPromptSubmit", "PreToolUse", "Stop", "StopFailure",
                 "Notification", "SubagentStart", "SubagentStop"] {
        XCTAssertNotNil(hooks[name], "missing \(name)")
    }

    let scriptURL = try XCTUnwrap(prepared.artifacts?.directoryURL.appendingPathComponent("grok-hook.sh"))
    let script = try String(contentsOf: scriptURL, encoding: .utf8)
    XCTAssertTrue(script.contains(sessionID)) // expected-session gate
    XCTAssertTrue(script.contains("grok-hooks"))
    XCTAssertTrue(script.contains("TOASTTY_SESSION_ID"))
}

func testPrepareGrokLaunchFailsWhenHooksDirectoryNotCreatable() throws {
    // optional: read-only parent if easy to simulate; else skip
}

func testGrokForwarderNoopsWhenSessionIdMismatch() throws {
    // prepare, run script with TOASTTY_SESSION_ID=other; expect exit 0 and no useful CLI call
    // can use cliExecutablePath pointing at a shell script that writes a marker file
}
```

**Step 2: Run — FAIL**

**Step 3: Implement `prepareGrokLaunch`**

Extend artifacts:

```swift
struct PreparedAgentLaunchArtifacts {
    let directoryURL: URL
    let codexSessionLogURL: URL?
    let cleanupPolicy: LaunchArtifactsCleanupPolicy
    /// Paths outside directoryURL that must be removed on cleanup (e.g. Grok hook JSON).
    let additionalCleanupURLs: [URL]

    // convenience init defaulting additionalCleanupURLs to [] for existing call sites
}
```

Update every existing `PreparedAgentLaunchArtifacts(...)` call site to compile (default `[]`).

`prepare` branch:

```swift
if agent == .grok {
    return try prepareGrokLaunch(
        argv: argv,
        cliExecutablePath: cliExecutablePath,
        sessionID: sessionID,
        workingDirectory: workingDirectory,
        fileManager: fileManager,
        launchEnvironment: launchEnvironment
    )
}
```

Implementation sketch:

1. Resolve `grokHome`:
   - `launchEnvironment["GROK_HOME"]` if non-empty
   - else `FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")`
2. `hooksDir = grokHome/hooks` — `createDirectory`
3. Artifacts dir `toastty-grok-launch-<sessionID>`
4. Write `grok-hook.sh` via customized forwarder:
   - Prefix gate:

```sh
expected_session="<sessionID>"
if [ -z "${TOASTTY_SESSION_ID:-}" ] || [ "$TOASTTY_SESSION_ID" != "$expected_session" ]; then
  exit 0
fi
```

   - Then same pattern as `makeTelemetryForwarderScript(..., source: "grok-hooks", inputMode: .stdinOrFirstArgument)`  
   - Prefer extending `makeTelemetryForwarderScript` with optional `expectedSessionID: String?` rather than duplicating the whole script.

5. Write `hooks/toastty-<sessionID>.json` with command `/bin/sh <scriptPath>` for each event (no matcher required for SessionStart/UserPromptSubmit/Stop; optional `*` matcher for tool events).

6. Return argv unchanged, environment `[:]`, artifacts with:
   - `cleanupPolicy: .retainAfterSessionStop` (late hooks — like Claude) **OR** document choice
   - `additionalCleanupURLs: [hookJSONURL]` — **must still be deleted on stop** (see Task 4)

**Step 4: Run instrumentation tests — PASS**

**Step 5: Commit**

```bash
git commit -m "feat(agents): inject per-session Grok hooks on managed launch"
```

---

### Task 4: Cleanup hook JSON on session stop + orphan sweep

**Files:**
- Modify: `Sources/App/Agents/ManagedAgentLaunchPlanner.swift` (`ManagedLaunchArtifacts`, `registerManagedArtifacts`, `cleanup`)
- Possibly: app bootstrap / config reload for orphan sweep
- Test: planner tests if any exist; else new focused tests or instrumentation-level unit test of a small `GrokHookCleanup` helper

**Problem:** Claude’s `retainAfterSessionStop` skips deleting the artifacts **directory**. Grok’s hook JSON lives under `$GROK_HOME/hooks/` and must not linger.

**Step 1: Failing test for cleanup helper**

Extract pure helper (easy to test):

```swift
enum GrokManagedHookCleanup {
    static func hookFileURL(grokHome: URL, sessionID: String) -> URL
    static func removeHookFile(at url: URL, fileManager: FileManager)
    static func removeOrphanHookFiles(
        in hooksDirectory: URL,
        activeSessionIDs: Set<String>,
        fileManager: FileManager
    )
}
```

Test: create `toastty-aaa.json` and `toastty-bbb.json`; active = `{aaa}`; sweep removes only bbb; pattern must match `toastty-*.json` only.

**Step 2: Wire planner**

```swift
private struct ManagedLaunchArtifacts {
    let directoryURL: URL
    let codexSessionLogWatcher: CodexSessionLogWatcher?
    let cleanupPolicy: LaunchArtifactsCleanupPolicy
    let additionalCleanupURLs: [URL]
}

private func cleanup(_ managedArtifacts: ManagedLaunchArtifacts) async {
    await managedArtifacts.codexSessionLogWatcher?.stop()
    for url in managedArtifacts.additionalCleanupURLs {
        try? fileManager.removeItem(at: url)
    }
    guard managedArtifacts.cleanupPolicy == .deleteImmediately else {
        return
    }
    try? fileManager.removeItem(at: managedArtifacts.directoryURL)
}
```

On `discardManagedLaunch` / inactive session cleanup, `additionalCleanupURLs` always removed.

**Step 3: Orphan sweep**

On app launch (find existing agent setup / `AppBootstrap` / `ManagedAgentLaunchPlanner` init path — prefer one clear call site):

```swift
// Default GROK_HOME only (or also scan if GROK_HOME set in process env)
GrokManagedHookCleanup.removeOrphanHookFiles(
    in: home.appendingPathComponent(".grok/hooks"),
    activeSessionIDs: /* currently tracked managed grok sessions or empty at cold start */,
    fileManager: .default
)
```

At cold start, active set is empty → remove all `toastty-*.json` left from prior crashes. That is intentional and correct for v1 (no durable multi-session survival across app restarts for hook files; resume uses resume records, not hook files).

**Step 4: Tests PASS + Commit**

```bash
git commit -m "fix(agents): clean up session-scoped Grok hook files"
```

---

### Task 5: Native resume for `grok`

**Files:**
- Modify: `Sources/App/Agents/ManagedAgentResumeResolver.swift`
- Test: `Tests/App/ManagedAgentResumeResolverTests.swift`

**Step 1: Failing tests**

```swift
func testResolveGrokResumeUsesDoubleDashResume() throws {
    // fixture with existing session file path + cwd directory
    // expect initialInput == "grok --resume <uuid>"
}

func testExpectedNativeSessionIDForGrokResumeArgv() {
    let id = "db4f311b-12d0-4f61-ba81-0ae44ed10492"
    #expect(
        ManagedAgentResumeResolver.expectedNativeSessionID(
            agent: .grok,
            argv: ["grok", "--resume", id]
        ) == id
    )
}
```

**Step 2: Implement**

```swift
// expectedNativeSessionID:
case .claude, .grok:
    resumeToken = "--resume"

// resumeArgv:
case .claude, .grok:
    resumeArguments = ["--resume", record.nativeSessionID]
```

`defaultResumeExecutableName` already returns `agent.rawValue` → `"grok"`.

**Step 3: PASS + Commit**

```bash
git commit -m "feat(agents): resume managed Grok sessions with grok --resume"
```

---

### Task 6: Launch service — implicit profile + initialPrompt

**Files:**
- Modify: `Sources/App/Agents/AgentLaunchService.swift`
- Tests: search `AgentLaunchServiceTests` / automation managed launch tests for `claude` patterns and add `grok` parallels

**Step 1: Failing tests** for:

- `supportsImplicitProfile` includes `.grok`
- `implicitProfile` has `initialPromptPlacement: .trailing`
- `initialPromptPlacement` / `argvIsDirectFirstPartyPromptCommand` treats `["grok"]` like Claude

**Step 2: Implement**

```swift
private static func supportsImplicitProfile(_ agent: AgentKind) -> Bool {
    agent == .codex || agent == .claude || agent == .mimocode
        || agent == .opencode || agent == .pi || agent == .grok
}

// implicitProfile:
initialPromptPlacement: (agent == .codex || agent == .claude || agent == .grok) ? .trailing : nil

// initialPromptPlacement default:
guard agent == .codex || agent == .claude || agent == .grok else { return nil }

// argvIsDirectFirstPartyPromptCommand:
case .grok:
    commandNames = ["grok"]
```

**Step 3: PASS + Commit**

```bash
git commit -m "feat(agents): allow automation launch and trailing prompts for grok"
```

---

### Task 7: Wire remaining built-in call sites

**Files (grep and update any remaining exclusive lists):**

```bash
rg -n "agent == \\.pi|AgentKind\\.pi|\"claude\", \"opencode\"|mimocode.*pi|codex.*claude.*opencode" \
  Sources Tests docs README.md --glob '!**/Derived/**'
```

Expected touch-ups:

- `Sources/App/Agents/ManagedAgentNativeSessionObserver.swift` — only if Claude-style session-file discovery is required as fallback; **YAGNI for v1** if SessionStart always provides resume metadata. Skip unless tests force it.
- README / running-agents lists of shim command names
- Privacy doc (Task 8)
- Any reserved-env docs (no new env keys required for v1 beyond `GROK_HOME` read)

**Step 1:** Grep, fix compile breaks, add small tests only where behavior is asserted.

**Step 2: Commit**

```bash
git commit -m "chore(agents): include grok in built-in agent surfaces"
```

---

### Task 8: Documentation

**Files:**
- Modify: `docs/running-agents.md` — well-known IDs, “What `grok` enables”, shims list, automation list
- Modify: `docs/privacy-and-local-data.md` — ephemeral `$GROK_HOME/hooks/toastty-*.json` + temp artifacts
- Modify: `README.md` — feature bullet / agents list where Codex/Claude/Pi are named
- Modify: `docs/shell-integration.md` if it lists shim basenames

**Step 1: Write “What `grok` enables” section** (mirror Claude structure):

1. Per-launch session-scoped hooks under `$GROK_HOME/hooks/toastty-<session>.json`
2. Forwarder → `ingest-agent-event --source grok-hooks`
3. Status mapping summary
4. Resume via `grok --resume`
5. Cleanup on stop + startup orphan sweep
6. Needs approval: document spike outcome honestly

**Step 2: Commit**

```bash
git commit -m "docs: describe first-party Grok Build agent support"
```

---

### Task 9: Focused verification

**Step 1: Unit/integration filter suite**

Run the xcodebuild filters from Preconditions covering:

- `AgentKindTests`
- `AgentEventParsersTests`
- `AgentLaunchInstrumentationTests`
- `ManagedAgentResumeResolverTests`
- Any new cleanup tests
- `AgentLaunchServiceTests` if modified

**Step 2: Live smoke (manual or dev-run skill)**

Use @.agents/skills/toastty-dev-run/SKILL.md if launching the app:

1. Add `~/.toastty/agents.toml` profile `[grok]` or use automation implicit launch.
2. Launch Grok from Agent menu → sidebar Working → Ready.
3. Type `grok` in a Toastty pane with shims enabled → managed session.
4. After stop, confirm `~/.grok/hooks/toastty-*.json` for that session is gone.
5. Restore panel with resume record → `grok --resume <id>`.
6. Permission prompt: confirm Needs approval if spike found a signal; else note gap.

**Step 3: Follow toastty-verify** for the appropriate remote/local mix after implementation is complete.

**Step 4: Final commit only if verification fixes were needed**

---

## Implementation notes (do not skip)

### Session gating (duplicate hook invocations)

Every Grok process loads every `toastty-*.json`. Forwarders **must** embed `expected_session` and exit 0 on mismatch. Otherwise concurrent sessions double-ingest.

### `GROK_HOME`

Respect `GROK_HOME` from `launchEnvironment` when preparing hooks so tests do not touch the developer’s real `~/.grok`. Production launches usually unset it → `~/.grok`.

### Resume path

`ManagedAgentResumeResolver` only checks `fileExists` on `sessionFilePath`. Prefer storing `.../<sessionId>/summary.json` (file) or the session directory (also works with `fileExists`).

### Claude retain vs Grok hooks

- Artifacts dir: retain-after-stop is OK (temp).
- Hook JSON under `$GROK_HOME/hooks/`: **always delete on stop** via `additionalCleanupURLs`, even when directory cleanup is retained.

### YAGNI

- No Get Started hooks installer
- No Codex watchers
- No `GROK_HOME` isolation
- No `grok-build` profile alias
- No native session observer fallback unless SessionStart proves insufficient

---

## Execution handoff

Plan complete and saved to `docs/plans/2026-08-08-grok-build-agent-support.md`.

**Two execution options:**

1. **Subagent-Driven (this session)** — dispatch a fresh subagent per task, review between tasks, fast iteration  
2. **Parallel Session (separate)** — open a new session with executing-plans and run task-by-task with checkpoints  

Which approach?
