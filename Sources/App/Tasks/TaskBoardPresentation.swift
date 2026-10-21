import CoreState
import SwiftUI

/// The words the sidebar and the Tasks view use for a task. Kept apart from
/// the views so they can be tested without hosting them.
enum TaskBoardPresentation {
    static func groupTitle(_ group: TaskStage.Group) -> String {
        switch group {
        case .inbox: "Inbox"
        case .needsYou: "Needs you"
        case .running: "Running"
        case .toShip: "To ship"
        case .done: "Done"
        case .archived: "Archived"
        }
    }

    /// The agent's display name, from its profile ID.
    static func agentName(_ item: TaskBoardItem) -> String {
        guard let agent = item.record?.resolved?.agent ?? item.record?.pinned.agent, agent.isEmpty == false else {
            return "The agent"
        }
        return agent.prefix(1).uppercased() + agent.dropFirst()
    }

    /// One line on what the task is doing or waiting for.
    static func statusLine(_ item: TaskBoardItem) -> String {
        switch item.stage {
        case .inbox:
            switch item.record?.setup {
            case .routing?: return "routing…"
            case .settingUp?: return "setting up"
            default: return "moving to worktree"
            }
        case .needsYou(let attention):
            switch attention {
            case .pickWorkspace: return "⚠ pick a workspace"
            case .setupFailed: return "⚠ setup failed"
            case .moveFailed: return "⚠ worktree failed"
            case .taskSpaceClosed: return "Task space closed before the task finished"
            case .agentNeedsInput: return "\(agentName(item)) is waiting for your input"
            case .agentError: return "\(agentName(item)) stopped with an error"
            case .review, .readyForReview: return "Ready for your review"
            }
        case .running:
            switch item.agent {
            case .working: return "\(agentName(item)) · working"
            case .none: return "No agent running"
            case .idle, .needsInput, .error: return "\(agentName(item)) · idle"
            }
        case .toShip: return "Merged · waiting for a release"
        case .done: return item.record?.shippedAt != nil ? "Shipped" : "Done"
        case .archived: return "Archived"
        }
    }

    /// The stage's name and why, for the detail pane.
    static func stageDescription(_ item: TaskBoardItem) -> (stage: String, why: String) {
        switch item.stage {
        case .inbox: return ("Inbox", statusLine(item))
        case .needsYou(let attention):
            switch attention {
            case .pickWorkspace(let reason), .setupFailed(let reason), .moveFailed(let reason):
                return ("Needs you", reason)
            case .taskSpaceClosed: return ("Needs you", "task space closed")
            case .agentNeedsInput: return ("Needs you", "the agent asked for input")
            case .agentError: return ("Needs you", "the agent stopped with an error")
            case .review:
                return ("Review", item.pullRequestState == nil ? "PR linked, agent idle" : "PR open, agent idle")
            case .readyForReview: return ("Review", "marked ready, agent idle")
            }
        case .running: return ("Running", statusLine(item))
        case .toShip: return ("To ship", "merged, waiting for a release tag")
        case .done:
            if let tag = item.record?.releaseTag { return ("Done", "shipped in \(tag)") }
            return ("Done", item.record?.mergedAt != nil || item.pullRequestState?.state == .merged ? "merged" : "marked done")
        case .archived: return ("Archived", "closed without finishing")
        }
    }

    static func pullRequestLine(_ item: TaskBoardItem) -> String? {
        guard let link = item.pullRequest else { return nil }
        guard let state = item.pullRequestState else { return "PR #\(link.number)" }
        if state.state == .open, state.isDraft {
            return "PR #\(link.number) · draft"
        }
        return "PR #\(link.number) · \(state.state.rawValue)"
    }

    /// "Created from the CLI · 2d ago · toastty".
    static func originLine(_ item: TaskBoardItem, now: Date) -> String {
        guard let record = item.record else {
            return ["Task space without a task record", item.projectTitle].compactMap { $0 }.joined(separator: " · ")
        }
        let source: String
        switch record.source {
        case .cli: source = "Created from the CLI"
        case .agent: source = "Created by an agent"
        case .recovered: source = "Rebuilt from its task space"
        case .adopted: source = "Tracked from an existing task space"
        case .quickEntry: source = "Created from quick entry"
        }
        let age = TaskAge.label(since: record.createdAt, now: now)
        return [source, age == "now" ? "just now" : "\(age) ago", item.projectTitle].compactMap { $0 }.joined(separator: " · ")
    }

    /// What happened to the task, oldest first.
    static func history(_ item: TaskBoardItem) -> [String] {
        guard let record = item.record else { return [] }
        var lines = ["Created" + (record.attachments.isEmpty ? "" : ", with \(record.attachments.count) \(record.attachments.count == 1 ? "attachment" : "attachments")")]
        if let worktree = record.worktree {
            lines.append("Moved to worktree \(worktree.branch)")
        }
        if let link = item.pullRequest {
            lines.append("PR #\(link.number) opened")
        }
        if record.readyForReviewAt != nil { lines.append("Marked ready for review") }
        if record.mergedAt != nil { lines.append("Merged") }
        if let tag = record.releaseTag { lines.append("Shipped in \(tag)") }
        if record.doneAt != nil { lines.append("Marked done") }
        if record.archivedAt != nil { lines.append("Archived") }
        return lines
    }
}

/// A task's square mark: the same family as the sidebar's task space marks.
struct TaskStageMark: View {
    let item: TaskBoardItem

    var body: some View {
        Group {
            switch item.stage {
            case .inbox:
                RoundedRectangle(cornerRadius: 1.5)
                    .strokeBorder(ToastyTheme.sidebarTaskInboxMark, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                    .frame(width: 9, height: 9)
            case .needsYou(let attention):
                switch attention {
                case .review, .readyForReview:
                    tinted(ToastyTheme.sidebarTaskReviewMarkBackground) {
                        Circle().fill(ToastyTheme.sidebarTaskReviewMark).frame(width: 4.5, height: 4.5)
                    }
                case .pickWorkspace, .setupFailed, .moveFailed:
                    RoundedRectangle(cornerRadius: 1.5)
                        .strokeBorder(ToastyTheme.sessionNeedsApprovalText, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                        .frame(width: 9, height: 9)
                case .agentError:
                    RoundedRectangle(cornerRadius: 1.5).fill(ToastyTheme.sessionErrorText).frame(width: 7, height: 7)
                case .agentNeedsInput, .taskSpaceClosed:
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(ToastyTheme.sessionNeedsApprovalText)
                        .frame(width: 7, height: 7)
                        .overlay {
                            RoundedRectangle(cornerRadius: 1.5).stroke(ToastyTheme.sidebarSessionRailApprovalHalo, lineWidth: 3)
                        }
                }
            case .running:
                if item.agent == .working {
                    SessionStatusIndicator(state: .spinner, size: 9, lineWidth: 1.4)
                } else {
                    RoundedRectangle(cornerRadius: 1.5)
                        .strokeBorder(ToastyTheme.sidebarSubspaceQuietMark, lineWidth: 1.2)
                        .frame(width: 7, height: 7)
                }
            case .toShip:
                tinted(ToastyTheme.sidebarTaskToShipMarkBackground) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 6.5, weight: .black))
                        .foregroundStyle(ToastyTheme.sidebarTaskToShipMark)
                }
            case .done:
                tinted(ToastyTheme.sidebarSubspaceDoneMarkBackground) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 6.5, weight: .black))
                        .foregroundStyle(ToastyTheme.sidebarSubspaceDoneMark)
                }
            case .archived:
                tinted(ToastyTheme.sidebarWorkspaceTagBackground) {
                    Image(systemName: "xmark")
                        .font(.system(size: 6, weight: .black))
                        .foregroundStyle(ToastyTheme.sidebarSubspaceQuietMark)
                }
            }
        }
        .frame(width: 12, height: 16)
        .accessibilityHidden(true)
    }

    private func tinted(_ background: Color, @ViewBuilder content: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(background)
            .frame(width: 10, height: 10)
            .overlay(content: content)
    }
}
