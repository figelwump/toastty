import CoreState
import Foundation
import RemoteProtocol

/// Public hook event names. These strings are part of the schema-v1 contract
/// documented in docs/agent-hooks.md and must stay stable.
enum AgentHookEventKind: String, Equatable, Sendable, CaseIterable {
    case sessionStart = "session-start"
    case turnComplete = "turn-complete"
    case needsApproval = "needs-approval"
    case sessionError = "session-error"
    case sessionStop = "session-stop"
}

enum AgentHookLaunchReason: String, Equatable, Sendable {
    case managed
    case restore
    case processWatch = "process-watch"
}

/// One normalized hook payload. JSON field names are explicit coding keys and
/// optional fields encode as explicit `null`, so schema-v1 consumers see a
/// stable shape. Breaking field changes require a schema-version increment.
struct AgentHookEvent: Equatable, Sendable {
    static let schemaVersion = 1

    var kind: AgentHookEventKind
    var timestamp: Date
    var sessionID: String
    var agent: AgentKind
    var workspaceID: UUID
    var panelID: UUID
    var cwd: String?
    var previousStatus: SessionStatusKind?
    var newStatus: SessionStatusKind?
    var launchReason: AgentHookLaunchReason?
}

extension AgentHookEvent: Encodable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case event
        case timestamp
        case sessionID
        case agent
        case workspaceID
        case panelID
        case cwd
        case previousStatus
        case newStatus
        case launchReason
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(kind.rawValue, forKey: .event)
        try container.encode(timestamp.formatted(Self.timestampStyle), forKey: .timestamp)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(agent.rawValue, forKey: .agent)
        try container.encode(workspaceID.uuidString, forKey: .workspaceID)
        try container.encode(panelID.uuidString, forKey: .panelID)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(previousStatus?.rawValue, forKey: .previousStatus)
        try container.encode(newStatus?.rawValue, forKey: .newStatus)
        try container.encode(launchReason?.rawValue, forKey: .launchReason)
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: .gmt
    )
}

private extension KeyedEncodingContainer {
    /// Encodes optionals as explicit `null` so every schema field is present.
    mutating func encode(_ value: String?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

struct AgentHookInvocationRequest: Equatable, Sendable {
    var scriptPath: String
    var stdinData: Data
    var environmentOverlay: [String: String]
    var executionTimeout: TimeInterval
    var terminationGracePeriod: TimeInterval
}

/// Result of one hook process run. `stdinWriteFailed` is reported alongside
/// completion because an early-exiting hook legitimately closes its stdin.
struct AgentHookRunResult: Equatable, Sendable {
    enum Completion: Equatable, Sendable {
        case exited(code: Int32)
        case timedOut(didForceKill: Bool)
        case spawnFailed(message: String)
    }

    var completion: Completion
    var stdinWriteFailed: Bool

    static func exited(code: Int32, stdinWriteFailed: Bool = false) -> AgentHookRunResult {
        AgentHookRunResult(completion: .exited(code: code), stdinWriteFailed: stdinWriteFailed)
    }
}

/// Async boundary for hook process execution. The live implementation runs
/// the process fully off the main actor; tests substitute deterministic fakes.
protocol AgentHookProcessRunning: Sendable {
    func run(_ request: AgentHookInvocationRequest) async -> AgentHookRunResult
}

/// Directly executes the configured hook script: launches the process with
/// stdout/stderr redirected to /dev/null, writes the JSON payload to stdin,
/// closes stdin, enforces the execution timeout with SIGTERM and a SIGKILL
/// escalation, and collects the exit. All blocking work happens on a utility
/// queue, never on the caller's actor.
struct AgentHookLiveProcessRunner: AgentHookProcessRunning {
    /// Upper bound on waiting for the post-SIGKILL exit notification, so a
    /// blocked kernel-side reap can never wedge hook delivery.
    private static let postKillReapTimeout: TimeInterval = 5

    func run(_ request: AgentHookInvocationRequest) async -> AgentHookRunResult {
        await withCheckedContinuation { continuation in
            // A dedicated thread keeps hook execution independent of the
            // shared GCD pool: a starved global queue must not wedge hook
            // delivery, and the dispatcher already bounds concurrency to four
            // invocations, so at most four short-lived threads exist.
            let thread = Thread {
                continuation.resume(returning: Self.runBlocking(request))
            }
            thread.name = "toastty-agent-hook"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    private static func runBlocking(_ request: AgentHookInvocationRequest) -> AgentHookRunResult {
        let process = Process()
        process.executableURL = URL(filePath: request.scriptPath)
        process.environment = ProcessInfo.processInfo.environment
            .merging(request.environmentOverlay) { _, overlay in overlay }
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }

        do {
            try process.run()
        } catch {
            stdinPipe.fileHandleForWriting.closeIgnoringErrors()
            stdinPipe.fileHandleForReading.closeIgnoringErrors()
            return AgentHookRunResult(
                completion: .spawnFailed(message: error.localizedDescription),
                stdinWriteFailed: false
            )
        }

        // A hook that exits before reading stdin closes the pipe's read end;
        // request EPIPE instead of a process-wide SIGPIPE for that write.
        let writeHandle = stdinPipe.fileHandleForWriting
        _ = fcntl(writeHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
        var stdinWriteFailed = false
        do {
            try writeHandle.write(contentsOf: request.stdinData)
        } catch {
            stdinWriteFailed = true
        }
        writeHandle.closeIgnoringErrors()

        let completion: AgentHookRunResult.Completion
        switch exitSemaphore.wait(timeout: .now() + request.executionTimeout) {
        case .success:
            completion = .exited(code: process.terminationStatus)
        case .timedOut:
            kill(process.processIdentifier, SIGTERM)
            switch exitSemaphore.wait(timeout: .now() + request.terminationGracePeriod) {
            case .success:
                completion = .timedOut(didForceKill: false)
            case .timedOut:
                kill(process.processIdentifier, SIGKILL)
                // SIGKILL cannot be caught; the exit normally arrives
                // promptly, but the wait stays bounded regardless.
                _ = exitSemaphore.wait(timeout: .now() + Self.postKillReapTimeout)
                completion = .timedOut(didForceKill: true)
            }
        }
        stdinPipe.fileHandleForReading.closeIgnoringErrors()
        return AgentHookRunResult(completion: completion, stdinWriteFailed: stdinWriteFailed)
    }
}

private extension FileHandle {
    func closeIgnoringErrors() {
        try? close()
    }
}

/// Dispatches normalized managed-session hook events to the user-configured
/// executable. Invocations for one session run strictly in order; different
/// sessions run concurrently up to a global process limit. Enqueueing never
/// blocks the main actor: execution happens in per-session drain tasks that
/// await the off-main process runner.
@MainActor
final class AgentHookDispatcher {
    static let defaultExecutionTimeout: TimeInterval = 10
    static let defaultTerminationGracePeriod: TimeInterval = 1
    static let maximumQueuedEventsPerSession = 8
    static let defaultMaximumConcurrentProcesses = 4

    private struct PendingInvocation {
        let event: AgentHookEvent
        let scriptPath: String
    }

    private struct SessionQueue {
        var pending: [PendingInvocation] = []
        var drainToken: UUID?
        var hasSeenStop = false
    }

    private let socketPath: String
    private let cliExecutablePath: String?
    private let runner: any AgentHookProcessRunning
    private let fileManager: FileManager
    private let executionTimeout: TimeInterval
    private let terminationGracePeriod: TimeInterval
    private let maximumConcurrentProcesses: Int

    private(set) var scriptPath: String?
    private var queuesBySessionID: [String: SessionQueue] = [:]
    private var availableProcessSlots: Int
    private var processSlotWaiters: [CheckedContinuation<Void, Never>] = []
    private var loggedLaunchFailureKeys: Set<String> = []
    private var runningProcessCount = 0
    private(set) var peakConcurrentProcessCountForTesting = 0

    init(
        socketPath: String,
        cliExecutablePath: String?,
        scriptPath: String? = nil,
        runner: any AgentHookProcessRunning = AgentHookLiveProcessRunner(),
        fileManager: FileManager = .default,
        executionTimeout: TimeInterval = AgentHookDispatcher.defaultExecutionTimeout,
        terminationGracePeriod: TimeInterval = AgentHookDispatcher.defaultTerminationGracePeriod,
        maximumConcurrentProcesses: Int = AgentHookDispatcher.defaultMaximumConcurrentProcesses
    ) {
        self.socketPath = socketPath
        self.cliExecutablePath = cliExecutablePath
        self.scriptPath = Self.normalizedScriptPath(scriptPath)
        self.runner = runner
        self.fileManager = fileManager
        self.executionTimeout = executionTimeout
        self.terminationGracePeriod = terminationGracePeriod
        self.maximumConcurrentProcesses = max(1, maximumConcurrentProcesses)
        availableProcessSlots = max(1, maximumConcurrentProcesses)
    }

    var isEnabled: Bool {
        scriptPath != nil
    }

    /// Applies a configured script path. Only newly enqueued events observe
    /// the change; queued and running invocations keep their captured path.
    func updateScriptPath(_ path: String?) {
        let normalized = Self.normalizedScriptPath(path)
        guard normalized != scriptPath else { return }
        scriptPath = normalized
        loggedLaunchFailureKeys.removeAll()
    }

    func enqueue(_ event: AgentHookEvent) {
        guard let scriptPath else { return }

        var queue = queuesBySessionID[event.sessionID] ?? SessionQueue()
        switch event.kind {
        case .sessionStart:
            // A reused session ID begins a new lifecycle.
            makeRoomForLifecycleEvent(&queue, incomingEvent: event)
            queue.hasSeenStop = false
            queue.pending.append(PendingInvocation(event: event, scriptPath: scriptPath))

        case .sessionStop:
            guard queue.hasSeenStop == false else {
                logDroppedEvent(event, reason: "duplicate_session_stop")
                return
            }
            queue.hasSeenStop = true
            makeRoomForLifecycleEvent(&queue, incomingEvent: event)
            queue.pending.append(PendingInvocation(event: event, scriptPath: scriptPath))

        case .turnComplete, .needsApproval, .sessionError:
            guard queue.hasSeenStop == false else {
                logDroppedEvent(event, reason: "session_already_stopped")
                return
            }
            guard queue.pending.count < Self.maximumQueuedEventsPerSession else {
                logDroppedEvent(event, reason: "queue_full")
                return
            }
            queue.pending.append(PendingInvocation(event: event, scriptPath: scriptPath))
        }

        queuesBySessionID[event.sessionID] = queue
        ensureDraining(sessionID: event.sessionID)
    }

    /// Lifecycle events take priority over queued status updates. A sustained
    /// lifecycle-only flood still cannot grow memory without bound: once all
    /// eight waiting slots contain lifecycle events, the oldest one is evicted
    /// in favor of the newest lifecycle state and the loss is logged.
    private func makeRoomForLifecycleEvent(
        _ queue: inout SessionQueue,
        incomingEvent: AgentHookEvent
    ) {
        while queue.pending.count >= Self.maximumQueuedEventsPerSession {
            if let oldestStatusIndex = queue.pending.firstIndex(where: { $0.event.kind.isStatusEvent }) {
                logDroppedEvent(
                    queue.pending[oldestStatusIndex].event,
                    reason: "queue_full_evicted_status_for_\(incomingEvent.kind.rawValue)"
                )
                queue.pending.remove(at: oldestStatusIndex)
            } else {
                let evicted = queue.pending.removeFirst()
                logDroppedEvent(
                    evicted.event,
                    reason: "queue_full_evicted_oldest_lifecycle_for_\(incomingEvent.kind.rawValue)"
                )
            }
        }
    }

    var queuedSessionIDsForTesting: Set<String> {
        Set(queuesBySessionID.keys)
    }

    func queuedEventCountForTesting(sessionID: String) -> Int {
        queuesBySessionID[sessionID]?.pending.count ?? 0
    }

    /// Issue message for a configured-but-unusable hook path, for config
    /// reload warning UI. Returns nil when the path is nil or usable.
    static func configuredScriptPathIssue(
        _ path: String?,
        fileManager: FileManager = .default
    ) -> String? {
        guard let path = normalizedScriptPath(path) else { return nil }
        switch validate(scriptPath: path, fileManager: fileManager) {
        case nil, .spawnFailed:
            return nil
        case .missing:
            return "Agent hook script does not exist: \(path)"
        case .notAFile:
            return "Agent hook script is not a regular file: \(path)"
        case .notExecutable:
            return "Agent hook script is not executable: \(path)"
        }
    }

    // MARK: - Draining

    private func ensureDraining(sessionID: String) {
        guard var queue = queuesBySessionID[sessionID], queue.drainToken == nil else { return }
        let token = UUID()
        queue.drainToken = token
        queuesBySessionID[sessionID] = queue
        Task { [weak self] in
            await self?.drainQueue(sessionID: sessionID, token: token)
        }
    }

    private func drainQueue(sessionID: String, token: UUID) async {
        while queueHasPendingInvocation(sessionID: sessionID, token: token) {
            await acquireProcessSlot()
            guard let next = dequeueNextInvocation(sessionID: sessionID, token: token) else {
                releaseProcessSlot()
                break
            }
            runningProcessCount += 1
            peakConcurrentProcessCountForTesting = max(
                peakConcurrentProcessCountForTesting,
                runningProcessCount
            )
            await execute(next)
            runningProcessCount -= 1
            releaseProcessSlot()
        }
        finishDraining(sessionID: sessionID, token: token)
    }

    private func queueHasPendingInvocation(sessionID: String, token: UUID) -> Bool {
        guard let queue = queuesBySessionID[sessionID], queue.drainToken == token else {
            return false
        }
        return queue.pending.isEmpty == false
    }

    private func dequeueNextInvocation(sessionID: String, token: UUID) -> PendingInvocation? {
        guard var queue = queuesBySessionID[sessionID],
              queue.drainToken == token,
              queue.pending.isEmpty == false else {
            return nil
        }
        let next = queue.pending.removeFirst()
        queuesBySessionID[sessionID] = queue
        return next
    }

    private func finishDraining(sessionID: String, token: UUID) {
        guard let queue = queuesBySessionID[sessionID], queue.drainToken == token else { return }
        queuesBySessionID.removeValue(forKey: sessionID)
    }

    private func acquireProcessSlot() async {
        if availableProcessSlots > 0 {
            availableProcessSlots -= 1
            return
        }
        await withCheckedContinuation { continuation in
            processSlotWaiters.append(continuation)
        }
    }

    private func releaseProcessSlot() {
        if processSlotWaiters.isEmpty == false {
            processSlotWaiters.removeFirst().resume()
        } else {
            availableProcessSlots += 1
        }
    }

    // MARK: - Execution

    private func execute(_ invocation: PendingInvocation) async {
        if let failureKind = Self.validate(
            scriptPath: invocation.scriptPath,
            fileManager: fileManager
        ) {
            logLaunchFailureOnce(
                kind: failureKind,
                scriptPath: invocation.scriptPath,
                event: invocation.event
            )
            return
        }

        let stdinData: Data
        do {
            stdinData = try invocation.event.jsonData()
        } catch {
            ToasttyLog.error(
                "Failed to encode agent hook event payload",
                category: .automation,
                metadata: [
                    "event": invocation.event.kind.rawValue,
                    "session_id": invocation.event.sessionID,
                    "error": error.localizedDescription,
                ]
            )
            return
        }

        ToasttyLog.debug(
            "Invoking agent hook",
            category: .automation,
            metadata: hookMetadata(for: invocation)
        )
        let result = await runner.run(
            AgentHookInvocationRequest(
                scriptPath: invocation.scriptPath,
                stdinData: stdinData,
                environmentOverlay: environmentOverlay(for: invocation.event),
                executionTimeout: executionTimeout,
                terminationGracePeriod: terminationGracePeriod
            )
        )
        logResult(result, for: invocation)
    }

    func environmentOverlay(for event: AgentHookEvent) -> [String: String] {
        [
            "TOASTTY_HOOK_SCHEMA_VERSION": String(AgentHookEvent.schemaVersion),
            "TOASTTY_HOOK_EVENT": event.kind.rawValue,
            ToasttyLaunchContextEnvironment.agentKey: event.agent.rawValue,
            ToasttyLaunchContextEnvironment.sessionIDKey: event.sessionID,
            "TOASTTY_WORKSPACE_ID": event.workspaceID.uuidString,
            ToasttyLaunchContextEnvironment.panelIDKey: event.panelID.uuidString,
            "TOASTTY_SESSION_CWD": event.cwd ?? "",
            ToasttyLaunchContextEnvironment.cliPathKey: cliExecutablePath ?? "",
            ToasttyLaunchContextEnvironment.socketPathKey: socketPath,
            ToasttyLaunchContextEnvironment.launchReasonKey: event.launchReason?.rawValue ?? "",
        ]
    }

    // MARK: - Validation and logging

    private enum LaunchFailureKind: String {
        case missing
        case notAFile = "not_a_file"
        case notExecutable = "not_executable"
        case spawnFailed = "spawn_failed"
    }

    private static func validate(
        scriptPath: String,
        fileManager: FileManager
    ) -> LaunchFailureKind? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: scriptPath, isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue == false else {
            return .notAFile
        }
        guard fileManager.isExecutableFile(atPath: scriptPath) else {
            return .notExecutable
        }
        return nil
    }

    private static func normalizedScriptPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    private func logLaunchFailureOnce(
        kind: LaunchFailureKind,
        scriptPath: String,
        event: AgentHookEvent
    ) {
        let key = "\(scriptPath)|\(kind.rawValue)"
        guard loggedLaunchFailureKeys.contains(key) == false else { return }
        loggedLaunchFailureKeys.insert(key)
        ToasttyLog.warning(
            "Agent hook script cannot be launched",
            category: .automation,
            metadata: [
                "script_path": scriptPath,
                "failure": kind.rawValue,
                "event": event.kind.rawValue,
                "session_id": event.sessionID,
            ]
        )
    }

    private func logResult(_ result: AgentHookRunResult, for invocation: PendingInvocation) {
        if result.stdinWriteFailed {
            ToasttyLog.warning(
                "Agent hook closed stdin before reading the event payload",
                category: .automation,
                metadata: hookMetadata(for: invocation)
            )
        }

        switch result.completion {
        case .exited(let code):
            if code == 0 {
                ToasttyLog.debug(
                    "Agent hook completed",
                    category: .automation,
                    metadata: hookMetadata(for: invocation)
                )
            } else {
                ToasttyLog.warning(
                    "Agent hook exited with a nonzero status",
                    category: .automation,
                    metadata: hookMetadata(for: invocation, additional: [
                        "exit_code": String(code),
                    ])
                )
            }
        case .timedOut(let didForceKill):
            ToasttyLog.warning(
                "Agent hook timed out",
                category: .automation,
                metadata: hookMetadata(for: invocation, additional: [
                    "timeout_seconds": String(executionTimeout),
                    "escalated_to_sigkill": didForceKill ? "true" : "false",
                ])
            )
        case .spawnFailed:
            logLaunchFailureOnce(
                kind: .spawnFailed,
                scriptPath: invocation.scriptPath,
                event: invocation.event
            )
        }
    }

    private func logDroppedEvent(_ event: AgentHookEvent, reason: String) {
        ToasttyLog.warning(
            "Dropped agent hook event",
            category: .automation,
            metadata: [
                "event": event.kind.rawValue,
                "session_id": event.sessionID,
                "reason": reason,
            ]
        )
    }

    private func hookMetadata(
        for invocation: PendingInvocation,
        additional: [String: String] = [:]
    ) -> [String: String] {
        var metadata = [
            "script_path": invocation.scriptPath,
            "event": invocation.event.kind.rawValue,
            "session_id": invocation.event.sessionID,
            "agent": invocation.event.agent.rawValue,
        ]
        for (key, value) in additional {
            metadata[key] = value
        }
        return metadata
    }
}

private extension AgentHookEventKind {
    var isStatusEvent: Bool {
        switch self {
        case .turnComplete, .needsApproval, .sessionError:
            return true
        case .sessionStart, .sessionStop:
            return false
        }
    }
}
