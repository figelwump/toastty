import Foundation

/// What a waiting session waits on: its own turn has ended, but work it
/// started is still running. The Mac builds this from a session's background
/// activities and pending provider tasks; the phone receives the same value in
/// `RemoteConversationSummary`, so both describe a waiting session in the
/// same words.
///
/// The counts always cover all outstanding work. `items` can hold fewer
/// entries than the counts add up to: the wire keeps at most
/// `maximumWireItemCount`.
public struct SessionWaitingSummary: Codable, Equatable, Hashable, Sendable {
    public static let maximumWireItemCount = 8
    /// Each count is clamped here, so a malformed value from the wire cannot
    /// overflow `totalCount`.
    public static let maximumCount = 9_999
    public static let maximumLabelLength = 80
    public static let maximumDetailLength = 160

    public enum ItemKind: String, Codable, Hashable, Sendable {
        /// A sub-agent or a child agent the session launched.
        case agent
        /// A background shell command.
        case process
        case workflow
        /// Any other provider task, such as an MCP task.
        case task
    }

    public struct Item: Codable, Equatable, Hashable, Identifiable, Sendable {
        public var id: String
        public var kind: ItemKind
        /// Short name: the sub-agent type, or the provider's task type such
        /// as "shell".
        public var label: String
        /// The task description or shell command.
        public var detail: String?
        /// Known only for agents, which report their own start.
        public var startedAt: Date?

        public init(id: String, kind: ItemKind, label: String, detail: String? = nil, startedAt: Date? = nil) {
            self.id = id
            self.kind = kind
            self.label = Self.boundedText(label, limit: SessionWaitingSummary.maximumLabelLength) ?? kind.defaultLabel
            self.detail = Self.boundedText(detail, limit: SessionWaitingSummary.maximumDetailLength)
            self.startedAt = startedAt
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // A newer host may send a kind this client does not know; show it
            // as a generic task rather than failing the whole session list.
            let rawKind = try container.decode(String.self, forKey: .kind)
            self.init(
                id: try container.decode(String.self, forKey: .id),
                kind: ItemKind(rawValue: rawKind) ?? .task,
                label: try container.decode(String.self, forKey: .label),
                detail: try container.decodeIfPresent(String.self, forKey: .detail),
                startedAt: try container.decodeIfPresent(Date.self, forKey: .startedAt)
            )
        }

        private enum CodingKeys: String, CodingKey {
            case id, kind, label, detail, startedAt
        }

        private static func boundedText(_ value: String?, limit: Int) -> String? {
            guard let value else { return nil }
            let collapsed = value
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.isEmpty == false }
                .joined(separator: " ")
            let bounded = RemoteWirePreviewText.sanitized(collapsed, maximumGraphemeCount: limit)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return bounded.isEmpty ? nil : bounded
        }
    }

    public var agentCount: Int
    public var processCount: Int
    public var workflowCount: Int
    public var taskCount: Int
    public var items: [Item]

    /// Counts every item by kind.
    public init(items: [Item]) {
        self.init(
            agentCount: items.filter { $0.kind == .agent }.count,
            processCount: items.filter { $0.kind == .process }.count,
            workflowCount: items.filter { $0.kind == .workflow }.count,
            taskCount: items.filter { $0.kind == .task }.count,
            items: items
        )
    }

    public init(agentCount: Int, processCount: Int, workflowCount: Int, taskCount: Int, items: [Item]) {
        self.agentCount = Self.clampedCount(agentCount)
        self.processCount = Self.clampedCount(processCount)
        self.workflowCount = Self.clampedCount(workflowCount)
        self.taskCount = Self.clampedCount(taskCount)
        self.items = items
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            agentCount: try container.decodeIfPresent(Int.self, forKey: .agentCount) ?? 0,
            processCount: try container.decodeIfPresent(Int.self, forKey: .processCount) ?? 0,
            workflowCount: try container.decodeIfPresent(Int.self, forKey: .workflowCount) ?? 0,
            taskCount: try container.decodeIfPresent(Int.self, forKey: .taskCount) ?? 0,
            items: try container.decodeIfPresent([Item].self, forKey: .items) ?? []
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if agentCount > 0 { try container.encode(agentCount, forKey: .agentCount) }
        if processCount > 0 { try container.encode(processCount, forKey: .processCount) }
        if workflowCount > 0 { try container.encode(workflowCount, forKey: .workflowCount) }
        if taskCount > 0 { try container.encode(taskCount, forKey: .taskCount) }
        if items.isEmpty == false { try container.encode(items, forKey: .items) }
    }

    private enum CodingKeys: String, CodingKey {
        case agentCount, processCount, workflowCount, taskCount, items
    }

    private static func clampedCount(_ count: Int) -> Int {
        min(max(0, count), maximumCount)
    }

    public var totalCount: Int {
        agentCount + processCount + workflowCount + taskCount
    }

    /// The same summary with at most `maximumWireItemCount` items. Counts are
    /// unchanged, so a client can still say how many more there are.
    public var boundedForWire: SessionWaitingSummary {
        var copy = self
        copy.items = Array(items.prefix(Self.maximumWireItemCount))
        return copy
    }

    public enum TextStyle: Sendable {
        /// "2 sub-agents · 1 background process"
        case full
        /// "2 sub-agents · 1 process", for narrow rows and headers.
        case compact
    }

    /// One phrase per kind that has work, agents first.
    public func countsText(_ style: TextStyle) -> String {
        let phrases = [
            Self.phrase(agentCount, ItemKind.agent, style),
            Self.phrase(processCount, ItemKind.process, style),
            Self.phrase(workflowCount, ItemKind.workflow, style),
            Self.phrase(taskCount, ItemKind.task, style),
        ].compactMap { $0 }
        return phrases.joined(separator: " · ")
    }

    /// A session row's summary line while waiting. With exactly one item, the
    /// line names it: "1 background process · npm test".
    public func rowText(_ style: TextStyle) -> String {
        let counts = countsText(style)
        guard totalCount == 1,
              let item = items.first,
              let name = item.detail ?? (item.label == item.kind.defaultLabel ? nil : item.label) else {
            return counts
        }
        return "\(counts) · \(name)"
    }

    /// "Waiting on 2 sub-agents · 1 process", for card headers.
    public var headline: String {
        "Waiting on \(countsText(.compact))"
    }

    private static func phrase(_ count: Int, _ kind: ItemKind, _ style: TextStyle) -> String? {
        guard count > 0 else { return nil }
        let (singular, plural): (String, String) = switch (kind, style) {
        case (.agent, _): ("sub-agent", "sub-agents")
        case (.process, .full): ("background process", "background processes")
        case (.process, .compact): ("process", "processes")
        case (.workflow, _): ("workflow", "workflows")
        case (.task, .full): ("background task", "background tasks")
        case (.task, .compact): ("task", "tasks")
        }
        return "\(count) \(count == 1 ? singular : plural)"
    }
}

extension SessionWaitingSummary.ItemKind {
    /// The label an item gets when its provider names nothing better.
    public var defaultLabel: String {
        switch self {
        case .agent: "sub-agent"
        case .process: "shell"
        case .workflow: "workflow"
        case .task: "task"
        }
    }
}
