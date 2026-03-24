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

    func start() {
        guard task == nil else { return }
        task = Self.makePollingTask(
            logURL: logURL,
            pollIntervalNanoseconds: pollIntervalNanoseconds,
            eventHandler: eventHandler
        )
    }

    func stop() {
        task?.cancel()
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
            var bufferedRemainder = ""
            var seenKeys: Set<String> = []
            defer { close(&handle) }

            while true {
                if let delta = Self.readDelta(from: logURL, handle: &handle, offset: &offset) {
                    let combined = bufferedRemainder + delta
                    let lines = combined.components(separatedBy: "\n")
                    bufferedRemainder = lines.last ?? ""

                    for line in lines.dropLast() {
                        guard let event = Self.parse(line: line, seenKeys: &seenKeys) else {
                            continue
                        }
                        await eventHandler(event)
                    }
                }

                if Task.isCancelled {
                    break
                }

                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }

            if let event = Self.parseBufferedRemainder(bufferedRemainder, seenKeys: &seenKeys) {
                await eventHandler(event)
            }
        }
    }

    static func readDelta(from logURL: URL, handle: inout FileHandle?, offset: inout UInt64) -> String? {
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
            return String(data: data, encoding: .utf8)
        } catch {
            close(&handle)
            return nil
        }
    }

    static func parseBufferedRemainder(
        _ bufferedRemainder: String,
        seenKeys: inout Set<String>
    ) -> CodexSessionLogEvent? {
        let trimmedRemainder = bufferedRemainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedRemainder.isEmpty == false else {
            return nil
        }
        return parse(line: trimmedRemainder, seenKeys: &seenKeys)
    }

    static func parse(line: String, seenKeys: inout Set<String>) -> CodexSessionLogEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              normalizedString(object["dir"]) == "to_tui",
              normalizedString(object["kind"]) == "codex_event",
              let payload = object["payload"] as? [String: Any],
              let message = payload["msg"] as? [String: Any],
              let type = normalizedString(message["type"]) else {
            return nil
        }

        switch type {
        case "user_message":
            let dedupeKey = "user_message:\(eventIdentifier(from: payload, message: message, fallback: line))"
            guard seenKeys.insert(dedupeKey).inserted else { return nil }
            return CodexSessionLogEvent(
                kind: .turnStarted,
                detail: normalizedSummaryText(message["message"], limit: 140) ?? "Responding to your prompt"
            )

        case "task_started":
            let dedupeKey = "task_started:\(eventIdentifier(from: payload, message: message, fallback: line))"
            guard seenKeys.insert(dedupeKey).inserted else { return nil }
            return CodexSessionLogEvent(kind: .turnStarted, detail: "Responding to your prompt")

        case "exec_command_begin":
            let dedupeKey = "exec_command_begin:\(eventIdentifier(from: payload, message: message, fallback: line))"
            guard seenKeys.insert(dedupeKey).inserted else { return nil }
            return CodexSessionLogEvent(
                kind: .turnStarted,
                detail: enrichedCommandDetail(from: message)
            )

        case "patch_apply_begin":
            let dedupeKey = "patch_apply_begin:\(eventIdentifier(from: payload, message: message, fallback: line))"
            guard seenKeys.insert(dedupeKey).inserted else { return nil }
            return CodexSessionLogEvent(
                kind: .turnStarted,
                detail: patchApplyDetail(from: message)
            )

        case "task_complete":
            let dedupeKey = "task_complete:\(eventIdentifier(from: payload, message: message, fallback: line))"
            guard seenKeys.insert(dedupeKey).inserted else { return nil }
            return CodexSessionLogEvent(
                kind: .taskCompleted,
                detail: normalizedSummaryText(message["last_agent_message"], limit: 240) ?? "Turn complete"
            )

        case "turn_aborted":
            let dedupeKey = "turn_aborted:\(eventIdentifier(from: payload, message: message, fallback: line))"
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
            let dedupeKey = "approval:\(eventIdentifier(from: payload, message: message, fallback: line))"
            guard seenKeys.insert(dedupeKey).inserted else { return nil }
            return CodexSessionLogEvent(
                kind: .approvalNeeded,
                detail: approvalDetail(type: type, message: message)
            )
        }
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
}
