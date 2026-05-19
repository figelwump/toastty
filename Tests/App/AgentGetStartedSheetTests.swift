@testable import ToasttyApp
import XCTest

final class AgentGetStartedSheetTests: XCTestCase {
    func testLoadedStateUsesInstallableCaseWhenFilesStillNeedUpdates() {
        let status = makeStatus(
            needsManagedSnippetWrite: true,
            needsInitFileUpdate: false,
            createsInitFile: false
        )

        let state = AgentGetStartedShellIntegrationStepResolver.loadedState(from: status)

        XCTAssertEqual(state, .installable(status))
    }

    func testLoadedStateUsesAlreadyInstalledCaseWhenNoUpdatesAreNeeded() {
        let status = makeStatus(
            needsManagedSnippetWrite: false,
            needsInitFileUpdate: false,
            createsInitFile: false
        )

        let state = AgentGetStartedShellIntegrationStepResolver.loadedState(from: status)

        XCTAssertEqual(state, .alreadyInstalled(status))
    }

    func testInstallFailureStatePreservesRetryStatusAndMessage() {
        let status = makeStatus(
            needsManagedSnippetWrite: true,
            needsInitFileUpdate: true,
            createsInitFile: true
        )

        let state = AgentGetStartedShellIntegrationStepResolver.installFailureState(
            for: status,
            message: "Unable to write ~/.zshrc"
        )

        XCTAssertEqual(state, .installFailed(status, "Unable to write ~/.zshrc"))
    }

    func testAgentStatusHooksLoadedStateUsesInstallableWhenCodexHooksNeedSetup() {
        let status = CodexStatusHookInstallStatus(
            hooksFileURL: URL(filePath: "/tmp/home/.codex/hooks.json"),
            forwarderScriptURL: URL(filePath: "/tmp/home/.toastty/codex-hooks/forwarder.sh"),
            state: .needsUpdate
        )

        let state = AgentStatusHooksStepResolver.loadedState(from: status)

        XCTAssertEqual(state, .installable(status))
    }

    func testAgentStatusHooksLoadedStateUsesAlreadyInstalledWhenCodexHooksAreCurrent() {
        let status = CodexStatusHookInstallStatus(
            hooksFileURL: URL(filePath: "/tmp/home/.codex/hooks.json"),
            forwarderScriptURL: URL(filePath: "/tmp/home/.toastty/codex-hooks/forwarder.sh"),
            state: .installed
        )

        let state = AgentStatusHooksStepResolver.loadedState(from: status)

        XCTAssertEqual(state, .alreadyInstalled(status))
    }

    func testBlocksNavigationOnlyWhileInstalling() {
        let status = makeStatus(
            needsManagedSnippetWrite: true,
            needsInitFileUpdate: true,
            createsInitFile: false
        )

        XCTAssertTrue(AgentGetStartedShellIntegrationStepState.installing(status).blocksNavigation)
        XCTAssertFalse(AgentGetStartedShellIntegrationStepState.loading.blocksNavigation)
        XCTAssertFalse(AgentGetStartedShellIntegrationStepState.installable(status).blocksNavigation)
        XCTAssertFalse(AgentGetStartedShellIntegrationStepState.alreadyInstalled(status).blocksNavigation)
        XCTAssertFalse(AgentGetStartedShellIntegrationStepState.installSucceeded(makeInstallResult()).blocksNavigation)
        XCTAssertFalse(AgentGetStartedShellIntegrationStepState.unavailable("No shell available").blocksNavigation)
        XCTAssertFalse(AgentGetStartedShellIntegrationStepState.installFailed(status, "Unable to write ~/.zshrc").blocksNavigation)
    }

    func testAgentStatusHooksBlocksNavigationOnlyWhileInstalling() {
        let status = CodexStatusHookInstallStatus(
            hooksFileURL: URL(filePath: "/tmp/home/.codex/hooks.json"),
            forwarderScriptURL: URL(filePath: "/tmp/home/.toastty/codex-hooks/forwarder.sh"),
            state: .needsUpdate
        )

        XCTAssertTrue(AgentStatusHooksStepState.installing(status).blocksNavigation)
        XCTAssertFalse(AgentStatusHooksStepState.loading.blocksNavigation)
        XCTAssertFalse(AgentStatusHooksStepState.installable(status).blocksNavigation)
        XCTAssertFalse(AgentStatusHooksStepState.alreadyInstalled(status).blocksNavigation)
        XCTAssertFalse(AgentStatusHooksStepState.unavailable("No Codex home").blocksNavigation)
        XCTAssertFalse(AgentStatusHooksStepState.installFailed(status, "Unable to write hooks.json").blocksNavigation)
    }

    func testDismissIsAllowedFromChooserEvenWhenShellStateIsInstalling() {
        let status = makeStatus(
            needsManagedSnippetWrite: true,
            needsInitFileUpdate: true,
            createsInitFile: false
        )

        let dismissDisabled = AgentGetStartedSheetBehavior.dismissDisabled(
            step: .chooser,
            shellIntegrationState: .installing(status)
        )

        XCTAssertFalse(dismissDisabled)
    }

    func testDismissIsAllowedFromKeyboardShortcutsEvenWhenShellStateIsInstalling() {
        let status = makeStatus(
            needsManagedSnippetWrite: true,
            needsInitFileUpdate: true,
            createsInitFile: false
        )

        let dismissDisabled = AgentGetStartedSheetBehavior.dismissDisabled(
            step: .keyboardShortcuts,
            shellIntegrationState: .installing(status)
        )

        XCTAssertFalse(dismissDisabled)
    }

    func testDismissIsBlockedWhileShellIntegrationInstalls() {
        let status = makeStatus(
            needsManagedSnippetWrite: true,
            needsInitFileUpdate: true,
            createsInitFile: false
        )

        let dismissDisabled = AgentGetStartedSheetBehavior.dismissDisabled(
            step: .shellIntegration,
            shellIntegrationState: .installing(status)
        )

        XCTAssertTrue(dismissDisabled)
    }

    func testDismissIsBlockedWhileAgentStatusHooksInstall() {
        let status = CodexStatusHookInstallStatus(
            hooksFileURL: URL(filePath: "/tmp/home/.codex/hooks.json"),
            forwarderScriptURL: URL(filePath: "/tmp/home/.toastty/codex-hooks/forwarder.sh"),
            state: .needsUpdate
        )

        let dismissDisabled = AgentGetStartedSheetBehavior.dismissDisabled(
            step: .agentStatusHooks,
            shellIntegrationState: .loading,
            agentStatusHooksState: .installing(status)
        )

        XCTAssertTrue(dismissDisabled)
    }

    func testDismissIsAllowedWhenShellIntegrationIsNotInstalling() {
        let status = makeStatus(
            needsManagedSnippetWrite: true,
            needsInitFileUpdate: false,
            createsInitFile: false
        )

        let dismissDisabled = AgentGetStartedSheetBehavior.dismissDisabled(
            step: .shellIntegration,
            shellIntegrationState: .installable(status)
        )

        XCTAssertFalse(dismissDisabled)
    }

    func testOpenAgentProfilesSuccessProducesNoInlineError() {
        let errorMessage = AgentGetStartedSheetBehavior.actionErrorMessage(for: .success(()))

        XCTAssertNil(errorMessage)
    }

    func testOpenAgentProfilesFailureUsesLocalizedDescription() {
        let errorMessage = AgentGetStartedSheetBehavior.actionErrorMessage(
            for: .failure(AgentGetStartedActionError(message: "Unable to open ~/.toastty/agents.toml"))
        )

        XCTAssertEqual(errorMessage, "Unable to open ~/.toastty/agents.toml")
    }

    private func makeStatus(
        needsManagedSnippetWrite: Bool,
        needsInitFileUpdate: Bool,
        createsInitFile: Bool
    ) -> ProfileShellIntegrationInstallStatus {
        ProfileShellIntegrationInstallStatus(
            plan: ProfileShellIntegrationInstallPlan(
                shell: .zsh,
                initFileURL: URL(filePath: "/tmp/.zshrc"),
                managedSnippetURL: URL(filePath: "/tmp/.toastty/shell/toastty-profile-shell-integration.zsh")
            ),
            needsManagedSnippetWrite: needsManagedSnippetWrite,
            needsInitFileUpdate: needsInitFileUpdate,
            createsInitFile: createsInitFile
        )
    }

    private func makeInstallResult() -> ProfileShellIntegrationInstallResult {
        ProfileShellIntegrationInstallResult(
            plan: ProfileShellIntegrationInstallPlan(
                shell: .zsh,
                initFileURL: URL(filePath: "/tmp/.zshrc"),
                managedSnippetURL: URL(filePath: "/tmp/.toastty/shell/toastty-profile-shell-integration.zsh")
            ),
            updatedManagedSnippet: true,
            updatedInitFile: true,
            createdInitFile: false
        )
    }
}
