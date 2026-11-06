import CoreState
import SwiftUI

/// The banner at the top of the Tasks view while a webhook waits for
/// approval, or after Toastty stopped one that the receiver refused.
/// Toastty never opens the review sheet by itself: a sheet that appeared
/// while the user typed in a terminal could take a keypress.
struct TaskWebhookApprovalBanner: View {
    @ObservedObject var webhooks: TaskWebhookService
    @State private var reviewing: TaskWebhook?
    @State private var error: String?

    var body: some View {
        let waiting = webhooks.pendingWebhooks + webhooks.stoppedWebhooks
        if let first = waiting.first {
            HStack(spacing: 12) {
                (Self.message(first) + Text(waiting.count > 1 ? " (\(waiting.count - 1) more)" : ""))
                    .font(.system(size: 11.5))
                    .foregroundStyle(ToastyTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(first.status == .disabled && first.auth.needsSecret ? "Enter new key…" : "Review…") {
                    error = nil
                    reviewing = first
                }
                .accessibilityIdentifier("tasks.view.webhook.review")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(ToastyTheme.sessionNeedsApprovalBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                Rectangle().fill(ToastyTheme.sessionNeedsApprovalText).frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("tasks.view.webhookBanner")
            .sheet(item: $reviewing) { webhook in
                TaskWebhookApprovalSheet(
                    webhook: webhook,
                    needsKey: webhook.auth.needsSecret && (webhook.status == .disabled || webhooks.hasSecret(webhook.id) == false),
                    error: error,
                    approve: { key in decide { try webhooks.approve(id: webhook.id, shownDigest: webhook.settingsDigest, secret: key) } },
                    deny: { decide { try webhooks.deny(id: webhook.id) } },
                    notNow: { reviewing = nil }
                )
            }
        }
    }

    static func message(_ webhook: TaskWebhook) -> Text {
        if webhook.status == .disabled {
            return Text("\"\(webhook.name)\" stopped:").fontWeight(.semibold)
                + Text(" \(webhook.host) refused it (\(webhook.disabledReason ?? "refused")). Task events are not being sent.")
        }
        return Text("\"\(webhook.name)\" wants to receive task events").fontWeight(.semibold)
            + Text(" at \(webhook.host). It is paused until you review it.")
    }

    private func decide(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
            reviewing = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// What leaves the Mac and where it goes. Approve has no key binding, so
/// only a click approves.
struct TaskWebhookApprovalSheet: View {
    let webhook: TaskWebhook
    /// Whether the sheet asks for the key: Toastty has none, or the
    /// receiver refused the one it has.
    let needsKey: Bool
    let error: String?
    let approve: (String?) -> Void
    let deny: () -> Void
    let notNow: () -> Void
    @State private var key = ""

    private var enteredKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(webhook.status == .disabled
                ? "Turn \"\(webhook.name)\" on again?"
                : "Allow \"\(webhook.name)\" to receive task events?")
                .font(.system(size: 14, weight: .semibold))
            Text(Self.explanation(webhook))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
                row("Sends to") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(webhook.host).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text(webhook.displayURL).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        if TaskWebhookValidation.isLoopback(url: webhook.url) {
                            Text("Local test address").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                row("Events") { Text(webhook.events.map(\.title).joined(separator: ", ")) }
                row("Tasks") { Text(Self.taskFilter(webhook)) }
                row("Sign-in") {
                    Text(webhook.auth.needsSecret && needsKey == false
                        ? "\(webhook.auth.title), key saved in the Keychain (••••••••)"
                        : webhook.auth.title)
                }
                if needsKey {
                    row("Key") { keyEntry }
                }
                row("Requested by") { Text(Self.requester(webhook)) }
            }
            .font(.system(size: 12))
            if webhook.requestedBy.isAgentSession {
                Text(Self.agentWarning(webhook))
                    .font(.system(size: 11.5))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("tasks.webhook.agentWarning")
            }
            if let error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red)
            }
            Divider()
            HStack(spacing: 8) {
                Button(webhook.status == .disabled ? "Remove" : "Deny", role: .destructive, action: deny)
                    .accessibilityIdentifier("tasks.webhook.deny")
                Spacer()
                Button("Not now", action: notNow)
                    .accessibilityIdentifier("tasks.webhook.notNow")
                // No .keyboardShortcut: Return and Escape must not decide.
                Button("Approve") { approve(needsKey ? enteredKey : nil) }
                    .disabled(needsKey && enteredKey.isEmpty)
                    .accessibilityIdentifier("tasks.webhook.approve")
            }
        }
        .padding(20)
        .frame(width: 520)
        // A container's identifier would replace its children's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tasks.webhook.sheet")
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("Paste the key, saved in the Keychain", text: $key)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("tasks.webhook.key")
            if let hint = webhook.secretHint {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Instructions from the requester. Toastty did not write or check them.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text(Self.hintText(hint))
                        .font(.system(size: 11.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("tasks.webhook.secretHint")
            } else {
                Text("Paste the key that the receiving service gave you for this webhook.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            content().fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The hint as plain text: no Markdown, so a link cannot hide where it
    /// goes. Web addresses in it show in full and open in the browser.
    static func hintText(_ hint: String) -> AttributedString {
        var text = AttributedString(hint)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return text }
        for match in detector.matches(in: hint, range: NSRange(hint.startIndex..., in: hint)) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: hint),
                  let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].link = url
        }
        return text
    }

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

    static func requester(_ webhook: TaskWebhook) -> String {
        let source = webhook.requestedBy.isAgentSession ? "an agent session" : "toastty webhook add, outside an agent session"
        let age = RelativeDateTimeFormatter().localizedString(for: webhook.requestedAt, relativeTo: Date())
        return "\(source) · \(age)"
    }

    static func agentWarning(_ webhook: TaskWebhook) -> String {
        let task = webhook.requestedBy.agentTaskTitle.map { " in task \"\($0)\"" } ?? ""
        return "Requested from an agent session\(task). An agent should not need to send task data off this Mac. Deny it unless you asked for this."
    }
}

/// The sidebar's count of webhooks that wait for approval or were
/// stopped, beside the Tasks row. It is apart from the Needs you badge: a
/// webhook is not a task.
struct TaskWebhookPendingPill: View {
    @ObservedObject var webhooks: TaskWebhookService
    let open: () -> Void

    var body: some View {
        let count = webhooks.pendingWebhooks.count + webhooks.stoppedWebhooks.count
        if count > 0 {
            Button(action: open) {
                Text(count == 1 ? "1 webhook" : "\(count) webhooks")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ToastyTheme.sessionNeedsApprovalText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay { Capsule().stroke(ToastyTheme.sessionNeedsApprovalText, lineWidth: 1) }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("A webhook needs you in the Tasks view")
            .accessibilityLabel(count == 1 ? "1 webhook needs you" : "\(count) webhooks need you")
            .accessibilityIdentifier("sidebar.tasks.webhooks")
        }
    }
}
