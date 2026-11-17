import Foundation
import RemoteProtocol

/// The coordinator's own files that its tab's … menu opens read-only. The
/// phone asks for each by name in the coordinator's conversation, and the
/// Mac resolves the name in the coordinator's folder, where the session
/// runs.
enum ToasttyCoordinatorFile: String, CaseIterable, Identifiable {
    case policy = "policy.md"
    case ledger = "ledger.md"
    case friction = "friction.md"

    var id: String { rawValue }
    var fileName: String { rawValue }

    var title: String {
        switch self {
        case .policy: "Policy"
        case .ledger: "Ledger"
        case .friction: "Friction Notes"
        }
    }

    var subtitle: String {
        switch self {
        case .policy: "Your rules for the coordinator"
        case .ledger: "What the coordinator did"
        case .friction: "What slows your tasks"
        }
    }

    var symbol: String {
        switch self {
        case .policy: "doc.text"
        case .ledger: "list.bullet"
        case .friction: "water.waves"
        }
    }

    /// An older coordinator folder can lack a file until the coordinator
    /// first writes it.
    var missingMessage: String {
        switch self {
        case .policy: "The coordinator has not written its policy yet."
        case .ledger: "The coordinator has not written its ledger yet."
        case .friction: "The coordinator has not written its friction notes yet."
        }
    }

    /// The sheet is read-only: the coordinator edits its policy and commits
    /// each change in its folder.
    var footer: String? {
        self == .policy ? "To change a rule, ask the coordinator in the chat." : nil
    }

    /// The ledger is a log with its newest entry last, so it opens there.
    var opensAtLastLine: Bool { self == .ledger }

    func selection(conversationID: UUID) -> ToasttyPreviewSelection {
        ToasttyPreviewSelection(
            target: .conversationFile(conversationID: RemoteConversationID(rawValue: conversationID),
                                      fileReference: fileName),
            title: title,
            coordinatorFile: self
        )
    }

    /// Whether `panel` shows one of these files from `folder`, the
    /// coordinator session's working folder. The Mac can send the folder
    /// with `~` for the home folder; the phone cannot expand it, so such a
    /// folder matches by the path after `~`. Without a folder, the file name
    /// alone decides.
    static func isShown(by panel: RemoteWorkspacePanel, folder: String?) -> Bool {
        guard let filePath = panel.filePath else { return false }
        let name = (filePath as NSString).lastPathComponent
        guard allCases.contains(where: { $0.fileName == name }) else { return false }
        guard let folder, !folder.isEmpty else { return true }
        let trimmed = String(folder.reversed().drop(while: { $0 == "/" }).reversed())
        if trimmed.hasPrefix("~/") {
            return filePath.hasSuffix("\(trimmed.dropFirst())/\(name)")
        }
        return (filePath as NSString).standardizingPath
            == ((trimmed as NSString).appendingPathComponent(name) as NSString).standardizingPath
    }

    /// The last line with text, so a reveal does not land on the blank end
    /// of a file that ends with a newline.
    static func lastContentLine(of content: String) -> Int {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let lastWithText = lines.lastIndex { !$0.allSatisfy(\.isWhitespace) }
        return (lastWithText ?? 0) + 1
    }
}
