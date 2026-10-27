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
        /// The coordinator's turn is running, as its sidebar row shows.
        var working = false
        /// When the running turn began, when the provider reports it.
        var turnStartedAt: Date?
    }

    struct Focus: Encodable, Equatable {
        var taskID: String
        var token: Int
        /// The card to open, when the task's newest card is a question: it
        /// asks the user something newer than any packet. `nil` lets the
        /// page open the newest packet card, else the last card.
        var cardID: String?
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

    /// What All tasks shows when a view request asks: one project's tasks,
    /// with one stage group open and its first row selected.
    struct TasksFilter: Encodable, Equatable {
        /// The stable project ID; `nil` for every project.
        var project: String?
        /// A group ID from `CoordinatorAllTasks.groupID`.
        var group: String
    }

    /// Asks the page to show the chat or All tasks; a new token asks again.
    struct ViewRequest: Encodable, Equatable {
        var view: CoordinatorChatPageView
        var filter: TasksFilter?
        var token: Int
    }

    struct RouteProject: Encodable, Equatable {
        var value: String
        var project: CoordinatorAllTasks.Project

        static func make(value: String, projects: [CoordinatorAllTasks.Project],
                         fallbackProjects: [CoordinatorAllTasks.Project] = [], homeDirectoryPath: String) -> Self? {
            if let project = projects.first(where: { $0.id == value }) {
                return Self(value: value, project: project)
            }
            let isPath = value.hasPrefix("/") || value == "~" || value.hasPrefix("~/")
            let root = isPath ? TasksConfigFile.normalizedPath(value, homeDirectoryPath: homeDirectoryPath) : nil
            if let project = projects.first(where: { root != nil && $0.rootPath == root })
                ?? fallbackProjects.first(where: { $0.id == value })
                ?? fallbackProjects.first(where: { root != nil && $0.rootPath == root }) {
                return Self(value: value, project: project)
            }
            return nil
        }
    }

    var coordinator: Coordinator
    var items: [CoordinatorChatItem]
    var focus: Focus?
    var notice: Notice?
    var ack: Ack?
    var view: ViewRequest?
    var taskGroups: [CoordinatorAllTasks.Group] = []
    var tasks: [CoordinatorAllTasks.Row] = []
    var projects: [CoordinatorAllTasks.Project] = []
    var routeProjects: [RouteProject] = []
    var projectFilter: String?
    var today = CoordinatorAllTasks.Today()
    var addresses: [CoordinatorComposerAddress] = []
    var hasUserRequests = false

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
    var options: [String]
    var answer: String?
    var thread: [CoordinatorChatTimeline.ThreadEntry]
    var isCurrent: Bool
    var task: CoordinatorChatTaskView?
    var packet: CoordinatorChatPacketView?
    var packetVersions: [Int]
    var answerPending = false
    var answeredQuestionIDs: [UUID]

    init(card: CoordinatorChatTimeline.Card, task: CoordinatorChatTaskView?, packet: CoordinatorChatPacketView?) {
        id = card.id
        at = card.at
        kind = card.kind.rawValue
        text = card.text
        superseded = card.superseded
        isNew = card.isNew
        options = card.options
        answer = card.answer
        thread = card.thread
        isCurrent = card.isCurrent
        self.task = task
        self.packet = packet
        packetVersions = card.packetVersions
        answerPending = card.answerPending
        answeredQuestionIDs = card.answeredQuestionIDs
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, at, kind, text, superseded, isNew, options, answer, thread, isCurrent, task, packet, packetVersions, answerPending, answeredQuestionIDs
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type)
        try values.encode(id, forKey: .id)
        try values.encode(at, forKey: .at)
        try values.encode(kind, forKey: .kind)
        try values.encode(text, forKey: .text)
        try values.encode(superseded, forKey: .superseded)
        try values.encode(isNew, forKey: .isNew)
        try values.encode(options, forKey: .options)
        // The page distinguishes unanswered (null) from an answer's text.
        try values.encode(answer, forKey: .answer)
        try values.encode(thread, forKey: .thread)
        try values.encode(isCurrent, forKey: .isCurrent)
        try values.encode(task, forKey: .task)
        try values.encode(packet, forKey: .packet)
        try values.encode(packetVersions, forKey: .packetVersions)
        try values.encode(answerPending, forKey: .answerPending)
        try values.encode(answeredQuestionIDs, forKey: .answeredQuestionIDs)
    }

}

enum CoordinatorChatReplyTarget: String, Encodable {
    case task, coordinator
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
    var projectID: String? = nil
    var defaultReplyTarget: CoordinatorChatReplyTarget = .coordinator
    var failureText: String? = nil
    var canArchive = false

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
            canReply: record != nil && finished == false && item?.taskSpaceWorkspaceID != nil,
            projectID: item.flatMap(CoordinatorAllTasks.projectID) ?? record?.projectRoot,
            canArchive: item.map { TaskBoardPresentation.detailActions($0).contains(.archive) } ?? false
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
        // Amber is for what needs the user; working stays calm.
        case .running: ("working", "working")
        case .toShip: ("merged · to ship", "violet")
        case .done: ("done", "green")
        case .archived: ("archived", "plain")
        case .needsYou(let attention):
            switch attention {
            case .review, .readyForReview: ("review", "blue")
            case .agentNeedsInput: ("needs input", "amber")
            case .agentFinished: ("finished", "blue")
            case .agentError: ("stuck", "red")
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
    var slug: String
    var canAnnotate: Bool
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

/// A native lookup key and the exact token offered by the composer.
struct CoordinatorComposerAddress: Encodable, Equatable {
    var kind: String
    var id: String
    var token: String
    var title: String
    var version: Int?
}

/// An explicit project pick, built from current workspace choices by Swift.
/// The one-line JSON envelope keeps titles and user text unambiguous.
struct CoordinatorProjectRequest: Codable, Equatable {
    var projectName: String
    var projectRoot: String
    var workspaceID: UUID?
    var text: String

    private static let prefix = "Toastty project request: "
    var message: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Self.prefix + String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }

    init(projectName: String, projectRoot: String, workspaceID: UUID?, text: String) {
        self.projectName = projectName
        self.projectRoot = projectRoot
        self.workspaceID = workspaceID
        self.text = text
    }

    init?(message: String) {
        guard message.hasPrefix(Self.prefix),
              let decoded = try? JSONDecoder().decode(Self.self, from: Data(message.dropFirst(Self.prefix.count).utf8)),
              decoded.projectRoot.hasPrefix("/"), !decoded.projectName.isEmpty, !decoded.text.isEmpty else { return nil }
        self = decoded
    }
}

struct CoordinatorReportMark: Codable, Equatable {
    var shot: String
    var note: String
    var x: Double
    var y: Double

    static func decode(_ raw: Any?) -> [Self]? {
        guard let raw = raw as? [[String: Any]], raw.count <= 100,
              JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode([Self].self, from: data)
    }

    static func message(_ marks: [Self], screenshotNames: Set<String>) -> String? {
        guard !marks.isEmpty, marks.count <= 100 else { return nil }
        var lines: [String] = []
        for (index, mark) in marks.enumerated() {
            let note = mark.note.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let unsafeControls = CharacterSet.controlCharacters.subtracting(.whitespacesAndNewlines)
            guard screenshotNames.contains(mark.shot), !note.isEmpty,
                  !mark.note.unicodeScalars.contains(where: { unsafeControls.contains($0) }),
                  mark.x.isFinite, mark.y.isFinite, (0...1).contains(mark.x), (0...1).contains(mark.y) else { return nil }
            lines.append("\(index + 1). \(note) [\(mark.shot)]")
        }
        let noun = marks.count == 1 ? "mark" : "marks"
        let text = "\(marks.count) \(noun) on the screenshots:\n" + lines.joined(separator: "\n")
        return text.utf8.count <= CoordinatorChatPageEvent.maximumTextLength ? text : nil
    }
}

enum CoordinatorReportSendResult: Equatable {
    case sent, rejected, unconfirmed
}

/// What the chat sends the coordinator when the user asks about a card: the
/// user's text, after a line that names the task. The agent needs the task
/// ID; the chat shows only what the user typed, so the transcript reads the
/// same format back with `init?(message:)`.
/// A project pick has no task yet. Use a complete JSON envelope so the
/// coordinator receives the original question and the exact selected choice.
struct CoordinatorRouteAnswer: Codable, Equatable {
    var questionID: UUID
    var replyID: UUID
    var question: String
    var answer: String

    private static let prefix = "Coordinator route answer: "

    var message: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // All fields have an infallible JSON representation.
        return Self.prefix + String(decoding: try! encoder.encode(self), as: UTF8.self)
    }

    init(questionID: UUID, replyID: UUID, question: String, answer: String) {
        self.questionID = questionID
        self.replyID = replyID
        self.question = question
        self.answer = answer
    }

    init?(message: String) {
        guard message.hasPrefix(Self.prefix), message.utf8.count <= CoordinatorChatPageEvent.maximumTextLength else { return nil }
        let data = Data(message.dropFirst(Self.prefix.count).utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["questionID", "replyID", "question", "answer"],
              let value = try? JSONDecoder().decode(Self.self, from: data),
              !value.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.question.count <= CoordinatorEvent.maximumTextLength,
              !value.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.answer.count <= CoordinatorEvent.maximumOptionLength else { return nil }
        self = value
    }
}

struct CoordinatorTaskAsk: Equatable {
    var taskID: UUID
    var title: String
    var packetVersion: Int?
    var text: String
    var replyID: UUID?
    var questionID: UUID?

    /// The title is quoted with `\"` and `\\` escaped, so nothing in it can
    /// look like the end of the line that names the task.
    var message: String {
        let packet = packetVersion.map { ", packet v\($0)" } ?? ""
        let references = replyID.map { ", reply ID \($0.uuidString)" } ?? ""
        let question = questionID.map { ", question ID \($0.uuidString)" } ?? ""
        let quoted = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "About task \"\(quoted)\" (task ID \(taskID.uuidString)\(packet)\(references)\(question)): \(text)"
    }

    init(taskID: UUID, title: String, packetVersion: Int?, text: String, replyID: UUID? = nil, questionID: UUID? = nil) {
        self.taskID = taskID
        self.title = title
        self.packetVersion = packetVersion
        self.text = text
        self.replyID = replyID
        self.questionID = questionID
    }

    /// The ask a message carries, or `nil` for anything else the user typed.
    /// An older message whose title has an unescaped quote stays as typed.
    init?(message: String) {
        // A regex is not Sendable, so it is built here rather than kept.
        let pattern = /About task "(?<title>(?:[^"\\]|\\.)*)" \(task ID (?<id>[0-9A-Fa-f-]{36})(?:, packet v(?<version>[0-9]+))?(?:, reply ID (?<reply>[0-9A-Fa-f-]{36}))?(?:, question ID (?<question>[0-9A-Fa-f-]{36}))?\): (?<text>.*)/
            .dotMatchesNewlines()
        guard let match = message.wholeMatch(of: pattern),
              let taskID = UUID(uuidString: String(match.output.id)) else { return nil }
        let text = String(match.output.text)
        guard text.isEmpty == false else { return nil }
        self.init(
            taskID: taskID,
            title: String(match.output.title).replacing(/\\(.)/.dotMatchesNewlines()) { String($0.output.1) },
            packetVersion: match.output.version.flatMap { Int($0) },
            text: text,
            replyID: match.output.reply.flatMap { UUID(uuidString: String($0)) },
            questionID: match.output.question.flatMap { UUID(uuidString: String($0)) }
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
        /// An assistant message's `commentary` or `final`, when the provider
        /// tells them apart: the chat folds commentary with the tool calls.
        var phase: String?
        /// The automatic first message of a coordinator session, which the
        /// chat does not show.
        var launch: Bool?
        var name: String?
        var detail: String?
        var outcome: String?
        /// For a question the user asked from a card: its task, which the
        /// chat names beside the message.
        var aboutTaskID: String?
        var aboutTitle: String?
        var replyID: UUID?
        var questionID: UUID?
        var sourceID: String?
        var routeAnswer: CoordinatorRouteAnswer?
    }

    private(set) var items: [Item] = []
    private(set) var cursor: ConversationEventCursor?
    private var conversationID: RemoteConversationID?
    private var toolIndexByCallID: [String: Int] = [:]
    /// Intro suggestions stay hidden after a real request, even when that
    /// message falls out of the bounded timeline. Lives with this chat.
    private(set) var hasUserRequests = false
    private var isFirstUserMessage = true
    private var bootstrapMessageID: String?

    /// A different conversation is a fresh coordinator session: its events
    /// follow the old ones.
    mutating func follow(_ conversationID: RemoteConversationID) {
        guard self.conversationID != conversationID else { return }
        if self.conversationID != nil {
            append(Item(type: .status, id: "session-\(conversationID.rawValue)", at: Date(), text: "A new coordinator session started"))
        }
        self.conversationID = conversationID
        isFirstUserMessage = true
        bootstrapMessageID = nil
        cursor = nil
        toolIndexByCallID = [:]
    }

    /// The projection was rebuilt; read it again from its start.
    mutating func reset() {
        items.removeAll { $0.id.hasPrefix(conversationID.map { "\($0.rawValue)/" } ?? "") }
        cursor = nil
        toolIndexByCallID = [:]
        isFirstUserMessage = true
        // Keep bootstrap identity for a replay with late origin enrichment.
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
            // Each fresh coordinator launch sends this exact first prompt.
            // Restoring a session resumes it without sending the prompt again.
            let isBootstrap = text == CoordinatorPrompts.initial &&
                (id == bootstrapMessageID || (isFirstUserMessage && message.origin == .unknown))
            isFirstUserMessage = false
            if isBootstrap { bootstrapMessageID = id }
            else { hasUserRequests = true }
            if let ask = CoordinatorTaskAsk(message: text) {
                append(Item(
                    type: .message, id: id, at: event.timestamp, role: "user", text: ask.text,
                    aboutTaskID: ask.taskID.uuidString, aboutTitle: ask.title,
                    replyID: ask.replyID, questionID: ask.questionID, sourceID: event.eventID
                ))
            } else if let answer = CoordinatorRouteAnswer(message: text) {
                append(Item(type: .message, id: id, at: event.timestamp, role: "user", text: "Project: \(answer.answer)",
                            sourceID: event.eventID, routeAnswer: answer))
            } else if let request = CoordinatorProjectRequest(message: text) {
                append(Item(type: .message, id: id, at: event.timestamp, role: "user", text: "@\(request.projectName) \(request.text)"))
            } else {
                append(Item(type: .message, id: id, at: event.timestamp, role: "user", text: text, launch: isBootstrap ? true : nil))
            }
        case .assistantMessage(let message):
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else { return }
            let phase = message.phase == .unknown ? nil : message.phase.rawValue
            append(Item(type: .message, id: id, at: event.timestamp, role: "assistant", text: text, phase: phase))
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
    case today
}

/// What the chat page asks for; see `ChatEvent` in the page's types.
enum CoordinatorChatPageEvent: Equatable {
    case ready
    /// The page drew the state; it reports the cards it has open, the view
    /// it shows, and the All tasks row selected.
    case rendered(expanded: [String], view: CoordinatorChatPageView = .chat, selectedRowID: String? = nil)
    /// An All tasks row's action, by the IDs the row was drawn with.
    case taskAction(rowID: String, actionID: String)
    case projectFilter(String?)
    case showView(CoordinatorChatPageView)
    case activate(view: CoordinatorChatPageView, selectedRowID: String?)
    case send(String)
    case project(id: String, text: String)
    case reply(taskID: UUID, version: Int?, text: String, cardID: String? = nil, questionID: UUID? = nil)
    case ask(taskID: UUID, version: Int?, text: String, cardID: String? = nil, questionID: UUID? = nil)
    case answerRoute(questionID: UUID, optionIndex: Int)
    case archiveTask(UUID)
    case merge(UUID)
    case taskMenu(taskID: UUID, rect: CGRect)
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
        let cardID = (body["cardID"] as? String).flatMap { $0.count <= 100 ? $0 : nil }
        let questionID = (body["questionID"] as? String).flatMap(UUID.init(uuidString:))
        if let value = body["cardID"], !(value is NSNull), cardID == nil { return nil }
        if let value = body["questionID"], !(value is NSNull), questionID == nil { return nil }
        if type == "reply" || type == "ask", let value = body["version"], !(value is NSNull), version() == nil { return nil }
        switch type {
        case "ready": self = .ready
        case "projectFilter":
            if body["project"] == nil || body["project"] is NSNull { self = .projectFilter(nil) }
            else if let project = body["project"] as? String, project.isEmpty == false, project.utf8.count <= 4096 {
                self = .projectFilter(project)
            } else { return nil }
        case "showView":
            guard let raw = body["view"] as? String, let view = CoordinatorChatPageView(rawValue: raw), view != .chat else { return nil }
            self = .showView(view)
        case "activate":
            guard let raw = body["view"] as? String, let view = CoordinatorChatPageView(rawValue: raw) else { return nil }
            self = .activate(view: view, selectedRowID: (body["selected"] as? String).flatMap { $0.count <= 64 ? $0 : nil })
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
        case "project":
            guard let id = body["projectID"] as? String, !id.isEmpty, id.utf8.count <= 4096,
                  let text = text() else { return nil }
            self = .project(id: id, text: text)
        case "reply":
            guard let taskID = taskID(), let text = text() else { return nil }
            self = .reply(taskID: taskID, version: version(), text: text, cardID: cardID, questionID: questionID)
        case "ask":
            guard let taskID = taskID(), let text = text() else { return nil }
            self = .ask(taskID: taskID, version: version(), text: text, cardID: cardID, questionID: questionID)
        case "answerRoute":
            guard let questionID,
                  let number = body["optionIndex"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let index = Int(exactly: number.doubleValue), (0..<CoordinatorEvent.maximumOptionCount).contains(index) else { return nil }
            self = .answerRoute(questionID: questionID, optionIndex: index)
        case "archiveTask":
            guard let taskID = taskID() else { return nil }
            self = .archiveTask(taskID)
        case "taskMenu":
            guard let taskID = taskID() else { return nil }
            func coordinate(_ key: String) -> Double? {
                guard let value = body[key] as? Double, value.isFinite, abs(value) <= 100_000 else { return nil }
                return value
            }
            guard let x = coordinate("x"), let y = coordinate("y"),
                  let width = coordinate("width"), let height = coordinate("height"),
                  width > 0, height > 0 else { return nil }
            self = .taskMenu(taskID: taskID, rect: CGRect(x: x, y: y, width: width, height: height))
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
