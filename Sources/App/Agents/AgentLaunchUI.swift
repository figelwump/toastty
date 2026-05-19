import AppKit
import CoreState
import Foundation

enum CodexStatusHookLaunchPreflightState: Equatable {
    case ready
    case needsSetup(CodexStatusHookInstallStatus)
    case unavailable(String)
}

enum CodexStatusHookLaunchPreflightResolver {
    static func state(
        profileID: String,
        launchReason: TerminalLaunchReason = .create,
        installationStatus: CodexStatusHookInstallStatus
    ) -> CodexStatusHookLaunchPreflightState {
        guard profileID == AgentKind.codex.rawValue else {
            return .ready
        }
        // Restored panes already have persisted native resume metadata. Hook setup
        // should not interrupt workspace recovery.
        guard launchReason != .restore else {
            return .ready
        }
        return installationStatus.requiresLaunchPreflightWarning ? .needsSetup(installationStatus) : .ready
    }
}

typealias CodexStatusHooksPreflightProvider = @MainActor (String) -> CodexStatusHookLaunchPreflightState
typealias CodexStatusHooksWarningPresenter = @MainActor (CodexStatusHookLaunchPreflightState, Bool) -> CodexStatusHookWarningChoice
typealias CodexStatusHooksAsyncWarningPresenter = @MainActor (
    CodexStatusHookLaunchPreflightState,
    UUID?,
    @escaping @MainActor (CodexStatusHookWarningChoice) -> Void
) -> Void
typealias AgentStatusHooksSetupPresenter = @MainActor (UUID?) -> Void

@MainActor
enum AgentLaunchUI {
    @discardableResult
    static func launch(
        profileID: String,
        workspaceID: UUID?,
        originWindowID: UUID? = nil,
        agentLaunchService: AgentLaunchService,
        codexStatusHooksPreflightProvider: CodexStatusHooksPreflightProvider = AgentLaunchUI.codexStatusHooksPreflightState,
        codexStatusHooksWarningPresenter: CodexStatusHooksWarningPresenter = AgentLaunchUI.presentCodexStatusHooksWarning,
        agentStatusHooksSetupPresenter: AgentStatusHooksSetupPresenter = AgentLaunchUI.presentAgentStatusHooksSetup
    ) -> Bool {
        let preflightState = codexStatusHooksPreflightProvider(profileID)
        switch preflightState {
        case .ready:
            break
        case .needsSetup, .unavailable:
            switch codexStatusHooksWarningPresenter(
                preflightState,
                originWindowID != nil
            ) {
            case .setUpHooks:
                agentStatusHooksSetupPresenter(originWindowID)
                return false
            case .runAnyway:
                break
            case .cancel:
                return false
            }
        }

        do {
            _ = try agentLaunchService.launch(
                profileID: profileID,
                workspaceID: workspaceID
            )
            return true
        } catch {
            presentLaunchError(error)
            return false
        }
    }

    private static func presentLaunchError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Unable to Run Agent"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func codexStatusHooksPreflightState(
        profileID: String
    ) -> CodexStatusHookLaunchPreflightState {
        guard profileID == AgentKind.codex.rawValue else {
            return .ready
        }

        do {
            return CodexStatusHookLaunchPreflightResolver.state(
                profileID: profileID,
                installationStatus: try CodexStatusHookInstaller().installationStatus()
            )
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func presentCodexStatusHooksWarning(
        _ state: CodexStatusHookLaunchPreflightState,
        canOpenSetup: Bool
    ) -> CodexStatusHookWarningChoice {
        let alert = codexStatusHooksWarningAlert(for: state)

        if canOpenSetup {
            alert.addButton(withTitle: "Set Up Hooks")
            alert.addButton(withTitle: "Run Anyway")
            alert.addButton(withTitle: "Cancel")
            return codexStatusHooksWarningChoice(response: alert.runModal(), canOpenSetup: true)
        }

        alert.addButton(withTitle: "Run Anyway")
        alert.addButton(withTitle: "Cancel")
        return codexStatusHooksWarningChoice(response: alert.runModal(), canOpenSetup: false)
    }

    static func presentCodexStatusHooksWarningAsync(
        _ state: CodexStatusHookLaunchPreflightState,
        windowID: UUID?,
        completion: @escaping @MainActor (CodexStatusHookWarningChoice) -> Void
    ) {
        guard let windowID,
              let window = window(for: windowID) else {
            completion(.cancel)
            return
        }

        let alert = codexStatusHooksWarningAlert(for: state)
        alert.addButton(withTitle: "Set Up Hooks")
        alert.addButton(withTitle: "Run Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            Task { @MainActor in
                let choice = codexStatusHooksWarningChoice(response: response, canOpenSetup: true)
                if choice == .setUpHooks {
                    presentAgentStatusHooksSetup(windowID: windowID)
                }
                completion(choice)
            }
        }
    }

    static func codexStatusHooksWarningTitle(
        for state: CodexStatusHookLaunchPreflightState
    ) -> String {
        switch state {
        case .ready:
            return "Codex Status Hooks Are Ready"
        case .needsSetup:
            return "Set Up Codex Status Hooks?"
        case .unavailable:
            return "Codex Status Hooks Could Not Be Verified"
        }
    }

    static func codexStatusHooksWarningDetail(
        for state: CodexStatusHookLaunchPreflightState
    ) -> String {
        switch state {
        case .ready:
            return ""
        case .needsSetup(let status):
            let stateDescription = status.state == .notInstalled ? "missing" : "out of date"
            return """
            Toastty can run Codex now, but progress, approvals, and turn completion may be incomplete because Codex status hooks are \(stateDescription).

            Set them up once to use Toastty's stable hook forwarder instead of the degraded log watcher fallback.
            """
        case .unavailable(let message):
            return """
            Toastty can run Codex now, but progress, approvals, and turn completion may be incomplete because Codex status hooks could not be checked.

            \(message)
            """
        }
    }

    private static func presentAgentStatusHooksSetup(windowID: UUID?) {
        guard let windowID else { return }
        NotificationCenter.default.post(
            name: .toasttyShowAgentGetStartedFlow,
            object: AgentGetStartedPresentationRequest(windowID: windowID, initialStep: .agentStatusHooks)
        )
    }

    private static func codexStatusHooksWarningAlert(
        for state: CodexStatusHookLaunchPreflightState
    ) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = codexStatusHooksWarningTitle(for: state)
        alert.informativeText = codexStatusHooksWarningDetail(for: state)
        return alert
    }

    private static func codexStatusHooksWarningChoice(
        response: NSApplication.ModalResponse,
        canOpenSetup: Bool
    ) -> CodexStatusHookWarningChoice {
        if canOpenSetup {
            switch response {
            case .alertFirstButtonReturn:
                return .setUpHooks
            case .alertSecondButtonReturn:
                return .runAnyway
            default:
                return .cancel
            }
        }

        switch response {
        case .alertFirstButtonReturn:
            return .runAnyway
        default:
            return .cancel
        }
    }

    private static func window(for windowID: UUID) -> NSWindow? {
        let identifier = NSUserInterfaceItemIdentifier(windowID.uuidString)
        return NSApplication.shared.windows.first { $0.identifier == identifier }
    }
}

enum CodexStatusHookWarningChoice: Equatable {
    case setUpHooks
    case runAnyway
    case cancel
}
