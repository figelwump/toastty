import AppKit
import CoreState
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

enum AgentStatusHooksStepState: Equatable {
    case loading
    case installable(CodexStatusHookInstallStatus)
    case alreadyInstalled(CodexStatusHookInstallStatus)
    case installing(CodexStatusHookInstallStatus)
    case installSucceeded(CodexStatusHookInstallResult)
    case unavailable(String)
    case installFailed(CodexStatusHookInstallStatus, String)

    var blocksNavigation: Bool {
        if case .installing = self {
            return true
        }
        return false
    }
}

enum AgentStatusHooksStepResolver {
    static func loadedState(
        from status: CodexStatusHookInstallStatus
    ) -> AgentStatusHooksStepState {
        if status.isInstalled {
            return .alreadyInstalled(status)
        }
        return .installable(status)
    }

    static func installFailureState(
        for status: CodexStatusHookInstallStatus,
        message: String
    ) -> AgentStatusHooksStepState {
        .installFailed(status, message)
    }
}

enum AgentGetStartedStep: Equatable {
    case chooser
    case shellIntegration
    case agentStatusHooks
    case keyboardShortcuts
}

struct AgentGetStartedPresentationRequest: Equatable {
    let windowID: UUID
    let initialStep: AgentGetStartedStep
    let isAutomatic: Bool

    init(
        windowID: UUID,
        initialStep: AgentGetStartedStep = .chooser,
        isAutomatic: Bool = false
    ) {
        self.windowID = windowID
        self.initialStep = initialStep
        self.isAutomatic = isAutomatic
    }
}

enum AgentGetStartedSheetBehavior {
    static let supportedAgentNames = "codex, claude, pi, opencode, mimo"
    static let supportedAgentHint = "Need an agent first? Open a pane and start codex, claude, pi, opencode, or mimo."
    static let onboardingHeroBody = "Copy the onboarding prompt and paste it into an agent of your choice to get started. The prompt will walk your agent through setting up agents, skills, and profiles in Toastty."
    static let manualSetupBody = "Choose manual setup if you had issues with the onboarding prompt, or prefer to setup Toastty manually."
    static let codexStatusHooksManualRowBody = "Toastty guides the install; Codex may ask you to trust the hook once."

    static let onboardingPrompt = """
    You are helping me set up Toastty. Please run:

    "$TOASTTY_CLI_PATH" setup guide

    Read the guide, narrate each step, dry-run every setup command first, show me the planned writes, and wait for my explicit OK before rerunning anything with --apply.
    """

    static func dismissDisabled(
        step: AgentGetStartedStep,
        shellIntegrationState: AgentGetStartedShellIntegrationStepState,
        agentStatusHooksState: AgentStatusHooksStepState = .loading
    ) -> Bool {
        switch step {
        case .shellIntegration:
            return shellIntegrationState.blocksNavigation
        case .agentStatusHooks:
            return agentStatusHooksState.blocksNavigation
        case .chooser, .keyboardShortcuts:
            return false
        }
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
    let markGettingStartedSeen: @MainActor () -> Void
    let resolveShellIntegrationPreferredShellPath: @MainActor () -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var step: AgentGetStartedStep
    @State private var shellIntegrationState: AgentGetStartedShellIntegrationStepState = .loading
    @State private var agentStatusHooksState: AgentStatusHooksStepState = .loading
    @State private var openAgentProfilesErrorMessage: String?
    @State private var openKeyboardShortcutsReferenceErrorMessage: String?
    @State private var onboardingPromptCopied = false
    @State private var dontShowAgain = false
    @State private var explicitlyOptedOutOfAutoShow = false
    @State private var shellIntegrationTask: Task<Void, Never>?
    @State private var agentStatusHooksTask: Task<Void, Never>?

    init(
        initialStep: AgentGetStartedStep = .chooser,
        openAgentProfilesConfiguration: @escaping @MainActor () -> Result<Void, AgentGetStartedActionError>,
        openKeyboardShortcutsReference: @escaping @MainActor () -> Result<Void, AgentGetStartedActionError>,
        markGettingStartedSeen: @escaping @MainActor () -> Void = {},
        resolveShellIntegrationPreferredShellPath: @escaping @MainActor () -> String? = { nil }
    ) {
        _step = State(initialValue: initialStep)
        self.openAgentProfilesConfiguration = openAgentProfilesConfiguration
        self.openKeyboardShortcutsReference = openKeyboardShortcutsReference
        self.markGettingStartedSeen = markGettingStartedSeen
        self.resolveShellIntegrationPreferredShellPath = resolveShellIntegrationPreferredShellPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .overlay(ToastyTheme.hairline)
            ScrollView {
                content
            }
            .frame(maxHeight: 720)
            Divider()
                .overlay(ToastyTheme.hairline)
            buttonBar
        }
        .frame(width: 640)
        .background(ToastyTheme.chromeBackground)
        .foregroundStyle(ToastyTheme.primaryText)
        .accessibilityIdentifier("sheet.agent.get-started")
        .interactiveDismissDisabled(
            AgentGetStartedSheetBehavior.dismissDisabled(
                step: step,
                shellIntegrationState: shellIntegrationState,
                agentStatusHooksState: agentStatusHooksState
            )
        )
        .onAppear {
            loadInitialStepIfNeeded()
        }
        .onDisappear {
            if explicitlyOptedOutOfAutoShow {
                markGettingStartedSeen()
            }
            if shellIntegrationState.blocksNavigation == false {
                shellIntegrationTask?.cancel()
            }
            if agentStatusHooksState.blocksNavigation == false {
                agentStatusHooksTask?.cancel()
            }
            shellIntegrationTask = nil
            agentStatusHooksTask = nil
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
        case .agentStatusHooks:
            agentStatusHooksContent
        case .keyboardShortcuts:
            keyboardShortcutsContent
        }
    }

    private var chooserContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingHero

            VStack(alignment: .leading, spacing: 10) {
                Text("Manual setup")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(ToastyTheme.primaryText)
                Text(AgentGetStartedSheetBehavior.manualSetupBody)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .fixedSize(horizontal: false, vertical: true)

                manualFallbackRow(
                    systemImage: "terminal",
                    title: "Shell integration",
                    body: "Track agents you start by hand."
                ) {
                    showShellIntegrationStep()
                }
                .accessibilityIdentifier("sheet.agent.get-started.typed-commands")

                manualFallbackRow(
                    systemImage: "checkmark.circle",
                    title: "Codex status hooks",
                    body: AgentGetStartedSheetBehavior.codexStatusHooksManualRowBody
                ) {
                    showAgentStatusHooksStep()
                }
                .accessibilityIdentifier("sheet.agent.get-started.status-hooks")

                manualFallbackRow(
                    systemImage: "slider.horizontal.3",
                    title: "Terminal profiles",
                    body: "Launchers for tmux, ssh, REPLs, and more."
                ) {
                    openAgentProfiles()
                }
                .accessibilityIdentifier("sheet.agent.get-started.open-agents")

                if let openAgentProfilesErrorMessage {
                    inlineMessage(
                        openAgentProfilesErrorMessage,
                        textColor: ToastyTheme.sessionErrorText,
                        backgroundColor: ToastyTheme.sessionErrorBackground,
                        identifier: "sheet.agent.get-started.error.open"
                    )
                }

                manualFallbackRow(
                    systemImage: "keyboard",
                    title: "Keyboard shortcuts",
                    body: "Reference."
                ) {
                    showKeyboardShortcutsStep()
                }
                .accessibilityIdentifier("sheet.agent.get-started.keyboard-shortcuts")
            }
        }
        .padding(24)
    }

    private var onboardingHero: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Set up with your agent")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(ToastyTheme.primaryText)
                Text(AgentGetStartedSheetBehavior.onboardingHeroBody)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            benefitsRow

            Text(AgentGetStartedSheetBehavior.supportedAgentHint)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(ToastyTheme.inactiveText)
                .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("\(AgentGetStartedSheetBehavior.supportedAgentHint) Supported agents: \(AgentGetStartedSheetBehavior.supportedAgentNames).")

            Button {
                copyOnboardingPrompt()
            } label: {
                Label(onboardingPromptCopied ? "Copied onboarding prompt" : "Copy onboarding prompt", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("sheet.agent.get-started.copy-onboarding-prompt")

            Text(AgentGetStartedSheetBehavior.onboardingPrompt)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(ToastyTheme.inactiveText)
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ToastyTheme.elevatedBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ToastyTheme.subtleBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("sheet.agent.get-started.onboarding-prompt")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var benefitsRow: some View {
        HStack(spacing: 10) {
            onboardingBenefit(
                systemImage: "waveform.path.ecg.rectangle",
                title: "Live status",
                body: "Track agent work and completion."
            )
            onboardingBenefit(
                systemImage: "sparkles",
                title: "Starter skills",
                body: "Install only what fits your workflow."
            )
            onboardingBenefit(
                systemImage: "slider.horizontal.3",
                title: "Profiles",
                body: "Add launchers for terminals you use."
            )
        }
    }

    private func onboardingBenefit(
        systemImage: String,
        title: String,
        body: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ToastyTheme.primaryText)
                .frame(width: 18, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(ToastyTheme.primaryText)
                    .lineLimit(1)
                Text(body)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .background(ToastyTheme.elevatedBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ToastyTheme.subtleBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    @ViewBuilder
    private var agentStatusHooksContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionCard(
                title: "Codex Status Hooks",
                body: "Toastty installs one stable Codex hook forwarder and adds it to ~/.codex/hooks.json. Codex may ask you to review and trust the hook once."
            ) {
                agentStatusHooksStateContent
            }

            sectionCard(
                title: "Claude Code Status Hooks",
                body: "Toastty-managed Claude Code sessions already receive status hooks at launch time, so no global setup is required for Claude Code."
            ) {
                inlineMessage(
                    "Automatic for Toastty launches.",
                    textColor: ToastyTheme.sessionReadyText,
                    backgroundColor: ToastyTheme.sessionReadyBackground,
                    identifier: "sheet.agent.get-started.claude-hooks-ready"
                )
            }
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
                dontShowAgainToggle

                Spacer(minLength: 0)

                Button("Done") {
                    completeAndDismiss()
                }
                .keyboardShortcut(.cancelAction)
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
                    completeAndDismiss()
                }
                .disabled(shellIntegrationState.blocksNavigation)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("sheet.agent.get-started.done")

            case .agentStatusHooks:
                Button("Back") {
                    agentStatusHooksTask?.cancel()
                    agentStatusHooksTask = nil
                    step = .chooser
                }
                .disabled(agentStatusHooksState.blocksNavigation)
                .accessibilityIdentifier("sheet.agent.get-started.back")

                Spacer(minLength: 0)

                Button("Done") {
                    completeAndDismiss()
                }
                .disabled(agentStatusHooksState.blocksNavigation)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("sheet.agent.get-started.done")

            case .keyboardShortcuts:
                Button("Back") {
                    openKeyboardShortcutsReferenceErrorMessage = nil
                    step = .chooser
                }
                .accessibilityIdentifier("sheet.agent.get-started.back")

                Spacer(minLength: 0)

                Button("Done") {
                    completeAndDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("sheet.agent.get-started.done")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var dontShowAgainToggle: some View {
        Toggle(
            "Don't show this again",
            isOn: Binding(
                get: { dontShowAgain },
                set: { newValue in
                    dontShowAgain = newValue
                    explicitlyOptedOutOfAutoShow = newValue
                }
            )
        )
        .toggleStyle(.checkbox)
        .font(.system(size: 12, weight: .regular))
        .foregroundStyle(ToastyTheme.inactiveText)
        .accessibilityIdentifier("sheet.agent.get-started.dont-show-again")
    }

    private var headerTitle: String {
        switch step {
        case .chooser:
            return "Get started with Toastty"
        case .shellIntegration:
            return "Set Up Typed Commands"
        case .agentStatusHooks:
            return "Agent Status Hooks"
        case .keyboardShortcuts:
            return "Keyboard Shortcuts"
        }
    }

    @ViewBuilder
    private var agentStatusHooksStateContent: some View {
        switch agentStatusHooksState {
        case .loading:
            loadingContent(message: "Checking Codex hook setup.")

        case .installable(let status):
            codexStatusHooksDetails(status: status)
            Button(status.state == .needsUpdate ? "Update Codex Hooks" : "Install Codex Hooks") {
                installAgentStatusHooks(status: status)
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("sheet.agent.get-started.install-status-hooks")

        case .alreadyInstalled(let status):
            inlineMessage(
                "Codex status hooks are installed.",
                textColor: ToastyTheme.sessionReadyText,
                backgroundColor: ToastyTheme.sessionReadyBackground,
                identifier: "sheet.agent.get-started.status-hooks-ready"
            )
            codexStatusHooksDetails(status: status)

        case .installing(let status):
            codexStatusHooksDetails(status: status)
            loadingContent(message: "Installing Codex status hooks.")
            Button("Installing…") {}
                .disabled(true)
                .accessibilityIdentifier("sheet.agent.get-started.installing-status-hooks")

        case .installSucceeded(let result):
            inlineMessage(
                codexStatusHooksInstallMessage(result),
                textColor: ToastyTheme.sessionReadyText,
                backgroundColor: ToastyTheme.sessionReadyBackground,
                identifier: "sheet.agent.get-started.status-hooks-installed"
            )
            codexStatusHooksDetails(status: result.status)

        case .unavailable(let message):
            inlineMessage(
                message,
                textColor: ToastyTheme.sessionErrorText,
                backgroundColor: ToastyTheme.sessionErrorBackground,
                identifier: "sheet.agent.get-started.status-hooks-unavailable"
            )

        case .installFailed(let status, let message):
            codexStatusHooksDetails(status: status)
            inlineMessage(
                message,
                textColor: ToastyTheme.sessionErrorText,
                backgroundColor: ToastyTheme.sessionErrorBackground,
                identifier: "sheet.agent.get-started.error.status-hooks-install"
            )
            Button(status.state == .needsUpdate ? "Update Codex Hooks" : "Install Codex Hooks") {
                installAgentStatusHooks(status: status)
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("sheet.agent.get-started.install-status-hooks")
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

    private func codexStatusHooksDetails(
        status: CodexStatusHookInstallStatus
    ) -> some View {
        shellIntegrationDetails(
            leadingText: "Codex hooks file",
            leadingValue: status.hooksFileURL.path,
            trailingText: "Toastty forwarder",
            trailingValue: status.forwarderScriptURL.path
        )
    }

    private func codexStatusHooksInstallMessage(
        _ result: CodexStatusHookInstallResult
    ) -> String {
        if result.hooksFileChanged || result.forwarderScriptChanged {
            return "Codex status hooks are installed."
        }
        return "Codex status hooks were already current."
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

    private func manualFallbackRow(
        systemImage: String,
        title: String,
        body: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ToastyTheme.primaryText)
                    .frame(width: 22, alignment: .center)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(ToastyTheme.primaryText)
                    Text(body)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(ToastyTheme.inactiveText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ToastyTheme.elevatedBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(ToastyTheme.subtleBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
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

    private func loadInitialStepIfNeeded() {
        switch step {
        case .shellIntegration:
            loadShellIntegrationStatus()
        case .agentStatusHooks:
            loadAgentStatusHooksStatus()
        case .chooser, .keyboardShortcuts:
            break
        }
    }

    private func showShellIntegrationStep() {
        onboardingPromptCopied = false
        openAgentProfilesErrorMessage = nil
        openKeyboardShortcutsReferenceErrorMessage = nil
        step = .shellIntegration
        loadShellIntegrationStatus()
    }

    private func showAgentStatusHooksStep() {
        onboardingPromptCopied = false
        openAgentProfilesErrorMessage = nil
        openKeyboardShortcutsReferenceErrorMessage = nil
        step = .agentStatusHooks
        loadAgentStatusHooksStatus()
    }

    private func showKeyboardShortcutsStep() {
        onboardingPromptCopied = false
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

    private func copyOnboardingPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(AgentGetStartedSheetBehavior.onboardingPrompt, forType: .string)
        onboardingPromptCopied = true
    }

    private func completeAndDismiss() {
        markGettingStartedSeen()
        dismiss()
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

    private func loadAgentStatusHooksStatus() {
        agentStatusHooksTask?.cancel()
        agentStatusHooksTask = Task(priority: .userInitiated) {
            await MainActor.run {
                agentStatusHooksState = .loading
            }
            let result: Result<CodexStatusHookInstallStatus, AgentGetStartedActionError>
            do {
                let status = try CodexStatusHookInstaller().installationStatus()
                result = .success(status)
            } catch {
                result = .failure(AgentGetStartedActionError(message: error.localizedDescription))
            }

            guard Task.isCancelled == false else { return }

            await MainActor.run {
                switch result {
                case .success(let status):
                    agentStatusHooksState = AgentStatusHooksStepResolver.loadedState(from: status)
                case .failure(let error):
                    agentStatusHooksState = .unavailable(error.localizedDescription)
                }
            }
        }
    }

    private func installAgentStatusHooks(
        status: CodexStatusHookInstallStatus
    ) {
        agentStatusHooksTask?.cancel()
        agentStatusHooksTask = Task(priority: .userInitiated) {
            await MainActor.run {
                agentStatusHooksState = .installing(status)
            }
            let result: Result<CodexStatusHookInstallResult, AgentGetStartedActionError>
            do {
                let installResult = try CodexStatusHookInstaller().install()
                result = .success(installResult)
            } catch {
                result = .failure(AgentGetStartedActionError(message: error.localizedDescription))
            }

            guard Task.isCancelled == false else { return }

            await MainActor.run {
                switch result {
                case .success(let installResult):
                    agentStatusHooksState = .installSucceeded(installResult)
                case .failure(let error):
                    agentStatusHooksState = AgentStatusHooksStepResolver.installFailureState(
                        for: status,
                        message: error.localizedDescription
                    )
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
