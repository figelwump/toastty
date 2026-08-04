import CoreState
import Foundation

enum CodexSessionLogContextField: Equatable, Sendable {
    case unspecified
    case null
    case string(String)

    var stringValue: String? {
        switch self {
        case .unspecified, .null:
            return nil
        case .string(let value):
            return value
        }
    }

    var isSpecified: Bool {
        switch self {
        case .unspecified:
            return false
        case .null, .string:
            return true
        }
    }

    var metadataValue: String {
        switch self {
        case .unspecified:
            return "unspecified"
        case .null:
            return "null"
        case .string(let value):
            return value
        }
    }
}

/// Newer Codex builds encrypt inter-agent message content, so rollout
/// `spawn_agent` arguments and hook `tool_input` payloads can carry an opaque
/// Fernet-style token instead of task text. Detect those tokens so ciphertext
/// is never shown as a subagent label or description.
func isLikelyEncryptedCodexAgentPayload(_ value: String) -> Bool {
    var candidate = Substring(value)
    if candidate.hasSuffix("...") {
        candidate = candidate.dropLast(3)
    }
    if candidate.hasPrefix("gAAAAA") {
        return true
    }
    guard candidate.count >= 64 else {
        return false
    }
    return candidate.allSatisfy { character in
        character.isASCII && (
            character.isLetter || character.isNumber ||
            character == "-" || character == "_" ||
            character == "+" || character == "/" || character == "="
        )
    }
}

struct CodexSessionLogEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case sessionConfigured
        case turnContextUpdated
        case turnStarted
        case historyUpdated
        case approvalNeeded
        case taskCompleted
        case turnAborted
        case backgroundActivityStarted
        case backgroundActivityFinished
    }

    let kind: Kind
    let detail: String
    let backgroundActivity: CodexSessionBackgroundActivity?
    let rootInputFingerprint: String?
    let rootThreadID: String?
    let rootTurnID: String?
    let completionThreadID: String?
    let completionTurnID: String?
    let nativeSessionID: String?
    let nativeSessionFilePath: String?
    let callID: String?
    let approvalID: String?
    let approvalPolicyField: CodexSessionLogContextField
    let approvalsReviewerField: CodexSessionLogContextField
    let approvalPolicy: String?
    let approvalsReviewer: String?

    init(
        kind: Kind,
        detail: String,
        backgroundActivity: CodexSessionBackgroundActivity? = nil,
        rootInputFingerprint: String? = nil,
        rootThreadID: String? = nil,
        rootTurnID: String? = nil,
        completionThreadID: String? = nil,
        completionTurnID: String? = nil,
        nativeSessionID: String? = nil,
        nativeSessionFilePath: String? = nil,
        callID: String? = nil,
        approvalID: String? = nil,
        approvalPolicyField: CodexSessionLogContextField? = nil,
        approvalsReviewerField: CodexSessionLogContextField? = nil,
        approvalPolicy: String? = nil,
        approvalsReviewer: String? = nil
    ) {
        let resolvedApprovalPolicyField = approvalPolicyField
            ?? approvalPolicy.map(CodexSessionLogContextField.string)
            ?? .unspecified
        let resolvedApprovalsReviewerField = approvalsReviewerField
            ?? approvalsReviewer.map(CodexSessionLogContextField.string)
            ?? .unspecified

        self.kind = kind
        self.detail = detail
        self.backgroundActivity = backgroundActivity
        self.rootInputFingerprint = rootInputFingerprint
        self.rootThreadID = rootThreadID
        self.rootTurnID = rootTurnID
        self.completionThreadID = completionThreadID
        self.completionTurnID = completionTurnID
        self.nativeSessionID = nativeSessionID
        self.nativeSessionFilePath = nativeSessionFilePath
        self.callID = callID
        self.approvalID = approvalID
        self.approvalPolicyField = resolvedApprovalPolicyField
        self.approvalsReviewerField = resolvedApprovalsReviewerField
        self.approvalPolicy = resolvedApprovalPolicyField.stringValue
        self.approvalsReviewer = resolvedApprovalsReviewerField.stringValue
    }

    var hasRootTurnContext: Bool {
        rootInputFingerprint != nil ||
            rootThreadID != nil ||
            rootTurnID != nil ||
            approvalPolicyField.isSpecified ||
            approvalsReviewerField.isSpecified
    }
}

struct CodexSessionBackgroundActivity: Equatable, Sendable {
    enum TurnTransition: Equatable, Sendable {
        case activated
        case deactivated
    }

    let activityID: String
    let hookActivityID: String?
    let spawnToolUseID: String?
    let kind: SessionBackgroundActivityKind
    let displayName: String?
    let command: String?
    let turnTransition: TurnTransition?

    init(
        activityID: String,
        hookActivityID: String? = nil,
        spawnToolUseID: String? = nil,
        kind: SessionBackgroundActivityKind,
        displayName: String? = nil,
        command: String? = nil,
        turnTransition: TurnTransition? = nil
    ) {
        self.activityID = activityID
        self.hookActivityID = hookActivityID
        self.spawnToolUseID = spawnToolUseID
        self.kind = kind
        self.displayName = displayName
        self.command = command
        self.turnTransition = turnTransition
    }
}

private struct CodexMultiAgentPendingCall: Sendable {
    var toolName: String
    var argumentsJSONString: String?
}

private struct CodexMultiAgentPendingCalls: Sendable {
    private var callsByID: [String: CodexMultiAgentPendingCall] = [:]
    private var orderedCallIDs: [String] = []
    private var recentlyResolvedCallsByID: [String: CodexMultiAgentPendingCall] = [:]
    private var orderedResolvedCallIDs: [String] = []

    mutating func store(callID: String, call: CodexMultiAgentPendingCall) {
        if callsByID[callID] != nil {
            orderedCallIDs.removeAll { $0 == callID }
        }
        if recentlyResolvedCallsByID.removeValue(forKey: callID) != nil {
            orderedResolvedCallIDs.removeAll { $0 == callID }
        }
        callsByID[callID] = call
        orderedCallIDs.append(callID)
        trimPendingCallsToLimit()
    }

    mutating func resolve(callID: String) -> CodexMultiAgentPendingCall? {
        guard let call = callsByID.removeValue(forKey: callID) else {
            return nil
        }
        orderedCallIDs.removeAll { $0 == callID }
        recentlyResolvedCallsByID[callID] = call
        orderedResolvedCallIDs.append(callID)
        trimResolvedCallsToLimit()
        return call
    }

    func peek(callID: String) -> CodexMultiAgentPendingCall? {
        callsByID[callID] ?? recentlyResolvedCallsByID[callID]
    }

    private mutating func trimPendingCallsToLimit() {
        while callsByID.count > Self.limit, let oldestCallID = orderedCallIDs.first {
            orderedCallIDs.removeFirst()
            callsByID.removeValue(forKey: oldestCallID)
        }
    }

    private mutating func trimResolvedCallsToLimit() {
        while recentlyResolvedCallsByID.count > Self.limit,
              let oldestCallID = orderedResolvedCallIDs.first {
            orderedResolvedCallIDs.removeFirst()
            recentlyResolvedCallsByID.removeValue(forKey: oldestCallID)
        }
    }

    private static let limit = 64
}

struct CodexSessionLogFileIdentity: Equatable, Sendable {
    let deviceNumber: UInt64
    let fileNumber: UInt64
}

struct CodexSessionLogCursor: Equatable, Sendable {
    let fileIdentity: CodexSessionLogFileIdentity?
    let completeLineOffset: UInt64
    let lastCompleteLineHash: UInt64
    let lastCompleteLineByteCount: UInt64
}

/// Reference storage avoids copying the stream-local dedupe set whenever the
/// runtime cursor advances. Watcher replacement is serialized by
/// `ManagedAgentLaunchPlanner`, so the cursor checkpoint and active parser have
/// one logical owner even though both retain this storage. Fixed-size dual
/// fingerprints avoid retaining complete log lines, and a high-water ceiling
/// fails open rather than turning memory pressure into lost session updates.
private final class CodexSessionLogSeenKeys: @unchecked Sendable {
    private struct Fingerprint: Hashable {
        let primary: UInt64
        let secondary: UInt64
    }

    private let lock = NSLock()
    private let capacity: Int
    private let onCapacityExceeded: @Sendable (Int) -> Void
    private var storage: Set<Fingerprint> = []
    private var didReportCapacityExceeded = false

    init(
        capacity: Int,
        onCapacityExceeded: @escaping @Sendable (Int) -> Void
    ) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.onCapacityExceeded = onCapacityExceeded
    }

    @discardableResult
    func insertIfAbsent(_ key: String) -> Bool {
        let fingerprint = Self.fingerprint(for: key)
        var shouldReportCapacityExceeded = false

        lock.lock()
        if storage.contains(fingerprint) {
            lock.unlock()
            return false
        }
        if storage.count >= capacity {
            if didReportCapacityExceeded == false {
                didReportCapacityExceeded = true
                shouldReportCapacityExceeded = true
            }
            lock.unlock()
            if shouldReportCapacityExceeded {
                onCapacityExceeded(capacity)
            }
            // Preserve already tracked duplicate protection without allowing
            // the set to grow. New observations continue fail-open so memory
            // pressure cannot suppress all later session updates.
            return true
        }
        storage.insert(fingerprint)
        lock.unlock()
        return true
    }

    func reset() {
        lock.lock()
        storage.removeAll(keepingCapacity: false)
        didReportCapacityExceeded = false
        lock.unlock()
    }

    var trackedKeyCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    private static func fingerprint(for key: String) -> Fingerprint {
        var primary: UInt64 = 14_695_981_039_346_656_037
        var secondary: UInt64 = 5_381
        for byte in key.utf8 {
            primary ^= UInt64(byte)
            primary &*= 1_099_511_628_211
            secondary = ((secondary << 5) &+ secondary) ^ UInt64(byte)
        }
        return Fingerprint(primary: primary, secondary: secondary)
    }
}

private struct CodexSessionLogParserState: Sendable {
    var seenKeys: CodexSessionLogSeenKeys
    var sessionTopLevelApprovalsReviewer: CodexSessionLogContextField = .unspecified
    var pendingMultiAgentCalls = CodexMultiAgentPendingCalls()

    init(
        seenKeyCapacity: Int,
        onSeenKeyCapacityExceeded: @escaping @Sendable (Int) -> Void
    ) {
        seenKeys = CodexSessionLogSeenKeys(
            capacity: seenKeyCapacity,
            onCapacityExceeded: onSeenKeyCapacityExceeded
        )
    }

    mutating func reset() {
        seenKeys.reset()
        sessionTopLevelApprovalsReviewer = .unspecified
        pendingMultiAgentCalls = CodexMultiAgentPendingCalls()
    }
}

private struct CodexSessionLogCheckpoint: Sendable {
    let cursor: CodexSessionLogCursor
    let parserState: CodexSessionLogParserState
}

/// Runtime-only checkpoint retained by the App while one managed session owns
/// a particular log stream. The parser state travels with the byte cursor so a
/// watcher recreation behaves like one continuous watcher without replaying
/// earlier lines or losing source-local parsing context.
final class CodexSessionLogCursorState: @unchecked Sendable {
    private let lock = NSLock()
    private var checkpoint: CodexSessionLogCheckpoint?

    fileprivate func snapshot() -> CodexSessionLogCheckpoint? {
        lock.lock()
        defer { lock.unlock() }
        return checkpoint
    }

    fileprivate func store(_ checkpoint: CodexSessionLogCheckpoint) {
        lock.lock()
        defer { lock.unlock() }
        self.checkpoint = checkpoint
    }

    fileprivate func reset() {
        lock.lock()
        defer { lock.unlock() }
        checkpoint = nil
    }

    var cursorForTesting: CodexSessionLogCursor? {
        snapshot()?.cursor
    }

    var trackedSeenKeyCountForTesting: Int {
        snapshot()?.parserState.seenKeys.trackedKeyCountForTesting ?? 0
    }

    var seenKeysObjectForTesting: AnyObject? {
        snapshot()?.parserState.seenKeys
    }
}

private struct CodexSessionLogFileSnapshot {
    let byteCount: UInt64
    let identity: CodexSessionLogFileIdentity?
}

private struct CodexSessionLogReaderState {
    var handle: FileHandle?
    var isInitialized = false
    var fileIdentity: CodexSessionLogFileIdentity?
    var readOffset: UInt64 = 0
    var completeLineOffset: UInt64 = 0
    var lastCompleteLineHash: UInt64?
    var lastCompleteLineByteCount: UInt64?

    var cursor: CodexSessionLogCursor? {
        guard completeLineOffset > 0,
              let lastCompleteLineHash,
              let lastCompleteLineByteCount else {
            return nil
        }
        return CodexSessionLogCursor(
            fileIdentity: fileIdentity,
            completeLineOffset: completeLineOffset,
            lastCompleteLineHash: lastCompleteLineHash,
            lastCompleteLineByteCount: lastCompleteLineByteCount
        )
    }

    mutating func resume(
        from cursor: CodexSessionLogCursor,
        fileIdentity: CodexSessionLogFileIdentity?
    ) {
        isInitialized = true
        self.fileIdentity = fileIdentity
        readOffset = cursor.completeLineOffset
        completeLineOffset = cursor.completeLineOffset
        lastCompleteLineHash = cursor.lastCompleteLineHash
        lastCompleteLineByteCount = cursor.lastCompleteLineByteCount
    }

    mutating func restart(fileIdentity: CodexSessionLogFileIdentity?) {
        CodexSessionLogWatcher.close(&handle)
        isInitialized = true
        self.fileIdentity = fileIdentity
        readOffset = 0
        completeLineOffset = 0
        lastCompleteLineHash = nil
        lastCompleteLineByteCount = nil
    }
}

private struct CodexSessionLogConsumedLines {
    let byteCount: UInt64
    let lastLineHash: UInt64
    let lastLineByteCount: UInt64
}

private enum CodexSessionLogReadResult {
    case data(Data)
    case discardIncompleteRemainder
    case restartFromZero
}

final class CodexSessionLogWatcher {
    typealias EventHandler = @Sendable (CodexSessionLogEvent) async -> Void

    static let maximumTrackedSeenKeyCount = 65_536

    private let logURL: URL
    private let pollIntervalNanoseconds: UInt64
    private let eventHandler: EventHandler
    private let cursorState: CodexSessionLogCursorState
    private let seenKeyCapacity: Int
    private let onSeenKeyCapacityExceeded: @Sendable (Int) -> Void
    // Ignore multi-agent lifecycle entries recorded before this instant.
    // Rollout files can be re-claimed across launches (workspace restore),
    // and replaying pre-launch spawns would resurrect dead collab agents.
    private let multiAgentEventCutoff: Date?
    private var task: Task<Void, Never>?

    init(
        logURL: URL,
        pollIntervalNanoseconds: UInt64 = 250_000_000,
        multiAgentEventCutoff: Date? = nil,
        cursorState: CodexSessionLogCursorState = CodexSessionLogCursorState(),
        seenKeyCapacity: Int = CodexSessionLogWatcher.maximumTrackedSeenKeyCount,
        onSeenKeyCapacityExceeded: (@Sendable (Int) -> Void)? = nil,
        eventHandler: @escaping EventHandler
    ) {
        precondition(seenKeyCapacity > 0)
        self.logURL = logURL
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.multiAgentEventCutoff = multiAgentEventCutoff
        self.cursorState = cursorState
        self.seenKeyCapacity = seenKeyCapacity
        self.onSeenKeyCapacityExceeded = onSeenKeyCapacityExceeded ?? { capacity in
            ToasttyLog.warning(
                "Codex session log dedupe capacity reached",
                category: .terminal,
                metadata: [
                    "capacity": String(capacity),
                    "degradation": "fail_open",
                    "stream_file": logURL.lastPathComponent,
                ]
            )
        }
        self.eventHandler = eventHandler
    }

    @MainActor
    func start() {
        guard task == nil else { return }
        task = Self.makePollingTask(
            logURL: logURL,
            pollIntervalNanoseconds: pollIntervalNanoseconds,
            multiAgentEventCutoff: multiAgentEventCutoff,
            cursorState: cursorState,
            seenKeyCapacity: seenKeyCapacity,
            onSeenKeyCapacityExceeded: onSeenKeyCapacityExceeded,
            eventHandler: eventHandler
        )
    }

    @MainActor
    func stop() async {
        guard let currentTask = task else { return }
        currentTask.cancel()
        _ = await currentTask.result
        task = nil
    }
}

private extension CodexSessionLogWatcher {
    static func makePollingTask(
        logURL: URL,
        pollIntervalNanoseconds: UInt64,
        multiAgentEventCutoff: Date? = nil,
        cursorState: CodexSessionLogCursorState,
        seenKeyCapacity: Int,
        onSeenKeyCapacityExceeded: @escaping @Sendable (Int) -> Void,
        eventHandler: @escaping EventHandler
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            var readerState = CodexSessionLogReaderState()
            var bufferedRemainder = Data()
            var parserState = CodexSessionLogParserState(
                seenKeyCapacity: seenKeyCapacity,
                onSeenKeyCapacityExceeded: onSeenKeyCapacityExceeded
            )
            defer { close(&readerState.handle) }

            while true {
                await Self.drainAvailableDeltas(
                    from: logURL,
                    readerState: &readerState,
                    bufferedRemainder: &bufferedRemainder,
                    parserState: &parserState,
                    cursorState: cursorState,
                    multiAgentEventCutoff: multiAgentEventCutoff,
                    eventHandler: eventHandler
                )

                if Task.isCancelled {
                    // The terminal process can exit immediately after Codex writes
                    // its final completion/abort event. Drain the file one last time
                    // before teardown so we do not lose that last status update.
                    await Self.drainAvailableDeltas(
                        from: logURL,
                        readerState: &readerState,
                        bufferedRemainder: &bufferedRemainder,
                        parserState: &parserState,
                        cursorState: cursorState,
                        multiAgentEventCutoff: multiAgentEventCutoff,
                        eventHandler: eventHandler
                    )
                    break
                }

                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
        }
    }

    static func drainAvailableDeltas(
        from logURL: URL,
        readerState: inout CodexSessionLogReaderState,
        bufferedRemainder: inout Data,
        parserState: inout CodexSessionLogParserState,
        cursorState: CodexSessionLogCursorState,
        multiAgentEventCutoff: Date? = nil,
        eventHandler: @escaping EventHandler
    ) async {
        guard prepareReaderIfNeeded(
            for: logURL,
            readerState: &readerState,
            bufferedRemainder: &bufferedRemainder,
            parserState: &parserState,
            cursorState: cursorState
        ) else {
            return
        }

        while let result = readDelta(from: logURL, readerState: &readerState) {
            switch result {
            case .restartFromZero:
                bufferedRemainder.removeAll(keepingCapacity: true)
                parserState.reset()
                cursorState.reset()

            case .discardIncompleteRemainder:
                bufferedRemainder.removeAll(keepingCapacity: true)

            case .data(let delta):
                guard let consumedLines = await processDelta(
                    delta,
                    bufferedRemainder: &bufferedRemainder,
                    seenKeys: parserState.seenKeys,
                    sessionTopLevelApprovalsReviewer: &parserState.sessionTopLevelApprovalsReviewer,
                    pendingMultiAgentCalls: &parserState.pendingMultiAgentCalls,
                    multiAgentEventCutoff: multiAgentEventCutoff,
                    eventHandler: eventHandler
                ) else {
                    continue
                }
                readerState.completeLineOffset += consumedLines.byteCount
                readerState.lastCompleteLineHash = consumedLines.lastLineHash
                readerState.lastCompleteLineByteCount = consumedLines.lastLineByteCount
                if let cursor = readerState.cursor {
                    cursorState.store(CodexSessionLogCheckpoint(
                        cursor: cursor,
                        parserState: parserState
                    ))
                }
            }
        }
    }

    static func processDelta(
        _ delta: Data,
        bufferedRemainder: inout Data,
        seenKeys: CodexSessionLogSeenKeys,
        sessionTopLevelApprovalsReviewer: inout CodexSessionLogContextField,
        pendingMultiAgentCalls: inout CodexMultiAgentPendingCalls,
        multiAgentEventCutoff: Date? = nil,
        eventHandler: @escaping EventHandler
    ) async -> CodexSessionLogConsumedLines? {
        guard delta.isEmpty == false else {
            return nil
        }

        bufferedRemainder.append(delta)
        var pendingHistoryUpdate: CodexSessionLogEvent?
        var consumedByteCount: UInt64 = 0
        var lastLineHash: UInt64?
        var lastLineByteCount: UInt64?

        while let newlineIndex = bufferedRemainder.firstIndex(of: newlineByte) {
            let lineData = Data(bufferedRemainder.prefix(upTo: newlineIndex))
            bufferedRemainder.removeSubrange(...newlineIndex)
            consumedByteCount += UInt64(lineData.count) + 1
            lastLineHash = completeLineHash(lineData)
            lastLineByteCount = UInt64(lineData.count)
            let events = parse(
                lineData: lineData,
                seenKeys: seenKeys,
                sessionTopLevelApprovalsReviewer: &sessionTopLevelApprovalsReviewer,
                pendingMultiAgentCalls: &pendingMultiAgentCalls,
                multiAgentEventCutoff: multiAgentEventCutoff
            )
            guard events.isEmpty == false else {
                continue
            }

            for event in events {
                if event.kind == .historyUpdated {
                    pendingHistoryUpdate = event
                    continue
                }

                if event.kind != .turnStarted,
                   let coalescedHistoryUpdate = pendingHistoryUpdate {
                    await eventHandler(coalescedHistoryUpdate)
                    pendingHistoryUpdate = nil
                }

                await eventHandler(event)
            }
        }

        if let pendingHistoryUpdate {
            await eventHandler(pendingHistoryUpdate)
        }

        guard let lastLineHash,
              let lastLineByteCount else {
            return nil
        }
        return CodexSessionLogConsumedLines(
            byteCount: consumedByteCount,
            lastLineHash: lastLineHash,
            lastLineByteCount: lastLineByteCount
        )
    }

    static func prepareReaderIfNeeded(
        for logURL: URL,
        readerState: inout CodexSessionLogReaderState,
        bufferedRemainder: inout Data,
        parserState: inout CodexSessionLogParserState,
        cursorState: CodexSessionLogCursorState
    ) -> Bool {
        guard readerState.isInitialized == false else {
            return true
        }
        guard let fileSnapshot = fileSnapshot(at: logURL) else {
            return false
        }

        if let checkpoint = cursorState.snapshot(),
           cursor(checkpoint.cursor, matches: fileSnapshot, at: logURL) {
            readerState.resume(
                from: checkpoint.cursor,
                fileIdentity: fileSnapshot.identity ?? checkpoint.cursor.fileIdentity
            )
            parserState = checkpoint.parserState
            return true
        }

        cursorState.reset()
        bufferedRemainder.removeAll(keepingCapacity: true)
        parserState.reset()
        readerState.restart(fileIdentity: fileSnapshot.identity)
        return true
    }

    static func readDelta(
        from logURL: URL,
        readerState: inout CodexSessionLogReaderState
    ) -> CodexSessionLogReadResult? {
        guard let fileSnapshot = fileSnapshot(at: logURL) else {
            close(&readerState.handle)
            return nil
        }

        if fileIdentitiesConflict(readerState.fileIdentity, fileSnapshot.identity) ||
            fileSnapshot.byteCount < readerState.completeLineOffset ||
            (readerState.cursor.map { cursor($0, matches: fileSnapshot, at: logURL) } == false) {
            readerState.restart(fileIdentity: fileSnapshot.identity)
            return .restartFromZero
        }

        if fileSnapshot.byteCount < readerState.readOffset {
            close(&readerState.handle)
            readerState.readOffset = readerState.completeLineOffset
            return .discardIncompleteRemainder
        }
        guard fileSnapshot.byteCount > readerState.readOffset else {
            return nil
        }

        if readerState.handle == nil {
            readerState.handle = try? FileHandle(forReadingFrom: logURL)
        }
        guard let fileHandle = readerState.handle else {
            return nil
        }

        do {
            try fileHandle.seek(toOffset: readerState.readOffset)
            let data = try fileHandle.readToEnd() ?? Data()
            readerState.readOffset += UInt64(data.count)
            return data.isEmpty ? nil : .data(data)
        } catch {
            close(&readerState.handle)
            return nil
        }
    }

    static func fileSnapshot(at logURL: URL) -> CodexSessionLogFileSnapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return nil
        }
        let identity: CodexSessionLogFileIdentity?
        if let deviceNumber = attributes[.systemNumber] as? NSNumber,
           let fileNumber = attributes[.systemFileNumber] as? NSNumber {
            identity = CodexSessionLogFileIdentity(
                deviceNumber: deviceNumber.uint64Value,
                fileNumber: fileNumber.uint64Value
            )
        } else {
            identity = nil
        }
        return CodexSessionLogFileSnapshot(
            byteCount: fileSize.uint64Value,
            identity: identity
        )
    }

    static func cursor(
        _ cursor: CodexSessionLogCursor,
        matches fileSnapshot: CodexSessionLogFileSnapshot,
        at logURL: URL
    ) -> Bool {
        guard fileIdentitiesConflict(cursor.fileIdentity, fileSnapshot.identity) == false,
              cursor.completeLineOffset <= fileSnapshot.byteCount,
              cursor.completeLineOffset > cursor.lastCompleteLineByteCount,
              cursor.lastCompleteLineByteCount < UInt64(Int.max) else {
            return false
        }

        let evidenceByteCount = Int(cursor.lastCompleteLineByteCount) + 1
        let evidenceOffset = cursor.completeLineOffset - UInt64(evidenceByteCount)
        guard let handle = try? FileHandle(forReadingFrom: logURL) else {
            return false
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: evidenceOffset)
            guard let evidence = try handle.read(upToCount: evidenceByteCount),
                  evidence.count == evidenceByteCount,
                  evidence.last == newlineByte else {
                return false
            }
            return completeLineHash(evidence.dropLast()) == cursor.lastCompleteLineHash
        } catch {
            return false
        }
    }

    static func completeLineHash<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    static func fileIdentitiesConflict(
        _ lhs: CodexSessionLogFileIdentity?,
        _ rhs: CodexSessionLogFileIdentity?
    ) -> Bool {
        guard let lhs, let rhs else {
            return false
        }
        return lhs != rhs
    }

    static func parse(
        lineData: Data,
        seenKeys: CodexSessionLogSeenKeys,
        sessionTopLevelApprovalsReviewer: inout CodexSessionLogContextField,
        pendingMultiAgentCalls: inout CodexMultiAgentPendingCalls,
        multiAgentEventCutoff: Date? = nil
    ) -> [CodexSessionLogEvent] {
        guard let normalizedLineData = normalizedJSONLineData(from: lineData),
              let object = try? JSONSerialization.jsonObject(with: normalizedLineData) as? [String: Any] else {
            return []
        }
        let fallbackLine = String(data: normalizedLineData, encoding: .utf8) ?? ""

        if let approvalsReviewer = topLevelDeveloperPermissionsApprovalsReviewer(from: object) {
            sessionTopLevelApprovalsReviewer = approvalsReviewer
            return []
        }

        if let event = parseTopLevelTurnContext(
            object: object,
            fallbackLine: fallbackLine,
            seenKeys: seenKeys,
            sessionTopLevelApprovalsReviewer: &sessionTopLevelApprovalsReviewer
        ) {
            return [event]
        }

        let collaborationEvents = parseCollaborationLifecycleEvent(
            object: object,
            seenKeys: seenKeys,
            pendingCalls: pendingMultiAgentCalls,
            multiAgentEventCutoff: multiAgentEventCutoff
        )
        if collaborationEvents.isEmpty == false {
            return collaborationEvents
        }

        let backgroundActivityEvents = parseMultiAgentResponseItem(
            object: object,
            fallbackLine: fallbackLine,
            seenKeys: seenKeys,
            pendingCalls: &pendingMultiAgentCalls,
            multiAgentEventCutoff: multiAgentEventCutoff
        )
        if backgroundActivityEvents.isEmpty == false {
            return backgroundActivityEvents
        }

        if let event = parseLegacyCodexEvent(
            object: object,
            fallbackLine: fallbackLine,
            seenKeys: seenKeys
        ) {
            return [event]
        }

        if let event = parseAppEvent(
            object: object,
            fallbackLine: fallbackLine,
            seenKeys: seenKeys
        ) {
            return [event]
        }

        if let event = parseHistoryInsertEvent(
            object: object,
            fallbackLine: fallbackLine,
            seenKeys: seenKeys
        ) {
            return [event]
        }

        if let event = parseOperationEvent(
            object: object,
            fallbackLine: fallbackLine,
            seenKeys: seenKeys
        ) {
            return [event]
        }
        return []
    }

    static func parseCollaborationLifecycleEvent(
        object: [String: Any],
        seenKeys: CodexSessionLogSeenKeys,
        pendingCalls: CodexMultiAgentPendingCalls,
        multiAgentEventCutoff: Date? = nil
    ) -> [CodexSessionLogEvent] {
        guard let payload = object["payload"] as? [String: Any],
              let payloadType = normalizedString(payload["type"]) else {
            return []
        }

        switch (normalizedString(object["type"]), payloadType) {
        case ("event_msg", "sub_agent_activity"):
            guard let agentPath = nonEmptyString(payload["agent_path"]),
                  isCurrentMultiAgentEvent(
                    object: object,
                    payload: payload,
                    cutoff: multiAgentEventCutoff
                  ) else {
                return []
            }
            let eventID = nonEmptyString(payload["event_id"])
                ?? "\(agentPath):\(normalizedString(payload["kind"]) ?? "unknown"):"
                    + "\(collaborationEventDate(object: object, payload: payload)?.timeIntervalSince1970 ?? 0)"
            guard seenKeys.insertIfAbsent("collaboration_activity:\(eventID)") else {
                return []
            }

            switch normalizedString(payload["kind"]) {
            case "started":
                let pendingCall = pendingCalls.peek(callID: eventID)
                let spawnArguments = pendingCall?.toolName == "spawn_agent"
                    ? jsonObject(fromJSONString: pendingCall?.argumentsJSONString)
                    : nil
                return [collaborationStartedEvent(
                    activityID: agentPath,
                    hookActivityID: nonEmptyString(payload["agent_thread_id"]),
                    spawnToolUseID: eventID,
                    displayName: spawnMetadataSummaryText(spawnArguments?["task_name"], limit: 80),
                    command: spawnMetadataSummaryText(spawnArguments?["message"], limit: 512)
                )]

            case "interrupted":
                let pendingCall = pendingCalls.peek(callID: eventID)
                guard pendingCall?.toolName == "interrupt_agent" else {
                    return [collaborationFinishedEvent(activityID: agentPath)]
                }
                return [collaborationFinishedEvent(
                    activityID: agentPath,
                    hookActivityID: nonEmptyString(payload["agent_thread_id"]),
                    turnTransition: .deactivated
                )]

            case "interacted":
                let pendingCall = pendingCalls.peek(callID: eventID)
                guard pendingCall?.toolName == "followup_task" else {
                    // Plain message delivery does not start a new agent turn.
                    return []
                }
                return [collaborationStartedEvent(
                    activityID: agentPath,
                    hookActivityID: nonEmptyString(payload["agent_thread_id"]),
                    turnTransition: .activated
                )]

            default:
                return []
            }

        case ("response_item", "agent_message"):
            guard isCurrentMultiAgentEvent(
                object: object,
                payload: payload,
                cutoff: multiAgentEventCutoff
            ), let messageType = collaborationMessageType(from: payload) else {
                return []
            }
            let timestamp = normalizedString(object["timestamp"]) ?? "unknown"
            switch messageType {
            case "NEW_TASK":
                guard let author = nonEmptyString(payload["author"]),
                      let recipient = nonEmptyString(payload["recipient"]),
                      collaborationParentPath(of: recipient) == author,
                      seenKeys.insertIfAbsent("collaboration_new_task:\(recipient):\(timestamp)") else {
                    return []
                }
                return [collaborationStartedEvent(activityID: recipient)]

            case "FINAL_ANSWER":
                guard let author = nonEmptyString(payload["author"]),
                      let recipient = nonEmptyString(payload["recipient"]),
                      collaborationParentPath(of: author) == recipient,
                      seenKeys.insertIfAbsent("collaboration_final_answer:\(author):\(timestamp)") else {
                    return []
                }
                return [collaborationFinishedEvent(activityID: author)]

            default:
                return []
            }

        default:
            return []
        }
    }

    static func isCurrentMultiAgentEvent(
        object: [String: Any],
        payload: [String: Any],
        cutoff: Date?
    ) -> Bool {
        guard let cutoff else {
            return true
        }
        guard let eventDate = collaborationEventDate(object: object, payload: payload) else {
            return false
        }
        return eventDate >= cutoff
    }

    static func collaborationEventDate(
        object: [String: Any],
        payload: [String: Any]
    ) -> Date? {
        if let occurredAtMilliseconds = payload["occurred_at_ms"] as? NSNumber {
            return Date(timeIntervalSince1970: occurredAtMilliseconds.doubleValue / 1_000)
        }
        return rolloutEntryDate(from: object)
    }

    static func collaborationAgentDisplayName(from agentPath: String) -> String {
        agentPath.split(separator: "/").last.map(String.init) ?? agentPath
    }

    static func collaborationParentPath(of agentPath: String) -> String? {
        let components = agentPath.split(separator: "/")
        guard components.count > 1 else { return nil }
        return "/" + components.dropLast().joined(separator: "/")
    }

    static func collaborationStartedEvent(
        activityID: String,
        hookActivityID: String? = nil,
        spawnToolUseID: String? = nil,
        displayName: String? = nil,
        command: String? = nil,
        turnTransition: CodexSessionBackgroundActivity.TurnTransition? = nil
    ) -> CodexSessionLogEvent {
        let resolvedDisplayName = displayName ?? collaborationAgentDisplayName(from: activityID)
        return CodexSessionLogEvent(
            kind: .backgroundActivityStarted,
            detail: "Started \(resolvedDisplayName)",
            backgroundActivity: CodexSessionBackgroundActivity(
                activityID: activityID,
                hookActivityID: hookActivityID,
                spawnToolUseID: spawnToolUseID,
                kind: .subagent,
                displayName: resolvedDisplayName,
                command: command,
                turnTransition: turnTransition
            )
        )
    }

    static func collaborationMessageType(from payload: [String: Any]) -> String? {
        guard let content = payload["content"] as? [[String: Any]] else {
            return nil
        }
        for item in content where normalizedString(item["type"]) == "input_text" {
            guard let text = item["text"] as? String,
                  let firstLine = text.split(separator: "\n", maxSplits: 1).first else {
                continue
            }
            let prefix = "Message Type:"
            guard firstLine.hasPrefix(prefix) else { continue }
            return firstLine.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func collaborationFinishedEvent(
        activityID: String,
        hookActivityID: String? = nil,
        turnTransition: CodexSessionBackgroundActivity.TurnTransition? = nil
    ) -> CodexSessionLogEvent {
        CodexSessionLogEvent(
            kind: .backgroundActivityFinished,
            detail: "Finished sub-agent",
            backgroundActivity: CodexSessionBackgroundActivity(
                activityID: activityID,
                hookActivityID: hookActivityID,
                kind: .subagent,
                turnTransition: turnTransition
            )
        )
    }

    static func parseMultiAgentResponseItem(
        object: [String: Any],
        fallbackLine: String,
        seenKeys: CodexSessionLogSeenKeys,
        pendingCalls: inout CodexMultiAgentPendingCalls,
        multiAgentEventCutoff: Date? = nil
    ) -> [CodexSessionLogEvent] {
        guard normalizedString(object["type"]) == "response_item",
              let payload = object["payload"] as? [String: Any],
              let type = normalizedString(payload["type"]) else {
            return []
        }
        if let multiAgentEventCutoff,
           let eventDate = rolloutEntryDate(from: object),
           eventDate < multiAgentEventCutoff {
            // Replayed history from before this managed session launched;
            // those collab agents died with their original process.
            return []
        }

        switch type {
        case "function_call":
            guard let callID = nonEmptyString(payload["call_id"]),
                  let rawName = nonEmptyString(payload["name"]),
                  let toolName = multiAgentToolName(
                    rawName: rawName,
                    namespace: nonEmptyString(payload["namespace"])
                  ),
                  shouldTrackMultiAgentTool(named: toolName) else {
                return []
            }
            let dedupeKey = "multi_agent_function_call:\(callID)"
            guard seenKeys.insertIfAbsent(dedupeKey) else {
                return []
            }
            pendingCalls.store(
                callID: callID,
                call: CodexMultiAgentPendingCall(
                    toolName: toolName,
                    argumentsJSONString: nonEmptyString(payload["arguments"])
                )
            )
            return []

        case "function_call_output":
            guard let callID = nonEmptyString(payload["call_id"]),
                  let pendingCall = pendingCalls.resolve(callID: callID) else {
                return []
            }
            let dedupeKey = "multi_agent_function_call_output:\(callID)"
            guard seenKeys.insertIfAbsent(dedupeKey) else {
                return []
            }
            return resolvedMultiAgentEvents(
                for: pendingCall,
                callID: callID,
                outputJSONString: nonEmptyString(payload["output"]),
                fallbackLine: fallbackLine
            )

        default:
            return []
        }
    }

    static func resolvedMultiAgentEvents(
        for call: CodexMultiAgentPendingCall,
        callID: String,
        outputJSONString: String?,
        fallbackLine _: String
    ) -> [CodexSessionLogEvent] {
        let arguments = jsonObject(fromJSONString: call.argumentsJSONString)
        let output = jsonObject(fromJSONString: outputJSONString)

        switch call.toolName {
        case "spawn_agent":
            guard let output,
                  let agentID = nonEmptyString(output["agent_id"]) else {
                return []
            }
            let displayName = normalizedSummaryText(output["nickname"], limit: 80)
                ?? normalizedSummaryText(arguments?["agent_type"], limit: 80)
                ?? "Sub-agent"
            return [
                CodexSessionLogEvent(
                    kind: .backgroundActivityStarted,
                    detail: "Started \(displayName)",
                    backgroundActivity: CodexSessionBackgroundActivity(
                        activityID: agentID,
                        hookActivityID: agentID,
                        spawnToolUseID: callID,
                        kind: .subagent,
                        displayName: displayName,
                        command: spawnMetadataSummaryText(arguments?["message"], limit: 512)
                    )
                ),
            ]

        case "wait_agent":
            guard let output else { return [] }
            return terminalAgentIDs(fromWaitOutput: output).map { agentID in
                CodexSessionLogEvent(
                    kind: .backgroundActivityFinished,
                    detail: "Finished sub-agent",
                    backgroundActivity: CodexSessionBackgroundActivity(
                        activityID: agentID,
                        kind: .subagent
                    )
                )
            }

        case "close_agent":
            guard let output else { return [] }
            return closeAgentIDs(fromOutput: output, arguments: arguments).map { agentID in
                CodexSessionLogEvent(
                    kind: .backgroundActivityFinished,
                    detail: "Finished sub-agent",
                    backgroundActivity: CodexSessionBackgroundActivity(
                        activityID: agentID,
                        kind: .subagent
                    )
                )
            }

        default:
            return []
        }
    }

    static func rolloutEntryDate(from object: [String: Any]) -> Date? {
        guard let raw = normalizedString(object["timestamp"]) else { return nil }
        return (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(raw, strategy: Date.ISO8601FormatStyle()))
    }

    static func multiAgentToolName(rawName: String, namespace: String?) -> String? {
        switch namespace {
        case "multi_agent_v1":
            return strippedMultiAgentToolName(rawName) ?? rawName
        case "collaboration":
            return shouldTrackCollaborationTool(named: rawName) ? rawName : nil
        case nil:
            if rawName == "spawn_agent" {
                return rawName
            }
            return strippedMultiAgentToolName(rawName)
        default:
            return nil
        }
    }

    static func strippedMultiAgentToolName(_ rawName: String) -> String? {
        for prefix in ["multi_agent_v1.", "multi_agent_v1/", "multi_agent_v1::", "multi_agent_v1_"] {
            guard rawName.hasPrefix(prefix) else { continue }
            let toolName = String(rawName.dropFirst(prefix.count))
            return toolName.isEmpty ? nil : toolName
        }
        return nil
    }

    static func shouldTrackMultiAgentTool(named toolName: String) -> Bool {
        switch toolName {
        case "spawn_agent", "wait_agent", "close_agent", "interrupt_agent", "followup_task":
            return true
        default:
            return false
        }
    }

    static func shouldTrackCollaborationTool(named toolName: String) -> Bool {
        switch toolName {
        case "spawn_agent", "interrupt_agent", "followup_task":
            return true
        default:
            return false
        }
    }

    static func jsonObject(fromJSONString jsonString: String?) -> [String: Any]? {
        guard let jsonString,
              let data = jsonString.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func terminalAgentIDs(fromWaitOutput output: [String: Any]) -> [String] {
        guard let statuses = output["status"] as? [String: Any] else {
            return []
        }
        return statuses.compactMap { agentID, status in
            guard let statusObject = status as? [String: Any],
                  statusObject.keys.contains(where: { terminalMultiAgentStatusKeys.contains($0) }) else {
                return nil
            }
            return nonEmptyString(agentID)
        }
        .sorted()
    }

    static func closeAgentIDs(fromOutput output: [String: Any], arguments: [String: Any]?) -> [String] {
        var agentIDs: Set<String> = []
        collectAgentIDs(from: output, into: &agentIDs)
        if let arguments {
            collectAgentIDs(from: arguments, into: &agentIDs)
        }
        return agentIDs.sorted()
    }

    static func collectAgentIDs(from object: [String: Any], into agentIDs: inout Set<String>) {
        if let agentID = nonEmptyString(object["agent_id"]) {
            agentIDs.insert(agentID)
        }
        if let values = object["agent_ids"] as? [Any] {
            for value in values {
                if let agentID = nonEmptyString(value) {
                    agentIDs.insert(agentID)
                }
            }
        }
    }

    static func parseTopLevelTurnContext(
        object: [String: Any],
        fallbackLine: String,
        seenKeys: CodexSessionLogSeenKeys,
        sessionTopLevelApprovalsReviewer: inout CodexSessionLogContextField
    ) -> CodexSessionLogEvent? {
        guard normalizedString(object["type"]) == "turn_context",
              let payload = object["payload"] as? [String: Any] else {
            return nil
        }

        let approvalPolicyField = contextField(
            from: payload,
            key: "approval_policy",
            nullMeansClear: false
        )
        var approvalsReviewerField = contextField(
            from: payload,
            key: "approvals_reviewer",
            nullMeansClear: false
        )
        if !approvalsReviewerField.isSpecified,
           sessionTopLevelApprovalsReviewer.isSpecified {
            approvalsReviewerField = sessionTopLevelApprovalsReviewer
        }

        guard normalizedString(payload["turn_id"]) != nil ||
            approvalPolicyField.isSpecified ||
            approvalsReviewerField.isSpecified else {
            return nil
        }

        let dedupeKey = "top_level_turn_context:\(topLevelEventIdentifier(from: object, payload: payload, fallback: fallbackLine))"
        guard seenKeys.insertIfAbsent(dedupeKey) else {
            return nil
        }

        return CodexSessionLogEvent(
            kind: .turnStarted,
            detail: "Responding to your prompt",
            rootTurnID: normalizedString(payload["turn_id"]),
            approvalPolicyField: approvalPolicyField,
            approvalsReviewerField: approvalsReviewerField
        )
    }

    static func parseLegacyCodexEvent(
        object: [String: Any],
        fallbackLine: String,
        seenKeys: CodexSessionLogSeenKeys
    ) -> CodexSessionLogEvent? {
        guard normalizedString(object["dir"]) == "to_tui",
              normalizedString(object["kind"]) == "codex_event",
              let payload = object["payload"] as? [String: Any],
              let message = payload["msg"] as? [String: Any],
              let type = normalizedString(message["type"]) else {
            return nil
        }

        switch type {
        case "session_configured":
            guard let sessionID = normalizedString(message["session_id"]),
                  let threadID = normalizedString(message["thread_id"]) ?? normalizedString(message["session_id"]),
                  sessionID == threadID else {
                return nil
            }

            let rolloutPath = nonEmptyString(message["rollout_path"])
            let dedupeKey = "session_configured:\(fallbackLine)"
            guard seenKeys.insertIfAbsent(dedupeKey) else { return nil }
            return CodexSessionLogEvent(
                kind: .sessionConfigured,
                detail: "Codex session configured",
                nativeSessionID: threadID,
                nativeSessionFilePath: rolloutPath
            )

        case "user_message":
            let dedupeKey = "user_message:\(eventIdentifier(from: payload, message: message, fallback: fallbackLine))"
            guard seenKeys.insertIfAbsent(dedupeKey) else { return nil }
            return CodexSessionLogEvent(
                kind: .turnStarted,
                detail: normalizedSummaryText(message["message"], limit: 140) ?? "Responding to your prompt",
                rootInputFingerprint: CodexInputFingerprint.fingerprint(for: normalizedString(message["message"])),
                rootTurnID: eventTurnID(from: object, payload: payload, message: message)
            )

        case "task_started":
            let dedupeKey = "task_started:\(eventIdentifier(from: payload, message: message, fallback: fallbackLine))"
            guard seenKeys.insertIfAbsent(dedupeKey) else { return nil }
            return CodexSessionLogEvent(kind: .turnStarted, detail: "Responding to your prompt")

        case "exec_command_begin":
            let dedupeKey = "exec_command_begin:\(eventIdentifier(from: payload, message: message, fallback: fallbackLine))"
            guard seenKeys.insertIfAbsent(dedupeKey) else { return nil }
            return CodexSessionLogEvent(
                kind: .turnStarted,
                detail: enrichedCommandDetail(from: message)
            )

        case "patch_apply_begin":
            let dedupeKey = "patch_apply_begin:\(eventIdentifier(from: payload, message: message, fallback: fallbackLine))"
            guard seenKeys.insertIfAbsent(dedupeKey) else { return nil }
            return CodexSessionLogEvent(
                kind: .turnStarted,
                detail: patchApplyDetail(from: message)
            )

        case "task_complete":
            let dedupeKey = "task_complete:\(eventIdentifier(from: payload, message: message, fallback: fallbackLine))"
            guard seenKeys.insertIfAbsent(dedupeKey) else { return nil }
            return CodexSessionLogEvent(
                kind: .taskCompleted,
                detail: normalizedSummaryText(message["last_agent_message"], limit: 240) ?? "Turn complete",
                completionThreadID: eventThreadID(payload: payload, message: message),
                completionTurnID: eventTurnID(from: object, payload: payload, message: message)
            )

        case "turn_aborted":
            let dedupeKey = "turn_aborted:\(eventIdentifier(from: payload, message: message, fallback: fallbackLine))"
            guard seenKeys.insertIfAbsent(dedupeKey) else { return nil }
            return CodexSessionLogEvent(kind: .turnAborted, detail: "Ready for prompt")

        case "context_compacted":
            // Intentionally skipped: this internal event does not carry actionable
            // status detail for the sidebar.
            return nil

        default:
            guard type.hasSuffix("_approval_request") || type == "request_user_input" else {
                return nil
            }
            let callID = eventField("call_id", payload: payload, message: message)
            let approvalID = eventField("approval_id", payload: payload, message: message)
            let effectiveApprovalID: String
            if let approvalID {
                effectiveApprovalID = "approval_id:\(approvalID)"
            } else if let callID {
                effectiveApprovalID = "call_id:\(callID)"
            } else {
                let legacyIdentifier = eventIdentifier(
                    from: payload,
                    message: message,
                    fallback: fallbackLine
                )
                effectiveApprovalID = "legacy:\(legacyIdentifier)"
            }
            let dedupeKey = "approval:\(effectiveApprovalID)"
            guard seenKeys.insertIfAbsent(dedupeKey) else { return nil }
            return CodexSessionLogEvent(
                kind: .approvalNeeded,
                detail: approvalDetail(type: type, message: message),
                rootThreadID: eventThreadID(payload: payload, message: message),
                rootTurnID: eventTurnID(from: object, payload: payload, message: message),
                callID: callID,
                approvalID: approvalID
            )
        }
    }

    static func parseAppEvent(
        object: [String: Any],
        fallbackLine: String,
        seenKeys: CodexSessionLogSeenKeys
    ) -> CodexSessionLogEvent? {
        guard normalizedString(object["dir"]) == "to_tui",
              normalizedString(object["kind"]) == "app_event",
              let variant = nonEmptyString(object["variant"]),
              let goal = threadGoalObjective(from: variant) else {
            return nil
        }

        let dedupeKey = "set_thread_goal_objective:\(fallbackLine)"
        guard seenKeys.insertIfAbsent(dedupeKey) else {
            return nil
        }

        return CodexSessionLogEvent(
            kind: .turnStarted,
            detail: normalizedSummaryText(goal.objective, limit: 140) ?? "Responding to your goal",
            rootInputFingerprint: CodexInputFingerprint.fingerprint(for: goal.objective),
            rootThreadID: goal.threadID
        )
    }

    static func parseOperationEvent(
        object: [String: Any],
        fallbackLine: String,
        seenKeys: CodexSessionLogSeenKeys
    ) -> CodexSessionLogEvent? {
        guard normalizedString(object["dir"]) == "from_tui",
              normalizedString(object["kind"]) == "op",
              let operation = normalizedOperationPayload(object["payload"]) else {
            return nil
        }

        switch operation.type {
        case "user_turn":
            let dedupeKey = "op_user_turn:\(operationEventIdentifier(from: object, payload: operation.payload, fallback: fallbackLine))"
            guard seenKeys.insertIfAbsent(dedupeKey) else {
                return nil
            }

            return CodexSessionLogEvent(
                kind: .turnStarted,
                detail: userTurnDetail(from: operation.payload) ?? "Responding to your prompt",
                rootInputFingerprint: userTurnInputFingerprint(from: operation.payload),
                rootTurnID: operationExplicitTurnID(from: operation.payload),
                approvalPolicyField: contextField(
                    from: operation.payload,
                    key: "approval_policy",
                    nullMeansClear: false
                ),
                approvalsReviewerField: contextField(
                    from: operation.payload,
                    key: "approvals_reviewer",
                    nullMeansClear: false
                )
            )

        case "override_turn_context":
            let approvalPolicyField = contextField(
                from: operation.payload,
                key: "approval_policy",
                nullMeansClear: true
            )
            let approvalsReviewerField = contextField(
                from: operation.payload,
                key: "approvals_reviewer",
                nullMeansClear: true
            )
            guard approvalPolicyField.isSpecified || approvalsReviewerField.isSpecified else {
                return nil
            }
            let dedupeKey = "op_override_turn_context:\(operationEventIdentifier(from: object, payload: operation.payload, fallback: fallbackLine))"
            guard seenKeys.insertIfAbsent(dedupeKey) else {
                return nil
            }

            return CodexSessionLogEvent(
                kind: .turnContextUpdated,
                detail: "Codex turn context updated",
                approvalPolicyField: approvalPolicyField,
                approvalsReviewerField: approvalsReviewerField
            )

        case "interrupt":
            // Current codex-cli recordings emit from_tui/op interrupt when the
            // user cancels the active turn (Esc, Ctrl-C, or equivalent).
            // Treat it as the modern equivalent of the legacy turn_aborted
            // record so the sidebar clears the working spinner promptly.
            let dedupeKey = "op_interrupt:\(operationEventIdentifier(from: object, payload: operation.payload, fallback: fallbackLine))"
            guard seenKeys.insertIfAbsent(dedupeKey) else {
                return nil
            }

            return CodexSessionLogEvent(kind: .turnAborted, detail: "Ready for prompt")

        default:
            return nil
        }
    }

    static func normalizedOperationPayload(_ value: Any?) -> (type: String, payload: [String: Any])? {
        if let payload = value as? [String: Any] {
            if let type = normalizedString(payload["type"]) {
                return (type: type, payload: payload)
            }

            if let userTurn = payload["UserTurn"] as? [String: Any] {
                return (type: "user_turn", payload: userTurn)
            }

            if let overrideTurnContext = payload["OverrideTurnContext"] as? [String: Any] {
                return (type: "override_turn_context", payload: overrideTurnContext)
            }
        }

        if normalizedString(value) == "Interrupt" {
            return (type: "interrupt", payload: [:])
        }

        return nil
    }

    static func parseHistoryInsertEvent(
        object: [String: Any],
        fallbackLine: String,
        seenKeys: CodexSessionLogSeenKeys
    ) -> CodexSessionLogEvent? {
        guard normalizedString(object["dir"]) == "to_tui",
              normalizedString(object["kind"]) == "insert_history_cell" else {
            return nil
        }

        let lineCount = (object["lines"] as? NSNumber)?.intValue ?? 0
        guard lineCount > 0 else {
            return nil
        }

        let dedupeKey = "insert_history_cell:\(fallbackLine)"
        guard seenKeys.insertIfAbsent(dedupeKey) else {
            return nil
        }

        return CodexSessionLogEvent(
            kind: .historyUpdated,
            detail: "History updated"
        )
    }

    static func approvalDetail(type: String, message: [String: Any]) -> String {
        if type == "request_user_input" {
            return normalizedSummaryText(message["question"]) ?? "Codex is waiting for input"
        }

        if let command = normalizedSummaryText(commandPreview(from: message), limit: 100) {
            return "Approve \(command)"
        }

        return "Codex is waiting for approval"
    }

    static func enrichedCommandDetail(from message: [String: Any]) -> String {
        if let detail = parsedCommandDetail(from: message) {
            return detail
        }
        if let command = normalizedSummaryText(commandPreview(from: message), limit: 100) {
            return "Running \(command)"
        }
        return "Running a shell command"
    }

    static func parsedCommandDetail(from message: [String: Any]) -> String? {
        guard let parsedCommands = message["parsed_cmd"] as? [Any] else {
            return nil
        }

        for case let command as [String: Any] in parsedCommands {
            guard let type = normalizedString(command["type"]) else {
                continue
            }

            switch type {
            case "read":
                if let fileName = fileName(from: command) {
                    return "Reading \(fileName)"
                }
                return "Reading files"

            case "search":
                if let query = normalizedSummaryText(command["query"], limit: 80) {
                    return "Searching for \(query)"
                }
                return "Searching the workspace"

            case "list_files":
                return "Listing files"

            default:
                continue
            }
        }

        return nil
    }

    static func patchApplyDetail(from message: [String: Any]) -> String {
        guard let changes = message["changes"] as? [String: Any] else {
            return "Editing files"
        }

        let sortedPaths = changes.keys
            .compactMap(nonEmptyString(_:))
            .sorted()
        guard let firstPath = sortedPaths.first else {
            return "Editing files"
        }

        let remainingCount = sortedPaths.count - 1
        guard remainingCount > 0 else {
            return "Editing \(lastPathComponent(firstPath))"
        }

        let remainder = remainingCount == 1
            ? "1 more file"
            : "\(remainingCount) more files"
        return "Editing \(lastPathComponent(firstPath)) and \(remainder)"
    }

    static func commandPreview(from message: [String: Any]) -> String? {
        if let command = normalizedString(message["command"]) {
            return command
        }
        if let commandArray = message["command"] as? [String] {
            return commandArray.joined(separator: " ")
        }
        if let commandArray = message["cmd"] as? [String] {
            return commandArray.joined(separator: " ")
        }
        return nil
    }

    static func eventIdentifier(
        from payload: [String: Any],
        message: [String: Any],
        fallback: String
    ) -> String {
        for key in ["call_id", "approval_id", "turn_id", "id"] {
            if let value = normalizedString(message[key]) ?? normalizedString(payload[key]) {
                return value
            }
        }
        return fallback
    }

    static func eventField(
        _ key: String,
        payload: [String: Any],
        message: [String: Any]
    ) -> String? {
        normalizedString(message[key]) ?? normalizedString(payload[key])
    }

    static func contextField(
        from payload: [String: Any],
        key: String,
        nullMeansClear: Bool
    ) -> CodexSessionLogContextField {
        guard payload.keys.contains(key) else {
            return .unspecified
        }
        guard let value = normalizedString(payload[key]) else {
            return nullMeansClear ? .null : .unspecified
        }
        return .string(value)
    }

    static func topLevelDeveloperPermissionsApprovalsReviewer(from object: [String: Any]) -> CodexSessionLogContextField? {
        guard normalizedString(object["type"]) == "response_item",
              let payload = object["payload"] as? [String: Any],
              normalizedString(payload["type"]) == "message",
              normalizedString(payload["role"]) == "developer",
              let contents = payload["content"] as? [Any] else {
            return nil
        }

        var sawPermissionsBlock = false
        for case let content as [String: Any] in contents {
            guard normalizedString(content["type"]) == "input_text",
                  let text = normalizedString(content["text"]),
                  text.contains("<permissions instructions>"),
                  text.contains("</permissions instructions>") else {
                continue
            }
            sawPermissionsBlock = true
            if text.contains("`approvals_reviewer` is `auto_review`") {
                return .string("auto_review")
            }
        }
        return sawPermissionsBlock ? .unspecified : nil
    }

    static func topLevelEventIdentifier(
        from object: [String: Any],
        payload: [String: Any],
        fallback: String
    ) -> String {
        for key in ["turn_id", "id", "request_id"] {
            if let value = normalizedString(payload[key]) {
                return value
            }
        }
        if let timestamp = normalizedString(object["timestamp"]) {
            return timestamp
        }
        return fallback
    }

    static func operationEventIdentifier(
        from object: [String: Any],
        payload: [String: Any],
        fallback: String
    ) -> String {
        for key in ["id", "turn_id", "request_id"] {
            if let value = normalizedString(payload[key]) {
                return value
            }
        }
        if let timestamp = normalizedString(object["ts"]) {
            return timestamp
        }
        return fallback
    }

    static func operationExplicitTurnID(from payload: [String: Any]) -> String? {
        for key in ["turn_id", "id", "request_id"] {
            if let value = normalizedString(payload[key]) {
                return value
            }
        }
        return nil
    }

    static func eventThreadID(
        payload: [String: Any],
        message: [String: Any]
    ) -> String? {
        for key in ["thread_id"] {
            if let value = normalizedString(message[key])
                ?? normalizedString(payload[key]) {
                return value
            }
        }
        return nil
    }

    static func eventTurnID(
        from object: [String: Any],
        payload: [String: Any],
        message: [String: Any]
    ) -> String? {
        for key in ["turn_id", "id", "request_id"] {
            if let value = normalizedString(message[key])
                ?? normalizedString(payload[key])
                ?? normalizedString(object[key]) {
                return value
            }
        }
        return nil
    }

    static func userTurnDetail(from payload: [String: Any]) -> String? {
        userTurnInputText(from: payload).flatMap { normalizedSummaryText($0, limit: 140) }
    }

    static func userTurnInputFingerprint(from payload: [String: Any]) -> String? {
        CodexInputFingerprint.fingerprint(for: userTurnInputText(from: payload))
    }

    static func userTurnInputText(from payload: [String: Any]) -> String? {
        if let items = payload["items"] as? [Any] {
            let textItems = items.compactMap { item -> String? in
                guard let item = item as? [String: Any],
                      normalizedString(item["type"]) == "text" else {
                    return nil
                }
                return normalizedString(item["text"])
            }
            if textItems.isEmpty == false {
                return textItems.joined(separator: "\n")
            }
        }
        return normalizedString(payload["text"])
    }

    static func threadGoalObjective(from variant: String) -> (threadID: String?, objective: String)? {
        guard variant.hasPrefix("SetThreadGoalObjective "),
              let objective = quotedValue(in: variant, after: "objective: ") else {
            return nil
        }

        return (
            threadID: threadID(fromGoalVariant: variant),
            objective: objective
        )
    }

    static func threadID(fromGoalVariant variant: String) -> String? {
        let marker = "thread_id: ThreadId { uuid: "
        guard let markerRange = variant.range(of: marker) else {
            return nil
        }

        var endIndex = markerRange.upperBound
        while endIndex < variant.endIndex, isThreadIDCharacter(variant[endIndex]) {
            variant.formIndex(after: &endIndex)
        }

        let candidate = String(variant[markerRange.upperBound..<endIndex])
        return candidate.isEmpty ? nil : candidate
    }

    static func quotedValue(in value: String, after marker: String) -> String? {
        guard let markerRange = value.range(of: marker) else {
            return nil
        }

        var index = markerRange.upperBound
        guard index < value.endIndex, value[index] == "\"" else {
            return nil
        }
        value.formIndex(after: &index)

        var result = ""
        var isEscaped = false
        while index < value.endIndex {
            let character = value[index]
            value.formIndex(after: &index)

            if isEscaped {
                switch character {
                case "n":
                    result.append("\n")
                case "r":
                    result.append("\r")
                case "t":
                    result.append("\t")
                default:
                    result.append(character)
                }
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            if character == "\"" {
                return normalizedString(result)
            }

            result.append(character)
        }

        return nil
    }

    static func isThreadIDCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return false
        }

        switch scalar.value {
        case 45, 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }

    static func normalizedJSONLineData(from lineData: Data) -> Data? {
        guard lineData.isEmpty == false else {
            return nil
        }

        let filteredBytes = lineData.filter { $0 != nulByte }
        guard filteredBytes.isEmpty == false else {
            return nil
        }

        let firstContentIndex = filteredBytes.firstIndex(where: { isNonWhitespaceByte($0) })
        guard let firstContentIndex else {
            return nil
        }

        let lastContentIndex = filteredBytes.lastIndex(where: { isNonWhitespaceByte($0) })
        guard let lastContentIndex else {
            return nil
        }

        return Data(filteredBytes[firstContentIndex...lastContentIndex])
    }

    static func isNonWhitespaceByte(_ byte: UInt8) -> Bool {
        !whitespaceBytes.contains(byte)
    }

    static func fileName(from object: [String: Any]) -> String? {
        if let name = normalizedSummaryText(object["name"], limit: 80) {
            return name
        }
        if let path = nonEmptyString(object["path"]) {
            return lastPathComponent(path)
        }
        return nil
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let collapsed = string
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    static func normalizedSummaryText(_ value: Any?, limit: Int = 160) -> String? {
        guard let string = normalizedString(value) else { return nil }
        guard string.count > limit else { return string }
        let endIndex = string.index(string.startIndex, offsetBy: limit - 3)
        return String(string[..<endIndex]) + "..."
    }

    static func spawnMetadataSummaryText(_ value: Any?, limit: Int) -> String? {
        guard let normalized = normalizedString(value),
              isLikelyEncryptedCodexAgentPayload(normalized) == false else {
            return nil
        }
        return normalizedSummaryText(normalized, limit: limit)
    }

    static func lastPathComponent(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    static func close(_ handle: inout FileHandle?) {
        try? handle?.close()
        handle = nil
    }

    static let newlineByte = UInt8(ascii: "\n")
    static let nulByte: UInt8 = 0
    static let whitespaceBytes: Set<UInt8> = [9, 10, 13, 32]
    static let terminalMultiAgentStatusKeys: Set<String> = [
        "completed",
        "failed",
        "errored",
        "cancelled",
    ]
}
