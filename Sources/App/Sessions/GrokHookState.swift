import CoreState
import Foundation

/// Reconciles hook processes using producer timestamps and native prompt IDs.
/// Stop is a gate: only a later idle observation confirms it actually settled.
struct GrokHookState {
    struct Update: Equatable {
        var status: SessionStatus?
    }

    private(set) var nativeSessionID: String?
    private var promptID: String?
    private var latestTimestamp = Date.distantPast
    private var latestToolTimestamp = Date.distantPast
    private var stopObserved = false
    private var toolBoundary = Date.distantPast
    private var toolBoundaryIsStop = false
    private var discardedToolsThrough = Date.distantPast
    private var nextToolOrder = 0
    private var tools: [String: ToolObservation] = [:]
    private var permission: PendingPermission?

    private struct ToolObservation {
        var startedAt: Date?
        var completedAt: Date?
        var activity: ToolActivity
        var order = 0

        var timestamp: Date { completedAt ?? startedAt ?? .distantPast }
        var isActive: Bool { startedAt != nil && completedAt == nil }

        func startedBefore(_ other: Self) -> Bool {
            if startedAt == other.startedAt { return order < other.order }
            return (startedAt ?? .distantPast) < (other.startedAt ?? .distantPast)
        }
    }

    private struct PendingPermission {
        var timestamp: Date
        var toolID: String?
    }

    mutating func apply(_ event: GrokHookEvent) -> Update? {
        guard !event.isSubagent else { return nil }
        if event.kind == .sessionStart {
            guard nativeSessionID == nil, event.timestamp > latestTimestamp else { return nil }
            nativeSessionID = event.nativeSessionID
            latestTimestamp = event.timestamp
            return Update(status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Grok is ready"))
        }
        if [.preToolUse, .postToolUse, .postToolUseFailure].contains(event.kind) {
            return applyTool(event)
        }
        guard event.timestamp > latestTimestamp else { return nil }
        if event.kind == .userPromptSubmit {
            guard event.promptID != nil else { return nil }
            // Root prompts have no subagentType and the launch helper checks
            // the producer PID. They recover lost startup/end observations
            // and establish the conversation selected by /clear or /resume.
            if nativeSessionID != event.nativeSessionID { tools.removeAll() }
            nativeSessionID = event.nativeSessionID
        }
        guard event.nativeSessionID == nativeSessionID else { return nil }

        let status: SessionStatus?
        switch event.kind {
        case .sessionStart:
            return nil
        case .userPromptSubmit:
            guard let id = event.promptID else { return nil }
            promptID = id
            stopObserved = false
            permission = nil
            toolBoundary = event.timestamp
            toolBoundaryIsStop = false
            discardedToolsThrough = .distantPast
            // A new prompt's first tool hook can arrive before its prompt hook.
            tools = tools.filter { $0.value.timestamp >= event.timestamp }
            latestToolTimestamp = tools.values.map(\.timestamp).max() ?? .distantPast
            status = workingStatus
        case .preToolUse, .postToolUse, .postToolUseFailure:
            return nil // Handled separately: tool hooks usually have no prompt ID.
        case .permissionRequest:
            guard matchesPrompt(event) else { return nil }
            status = requestPermission(event)
        case .stop:
            guard matchesPrompt(event) else { return nil }
            toolBoundary = event.timestamp
            toolBoundaryIsStop = true
            tools = tools.filter { $0.value.timestamp > event.timestamp }
            permission = nil
            stopObserved = latestToolTimestamp <= event.timestamp
            status = stopObserved
                ? SessionStatus(kind: .idle, summary: "Waiting", detail: "Grok finished a response")
                : workingStatus
        case .stopFailure, .stopCancelled:
            guard matchesPrompt(event) else { return nil }
            promptID = nil
            stopObserved = false
            tools.removeAll()
            permission = nil
            status = event.kind == .stopFailure
                ? SessionStatus(kind: .error, summary: "Error", detail: "Grok could not complete the turn")
                : SessionStatus(kind: .idle, summary: "Stopped", detail: "Grok stopped the turn")
        case .notification:
            switch event.notificationType {
            case "permission_prompt":
                guard promptID != nil else { return nil }
                status = requestPermission(event)
            case "agent_error":
                guard promptID != nil else { return nil }
                promptID = nil
                stopObserved = false
                tools.removeAll()
                permission = nil
                status = SessionStatus(kind: .error, summary: "Error", detail: "Grok reported an error")
            case "idle_prompt":
                guard latestToolTimestamp <= event.timestamp else { return nil }
                if promptID != nil {
                    status = stopObserved
                        ? SessionStatus(kind: .ready, summary: "Ready", detail: "Turn complete")
                        : SessionStatus(kind: .idle, summary: "Waiting", detail: "Grok is waiting for your next prompt")
                } else {
                    // Idle also follows failures and cancellations; keep them visible.
                    status = nil
                }
                promptID = nil
                stopObserved = false
                tools.removeAll()
                permission = nil
            default:
                return nil
            }
        case .sessionEnd:
            status = promptID == nil ? nil : SessionStatus(kind: .idle, summary: "Stopped", detail: "Grok session ended")
            nativeSessionID = nil
            promptID = nil
            stopObserved = false
            tools.removeAll()
            permission = nil
        }
        latestTimestamp = event.timestamp
        return Update(status: status)
    }

    private func matchesPrompt(_ event: GrokHookEvent) -> Bool {
        promptID != nil && event.promptID == promptID
    }

    private mutating func applyTool(_ event: GrokHookEvent) -> Update? {
        guard promptID != nil, event.nativeSessionID == nativeSessionID,
              event.timestamp >= toolBoundary,
              !toolBoundaryIsStop || event.timestamp > toolBoundary,
              event.promptID == nil || event.promptID == promptID else { return nil }

        guard let id = event.toolUseID else {
            // Older helpers only forwarded prompt IDs. Keep their generic status
            // without letting an uncorrelated observation alter tracked calls.
            guard matchesPrompt(event) else { return nil }
            if let pending = permission, pending.toolID == nil, event.timestamp > pending.timestamp {
                permission = nil
            }
            stopObserved = false
            latestToolTimestamp = max(latestToolTimestamp, event.timestamp)
            return Update(status: workingStatus)
        }

        if event.kind == .preToolUse {
            guard tools[id] == nil, event.timestamp > discardedToolsThrough, makeRoomForTool(at: event.timestamp) else { return nil }
            nextToolOrder += 1
            tools[id] = ToolObservation(startedAt: event.timestamp, activity: ToolActivity(event.toolName), order: nextToolOrder)
            stopObserved = false
            if let pending = permission, pending.toolID == nil {
                if event.timestamp <= pending.timestamp {
                    permission?.toolID = id
                } else {
                    permission = nil
                }
            }
        } else {
            if let observation = tools[id] {
                guard observation.completedAt == nil,
                      event.timestamp >= (observation.startedAt ?? .distantPast) else { return nil }
                tools[id]?.completedAt = event.timestamp
            } else {
                guard event.timestamp > discardedToolsThrough, makeRoomForTool(at: event.timestamp) else { return nil }
                // Remember a completion delivered before its start. It must not
                // revive that call when the delayed start helper reaches us.
                tools[id] = ToolObservation(completedAt: event.timestamp, activity: ToolActivity(event.toolName))
                latestToolTimestamp = max(latestToolTimestamp, event.timestamp)
                return Update(status: resolvePermission(completing: id, at: event.timestamp) ? workingStatus : nil)
            }
            _ = resolvePermission(completing: id, at: event.timestamp)
        }
        latestToolTimestamp = max(latestToolTimestamp, event.timestamp)
        return Update(status: workingStatus)
    }

    private mutating func requestPermission(_ event: GrokHookEvent) -> SessionStatus? {
        // The notification has no call ID on current Grok. Select the newest
        // call that was in progress at its producer timestamp, not arrival time.
        let candidates = tools.filter { _, tool in
            guard let start = tool.startedAt, start <= event.timestamp else { return false }
            return (tool.completedAt ?? .distantFuture) >= event.timestamp
        }
        let candidate = candidates.filter { $0.value.isActive }.max { $0.value.startedBefore($1.value) }
        let id = event.toolUseID ?? permission?.toolID ?? candidate?.key
        if let id, tools[id]?.completedAt != nil { return nil }
        if id == nil && !candidates.isEmpty { return nil }
        permission = PendingPermission(timestamp: event.timestamp, toolID: id)
        return workingStatus
    }

    private mutating func resolvePermission(completing id: String, at timestamp: Date) -> Bool {
        guard let pending = permission else { return false }
        if pending.toolID == id, timestamp < pending.timestamp {
            // This call had already finished when permission was requested.
            // Keep the request visible until its delayed start identifies it.
            permission?.toolID = nil
            return true
        }
        guard pending.toolID == id || (pending.toolID == nil && timestamp >= pending.timestamp) else { return false }
        permission = nil
        return true
    }

    private var workingStatus: SessionStatus {
        if let permission {
            let activity = permission.toolID.flatMap { tools[$0]?.activity }
            return SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: activity?.approvalDetail ?? "Grok is waiting for permission")
        }
        let active = tools.values.filter(\.isActive).max { $0.startedBefore($1) }
        return SessionStatus(kind: .working, summary: "Working", detail: active?.activity.detail ?? "Responding to your prompt")
    }

    private mutating func makeRoomForTool(at timestamp: Date) -> Bool {
        guard tools.count >= 128 else { return true }
        guard let oldest = tools.filter({ $0.value.completedAt != nil }).min(by: { $0.value.timestamp < $1.value.timestamp }),
              timestamp > oldest.value.timestamp else {
            return false
        }
        // Bound completed-call history without losing active calls or reviving
        // an evicted completion when its old start arrives late.
        discardedToolsThrough = max(discardedToolsThrough, oldest.value.timestamp)
        tools.removeValue(forKey: oldest.key)
        return true
    }

    private enum ToolActivity {
        case command, read, edit, search, list, webSearch, webFetch, subagent, other

        init(_ name: String?) {
            switch name {
            case "run_terminal_command", "Bash": self = .command
            case "read_file", "Read": self = .read
            case "search_replace", "write_file", "Edit", "Write", "MultiEdit": self = .edit
            case "grep", "Grep": self = .search
            case "list_dir", "Glob", "ListDir": self = .list
            case "web_search", "WebSearch": self = .webSearch
            case "web_fetch", "WebFetch": self = .webFetch
            case "spawn_subagent", "Task": self = .subagent
            default: self = .other
            }
        }

        var detail: String {
            switch self {
            case .command: "Running a command"
            case .read: "Reading files"
            case .edit: "Editing files"
            case .search: "Searching code"
            case .list: "Listing files"
            case .webSearch: "Searching the web"
            case .webFetch: "Fetching a web page"
            case .subagent: "Running a subagent"
            case .other: "Using a tool"
            }
        }

        var approvalDetail: String {
            switch self {
            case .command: "Waiting for command approval"
            case .read, .edit, .list, .search: "Waiting for file access approval"
            case .webSearch, .webFetch: "Waiting for web access approval"
            case .subagent: "Waiting for subagent approval"
            case .other: "Grok is waiting for permission"
            }
        }
    }
}
