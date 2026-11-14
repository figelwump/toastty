@testable import ToasttyApp
import ConversationUI
import CoreState
import Foundation
import Testing

/// What a link in the coordinator's text can do. The text is an agent's, so
/// a link opens a task that exists or a web page, and nothing else.
@MainActor
struct CoordinatorChatLinkTests {
    private let taskID = UUID(uuidString: "8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F")!
    private let taskSpaceID = UUID()
    /// A done or archived task: its space closed.
    private let closedTaskID = UUID(uuidString: "74C9F5EA-8F2F-4014-A078-3AB97213BC34")!

    private func action(_ text: String, webPagesOpenInSystemBrowser: Bool = false) throws -> CoordinatorChatLinks.Action {
        let url = try #require(URL(string: text))
        return CoordinatorChatLinks.action(for: url, webPagesOpenInSystemBrowser: webPagesOpenInSystemBrowser) { id in
            switch id {
            case taskID: .taskSpace(workspaceID: taskSpaceID)
            case closedTaskID: .tasksView
            default: nil
            }
        }
    }

    @Test func aLinkToATaskWithAnOpenSpaceOpensThatSpace() throws {
        #expect(try action("toastty://task/\(taskID.uuidString)") == .openTaskSpace(workspaceID: taskSpaceID))
    }

    @Test func aLinkToATaskWhoseSpaceClosedShowsItInTheTasksView() throws {
        #expect(try action("toastty://task/\(closedTaskID.uuidString)") == .showInTasksView(taskID: closedTaskID))
        #expect(try action("toastty://task/\(closedTaskID.uuidString.lowercased())") == .showInTasksView(taskID: closedTaskID))
    }

    @Test(arguments: [
        // A task that does not exist.
        "toastty://task/99999999-9999-4999-8999-999999999999",
        // Toastty's own pages and actions.
        "toastty://action/open-settings",
        "toastty://getting-started/",
        "toastty://task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F/merge",
        "toastty://task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F?then=merge",
        // Anything that could start a program or read a file.
        "file:///Applications/Calculator.app",
        "file:///etc/passwd",
        "ssh://example.com",
        "x-apple.systempreferences:com.apple.preference.security",
        "javascript:alert(1)",
        "data:text/html,<script>alert(1)</script>",
        "vscode://file/etc/passwd",
        "mailto:someone@example.com",
        "tel:5551234",
        "https:///no-host",
        "relative/path.md",
    ])
    func noOtherLinkOpensAnything(_ text: String) throws {
        #expect(try action(text) == .ignore)
        #expect(try action(text, webPagesOpenInSystemBrowser: true) == .ignore)
    }

    @Test(arguments: ["https://example.com/docs", "http://example.com", "HTTPS://github.com/figelwump/toastty/pull/283"])
    func aWebLinkOpensInAToasttyBrowserOrWithShiftInTheSystemBrowser(_ text: String) throws {
        #expect(try action(text) == .openWebPageInToastty)
        #expect(try action(text, webPagesOpenInSystemBrowser: true) == .openWebPageInSystemBrowser)
    }

    @Test func shiftDoesNotChangeWhatATaskLinkDoes() throws {
        #expect(try action("toastty://task/\(taskID.uuidString)", webPagesOpenInSystemBrowser: true)
            == .openTaskSpace(workspaceID: taskSpaceID))
        #expect(try action("toastty://task/\(closedTaskID.uuidString)", webPagesOpenInSystemBrowser: true)
            == .showInTasksView(taskID: closedTaskID))
    }

    // MARK: - Chips

    private func item(_ id: UUID, title: String, stage: TaskStage, pullRequest: Int? = nil) -> TaskBoardItem {
        TaskBoardItem(
            id: .task(id),
            title: title,
            stage: stage,
            agent: .idle,
            pullRequest: pullRequest.flatMap {
                WorkspacePullRequestLink(annotationURL: "https://github.com/example/toastty/pull/\($0)")
            },
            activityAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    @Test func aChipShowsTheTasksTitleStageColorAndPullRequestNumber() throws {
        let other = UUID()
        let chips = CoordinatorTaskChips(items: [
            item(taskID, title: "  Restore   split\nratios ", stage: .needsYou(.review), pullRequest: 283),
            item(other, title: String(repeating: "long ", count: 40), stage: .done),
            // A task space with no task record is not a task.
            TaskBoardItem(id: .taskSpace(UUID()), title: "Scratch", stage: .idle, agent: .idle,
                          activityAt: Date(timeIntervalSince1970: 0)),
        ])
        #expect(chips.chips.count == 2)
        let chip = try #require(chips.chips[taskID])
        #expect(chip.title == "Restore split ratios")
        #expect(chip.detail == "#283")
        let long = try #require(chips.chips[other])
        #expect(long.title.count == CoordinatorTaskChips.maximumTitleLength)
        #expect(long.title.hasSuffix("…"))
        #expect(long.detail == nil)
        // Stages differ in color.
        #expect(chip.markColor != long.markColor)

        let link = CoordinatorTaskLink.url(taskID: taskID)
        #expect(CoordinatorTaskChips.presentation(for: link, chips: chips.chips) == .chip(chip))
        // A link to no task, and any other Toastty link, is plain text.
        for text in ["toastty://task/99999999-9999-4999-8999-999999999999", "toastty://action/open-settings",
                     "toastty://task/\(taskID.uuidString)/merge"] {
            let url = try #require(URL(string: text))
            #expect(CoordinatorTaskChips.presentation(for: url, chips: chips.chips) == .plainText)
        }
        // Other links are left to the transcript.
        let web = try #require(URL(string: "https://example.com"))
        #expect(CoordinatorTaskChips.presentation(for: web, chips: chips.chips) == nil)
    }

    @Test func aChipFollowsItsTasksRecord() {
        let before = CoordinatorTaskChips(items: [item(taskID, title: "Fix the dot", stage: .running)])
        let renamed = CoordinatorTaskChips(items: [item(taskID, title: "Fix the unread dot", stage: .running)])
        let staged = CoordinatorTaskChips(items: [item(taskID, title: "Fix the dot", stage: .needsYou(.review))])
        let same = CoordinatorTaskChips(items: [item(taskID, title: "Fix the dot", stage: .running)])
        // The transcript draws again when the presenter's revision changes.
        #expect(before.presenter.revision != renamed.presenter.revision)
        #expect(before.presenter.revision != staged.presenter.revision)
        #expect(before.presenter.revision == same.presenter.revision)
    }
}
