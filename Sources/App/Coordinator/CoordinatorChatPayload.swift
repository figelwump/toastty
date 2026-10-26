import CoreState
import Foundation
import RemoteProtocol

/// The state the chat page renders: `WebPanels/CoordinatorApp/src/types.ts`
/// is the same shape. Items are in time order.
struct CoordinatorChatPayload: Encodable, Equatable {
    struct Coordinator: Encodable, Equatable {
        var title: String
        var detail: String
        var canSend: Bool
        var sendHint: String?
        var hasTerminal: Bool
    }

    struct Focus: Encodable, Equatable {
        var taskID: String
        var token: Int
    }

    struct Notice: Encodable, Equatable {
        var text: String
        var isError: Bool
        var token: Int
    }

    /// The answer to a send, reply or ask that carried `token`: the page
    /// clears what was typed only once it was taken.
    struct Ack: Encodable, Equatable {
        var token: Int
        var ok: Bool
    }

    /// Asks the page to show the chat or All tasks; a new token asks again.
    struct ViewRequest: Encodable, Equatable {
        var view: CoordinatorChatPageView
        var token: Int
    }

    var coordinator: Coordinator
    var items: [CoordinatorChatItem]
    var focus: Focus?
    var notice: Notice?
    var ack: Ack?
    var view: ViewRequest?
    var taskGroups: [CoordinatorAllTasks.Group] = []
    var tasks: [CoordinatorAllTasks.Row] = []

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

enum CoordinatorChatItem: Encodable, Equatable {
    case transcript(CoordinatorChatTranscript.Item)
    case card(CoordinatorChatCardView)

    var at: Date {
        switch self {
        case .transcript(let item): item.at
        case .card(let card): card.at
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .transcript(let item): try item.encode(to: encoder)
        case .card(let card): try card.encode(to: encoder)
        }
    }
}

struct CoordinatorChatCardView: Encodable, Equatable {
    var type = "card"
    var id: String
    var at: Date
    var kind: String
    var text: String?
    var superseded: Bool
    var isNew: Bool
    var task: CoordinatorChatTaskView?
    var packet: CoordinatorChatPacketView?

    init(card: CoordinatorChatTimeline.Card, task: CoordinatorChatTaskView?, packet: CoordinatorChatPacketView?) {
        id = card.id
        at = card.at
        kind = card.kind.rawValue
        text = card.text
        superseded = card.superseded
        isNew = card.isNew
        self.task = task
        self.packet = packet
    }
}

struct CoordinatorChatTaskView: Encodable, Equatable {
    var id: String
    var title: String
    var slug: String
    var project: String?
    var stageLabel: String
    var stageTone: String
    var needsUser: Bool
    var hasTaskSpace: Bool
    var pullRequestURL: String?
    var pullRequestLabel: String?
    var packetVersion: Int?
    var stale: Bool
    var mergePolicy: String
    var canMerge: Bool
    var canReply: Bool

    static func make(
        taskID: UUID,
        record: TaskRecord?,
        item: TaskBoardItem?,
        stale: Bool,
        config: TasksConfig?,
        homeDirectoryPath: String
    ) -> CoordinatorChatTaskView {
        let stage = item?.stage
        let (label, tone) = item.map(Self.label) ?? ("deleted", "plain")
        let pullRequestURL = item?.pullRequest?.url ?? record?.pullRequestURL
        let project = item?.projectTitle ?? record?.projectRoot.map { URL(filePath: $0).lastPathComponent }
        let finished = stage.map { $0.isFinished } ?? true
        return CoordinatorChatTaskView(
            id: taskID.uuidString,
            title: record?.title ?? item?.title ?? "Deleted task",
            slug: record?.slug ?? "",
            project: project,
            stageLabel: label,
            stageTone: tone,
            needsUser: stage?.needsUser ?? false,
            hasTaskSpace: item?.taskSpaceWorkspaceID != nil,
            pullRequestURL: pullRequestURL,
            pullRequestLabel: item?.pullRequest.map { "PR #\($0.number)" } ?? pullRequestURL.map { _ in "PR" },
            packetVersion: record?.packetVersion,
            stale: stale,
            mergePolicy: Self.mergePolicy(record: record, config: config, homeDirectoryPath: homeDirectoryPath),
            canMerge: item.map { TaskBoardPresentation.detailActions($0).contains(.merge) } ?? false,
            canReply: record != nil && finished == false && item?.taskSpaceWorkspaceID != nil
        )
    }

    static func label(_ item: TaskBoardItem) -> (String, String) {
        if item.stage == .running, TaskBoardPresentation.showsSetup(item) {
            return (item.record?.setup.isStarted == true ? "moving to worktree" : "setting up", "plain")
        }
        return label(item.stage)
    }

    /// What the stage looks like on a card: the prototype's badges.
    static func label(_ stage: TaskStage) -> (String, String) {
        switch stage {
        case .running: ("working", "amber")
        case .toShip: ("merged · to ship", "violet")
        case .done: ("done", "green")
        case .archived: ("archived", "plain")
        case .needsYou(let attention):
            switch attention {
            case .review, .readyForReview: ("review", "blue")
            case .agentNeedsInput: ("needs input", "amber")
            case .agentFinished: ("finished", "blue")
            case .agentError: ("error", "red")
            case .setupFailed, .moveFailed: ("failed", "red")
            case .taskSpaceClosed: ("task space closed", "plain")
            case .pickWorkspace: ("pick a project", "amber")
            case .cleanupStopped: ("cleanup stopped", "red")
            }
        }
    }

    /// What Merge does in the task's project, as the confirmation says it.
    /// Toastty never merges on the coordinator's word: Merge here is the
    /// user's own acceptance, as the Merge button is.
    static func mergePolicy(record: TaskRecord?, config: TasksConfig?, homeDirectoryPath: String) -> String {
        let workspace = record?.projectRoot.flatMap { config?.workspace(forProjectRoot: $0, homeDirectoryPath: homeDirectoryPath) }
        let mode = workspace?.merge ?? config?.defaults.merge ?? .agent
        var policy: String
        switch mode {
        case .direct:
            policy = "Merge merges right away (merge = \"direct\")."
        case .agent:
            let skill = workspace?.mergeSkill ?? config?.defaults.mergeSkill
            let prompt = workspace?.mergePrompt ?? config?.defaults.mergePrompt
            if let skill {
                policy = "Merge sends \(skill) to the task's agent, which checks the pull request first."
            } else if prompt != nil {
                policy = "Merge sends the project's merge_prompt to the task's agent."
            } else {
                policy = "Merge sends \(TaskPrompt.defaultMergeSkill) to the task's agent, which checks the pull request first."
            }
        }
        if let tags = workspace?.releaseTags {
            policy += " It then waits in To ship for a \(tags) release."
        }
        return policy
    }
}

struct CoordinatorChatPacketView: Encodable, Equatable {
    struct Check: Encodable, Equatable {
        var name: String
        var ok: Bool
        var log: String?
    }

    struct Screenshot: Encodable, Equatable {
        var name: String
        var pair: String?
        var width: Int?
        var url: String

        private enum CodingKeys: String, CodingKey { case name, pair, width, url }

        // The page tells an unpaired screenshot by `pair: null`, so nulls
        // are written out rather than left out.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(pair, forKey: .pair)
            try container.encode(width, forKey: .width)
            try container.encode(url, forKey: .url)
        }
    }

    var version: Int
    var latestVersion: Int
    var summary: String
    var lookAt: String
    var checks: [Check]
    var notVerified: [String]
    var screenshots: [Screenshot]

    init(packet: TaskPacket, taskID: UUID, latestVersion: Int) {
        let version = packet.version ?? 0
        self.version = version
        self.latestVersion = max(latestVersion, version)
        summary = packet.summary
        lookAt = packet.lookAt
        checks = packet.checks.map { Check(name: $0.name, ok: $0.ok, log: $0.log) }
        notVerified = packet.notVerified
        screenshots = packet.screenshots.compactMap { shot in
            shot.file.map {
                Screenshot(
                    name: shot.name,
                    pair: shot.pair?.rawValue,
                    width: shot.width,
                    url: "toastty://coordinator/packet-files/\(taskID.uuidString)/v\(version)/\($0)"
                )
            }
        }
    }
}

/// What the report page reads from `packet-data/<task>/<version>`.
struct CoordinatorChatReport: Encodable {
    var taskID: String
    var title: String
    var version: Int
    var latestVersion: Int
    var summary: String
    var lookAt: String
    var checks: [CoordinatorChatPacketView.Check]
    var notVerified: [String]
    var screenshots: [CoordinatorChatPacketView.Screenshot]
    var headCommit: String?
    var createdAt: String?
}

/// What the chat sends the coordinator when the user asks about a card: the
/// user's text, after a line that names the task. The agent needs the task
/// ID; the chat shows only what the user typed, so the transcript reads the
/// same format back with `init?(message:)`.
struct CoordinatorTaskAsk: Equatable {
    var taskID: UUID
    var title: String
    var packetVersion: Int?
    var text: String

    var message: String {
        let packet = packetVersion.map { ", packet v\($0)" } ?? ""
        return "About task \"\(title)\" (task ID \(taskID.uuidString)\(packet)): \(text)"
    }

    init(taskID: UUID, title: String, packetVersion: Int?, text: String) {
        self.taskID = taskID
        self.title = title
        self.packetVersion = packetVersion
        self.text = text
    }

    /// The ask a message carries, or `nil` for anything else the user typed.
    init?(message: String) {
        // A regex is not Sendable, so it is built here rather than kept.
        let pattern = /About task "(?<title>.*?)" \(task ID (?<id>[0-9A-Fa-f-]{36})(?:, packet v(?<version>[0-9]+))?\): (?<text>.*)/
            .dotMatchesNewlines()
        guard let match = message.wholeMatch(of: pattern),
              let taskID = UUID(uuidString: String(match.output.id)) else { return nil }
        let text = String(match.output.text)
        guard text.isEmpty == false else { return nil }
        self.init(
            taskID: taskID,
            title: String(match.output.title),
            packetVersion: match.output.version.flatMap { Int($0) },
            text: text
        )
    }
}

/// The coordinator's conversation as chat lines: messages, tool calls
/// folded to one line each, and where a session began or ended. Kept to
/// the last `maximumItems`.
struct CoordinatorChatTranscript {
    static let maximumItems = 400

    struct Item: Encodable, Equatable {
        enum Kind: String, Encodable {
            case message, tool, status
        }

        var type: Kind
        var id: String
        var at: Date
        var role: String?
        var text: String?
        var name: String?
        var detail: String?
        var outcome: String?
        /// For a question the user asked from a card: its task, which the
        /// chat names beside the message.
        var aboutTaskID: String?
        var aboutTitle: String?
    }

    private(set) var items: [Item] = []
    private(set) var cursor: ConversationEventCursor?
    private var conversationID: RemoteConversationID?
    private var toolIndexByCallID: [String: Int] = [:]

    /// A different conversation is a fresh coordinator session: its events
    /// follow the old ones.
    mutating func follow(_ conversationID: RemoteConversationID) {
        guard self.conversationID != conversationID else { return }
        if self.conversationID != nil {
            append(Item(type: .status, id: "session-\(conversationID.rawValue)", at: Date(), text: "A new coordinator session started"))
        }
        self.conversationID = conversationID
        cursor = nil
        toolIndexByCallID = [:]
    }

    /// The projection was rebuilt; read it again from its start.
    mutating func reset() {
        items.removeAll { $0.id.hasPrefix(conversationID.map { "\($0.rawValue)/" } ?? "") }
        cursor = nil
        toolIndexByCallID = [:]
    }

    mutating func apply(_ page: ConversationEventPage) {
        for event in page.events { apply(event) }
        if let last = page.events.last {
            cursor = ConversationEventCursor(
                projectionRunID: page.projectionRunID,
                projectionGeneration: page.projectionGeneration,
                afterSequence: last.sequence
            )
        }
    }

    mutating func apply(_ event: ConversationEvent) {
        let id = "\(event.conversationID.rawValue)/\(event.sequence)"
        switch event.payload {
        case .userMessage(let message):
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else { return }
            if let ask = CoordinatorTaskAsk(message: text) {
                append(Item(
                    type: .message, id: id, at: event.timestamp, role: "user", text: ask.text,
                    aboutTaskID: ask.taskID.uuidString, aboutTitle: ask.title
                ))
            } else {
                append(Item(type: .message, id: id, at: event.timestamp, role: "user", text: text))
            }
        case .assistantMessage(let message):
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else { return }
            append(Item(type: .message, id: id, at: event.timestamp, role: "assistant", text: text))
        case .toolStarted(let tool):
            append(Item(type: .tool, id: id, at: event.timestamp, name: tool.toolName, detail: tool.detail, outcome: "running"))
            toolIndexByCallID[tool.callID] = items.count - 1
        case .toolFinished(let tool):
            if let index = toolIndexByCallID.removeValue(forKey: tool.callID), items.indices.contains(index) {
                items[index].outcome = tool.outcome.rawValue
            }
        case .sessionBindingChanged(let change):
            switch change.reason {
            case .runtimeEnded:
                append(Item(type: .status, id: id, at: event.timestamp, text: "The coordinator session ended"))
            default:
                break
            }
        case .interactionPresented:
            append(Item(type: .status, id: id, at: event.timestamp, text: "The coordinator waits for an answer in its terminal"))
        case .statusChanged, .interactionResolved, .interactionResponseClosed, .subagentSummary, .sendDeliveryUnconfirmed:
            break
        }
    }

    private mutating func append(_ item: Item) {
        items.append(item)
        let overflow = items.count - Self.maximumItems
        guard overflow > 0 else { return }
        items.removeFirst(overflow)
        toolIndexByCallID = toolIndexByCallID.compactMapValues { $0 >= overflow ? $0 - overflow : nil }
    }
}

/// The page's two views: the chat, and the All tasks list.
enum CoordinatorChatPageView: String, Encodable, Equatable {
    case chat
    case tasks
}

/// What the chat page asks for; see `ChatEvent` in the page's types.
enum CoordinatorChatPageEvent: Equatable {
    case ready
    /// The page drew the state; it reports the cards it has open, the view
    /// it shows, and the All tasks row selected.
    case rendered(expanded: [String], view: CoordinatorChatPageView = .chat, selectedRowID: String? = nil)
    /// An All tasks row's action, by the IDs the row was drawn with.
    case taskAction(rowID: String, actionID: String)
    case send(String)
    case reply(taskID: UUID, version: Int, text: String)
    case ask(taskID: UUID, version: Int?, text: String)
    case merge(UUID)
    case openTaskSpace(UUID)
    case openURL(String)
    case openReport(taskID: UUID, version: Int, screenshot: String?)
    case openRouting
    case openTerminal

    static let maximumTextLength = 16 * 1024

    /// The page's message body, or `nil` for anything malformed.
    init?(body: Any) {
        guard let body = body as? [String: Any], let type = body["type"] as? String else { return nil }
        func text() -> String? {
            guard let raw = body["text"] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, trimmed.utf8.count <= Self.maximumTextLength else { return nil }
            return trimmed
        }
        func taskID() -> UUID? { (body["taskID"] as? String).flatMap(UUID.init(uuidString:)) }
        func version() -> Int? {
            guard let number = body["version"] as? NSNumber, let value = Int(exactly: number.doubleValue), value > 0 else { return nil }
            return value
        }
        switch type {
        case "ready": self = .ready
        case "rendered":
            self = .rendered(
                expanded: ((body["expanded"] as? [Any]) ?? []).compactMap { $0 as? String }.prefix(200).map { $0 },
                view: (body["view"] as? String).flatMap(CoordinatorChatPageView.init(rawValue:)) ?? .chat,
                selectedRowID: (body["selected"] as? String).flatMap { $0.count <= 64 ? $0 : nil }
            )
        case "taskAction":
            guard let rowID = body["rowID"] as? String, rowID.count <= 64,
                  let actionID = body["actionID"] as? String, actionID.count <= 64 else { return nil }
            self = .taskAction(rowID: rowID, actionID: actionID)
        case "send":
            guard let text = text() else { return nil }
            self = .send(text)
        case "reply":
            guard let taskID = taskID(), let version = version(), let text = text() else { return nil }
            self = .reply(taskID: taskID, version: version, text: text)
        case "ask":
            guard let taskID = taskID(), let text = text() else { return nil }
            self = .ask(taskID: taskID, version: version(), text: text)
        case "merge":
            guard let taskID = taskID() else { return nil }
            self = .merge(taskID)
        case "openTaskSpace":
            guard let taskID = taskID() else { return nil }
            self = .openTaskSpace(taskID)
        case "openURL":
            guard let url = body["url"] as? String, url.hasPrefix("https://") || url.hasPrefix("http://") else { return nil }
            self = .openURL(url)
        case "openReport":
            guard let taskID = taskID(), let version = version() else { return nil }
            self = .openReport(taskID: taskID, version: version, screenshot: body["screenshot"] as? String)
        case "openRouting": self = .openRouting
        case "openTerminal": self = .openTerminal
        default: return nil
        }
    }
}
