import Foundation

struct CodexSessionLogEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case turnStarted
        case approvalNeeded
        case taskCompleted
        case turnAborted
    }

    let kind: Kind
    let detail: String
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

        while let newlineIndex = bufferedRemainder.firstIndex(of: newlineByte) {
            let lineData = bufferedRemainder.prefix(upTo: newlineIndex)
            bufferedRemainder.removeSubrange(...newlineIndex)
            guard let event = parse(lineData: Data(lineData), seenKeys: &seenKeys) else {
                continue
            }
            await eventHandler(event)
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
        case "user_message":
            let dedupeKey = "user_message:\(eventIdentifier(from: payload, message: message, fallback: fallbackLine))"
            guard seenKeys.insert(dedupeKey).inserted else { return nil }
            return CodexSessionLogEvent(
                kind: .turnStarted,
                detail: normalizedSummaryText(message["message"], limit: 140) ?? "Responding to your prompt"
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
                detail: normalizedSummaryText(message["last_agent_message"], limit: 240) ?? "Turn complete"
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

    static func parseOperationEvent(
        object: [String: Any],
        fallbackLine: String,
        seenKeys: inout Set<String>
    ) -> CodexSessionLogEvent? {
        guard normalizedString(object["dir"]) == "from_tui",
              normalizedString(object["kind"]) == "op",
              let payload = object["payload"] as? [String: Any],
              let type = normalizedString(payload["type"]) else {
            return nil
        }

        guard type == "user_turn" else {
            return nil
        }

        let dedupeKey = "op_user_turn:\(operationEventIdentifier(from: object, payload: payload, fallback: fallbackLine))"
        guard seenKeys.insert(dedupeKey).inserted else {
            return nil
        }

        return CodexSessionLogEvent(
            kind: .turnStarted,
            detail: userTurnDetail(from: payload) ?? "Responding to your prompt"
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

    static func userTurnDetail(from payload: [String: Any]) -> String? {
        if let items = payload["items"] as? [Any] {
            for case let item as [String: Any] in items {
                guard normalizedString(item["type"]) == "text" else {
                    continue
                }
                if let summary = normalizedSummaryText(item["text"], limit: 140) {
                    return summary
                }
            }
        }

        return normalizedSummaryText(payload["text"], limit: 140)
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
