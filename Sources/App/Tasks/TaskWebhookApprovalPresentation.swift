import CoreState
import Foundation

/// The words of the webhook approval banner and sheet, which
/// `TaskWebhookApprovalViews` (macOS) and the GTK Tasks view draw.
enum TaskWebhookApprovalPresentation {
    /// Where the key is kept: the Keychain, or Toastty's private key file on
    /// Linux (`FileTaskWebhookSecretStore`).
    #if os(Linux)
    static let keyStoreName = "Toastty's key file"
    static let thisComputer = "this computer"
    #else
    static let keyStoreName = "the Keychain"
    static let thisComputer = "this Mac"
    #endif

    /// The banner's message: its bold start and the rest.
    static func bannerMessage(_ webhook: TaskWebhook) -> (lead: String, rest: String) {
        if webhook.status == .disabled {
            return (
                "\"\(webhook.name)\" stopped:",
                " \(webhook.host) refused it (\(webhook.disabledReason ?? "refused")). Task events are not being sent."
            )
        }
        return ("\"\(webhook.name)\" wants to receive task events", " at \(webhook.host). It is paused until you review it.")
    }

    /// The banner's button.
    static func reviewTitle(_ webhook: TaskWebhook) -> String {
        webhook.status == .disabled && webhook.auth.needsSecret ? "Enter new key…" : "Review…"
    }

    /// Whether the sheet asks for the key: Toastty has none, or the
    /// receiver refused the one it has.
    static func needsKey(_ webhook: TaskWebhook, hasSecret: Bool) -> Bool {
        webhook.auth.needsSecret && (webhook.status == .disabled || hasSecret == false)
    }

    static func sheetTitle(_ webhook: TaskWebhook) -> String {
        webhook.status == .disabled
            ? "Turn \"\(webhook.name)\" on again?"
            : "Allow \"\(webhook.name)\" to receive task events?"
    }

    static func signIn(_ webhook: TaskWebhook, needsKey: Bool) -> String {
        webhook.auth.needsSecret && needsKey == false
            ? "\(webhook.auth.title), key saved in \(keyStoreName) (••••••••)"
            : webhook.auth.title
    }

    static func denyTitle(_ webhook: TaskWebhook) -> String {
        webhook.status == .disabled ? "Remove" : "Deny"
    }

    static var keyPlaceholder: String { "Paste the key, saved in \(keyStoreName)" }

    static func explanation(_ webhook: TaskWebhook) -> String {
        let events = webhook.events.map { $0.title.lowercased() }
        let stopped = webhook.status == .disabled
            ? "Toastty stopped sending after \(webhook.host) refused a request (\(webhook.disabledReason ?? "refused")). "
            : ""
        return stopped + "Toastty will POST an event to this address when a task changes to: \(events.joined(separator: ", ")). "
            + "Each event includes the task's title, project path, external reference, pull request link, "
            + "and the question an agent asked you. Reply text and attachments are never sent."
    }

    static func taskFilter(_ webhook: TaskWebhook) -> String {
        let roots = webhook.roots.isEmpty ? "All projects" : webhook.roots.joined(separator: ", ")
        let ref = webhook.externalRefPrefix.map { "external reference starting with \($0)" } ?? "any external reference"
        return "\(roots) · \(ref)"
    }

    static func requester(_ webhook: TaskWebhook, now: Date = Date()) -> String {
        let source = webhook.requestedBy.isAgentSession ? "an agent session" : "toastty webhook add, outside an agent session"
        let age = RelativeDateTimeFormatter().localizedString(for: webhook.requestedAt, relativeTo: now)
        return "\(source) · \(age)"
    }

    static func agentWarning(_ webhook: TaskWebhook) -> String {
        let task = webhook.requestedBy.agentTaskTitle.map { " in task \"\($0)\"" } ?? ""
        return "Requested from an agent session\(task). An agent should not need to send task data off \(thisComputer). Deny it unless you asked for this."
    }

    /// The sidebar pill's count of webhooks that wait or were stopped.
    static func pillTitle(count: Int) -> String {
        count == 1 ? "1 webhook" : "\(count) webhooks"
    }
}
