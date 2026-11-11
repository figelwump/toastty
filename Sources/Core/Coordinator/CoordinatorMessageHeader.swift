import Foundation

/// The first line that Toastty writes on a message it types into the
/// coordinator for someone else.
///
/// The coordinator reads its messages as text, so the text must say who
/// sent it. Toastty decides that from who called it, never from the
/// message: the sender's own text starts on the second line, and only the
/// first line counts. So no text can make a message look like the user's,
/// like a digest, or like another sender's.
///
/// - `[Toastty] Wake …`: a digest (`CoordinatorWakeState`).
/// - `[Toastty] From …`: a message that `coordinator send` brought.
/// - `[Toastty] Quick entry …`: the user's message from the quick entry
///   panel, with the choices the user made there.
public enum CoordinatorMessageHeader {
    /// Who ran `coordinator send`, as far as Toastty can tell.
    public enum Sender: Equatable, Sendable {
        /// A session in a task's space.
        case task(id: UUID, title: String)
        /// A managed session that belongs to no task.
        case session(id: String, agent: String, workspaceTitle: String?)
        /// A caller that named no running session: a shell, a script, or
        /// an agent without its session's environment.
        case unknown
    }

    public static let senderPrefix = "[Toastty] From "
    public static let quickEntryPrefix = "[Toastty] Quick entry"

    /// The longest title a header carries.
    static let maximumTitleLength = 60

    // MARK: - coordinator send

    public static func senderLine(_ sender: Sender) -> String {
        switch sender {
        case .task(let id, let title):
            return "\(senderPrefix)task [\(CoordinatorWakeState.linkText(title))](toastty://task/\(id.uuidString)): not from the user."
        case .session(let id, let agent, let workspaceTitle):
            let place = workspaceTitle.map { ", workspace \(quoted($0))" } ?? ""
            return "\(senderPrefix)agent session \(word(id)) (\(word(agent))\(place)): not from the user."
        case .unknown:
            return "\(senderPrefix)a terminal command: Toastty cannot tell who ran it."
        }
    }

    /// The text to type for a message that `coordinator send` brought.
    public static func message(from sender: Sender, text: String) -> String {
        senderLine(sender) + "\n" + text
    }

    // MARK: - Quick entry

    /// A workspace as a header names it: its title for the reader, its ID
    /// for `task create --workspace`.
    public struct Workspace: Equatable, Sendable {
        public var id: UUID
        public var title: String

        public init(id: UUID, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// What the user set in the quick entry panel, and what Toastty saw.
    public struct QuickEntry: Equatable, Sendable {
        /// The project the user chose with the Workspace pill.
        public var project: Workspace?
        /// The agent profile the user chose with the Agent pill.
        public var agent: String?
        public var model: String?
        public var effort: String?
        /// The project selected in Toastty when the panel opened. A hint:
        /// the user did not choose it for this message.
        public var selectedProject: Workspace?

        public init(
            project: Workspace? = nil,
            agent: String? = nil,
            model: String? = nil,
            effort: String? = nil,
            selectedProject: Workspace? = nil
        ) {
            self.project = project
            self.agent = agent
            self.model = model
            self.effort = effort
            self.selectedProject = selectedProject
        }
    }

    static let projectLabel = "project chosen: "
    static let agentLabel = "agent chosen: "
    static let selectedLabel = "selected in Toastty, a hint only: "
    static let separator = " | "

    public static func quickEntryLine(_ entry: QuickEntry) -> String {
        var parts = ["\(quickEntryPrefix) from the user"]
        if let project = entry.project {
            parts.append(projectLabel + workspace(project))
        }
        if let agent = entry.agent {
            var choice = word(agent)
            if let model = entry.model { choice += ", model \(word(model))" }
            if let effort = entry.effort { choice += ", effort \(word(effort))" }
            parts.append(agentLabel + choice)
        }
        // A project the user chose needs no hint.
        if entry.project == nil, let selected = entry.selectedProject {
            parts.append(selectedLabel + workspace(selected))
        }
        return parts.joined(separator: separator)
    }

    /// The text to type for a message from the quick entry panel. Each
    /// attached file is a path in a code span on its own line: Claude Code
    /// drops the Return that follows a bare pasted image path.
    public static func quickEntryMessage(_ entry: QuickEntry, text: String, attachmentPaths: [String] = []) -> String {
        let delivered = RemoteMessageAttachmentStore.Staged.deliveryText(text: text, paths: attachmentPaths)
        return quickEntryLine(entry) + "\n" + delivered
    }

    // MARK: - Reading a message

    /// What the first line of a message says about it.
    public enum Kind: Equatable, Sendable {
        /// One of Toastty's digests.
        case digest(updateCount: Int)
        /// A message that `coordinator send` brought. `sender` is short,
        /// for one line of a chat: "task Fix the unread dot".
        case fromSender(sender: String)
        /// The user's message from the quick entry panel. `text` is what
        /// the user wrote; `detail` names the choices and the files.
        case quickEntry(text: String, detail: String?)
        case plain
    }

    public static func kind(of message: String) -> Kind {
        if let updateCount = CoordinatorDigestFold.updateCount(inMessage: message) {
            return .digest(updateCount: updateCount)
        }
        let (first, rest) = splitFirstLine(message)
        if first.hasPrefix(senderPrefix) {
            return .fromSender(sender: senderName(inLine: first))
        }
        if first.hasPrefix(quickEntryPrefix) {
            let (text, fileNames) = splitAttachments(rest)
            var details = quickEntryDetails(inLine: first)
            if fileNames.isEmpty == false {
                details.append(fileNames.joined(separator: ", "))
            }
            return .quickEntry(text: text, detail: details.isEmpty ? nil : details.joined(separator: " · "))
        }
        return .plain
    }

    /// The message as a chat shows it in the user's bubble: a quick entry
    /// message without Toastty's first line, and any message without the
    /// folder of each attached file. A message without either is shown as
    /// it is.
    public static func displayText(of message: String) -> String {
        switch kind(of: message) {
        case .quickEntry(let text, let detail):
            return [text, detail].compactMap { $0 }.filter { $0.isEmpty == false }.joined(separator: "\n\n")
        case .plain:
            let (text, fileNames) = splitAttachments(message)
            guard fileNames.isEmpty == false else { return message }
            return [text, fileNames.joined(separator: ", ")].filter { $0.isEmpty == false }.joined(separator: "\n\n")
        case .digest, .fromSender:
            return message
        }
    }

    private static func splitFirstLine(_ message: String) -> (first: Substring, rest: String) {
        guard let end = message.firstIndex(where: \.isNewline) else { return (message[...], "") }
        return (message[..<end], String(message[message.index(after: end)...]))
    }

    /// "task Fix the unread dot", "agent session 1B2C (claude)" or
    /// "a terminal command", from a line `senderLine` wrote.
    private static func senderName(inLine line: Substring) -> String {
        var name = line.dropFirst(senderPrefix.count)
        // The clause after the last ": " is Toastty's note, not the name.
        if let note = name.range(of: ": ", options: .backwards) {
            name = name[..<note.lowerBound]
        }
        let prefix = "task ["
        let suffixStart = "](toastty://task/"
        if name.hasPrefix(prefix), let link = name.range(of: suffixStart, options: .backwards) {
            let title = name[name.index(name.startIndex, offsetBy: prefix.count)..<link.lowerBound]
                .replacingOccurrences(of: "\\[", with: "[")
                .replacingOccurrences(of: "\\]", with: "]")
                .replacingOccurrences(of: "\\\\", with: "\\")
            return "task \(title)"
        }
        return String(name)
    }

    /// The choices of a quick entry line, short: `project "toastty"`,
    /// `codex, model gpt-6.1-sol, effort high`. The hint is left out: the
    /// user did not choose it.
    private static func quickEntryDetails(inLine line: Substring) -> [String] {
        line.components(separatedBy: separator).dropFirst().compactMap { part in
            if part.hasPrefix(projectLabel) {
                return "project " + withoutWorkspaceID(part.dropFirst(projectLabel.count))
            }
            if part.hasPrefix(agentLabel) {
                return String(part.dropFirst(agentLabel.count))
            }
            return nil
        }
    }

    private static func withoutWorkspaceID(_ text: Substring) -> String {
        guard let id = text.range(of: " (workspace ", options: .backwards) else { return String(text) }
        return String(text[..<id.lowerBound])
    }

    /// The list of attached files at the end of a message: the text before
    /// it, and the path of each file. Only a list as Toastty writes it
    /// counts: the introduction, then nothing but one absolute path in a
    /// code span on each line, to the end. `nil` for a message without such
    /// a list; text that only quotes those words stays text.
    public static func attachedFiles(in message: String) -> (text: String, paths: [String])? {
        let marker = RemoteMessageAttachmentStore.Staged.attachmentsIntroduction
        guard let range = message.range(of: marker, options: .backwards) else { return nil }
        var paths: [String] = []
        for line in message[range.upperBound...].split(whereSeparator: \.isNewline) {
            guard let path = codeSpanContent(line), path.hasPrefix("/") else { return nil }
            paths.append(path)
        }
        guard paths.isEmpty == false else { return nil }
        return (message[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines), paths)
    }

    /// The text inside a code span that is the whole line, as
    /// `RemoteMessageAttachmentStore.Staged.codeSpan` writes it.
    private static func codeSpanContent(_ rawLine: Substring) -> String? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let fence = String(line.prefix { $0 == "`" })
        guard fence.isEmpty == false, line.count > fence.count * 2, line.hasSuffix(fence) else { return nil }
        var content = line.dropFirst(fence.count).dropLast(fence.count)
        // The closing run of backticks must be as long as the opening one.
        guard content.last != "`" else { return nil }
        // A path that starts or ends with a backtick is padded with a space.
        if content.count > 2, content.hasPrefix(" "), content.hasSuffix(" "),
           content.dropFirst().hasPrefix("`") || content.dropLast().hasSuffix("`") {
            content = content.dropFirst().dropLast()
        }
        return String(content)
    }

    /// Takes the list of attached files off the end of the text, and gives
    /// the name of each file.
    private static func splitAttachments(_ text: String) -> (text: String, fileNames: [String]) {
        guard let (rest, paths) = attachedFiles(in: text) else { return (text, []) }
        return (rest, paths.map { ($0 as NSString).lastPathComponent })
    }

    // MARK: - Text that is safe in a header

    private static func workspace(_ workspace: Workspace) -> String {
        "\(quoted(workspace.title)) (workspace \(workspace.id.uuidString))"
    }

    /// A title in quotes on one line. A workspace's title is a person's or
    /// an agent's text. It must not end the header's line, read as a
    /// second part of the header, or end its own quotes.
    static func quoted(_ title: String) -> String {
        let cleaned = oneLine(title)
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "|", with: "/")
        let shortened = cleaned.count > maximumTitleLength ? cleaned.prefix(maximumTitleLength - 1) + "…" : cleaned[...]
        return "\"\(shortened.isEmpty ? "untitled" : shortened)\""
    }

    /// An identifier, such as a profile ID or a model, as one word group
    /// on the header's line.
    static func word(_ value: String) -> String {
        let cleaned = oneLine(value).replacingOccurrences(of: "|", with: "/")
        let shortened = String(cleaned.prefix(maximumTitleLength * 2))
        return shortened.isEmpty ? "unknown" : shortened
    }

    /// No control character goes through: the text is typed into a
    /// terminal, where an escape sequence could end the paste early.
    private static func oneLine(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                scalars.append(" ")
            } else if scalar.properties.generalCategory != .control, scalar.properties.generalCategory != .format {
                scalars.append(scalar)
            }
        }
        return String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}
