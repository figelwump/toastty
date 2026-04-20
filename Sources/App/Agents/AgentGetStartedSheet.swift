import SwiftUI

struct AgentGetStartedActionError: LocalizedError, Equatable, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}

enum AgentGetStartedShellIntegrationStepState: Equatable {
    case loading
    case installable(ProfileShellIntegrationInstallStatus)
    case alreadyInstalled(ProfileShellIntegrationInstallStatus)
    case installing(ProfileShellIntegrationInstallStatus)
    case installSucceeded(ProfileShellIntegrationInstallResult)
    case unavailable(String)
    case installFailed(ProfileShellIntegrationInstallStatus, String)

    var blocksNavigation: Bool {
        if case .installing = self {
            return true
        }
        return false
    }
}

enum AgentGetStartedShellIntegrationStepResolver {
    static func loadedState(
        from status: ProfileShellIntegrationInstallStatus
    ) -> AgentGetStartedShellIntegrationStepState {
        if status.isInstalled {
            return .alreadyInstalled(status)
        }
        return .installable(status)
    }

    static func installFailureState(
        for status: ProfileShellIntegrationInstallStatus,
        message: String
    ) -> AgentGetStartedShellIntegrationStepState {
        .installFailed(status, message)
    }
}

enum AgentGetStartedStep: Equatable {
    case chooser
    case shellIntegration
    case keyboardShortcuts
}

enum AgentGetStartedSheetBehavior {
    static func dismissDisabled(
        step: AgentGetStartedStep,
        shellIntegrationState: AgentGetStartedShellIntegrationStepState
    ) -> Bool {
        step == .shellIntegration && shellIntegrationState.blocksNavigation
    }

    static func actionErrorMessage(
        for result: Result<Void, AgentGetStartedActionError>
    ) -> String? {
        switch result {
        case .success:
            return nil
        case .failure(let error):
            return error.localizedDescription
        }
    }
}

struct AgentGetStartedSheet: View {
    let openAgentProfilesConfiguration: @MainActor () -> Result<Void, AgentGetStartedActionError>
    let openKeyboardShortcutsReference: @MainActor () -> Result<Void, AgentGetStartedActionError>
    let resolveShellIntegrationPreferredShellPath: @MainActor () -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var step: AgentGetStartedStep = .chooser
    @State private var shellIntegrationState: AgentGetStartedShellIntegrationStepState = .loading
    @State private var openAgentProfilesErrorMessage: String?
    @State private var openKeyboardShortcutsReferenceErrorMessage: String?
    @State private var shellIntegrationTask: Task<Void, Never>?

    init(
        openAgentProfilesConfiguration: @escaping @MainActor () -> Result<Void, AgentGetStartedActionError>,
        openKeyboardShortcutsReference: @escaping @MainActor () -> Result<Void, AgentGetStartedActionError>,
        resolveShellIntegrationPreferredShellPath: @escaping @MainActor () -> String? = { nil }
    ) {
        self.openAgentProfilesConfiguration = openAgentProfilesConfiguration
        self.openKeyboardShortcutsReference = openKeyboardShortcutsReference
        self.resolveShellIntegrationPreferredShellPath = resolveShellIntegrationPreferredShellPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .overlay(ToastyTheme.hairline)
            content
            Divider()
                .overlay(ToastyTheme.hairline)
            buttonBar
        }
        .frame(width: 560)
        .background(ToastyTheme.chromeBackground)
        .foregroundStyle(ToastyTheme.primaryText)
        .accessibilityIdentifier("sheet.agent.get-started")
        .interactiveDismissDisabled(
            AgentGetStartedSheetBehavior.dismissDisabled(
                step: step,
                shellIntegrationState: shellIntegrationState
            )
        )
        .onDisappear {
            if shellIntegrationState.blocksNavigation == false {
                shellIntegrationTask?.cancel()
            }
            shellIntegrationTask = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headerTitle)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(ToastyTheme.primaryText)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .chooser:
            chooserContent
        case .shellIntegration:
            shellIntegrationContent
        case .keyboardShortcuts:
            keyboardShortcutsContent
        }
    }

    private var chooserContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionCard(
                title: "Typed Commands",
                body: """
                Type codex, claude, or supported wrapper executables directly in Toastty terminals. Shell integration keeps agent sessions visible on the sidebar and preserves terminal history across restarts.
                """
            ) {
                Button("Set Up Typed Commands") {
                    showShellIntegrationStep()
                }
                .accessibilityIdentifier("sheet.agent.get-started.typed-commands")
            }

            quickLaunchButtonsCard
            keyboardShortcutsCard()
        }
        .padding(24)
    }

    @ViewBuilder
    private var shellIntegrationContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionCard(
                title: "Shell Integration",
                body: "Shell integration keeps agent sessions visible on the sidebar and preserves terminal history across restarts."
            ) {
                shellIntegrationStateContent
            }

            quickLaunchButtonsCard
            keyboardShortcutsCard(isDisabled: shellIntegrationState.blocksNavigation)
        }
        .padding(24)
    }

    private var keyboardShortcutsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionCard(
                title: "Keyboard Shortcuts",
                body: "Start with the core workspace, split, focus, and close shortcuts, then open the full reference when you want the complete list."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    shortcutReferenceRow(
                        title: "Show or hide the sidebar",
                        shortcut: ToasttyKeyboardShortcuts.toggleSidebar.symbolLabel
                    )
                    shortcutReferenceRow(
                        title: "Create a new workspace",
                        shortcut: ToasttyKeyboardShortcuts.newWorkspace.symbolLabel
                    )
                    shortcutReferenceRow(
                        title: "Split horizontally",
                        shortcut: ToasttyKeyboardShortcuts.splitHorizontal.symbolLabel
                    )
                    shortcutReferenceRow(
                        title: "Split vertically",
                        shortcut: ToasttyKeyboardShortcuts.splitVertical.symbolLabel
                    )
                    shortcutReferenceRow(
                        title: "Focus the previous or next pane",
                        shortcut: "\(ToasttyKeyboardShortcuts.focusPreviousPane.symbolLabel) / \(ToasttyKeyboardShortcuts.focusNextPane.symbolLabel)"
                    )
                    shortcutReferenceRow(
                        title: "Jump to the next active or unread panel",
                        shortcut: ToasttyKeyboardShortcuts.focusNextUnreadOrActivePanel.symbolLabel
                    )
                    shortcutReferenceRow(
                        title: "Close the focused panel",
                        shortcut: ToasttyKeyboardShortcuts.closePanel.symbolLabel
                    )
                    shortcutReferenceRow(
                        title: "Toggle focused panel mode",
                        shortcut: ToasttyKeyboardShortcuts.toggleFocusedPanel.symbolLabel
                    )
                }

                if let openKeyboardShortcutsReferenceErrorMessage {
                    inlineMessage(
                        openKeyboardShortcutsReferenceErrorMessage,
                        textColor: ToastyTheme.sessionErrorText,
                        backgroundColor: ToastyTheme.sessionErrorBackground,
                        identifier: "sheet.agent.get-started.error.shortcuts-reference"
                    )
                }

                Button("Open Full Shortcut Reference") {
                    openShortcutReference()
                }
                .accessibilityIdentifier("sheet.agent.get-started.open-shortcuts-reference")
            }
        }
        .padding(24)
    }

    private var quickLaunchButtonsCard: some View {
        sectionCard(
            title: "Quick-Launch Buttons",
            body: """
                Configure ~/.toastty/agents.toml when you want dedicated header buttons, agent menu entries, and optional keyboard shortcuts for your favorite agent launch commands.
                """
        ) {
            if let openAgentProfilesErrorMessage {
                inlineMessage(
                    openAgentProfilesErrorMessage,
                    textColor: ToastyTheme.sessionErrorText,
                    backgroundColor: ToastyTheme.sessionErrorBackground,
                    identifier: "sheet.agent.get-started.error.open"
                )
            }

            Button("Open agents.toml") {
                openAgentProfiles()
            }
            .accessibilityIdentifier("sheet.agent.get-started.open-agents")
        }
    }

    private func keyboardShortcutsCard(isDisabled: Bool = false) -> some View {
        sectionCard(
            title: "Keyboard Shortcuts",
            body: "Review the primary workspace, split, focus, and close shortcuts so you can drive Toastty faster from the keyboard."
        ) {
            Button("View Keyboard Shortcuts") {
                showKeyboardShortcutsStep()
            }
            .disabled(isDisabled)
            .accessibilityIdentifier("sheet.agent.get-started.keyboard-shortcuts")
        }
    }

    private var buttonBar: some View {
        HStack(spacing: 10) {
            switch step {
            case .chooser:
                Spacer(minLength: 0)

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("sheet.agent.get-started.done")

            case .shellIntegration:
                Button("Back") {
                    shellIntegrationTask?.cancel()
                    shellIntegrationTask = nil
                    openAgentProfilesErrorMessage = nil
                    openKeyboardShortcutsReferenceErrorMessage = nil
                    step = .chooser
                }
                .disabled(shellIntegrationState.blocksNavigation)
                .accessibilityIdentifier("sheet.agent.get-started.back")

                Spacer(minLength: 0)

                Button("Done") {
                    dismiss()
                }
                .disabled(shellIntegrationState.blocksNavigation)
                .accessibilityIdentifier("sheet.agent.get-started.done")

            case .keyboardShortcuts:
                Button("Back") {
                    openKeyboardShortcutsReferenceErrorMessage = nil
                    step = .chooser
                }
                .accessibilityIdentifier("sheet.agent.get-started.back")

                Spacer(minLength: 0)

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("sheet.agent.get-started.done")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var headerTitle: String {
        switch step {
        case .chooser:
            return "Get started with Toastty"
        case .shellIntegration:
            return "Set Up Typed Commands"
        case .keyboardShortcuts:
            return "Keyboard Shortcuts"
        }
    }

    @ViewBuilder
    private var shellIntegrationStateContent: some View {
        switch shellIntegrationState {
        case .loading:
            loadingContent(message: "Checking whether shell integration is available for this shell.")

        case .installable(let status):
            shellIntegrationStatusContent(status: status)
            Button("Install Integration") {
                installShellIntegration(status: status)
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("sheet.agent.get-started.install-integration")

        case .alreadyInstalled(let status):
            inlineMessage(
                "Shell integration is already installed for \(status.plan.shell.displayName).",
                textColor: ToastyTheme.sessionReadyText,
                backgroundColor: ToastyTheme.sessionReadyBackground,
                identifier: "sheet.agent.get-started.ready"
            )
            shellIntegrationDetails(
                leadingText: "Init file",
                leadingValue: status.plan.initFileURL.path,
                trailingText: "Managed snippet",
                trailingValue: status.plan.managedSnippetURL.path
            )

        case .installing(let status):
            shellIntegrationStatusContent(status: status)
            loadingContent(message: "Installing shell integration.")
            Button("Installing…") {}
                .disabled(true)
                .accessibilityIdentifier("sheet.agent.get-started.installing")

        case .installSucceeded(let result):
            inlineMessage(
                "Shell integration is installed.",
                textColor: ToastyTheme.sessionReadyText,
                backgroundColor: ToastyTheme.sessionReadyBackground,
                identifier: "sheet.agent.get-started.installed"
            )
            shellIntegrationDetails(
                leadingText: "Managed snippet",
                leadingValue: ProfileShellIntegrationMessaging.managedSnippetResultLine(for: result),
                trailingText: "Init file",
                trailingValue: ProfileShellIntegrationMessaging.initFileResultLine(for: result)
            )
            Text(ProfileShellIntegrationMessaging.restartNotice)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(ToastyTheme.inactiveText)
                .fixedSize(horizontal: false, vertical: true)

        case .unavailable(let message):
            inlineMessage(
                message,
                textColor: ToastyTheme.sessionErrorText,
                backgroundColor: ToastyTheme.sessionErrorBackground,
                identifier: "sheet.agent.get-started.unavailable"
            )

        case .installFailed(let status, let message):
            shellIntegrationStatusContent(status: status)
            inlineMessage(
                message,
                textColor: ToastyTheme.sessionErrorText,
                backgroundColor: ToastyTheme.sessionErrorBackground,
                identifier: "sheet.agent.get-started.error.install"
            )
            Button("Install Integration") {
                installShellIntegration(status: status)
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("sheet.agent.get-started.install-integration")
        }
    }

    private func sectionCard<Content: View>(
        title: String,
        body: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(ToastyTheme.primaryText)
            Text(body)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(ToastyTheme.inactiveText)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ToastyTheme.elevatedBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(ToastyTheme.subtleBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func shellIntegrationStatusContent(
        status: ProfileShellIntegrationInstallStatus
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            inlineMessage(
                "Toastty detected \(status.plan.shell.displayName).",
                textColor: ToastyTheme.primaryText,
                backgroundColor: ToastyTheme.elevatedBackground,
                identifier: "sheet.agent.get-started.detected-shell"
            )

            shellIntegrationDetails(
                leadingText: "Managed snippet",
                leadingValue: ProfileShellIntegrationMessaging.managedSnippetPlanLine(for: status),
                trailingText: "Init file",
                trailingValue: ProfileShellIntegrationMessaging.initFilePlanLine(for: status)
            )

            Text(ProfileShellIntegrationMessaging.restartNotice)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(ToastyTheme.inactiveText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shellIntegrationDetails(
        leadingText: String,
        leadingValue: String,
        trailingText: String,
        trailingValue: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            detailBlock(title: leadingText, value: leadingValue)
            detailBlock(title: trailingText, value: trailingValue)
        }
    }

    private func detailBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(ToastyTheme.fontMonoHeader)
                .foregroundStyle(ToastyTheme.primaryText)
            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(ToastyTheme.inactiveText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ToastyTheme.elevatedBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(ToastyTheme.subtleBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func shortcutReferenceRow(title: String, shortcut: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(shortcut)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(ToastyTheme.primaryText)
                .frame(width: 112, alignment: .leading)

            Text(title)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(ToastyTheme.inactiveText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inlineMessage(
        _ message: String,
        textColor: Color,
        backgroundColor: Color,
        identifier: String
    ) -> some View {
        Text(message)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(textColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier(identifier)
    }

    private func loadingContent(message: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(ToastyTheme.inactiveText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func showShellIntegrationStep() {
        openAgentProfilesErrorMessage = nil
        openKeyboardShortcutsReferenceErrorMessage = nil
        step = .shellIntegration
        loadShellIntegrationStatus()
    }

    private func showKeyboardShortcutsStep() {
        openAgentProfilesErrorMessage = nil
        openKeyboardShortcutsReferenceErrorMessage = nil
        step = .keyboardShortcuts
    }

    private func openAgentProfiles() {
        let result = openAgentProfilesConfiguration()
        openAgentProfilesErrorMessage = AgentGetStartedSheetBehavior.actionErrorMessage(for: result)
    }

    private func openShortcutReference() {
        let result = openKeyboardShortcutsReference()
        openKeyboardShortcutsReferenceErrorMessage = AgentGetStartedSheetBehavior.actionErrorMessage(
            for: result
        )
    }

    private func loadShellIntegrationStatus() {
        shellIntegrationTask?.cancel()
        shellIntegrationTask = Task(priority: .userInitiated) {
            await MainActor.run {
                shellIntegrationState = .loading
            }
            let result: Result<ProfileShellIntegrationInstallStatus, AgentGetStartedActionError>
            do {
                let preferredShellPath = await MainActor.run {
                    resolveShellIntegrationPreferredShellPath()
                }
                let status = try ProfileShellIntegrationInstaller(
                    preferredShellPath: preferredShellPath,
                    preferredShellSource: .liveTerminalShell
                ).installationStatus()
                result = .success(status)
            } catch {
                result = .failure(AgentGetStartedActionError(message: error.localizedDescription))
            }

            guard Task.isCancelled == false else { return }

            await MainActor.run {
                switch result {
                case .success(let status):
                    shellIntegrationState = AgentGetStartedShellIntegrationStepResolver.loadedState(from: status)
                case .failure(let error):
                    shellIntegrationState = .unavailable(error.localizedDescription)
                }
            }
        }
    }

    private func installShellIntegration(
        status: ProfileShellIntegrationInstallStatus
    ) {
        openAgentProfilesErrorMessage = nil
        shellIntegrationTask?.cancel()
        shellIntegrationTask = Task(priority: .userInitiated) {
            await MainActor.run {
                shellIntegrationState = .installing(status)
            }
            let result: Result<ProfileShellIntegrationInstallResult, AgentGetStartedActionError>
            do {
                let preferredShellPath = await MainActor.run {
                    resolveShellIntegrationPreferredShellPath()
                }
                let installResult = try ProfileShellIntegrationInstaller(
                    preferredShellPath: preferredShellPath,
                    preferredShellSource: .liveTerminalShell
                ).install(plan: status.plan)
                result = .success(installResult)
            } catch {
                result = .failure(AgentGetStartedActionError(message: error.localizedDescription))
            }

            guard Task.isCancelled == false else { return }

            await MainActor.run {
                switch result {
                case .success(let installResult):
                    shellIntegrationState = .installSucceeded(installResult)
                case .failure(let error):
                    shellIntegrationState = AgentGetStartedShellIntegrationStepResolver.installFailureState(
                        for: status,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }
}
