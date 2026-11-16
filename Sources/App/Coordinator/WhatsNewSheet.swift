import AppKit
import CoreState
import SwiftUI

/// What the What's new sheet shows for this user: the quick entry key, and
/// the lines that name what changed for a user who updates.
struct WhatsNewFacts: Equatable {
    enum Shortcut: Equatable {
        /// `tasks.toml` does not set a key: the sheet asks before Toastty
        /// takes this one, the default.
        case askForDefault(label: String)
        /// `tasks.toml` sets the key, or turns it off with nil. The sheet
        /// shows it and asks nothing.
        case written(label: String?)
    }

    var shortcut: Shortcut
    /// The box's first state: the saved answer, if the sheet shows again.
    var allowsDefaultShortcut = true
    /// Task spaces that have no task record, such as those from an earlier
    /// version, which the board now lists as tasks.
    var hasTaskSpacesFromBefore = false
    /// A paired phone that may merge, archive and delete tasks.
    var hasPhoneWithTaskActions = false
    /// Old example skills in the user's skills folder that are still
    /// delivered next to the built-in task skills.
    var oldExampleSkills: [UserSkillPackage] = []
}

/// What the sheet's links do, and where its answer about the key goes.
@MainActor
final class WhatsNewSheetActions {
    var facts: @MainActor () -> WhatsNewFacts = { WhatsNewFacts(shortcut: .askForDefault(label: QuickEntryShortcut.default.symbolLabel)) }
    /// The user's answer to "Use ⌥⇧T in every app", given with either
    /// button.
    var chooseDefaultShortcut: @MainActor (Bool) -> Void = { _ in }
    var openTasksConfiguration: @MainActor (_ windowID: UUID) -> Void = { _ in }
    var openRemoteAccess: @MainActor (_ windowID: UUID) -> Void = { windowID in
        NotificationCenter.default.post(name: .toasttyOpenRemoteAccess, object: windowID)
    }
    var revealInFinder: @MainActor ([URL]) -> Void = { urls in
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
    var openURL: @MainActor (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }
}

/// The sheet that a new user and a user who updates see once, in place of
/// the question whether to start the coordinator: tasks, quick entry and
/// its key, and the coordinator. Its two buttons answer that question.
struct WhatsNewSheet: View {
    enum Words {
        static let title = "New in Toastty: tasks"
        static let subtitle = "Hand work to agents, and follow all of it in one place."
        static let tasksTitle = "Tasks"
        static let tasks = "Describe a change. Toastty starts an agent on it in its own git worktree, shows its pull request, and merges it when you press Merge."
        static let quickEntryTitle = "Quick entry"
        static let quickEntry = "Add a task from any app."
        static func useEverywhere(_ label: String) -> String { "Use \(label) in every app" }
        static let useEverywhereNote = "Other apps, and Toastty's own terminals, then do not get this key."
        static let writtenShortcutNote = "Your tasks.toml sets this key."
        static let shortcutOffNote = "Your tasks.toml turns the key off. Use New Task… in the File menu."
        static let changeKey = "Change the key…"
        static let coordinatorTitle = "The coordinator"
        static let coordinator = "One agent that follows your tasks: it tells you what needs you, unblocks stuck tasks and turns your requests into tasks. The first time, it asks you a few questions about how you work. It can also run by itself each day. It keeps your rules in policy.md and changes them when you ask it to work differently. In friction.md it notes what slows your tasks, and it suggests fixes."
        static let startLater = "Not now? Start it later with Open Coordinator in the Agent menu."
        static let sidebar = "The sidebar now groups your sessions under Needs you, Running and Idle."
        static let taskSpacesFromBefore = "Your task spaces from before now show as tasks."
        static let phone = "Your paired phone can now merge, archive and delete tasks."
        static let phoneLink = "Change in Remote Access…"
        static func oldSkills(_ names: [String]) -> String {
            "Old example skills in ~/.toastty/skills (\(names.joined(separator: ", "))) compete with the new task skills. Delete them to use the built-in ones."
        }
        static let oldSkillsLink = "Show in Finder"
        static let readAboutTasks = "Read about tasks"
        static let notNow = "Not Now"
        static let start = "Start Coordinator"
    }

    static let tasksDocumentURL = URL(string: "https://github.com/figelwump/toastty/blob/main/docs/tasks.md")!

    let facts: WhatsNewFacts
    let windowID: UUID
    let actions: WhatsNewSheetActions
    /// Called once, with the user's answer and the state of the key's box.
    let finish: @MainActor (_ answer: CoordinatorStartOffer.Answer, _ allowsDefaultShortcut: Bool) -> Void

    @State private var allowsDefaultShortcut: Bool

    init(
        facts: WhatsNewFacts,
        windowID: UUID,
        actions: WhatsNewSheetActions,
        finish: @escaping @MainActor (_ answer: CoordinatorStartOffer.Answer, _ allowsDefaultShortcut: Bool) -> Void
    ) {
        self.facts = facts
        self.windowID = windowID
        self.actions = actions
        self.finish = finish
        _allowsDefaultShortcut = State(initialValue: facts.allowsDefaultShortcut)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Words.title)
                    .font(.system(size: 19, weight: .semibold))
                Text(Words.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(ToastyTheme.inactiveText)
            }
            card
            notes
            buttons
        }
        .padding(22)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .background(ToastyTheme.chromeBackground)
        .foregroundStyle(ToastyTheme.primaryText)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("whats-new.sheet")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            item(symbol: "checklist", title: Words.tasksTitle) {
                (Text(Words.tasks + " ") + Text("⇧⌘T").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(ToastyTheme.primaryText) + Text(" shows all tasks."))
                    .itemBody()
            }
            divider
            item(symbol: "keyboard", title: Words.quickEntryTitle, key: shortcutLabel) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(Words.quickEntry).itemBody()
                    shortcutChoice
                }
            }
            divider
            item(symbol: "sparkles", title: Words.coordinatorTitle) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(Words.coordinator).itemBody()
                    Text(Words.startLater)
                        .font(.system(size: 11))
                        .foregroundStyle(ToastyTheme.inactiveText.opacity(0.8))
                }
            }
        }
        .background(ToastyTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(ToastyTheme.hairline, lineWidth: 1)
        }
    }

    private var shortcutLabel: String? {
        switch facts.shortcut {
        case .askForDefault(let label): label
        case .written(let label): label
        }
    }

    @ViewBuilder
    private var shortcutChoice: some View {
        switch facts.shortcut {
        case .askForDefault(let label):
            VStack(alignment: .leading, spacing: 3) {
                Toggle(isOn: $allowsDefaultShortcut) {
                    Text(Words.useEverywhere(label))
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("whats-new.shortcut")
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Words.useEverywhereNote)
                    link(Words.changeKey, identifier: "whats-new.change-key") {
                        actions.openTasksConfiguration(windowID)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(ToastyTheme.inactiveText.opacity(0.8))
                .padding(.leading, 20)
            }
        case .written(let label):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label == nil ? Words.shortcutOffNote : Words.writtenShortcutNote)
                link(Words.changeKey, identifier: "whats-new.change-key") {
                    actions.openTasksConfiguration(windowID)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(ToastyTheme.inactiveText.opacity(0.8))
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            note(Words.sidebar)
            if facts.hasTaskSpacesFromBefore {
                note(Words.taskSpacesFromBefore)
                    .accessibilityIdentifier("whats-new.task-spaces")
            }
            if facts.hasPhoneWithTaskActions {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    note(Words.phone)
                    link(Words.phoneLink, identifier: "whats-new.remote-access") {
                        actions.openRemoteAccess(windowID)
                    }
                }
                .font(.system(size: 11))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("whats-new.phone")
            }
            if facts.oldExampleSkills.isEmpty == false {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("⚠ " + Words.oldSkills(facts.oldExampleSkills.map(\.name)))
                        .foregroundStyle(ToastyTheme.sessionNeedsApprovalText)
                        .fixedSize(horizontal: false, vertical: true)
                    link(Words.oldSkillsLink, identifier: "whats-new.old-skills") {
                        actions.revealInFinder(facts.oldExampleSkills.map(\.sourceURL))
                    }
                }
                .font(.system(size: 11))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("whats-new.old-skills-note")
            }
        }
        .padding(.horizontal, 2)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            link(Words.readAboutTasks + " ↗", identifier: "whats-new.read-about-tasks") {
                actions.openURL(Self.tasksDocumentURL)
            }
            .font(.system(size: 12))
            Spacer()
            Button(Words.notNow) { finish(.notNow, allowsDefaultShortcut) }
                .buttonStyle(SheetButtonStyle(isProminent: false))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("whats-new.not-now")
            Button(Words.start) { finish(.start, allowsDefaultShortcut) }
                .buttonStyle(SheetButtonStyle(isProminent: true))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("whats-new.start")
        }
        .padding(.top, 2)
    }

    // MARK: - Parts

    private func item<Content: View>(
        symbol: String,
        title: String,
        key: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ToastyTheme.accent)
                .frame(width: 28, height: 28)
                .background(ToastyTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if let key {
                        Text(key)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(ToastyTheme.subtleBorder, lineWidth: 1)
                            }
                    }
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Rectangle().fill(ToastyTheme.hairline).frame(height: 1)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(ToastyTheme.inactiveText.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func link(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundStyle(ToastyTheme.accent)
            .fixedSize()
            .accessibilityIdentifier(identifier)
    }
}

/// The sheet's two buttons, in the app's colors: the default one filled
/// with the accent.
private struct SheetButtonStyle: ButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: isProminent ? .semibold : .regular))
            .foregroundStyle(isProminent ? ToastyTheme.accentDark : ToastyTheme.primaryText)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(
                isProminent ? ToastyTheme.accent : Color(hex: 0x2A2A2A),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isProminent ? ToastyTheme.accent : Color(hex: 0x3A3A3A), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

private extension Text {
    func itemBody() -> some View {
        font(.system(size: 12))
            .foregroundStyle(ToastyTheme.inactiveText)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension WhatsNewSheet {
    /// Shows the sheet over a window as the coordinator question's
    /// presenter. The answer about the key is given before the question's
    /// answer, so the key is set up before the coordinator starts.
    static func presenter(actions: WhatsNewSheetActions) -> CoordinatorStartOffer.Presenter {
        { windowID, answer in
            guard let window = AgentLaunchUI.window(for: windowID), window.attachedSheet == nil else { return nil }
            let facts = actions.facts()
            let sheetWindow = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: true
            )
            sheetWindow.titleVisibility = .hidden
            sheetWindow.titlebarAppearsTransparent = true
            sheetWindow.isReleasedWhenClosed = false
            sheetWindow.setAccessibilityIdentifier("coordinator.start-offer")
            let view = WhatsNewSheet(facts: facts, windowID: windowID, actions: actions) { [weak window, weak sheetWindow] choice, allowsDefaultShortcut in
                if case .askForDefault = facts.shortcut {
                    actions.chooseDefaultShortcut(allowsDefaultShortcut)
                }
                guard let window, let sheetWindow else { return }
                window.endSheet(sheetWindow, returnCode: choice == .start ? .alertFirstButtonReturn : .alertSecondButtonReturn)
            }
            let hosting = NSHostingController(rootView: view)
            hosting.sizingOptions = [.preferredContentSize]
            sheetWindow.contentViewController = hosting
            sheetWindow.setContentSize(hosting.view.fittingSize)
            window.beginSheet(sheetWindow) { response in
                // The handler holds the sheet until it ends.
                _ = sheetWindow
                Task { @MainActor in
                    switch response {
                    case .alertFirstButtonReturn: answer(.start)
                    case .alertSecondButtonReturn: answer(.notNow)
                    // Taken down, or its window closed.
                    default: answer(nil)
                    }
                }
            }
            return { [weak window, weak sheetWindow] in
                guard let sheetWindow else { return }
                window?.endSheet(sheetWindow, returnCode: .abort)
            }
        }
    }
}
