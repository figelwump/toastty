import ConversationUI
import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

// MARK: - Running an action

/// Runs a task action or a release the user picked, through the nearest
/// presenter, which asks first where it should and shows what went wrong.
/// Absent where no presenter is installed, and views then show no actions.
struct ToasttyTaskActionRunner: Sendable {
    let run: @MainActor @Sendable (RemoteTaskActionItem, RemoteTaskSummary) -> Void
    let release: @MainActor @Sendable (MobileProjectRelease) -> Void
}

private struct ToasttyTaskActionRunnerKey: EnvironmentKey {
    static let defaultValue: ToasttyTaskActionRunner? = nil
}

extension EnvironmentValues {
    var toasttyTaskActionRunner: ToasttyTaskActionRunner? {
        get { self[ToasttyTaskActionRunnerKey.self] }
        set { self[ToasttyTaskActionRunnerKey.self] = newValue }
    }
}

/// An action that waits for the user's yes. The phone asks before a merge
/// and a release, unlike the Mac's one-click buttons, since a tap on glass
/// is easy to make by mistake. Mark Done and Delete ask as they do on the
/// Mac.
struct ToasttyTaskActionConfirmation: Identifiable {
    enum Request {
        /// The task as the phone showed it, so the Mac refuses if its pull
        /// request changed since.
        case task(RemoteTaskActionItem, RemoteTaskSummary)
        case release(MobileProjectRelease)
    }

    let id = UUID()
    let request: Request
    let title: String
    let message: String
    let confirmTitle: String
    let isDestructive: Bool

    /// `nil` for an action that runs without asking, as on the Mac.
    static func make(_ item: RemoteTaskActionItem, task: RemoteTaskSummary) -> Self? {
        let name = "\u{201C}\(task.title)\u{201D}"
        switch item.action {
        case .merge:
            let pullRequest = task.pullRequest.map { "PR #\($0.number)" }
            return Self(
                request: .task(item, task),
                title: pullRequest.map { "Merge \($0)?" } ?? "Merge \(name)?",
                message: "Your Mac asks the task\u{2019}s agent to check \(pullRequest ?? "the pull request"), then merge it, "
                    + "unless tasks.toml merges directly. Toastty then closes the task space and removes its worktree.",
                confirmTitle: pullRequest.map { "Merge \($0)" } ?? "Merge",
                isDestructive: false
            )
        case .markDone:
            return Self(
                request: .task(item, task),
                title: "Complete \(name)?",
                message: "Moves the task to Done and closes its task space on your Mac. The worktree stays.",
                confirmTitle: item.title,
                isDestructive: false
            )
        case .delete:
            return Self(
                request: .task(item, task),
                title: "Delete \(name)?",
                message: "Removes the task from your Mac. This can\u{2019}t be undone.",
                confirmTitle: "Delete Task",
                isDestructive: true
            )
        case .archive, .cancelMerge, .cleanUp, .keepAsIs, .retry:
            return nil
        }
    }

    /// The question before a release: the project, how many tasks wait to
    /// ship, and the newest of them by title.
    static func release(_ release: MobileProjectRelease) -> Self {
        let count = release.taskCount
        var message = "Your Mac starts a release task for \(count) merged \(count == 1 ? "task" : "tasks") waiting to ship. "
            + "Its agent starts from the remote default branch\u{2019}s latest commit and can publish the release."
        let listed = release.taskTitles.prefix(Self.listedReleaseTasks)
        if listed.isEmpty == false {
            message += "\n\n" + listed.map { "\u{2022} \($0)" }.joined(separator: "\n")
            let more = max(count, release.taskTitles.count) - listed.count
            if more > 0 { message += "\n\u{2022} and \(more) more" }
        }
        return Self(
            request: .release(release),
            title: "Release \u{201C}\(release.projectTitle)\u{201D}?",
            message: message,
            confirmTitle: "Release",
            isDestructive: false
        )
    }

    static let listedReleaseTasks = 5
}

struct ToasttyTaskArchiveSelection: Identifiable {
    var id: UUID { task.id }
    let item: RemoteTaskActionItem
    let task: RemoteTaskSummary
}

/// One presenter's state: the question it asks, the archive sheet, and the
/// last failure.
@MainActor
@Observable
final class ToasttyTaskActionPresentation {
    var confirmation: ToasttyTaskActionConfirmation?
    var archive: ToasttyTaskArchiveSelection?
    var failure: ToasttyTaskActionFailure?

    func request(_ item: RemoteTaskActionItem, task: RemoteTaskSummary, controller: HomeScreenController) {
        if item.action == .archive {
            archive = ToasttyTaskArchiveSelection(item: item, task: task)
        } else if let confirmation = ToasttyTaskActionConfirmation.make(item, task: task) {
            self.confirmation = confirmation
        } else {
            send(item, task: task, controller: controller)
        }
    }

    func requestRelease(_ release: MobileProjectRelease) {
        confirmation = .release(release)
    }

    func confirm(_ confirmation: ToasttyTaskActionConfirmation, controller: HomeScreenController) {
        self.confirmation = nil
        switch confirmation.request {
        case .task(let item, let task):
            send(item, task: task, controller: controller)
        case .release(let release):
            Task { @MainActor [weak self] in
                let failure = await controller.releaseProject(release)
                if let failure { self?.failure = failure }
            }
        }
    }

    private func send(_ item: RemoteTaskActionItem, task: RemoteTaskSummary, controller: HomeScreenController) {
        Task { @MainActor [weak self] in
            let failure = await controller.performTaskAction(item, on: task)
            if let failure { self?.failure = failure }
        }
    }
}

/// Installs a task action runner for the views inside, and presents what
/// it needs: confirmations, the archive sheet, and failures. A sheet that
/// shows task actions installs its own, since a presenter under a sheet
/// cannot show anything over it.
struct ToasttyTaskActionPresenterModifier: ViewModifier {
    let controller: HomeScreenController
    @State private var presentation = ToasttyTaskActionPresentation()

    func body(content: Content) -> some View {
        content
            .environment(\.toasttyTaskActionRunner, ToasttyTaskActionRunner(
                run: { [presentation, controller] item, task in
                    presentation.request(item, task: task, controller: controller)
                },
                release: { [presentation] release in
                    presentation.requestRelease(release)
                }
            ))
            .alert(
                presentation.confirmation?.title ?? "",
                isPresented: Binding(
                    get: { presentation.confirmation != nil },
                    set: { if $0 == false { presentation.confirmation = nil } }
                ),
                presenting: presentation.confirmation
            ) { confirmation in
                Button("Cancel", role: .cancel) {}
                Button(confirmation.confirmTitle, role: confirmation.isDestructive ? .destructive : nil) {
                    presentation.confirm(confirmation, controller: controller)
                }
            } message: { confirmation in
                Text(confirmation.message)
            }
            .alert(
                presentation.failure?.title ?? "",
                isPresented: Binding(
                    get: { presentation.failure != nil },
                    set: { if $0 == false { presentation.failure = nil } }
                ),
                presenting: presentation.failure
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.message)
            }
            .sheet(item: Binding(
                get: { presentation.archive },
                set: { presentation.archive = $0 }
            )) { selection in
                ToasttyTaskArchiveSheet(item: selection.item, task: selection.task, controller: controller)
            }
    }
}

extension View {
    func toasttyTaskActionPresenter(_ controller: HomeScreenController) -> some View {
        modifier(ToasttyTaskActionPresenterModifier(controller: controller))
    }
}

// MARK: - Task bar

/// Under a task space session's title, like the Mac's top bar: the task's
/// stage, its pull request, and the Merge control.
struct ToasttyTaskBar: View {
    let task: RemoteTaskSummary
    let controller: HomeScreenController

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(ToasttyTaskDetailSheet.stageColor(task))
                    .frame(width: 8, height: 8)
                Text(task.stageTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ToasttyDesignTokens.secondaryText)
                    .lineLimit(1)
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Stage: \(task.stageTitle)")
            .accessibilityIdentifier("toastty-task-bar-stage")
            if let pullRequest = task.pullRequest {
                ToasttyTaskPullRequestChip(pullRequest: pullRequest)
            }
            Spacer(minLength: 4)
            if let control = task.mergeControl {
                ToasttyTaskMergeControlView(control: control, task: task, controller: controller)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(ToasttyDesignTokens.raisedSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ToasttyDesignTokens.divider)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toastty-task-bar")
    }
}

/// The Mac's Merge control in one of its states, with its ▼ menu. Without a
/// runner, or while the phone cannot act on tasks, it shows the state
/// without acting, so older Macs and devices without the permission still
/// see where the task stands.
struct ToasttyTaskMergeControlView: View {
    let control: RemoteTaskMergeControl
    let task: RemoteTaskSummary
    let controller: HomeScreenController
    @Environment(\.toasttyTaskActionRunner) private var runner
    @Environment(\.openURL) private var openURL

    private enum Tone {
        case merge
        case neutral
    }

    private var canAct: Bool {
        runner != nil && controller.canActOnTasks
    }

    private var isBusy: Bool {
        controller.isTaskActionInFlight(task.id)
    }

    var body: some View {
        content
            .disabled(isBusy)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("toastty-task-merge-control")
            .accessibilityValue(control.kind.rawValue)
    }

    @ViewBuilder
    private var content: some View {
        switch control.kind {
        case .merge:
            splitButton(icon: "arrow.triangle.merge", tone: .merge) { run(control.action) }
        case .openPullRequest:
            // Opening the pull request is not a task action, so it works
            // read-only too.
            splitButton(icon: "arrow.up.right", tone: .neutral) {
                if let url = task.pullRequest?.url { openURL(url) }
            }
        case .completeTask:
            splitButton(icon: "checkmark", tone: .merge) { run(control.action) }
        case .archive:
            splitButton(icon: "archivebox", tone: .neutral) { run(control.action) }
        case .merging:
            menuLabel {
                HStack(spacing: 5) {
                    ToasttySpinner(size: 9, lineWidth: 1.5, color: ToasttyDesignTokens.secondaryText)
                    Text(control.title)
                        .lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: ToasttyDesignTokens.chipCornerRadius, style: .continuous)
                        .strokeBorder(ToasttyDesignTokens.border, lineWidth: 1)
                )
            }
        case .cleanupStopped:
            menuLabel {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.bold))
                    Text(control.title)
                        .lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(ToasttyDesignTokens.amberText)
                .frame(height: 28)
            }
            .accessibilityHint(control.detail ?? "")
        case .done:
            menuLabel {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                    Text(control.title)
                        .lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(ToasttyDesignTokens.green)
                .frame(height: 28)
            }
        }
    }

    /// The Merge button shape: the primary action on the left and, when
    /// the Mac's menu has items, a ▼ that opens it.
    private func splitButton(icon: String, tone: Tone, primary: @escaping () -> Void) -> some View {
        let isActive = control.kind == .openPullRequest || canAct
        let showsMenu = canAct && control.menu.isEmpty == false
        return HStack(spacing: 1) {
            Button(action: primary) {
                HStack(spacing: 4) {
                    if isBusy {
                        ToasttySpinner(size: 9, lineWidth: 1.5, color: foreground(tone))
                    } else {
                        Image(systemName: icon)
                            .font(.caption2.weight(.bold))
                    }
                    Text(control.title)
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(segment(tone, leading: true, trailing: showsMenu == false))
            }
            .buttonStyle(.plain)
            .allowsHitTesting(isActive)
            .accessibilityLabel(control.title)
            .accessibilityHint(control.detail.map { "\($0). Opens the pull request." } ?? "")
            .accessibilityIdentifier("toastty-task-merge-control-primary")
            if showsMenu {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .frame(height: 28)
                        .background(segment(tone, leading: false, trailing: true))
                }
                .accessibilityLabel("More task actions")
                .accessibilityIdentifier("toastty-task-merge-control-menu")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(foreground(tone))
        .opacity(isActive ? 1 : 0.75)
        .fixedSize()
    }

    /// A state that only opens its menu: the label with a ▼, or the label
    /// alone without a menu or while the phone cannot act.
    @ViewBuilder
    private func menuLabel(@ViewBuilder _ label: () -> some View) -> some View {
        if canAct, control.menu.isEmpty == false {
            Menu {
                menuItems
            } label: {
                HStack(spacing: 4) {
                    label()
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                }
            }
            .accessibilityLabel(control.title)
            .accessibilityHint(control.detail ?? "Shows task actions")
            .accessibilityIdentifier("toastty-task-merge-control-menu")
            .fixedSize()
        } else {
            label()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(control.title)
                .accessibilityIdentifier("toastty-task-merge-control-primary")
                .fixedSize()
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        ForEach(control.menu, id: \.self) { item in
            Button(item.title, systemImage: ToasttyTaskActionStyle.symbol(item.action)) { run(item) }
        }
    }

    private func run(_ item: RemoteTaskActionItem?) {
        guard let item, canAct else { return }
        runner?.run(item, task)
    }

    private func foreground(_ tone: Tone) -> Color {
        switch tone {
        case .merge: ToasttyDesignTokens.inkOnAmber
        case .neutral: ToasttyDesignTokens.primaryText
        }
    }

    private func segment(_ tone: Tone, leading: Bool, trailing: Bool) -> some View {
        let radius = ToasttyDesignTokens.chipCornerRadius
        return UnevenRoundedRectangle(
            topLeadingRadius: leading ? radius : 0,
            bottomLeadingRadius: leading ? radius : 0,
            bottomTrailingRadius: trailing ? radius : 0,
            topTrailingRadius: trailing ? radius : 0,
            style: .continuous
        )
        .fill(tone == .merge ? ToasttyDesignTokens.green : ToasttyDesignTokens.chipSurface)
    }
}

enum ToasttyTaskActionStyle {
    static func symbol(_ action: RemoteTaskAction) -> String {
        switch action {
        case .merge: "arrow.triangle.merge"
        case .markDone: "checkmark.square"
        case .archive: "archivebox"
        case .cancelMerge: "xmark.circle"
        case .cleanUp: "arrow.clockwise"
        case .keepAsIs: "hand.raised"
        case .retry: "arrow.clockwise"
        case .delete: "trash"
        }
    }

    /// The Mac's detail pane draws Merge and Clean Up as its main buttons;
    /// Retry is the main way out of a failed setup.
    static func isPrimary(_ action: RemoteTaskAction) -> Bool {
        action == .merge || action == .cleanUp || action == .retry
    }
}

// MARK: - Menus and buttons

/// A task's actions in a row's context menu, after a divider.
struct ToasttyTaskActionMenuItems: View {
    let task: RemoteTaskSummary
    let controller: HomeScreenController
    @Environment(\.toasttyTaskActionRunner) private var runner

    var body: some View {
        if let runner, controller.canActOnTasks, task.actions.isEmpty == false {
            Section {
                ForEach(task.actions, id: \.self) { item in
                    Button(
                        item.title,
                        systemImage: ToasttyTaskActionStyle.symbol(item.action),
                        role: item.action == .delete ? .destructive : nil
                    ) {
                        runner.run(item, task)
                    }
                }
            }
        }
    }
}

/// The detail sheet's buttons: the task's actions, two to a row.
struct ToasttyTaskActionButtons: View {
    let task: RemoteTaskSummary
    let controller: HomeScreenController
    @Environment(\.toasttyTaskActionRunner) private var runner

    var body: some View {
        if let runner, controller.canActOnTasks, task.actions.isEmpty == false {
            let isBusy = controller.isTaskActionInFlight(task.id)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(task.actions, id: \.self) { item in
                    Button {
                        runner.run(item, task)
                    } label: {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundStyle(foreground(item.action))
                            .background(background(item.action), in: RoundedRectangle(
                                cornerRadius: ToasttyDesignTokens.controlCornerRadius, style: .continuous
                            ))
                            .overlay(
                                RoundedRectangle(cornerRadius: ToasttyDesignTokens.controlCornerRadius, style: .continuous)
                                    .strokeBorder(ToasttyTaskActionStyle.isPrimary(item.action)
                                        ? Color.clear : ToasttyDesignTokens.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .accessibilityIdentifier("toastty-task-action-\(item.action.rawValue)")
                }
            }
            .opacity(isBusy ? 0.6 : 1)
            .accessibilityIdentifier("toastty-task-detail-actions")
        }
    }

    private func foreground(_ action: RemoteTaskAction) -> Color {
        if ToasttyTaskActionStyle.isPrimary(action) { return ToasttyDesignTokens.inkOnAmber }
        return action == .delete ? ToasttyDesignTokens.red : ToasttyDesignTokens.primaryText
    }

    private func background(_ action: RemoteTaskAction) -> Color {
        ToasttyTaskActionStyle.isPrimary(action) ? ToasttyDesignTokens.amber : ToasttyDesignTokens.raisedSurface
    }
}

// MARK: - Release

/// Release… on a To ship lane or a project card's To ship line, while the
/// Mac takes releases from this phone. It asks first, then the Mac starts a
/// release task. While a release of the project runs it reads Releasing…
/// and is off.
struct ToasttyReleaseButton: View {
    let release: MobileProjectRelease
    let controller: HomeScreenController
    let accessibilityIdentifier: String
    @Environment(\.toasttyTaskActionRunner) private var runner

    var body: some View {
        if let runner, controller.canReleaseProjects {
            let isOff = release.isReleasing || controller.isProjectReleaseInFlight(release)
            Button {
                runner.release(release)
            } label: {
                Text(release.isReleasing ? "Releasing\u{2026}" : "Release\u{2026}")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ToasttyDesignTokens.taskToShip)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(ToasttyDesignTokens.taskToShip.opacity(0.5), lineWidth: 1)
                    )
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isOff)
            .opacity(isOff ? 0.5 : 1)
            .fixedSize()
            .accessibilityLabel(release.isReleasing
                ? "Releasing \(release.projectTitle)" : "Release \(release.projectTitle)")
            .accessibilityHint(release.isReleasing ? "" : "Asks first, then starts a release task on your Mac")
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}

// MARK: - Archive

/// Archive Task…: what the Mac would close and lose, read from the Mac
/// first, then Cancel or Archive. Choices that would discard work stay on
/// the Mac: uncommitted changes or commits on no branch stop the archive.
struct ToasttyTaskArchiveSheet: View {
    let item: RemoteTaskActionItem
    let task: RemoteTaskSummary
    let controller: HomeScreenController

    private enum Load {
        case loading
        case ready(RemoteTaskArchiveCheck)
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var load = Load.loading
    @State private var closesPullRequest = false
    @State private var isArchiving = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Archive \u{201C}\(task.title)\u{201D}?")
                .font(.headline)
                .foregroundStyle(ToasttyDesignTokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("toastty-task-archive-title")
            switch load {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking the worktree on your Mac…")
                        .font(.subheadline)
                        .foregroundStyle(ToasttyDesignTokens.secondaryText)
                }
                .padding(.vertical, 12)
            case .failed(let message):
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(ToasttyDesignTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("toastty-task-archive-failure")
                buttons(canArchive: false)
            case .ready(let check):
                Text(Self.summary(check))
                    .font(.subheadline)
                    .foregroundStyle(ToasttyDesignTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(Self.rows(check).enumerated()), id: \.offset) { _, row in
                        checkRow(row)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("toastty-task-archive-checks")
                if let blocked = check.blockedReason {
                    Text(blocked)
                        .font(.footnote)
                        .foregroundStyle(ToasttyDesignTokens.amberText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ToasttyDesignTokens.amber.opacity(0.12), in: RoundedRectangle(
                            cornerRadius: ToasttyDesignTokens.controlCornerRadius, style: .continuous
                        ))
                        .accessibilityIdentifier("toastty-task-archive-blocked")
                }
                if let pullRequest = check.pullRequest {
                    Divider().overlay(ToasttyDesignTokens.divider)
                    Toggle("Close PR #\(pullRequest.number) on GitHub", isOn: $closesPullRequest)
                        .font(.subheadline)
                        .foregroundStyle(ToasttyDesignTokens.primaryText)
                        .tint(ToasttyDesignTokens.amber)
                        .disabled(check.blockedReason != nil)
                        .accessibilityIdentifier("toastty-task-archive-close-pull-request")
                }
                if let failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(ToasttyDesignTokens.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("toastty-task-archive-failure")
                }
                buttons(canArchive: check.blockedReason == nil)
            }
            Text("Deleting unpushed commits stays on the Mac.")
                .font(.caption)
                .foregroundStyle(ToasttyDesignTokens.mutedText)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ToasttyDesignTokens.elevatedSurface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            switch await controller.taskArchiveCheck(taskID: task.id) {
            case .answered(.ready(let check)):
                load = .ready(check)
            case .answered(.rejected(let reason, let message)):
                load = .failed(HomeScreenController.message(for: reason, macMessage: message))
            case .answered(.unrecognized):
                load = .failed("Your Mac answered in a way this app does not understand. Archive this task on your Mac.")
            case .unreachable:
                load = .failed("Toastty couldn\u{2019}t reach your Mac. Try again when it reconnects.")
            }
        }
    }

    private func buttons(canArchive: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(ToasttyDesignTokens.primaryText)
                    .background(ToasttyDesignTokens.raisedSurface, in: RoundedRectangle(
                        cornerRadius: ToasttyDesignTokens.controlCornerRadius, style: .continuous
                    ))
            }
            .accessibilityIdentifier("toastty-task-archive-cancel")
            Button {
                archive()
            } label: {
                HStack(spacing: 6) {
                    if isArchiving { ProgressView().controlSize(.small) }
                    Text("Archive")
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(canArchive ? ToasttyDesignTokens.red : ToasttyDesignTokens.mutedText)
                .background(ToasttyDesignTokens.raisedSurface, in: RoundedRectangle(
                    cornerRadius: ToasttyDesignTokens.controlCornerRadius, style: .continuous
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: ToasttyDesignTokens.controlCornerRadius, style: .continuous)
                        .strokeBorder(ToasttyDesignTokens.border, lineWidth: 1)
                )
            }
            .disabled(canArchive == false || isArchiving)
            .accessibilityIdentifier("toastty-task-archive-confirm")
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.plain)
    }

    private func archive() {
        guard isArchiving == false else { return }
        isArchiving = true
        failure = nil
        Task { @MainActor in
            // The pull request the sheet showed, from the archive check, is
            // the one the Mac must still have and may close.
            var shown = task
            if case .ready(let check) = load { shown.pullRequest = check.pullRequest }
            let result = await controller.performTaskAction(item, on: shown, closePullRequest: closesPullRequest)
            isArchiving = false
            if let result {
                failure = result.message
            } else {
                dismiss()
            }
        }
    }

    private struct CheckRow {
        let isClear: Bool
        let text: String
    }

    private func checkRow(_ row: CheckRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: row.isClear ? "checkmark" : "exclamationmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(row.isClear ? ToasttyDesignTokens.green : ToasttyDesignTokens.amber)
                .frame(width: 14)
            Text(row.text)
                .font(.subheadline)
                .foregroundStyle(ToasttyDesignTokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// "The Mac closes the task space and its agents, removes the worktree,
    /// and keeps the remote branch."
    private static func summary(_ check: RemoteTaskArchiveCheck) -> String {
        var parts: [String] = []
        if check.closesTaskSpace {
            parts.append(check.agentSessions > 0 ? "closes the task space and its agents" : "closes the task space")
        }
        if check.removesWorktree { parts.append("removes the worktree") }
        if check.branch != nil { parts.append("keeps the remote branch") }
        guard parts.isEmpty == false else { return "The Mac marks the task archived." }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + ", and " + parts.last!
        return "The Mac \(list)."
    }

    private static func rows(_ check: RemoteTaskArchiveCheck) -> [CheckRow] {
        func count(_ number: Int, _ singular: String, _ plural: String) -> String {
            number == 1 ? "1 \(singular)" : "\(number) \(plural)"
        }
        var rows: [CheckRow] = []
        if check.removesWorktree {
            rows.append(check.uncommittedFiles == 0
                ? CheckRow(isClear: true, text: "Worktree has no uncommitted changes")
                : CheckRow(isClear: false, text: "\(count(check.uncommittedFiles, "uncommitted file", "uncommitted files")) in the worktree"))
        }
        if check.unpushedCommits > 0 {
            let commits = count(check.unpushedCommits, "commit is", "commits are")
            rows.append(CheckRow(isClear: false, text: "\(commits) not on the remote. The local branch stays."))
        }
        if check.orphanedCommits > 0 {
            let commits = count(check.orphanedCommits, "commit", "commits")
            rows.append(CheckRow(isClear: false, text: "\(commits) at the worktree\u{2019}s HEAD on no branch"))
        }
        if check.unsavedDocuments > 0 {
            let documents = count(check.unsavedDocuments, "unsaved document", "unsaved documents")
            rows.append(CheckRow(isClear: false, text: "\(documents) in the task space"))
        }
        return rows
    }
}
