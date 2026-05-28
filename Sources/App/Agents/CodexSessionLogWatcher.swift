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

struct CodexSessionLogEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case sessionConfigured
        case turnContextUpdated
        case turnStarted
        case historyUpdated
        case approvalNeeded
        case taskCompleted
        case turnAborted
    }

    let kind: Kind
    let detail: String
    let rootInputFingerprint: String?
    let rootThreadID: String?
    let rootTurnID: String?
    let completionThreadID: String?
    let completionTurnID: String?
    let nativeSessionID: String?
    let nativeSessionFilePath: String?
    let approvalPolicyField: CodexSessionLogContextField
    let approvalsReviewerField: CodexSessionLogContextField
    let approvalPolicy: String?
    let approvalsReviewer: String?

    init(
        kind: Kind,
        detail: String,
        rootInputFingerprint: String? = nil,
        rootThreadID: String? = nil,
        rootTurnID: String? = nil,
        completionThreadID: String? = nil,
        completionTurnID: String? = nil,
        nativeSessionID: String? = nil,
        nativeSessionFilePath: String? = nil,
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
        self.rootInputFingerprint = rootInputFingerprint
        self.rootThreadID = rootThreadID
        self.rootTurnID = rootTurnID
        self.completionThreadID = completionThreadID
        self.completionTurnID = completionTurnID
        self.nativeSessionID = nativeSessionID
        self.nativeSessionFilePath = nativeSessionFilePath
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

final class CodexSessionLogWatcher {
    typealias EventHandler = @Sendable (CodexSessionLogEvent) async -> Void

    private let logURL: URL
    private let pollIntervalNanoseconds: UInt64
    private let eventHandler: EventHandler
    private var task: Task<Void, Never>?

    init(
        logURL: URL,
        pollIntervalNanoseconds: UInt64 = 250_000_000,
        eventHandler: @escaping EventHandler
    ) {
        self.logURL = logURL
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.eventHandler = eventHandler
    }

    @MainActor
    func start() {
        guard task == nil else { return }
        task = Self.makePollingTask(
            logURL: logURL,
            pollIntervalNanoseconds: pollIntervalNanoseconds,
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
        eventHandler: @escaping EventHandler
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            var handle: FileHandle?
            var offset: UInt64 = 0
            var bufferedRemainder = Data()
            var seenKeys: Set<String> = []
            defer { close(&handle) }

            while true {
                await Self.drainAvailableDeltas(
                    from: logURL,
                    handle: &handle,
                    offset: &offset,
                    bufferedRemainder: &bufferedRemainder,
                    seenKeys: &seenKeys,
                    eventHandler: eventHandler
                )

                if Task.isCancelled {
                    // The terminal process can exit immediately after Codex writes
                    // its final completion/abort event. Drain the file one last time
                    // before teardown so we do not lose that last status update.
                    await Self.drainAvailableDeltas(
                        from: logURL,
                        handle: &handle,
                        offset: &offset,
                        bufferedRemainder: &bufferedRemainder,
                        seenKeys: &seenKeys,
                        eventHandler: eventHandler
                    )
                    break
                }

                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }

            if let event = Self.parseBufferedRemainder(bufferedRemainder, seenKeys: &seenKeys) {
                await eventHandler(event)
            }
        }
    }

    static func drainAvailableDeltas(
        from logURL: URL,
        handle: inout FileHandle?,
        offset: inout UInt64,
        bufferedRemainder: inout Data,
        seenKeys: inout Set<String>,
        eventHandler: @escaping EventHandler
    ) async {
        while let delta = readDelta(from: logURL, handle: &handle, offset: &offset) {
            await processDelta(
                delta,
                bufferedRemainder: &bufferedRemainder,
                seenKeys: &seenKeys,
                eventHandler: eventHandler
            )
        }
    }

    static func processDelta(
        _ delta: Data,
        bufferedRemainder: inout Data,
        seenKeys: inout Set<String>,
        eventHandler: @escaping EventHandler
    ) async {
        guard delta.isEmpty == false else {
            return
        }

        bufferedRemainder.append(delta)
        var pendingHistoryUpdate: CodexSessionLogEvent?

        while let newlineIndex = bufferedRemainder.firstIndex(of: newlineByte) {
            let lineData = bufferedRemainder.prefix(upTo: newlineIndex)
            bufferedRemainder.removeSubrange(...newlineIndex)
            guard let event = parse(lineData: Data(lineData), seenKeys: &seenKeys) else {
                continue
            }
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

        if let pendingHistoryUpdate {
            await eventHandler(pendingHistoryUpdate)
        }
    }

    static func readDelta(from logURL: URL, handle: inout FileHandle?, offset: inout UInt64) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let fileSize = attributes[.size] as? NSNumber else {
            close(&handle)
            offset = 0
            return nil
        }

        let length = fileSize.uint64Value
        if length < offset {
            close(&handle)
            offset = 0
        }
        guard length > offset else {
            return nil
        }

        if handle == nil {
            handle = try? FileHandle(forReadingFrom: logURL)
        }
        guard let fileHandle = handle else {
            return nil
        }

        do {
            try fileHandle.seek(toOffset: offset)
            let data = try fileHandle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            return data.isEmpty ? nil : data
        } catch {
            close(&handle)
            return nil
        }
    }

    static func parseBufferedRemainder(
        _ bufferedRemainder: Data,
        seenKeys: inout Set<String>
    ) -> CodexSessionLogEvent? {
        guard bufferedRemainder.isEmpty == false else {
            return nil
        }
        return parse(lineData: bufferedRemainder, seenKeys: &seenKeys)
    }

    static func parse(lineData: Data, seenKeys: inout Set<String>) -> CodexSessionLogEvent? {
        guard let normalizedLineData = normalizedJSONLineData(from: lineData),
              let object = try? JSONSerialization.jsonObject(with: normalizedLineData) as? [String: Any] else {
            return nil
        }
        let fallbackLine = String(data: normalizedLineData, encoding: .utf8) ?? ""

        if let event = parseLegacyCodexEvent(
            object: object,
            fallbackLine: fallbackLine,
            seenKeys: &seenKeys
        ) {
            return event
        }

        if let event = parseAppEvent(
            object: object,
            fallbackLine: fallbackLine,
            seenKeys: &seenKeys
        ) {
            return event
        }

        if let event = parseHistoryInsertEvent(
            object: object,
            fallbackLine: fallbackLine,
            seenKeys: &seenKeys
        ) {
            return event
        }

        return parseOperationEvent(
            object: object,
            fallbackLine: fallbackLine,
            seenKeys: &seenKeys
        )
    }

    static func parseLegacyCodexEvent(
        object: [String: Any],
        fallbackLine: String,
        seenKeys: inout Set<String>
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
            guard seenKeys.insert(dedupeKey).inserted else { return nil }
            return CodexSessionLogEvent(
                kind: .sessionConfigured,
                detail: "Codex session configured",
                nativeSessionID: threadID,
                nativeSessionFilePath: rolloutPath
            )

        case "user_message":
            let dedupeKey = "user_message:\(eventIdentifier(from: payload, message: message, fallback: fallbackLine))"
            guard seenKeys.insert(dedupeKey).inserted else { return nil }
            return CodexSessionLogEvent(
                kind: .turnStarted,
                detail: normalizedSummaryText(message["message"], limit: 140) ?? "Responding to your prompt",
                rootInputFingerprint: CodexInputFingerprint.fingerprint(for: normalizedString(message["message"])),
                rootTurnID: eventTurnID(from: object, payload: payload, message: message)
            )

        case "task_started":
            let dedupeKey = "task_started:\(eventIdentifier(from: payload, message: message, fallback: fallbackLine))"
            guard seenKeys.insert(dedupeKey).inserted else { return nil }
            return CodexSessionLogEvent(kind: .turnStarted, detail: "Responding to your prompt")

        case "exec_command_begin":
            let dedupeKey = "exec_command_begin:\(eventIdentifier(from: payload, message: message, fallback: fallbackLine))"
            guard seenKeys.insert(dedupeKey).inserted else { return nil }
            return CodexSessionLogEvent(
                kind: .turnStarted,
                detail: enrichedCommandDetail(from: message)
            )

        case "patch_apply_begin":
            let dedupeKey = "patch_apply_begin:\(eventIdentifier(from: payload, message: message, fallback: fallbackLine))"
            guard seenKeys.insert(dedupeKey).inserted else { return nil }
            return CodexSessionLogEvent(
                kind: .turnStarted,
                detail: patchApplyDetail(from: message)
            )

        case "task_complete":
            let dedupeKey = "task_complete:\(eventIdentifier(from: payload, message: message, fallback: fallbackLine))"
            guard seenKeys.insert(dedupeKey).inserted else { return nil }
            return CodexSessionLogEvent(
                kind: .taskCompleted,
                detail: normalizedSummaryText(message["last_agent_message"], limit: 240) ?? "Turn complete",
                completionThreadID: eventThreadID(payload: payload, message: message),
                completionTurnID: eventTurnID(from: object, payload: payload, message: message)
            )

        case "turn_aborted":
            let dedupeKey = "turn_aborted:\(eventIdentifier(from: payload, message: message, fallback: fallbackLine))"
            guard seenKeys.insert(dedupeKey).inserted else { return nil }
            return CodexSessionLogEvent(kind: .turnAborted, detail: "Ready for prompt")

        case "context_compacted":
            // Intentionally skipped: this internal event does not carry actionable
            // status detail for the sidebar.
            return nil

        default:
            guard type.hasSuffix("_approval_request") || type == "request_user_input" else {
                return nil
            }
            let dedupeKey = "approval:\(eventIdentifier(from: payload, message: message, fallback: fallbackLine))"
            guard seenKeys.insert(dedupeKey).inserted else { return nil }
            return CodexSessionLogEvent(
                kind: .approvalNeeded,
                detail: approvalDetail(type: type, message: message)
            )
        }
    }

    static func parseAppEvent(
        object: [String: Any],
        fallbackLine: String,
        seenKeys: inout Set<String>
    ) -> CodexSessionLogEvent? {
        guard normalizedString(object["dir"]) == "to_tui",
              normalizedString(object["kind"]) == "app_event",
              let variant = nonEmptyString(object["variant"]),
              let goal = threadGoalObjective(from: variant) else {
            return nil
        }

        let dedupeKey = "set_thread_goal_objective:\(fallbackLine)"
        guard seenKeys.insert(dedupeKey).inserted else {
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
        seenKeys: inout Set<String>
    ) -> CodexSessionLogEvent? {
        guard normalizedString(object["dir"]) == "from_tui",
              normalizedString(object["kind"]) == "op",
              let operation = normalizedOperationPayload(object["payload"]) else {
            return nil
        }

        switch operation.type {
        case "user_turn":
            let dedupeKey = "op_user_turn:\(operationEventIdentifier(from: object, payload: operation.payload, fallback: fallbackLine))"
            guard seenKeys.insert(dedupeKey).inserted else {
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
            guard seenKeys.insert(dedupeKey).inserted else {
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
            guard seenKeys.insert(dedupeKey).inserted else {
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
        seenKeys: inout Set<String>
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
        guard seenKeys.insert(dedupeKey).inserted else {
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
}
