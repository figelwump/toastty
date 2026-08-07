import CoreState
import Darwin
import Foundation

struct SetupInstallerExecution {
    var output: String
    var exitCode: Int32
}
struct SetupInstallerResult: Codable, Equatable {
    var applied: Bool
    var outcome: SetupInstallerOutcome
    var plannedChanges: [String]
    var changedFiles: [String]
    var warnings: [String]
    var nextSteps: [String]
}

enum SetupInstallerOutcome: String, Codable, Equatable {
    case dryRun
    case applied
    case noChanges
    case failed
}

enum SetupInstallerCommandRunner {
    static func execute(
        command: SetupCommand,
        jsonOutput: Bool,
        environment: [String: String],
        fileManager: FileManager = .default
    ) throws -> SetupInstallerExecution {
        guard let contextWarning = missingPaneContextWarning(environment: environment) else {
            let result = try installerResult(
                command: command,
                environment: environment,
                fileManager: fileManager
            )
            return SetupInstallerExecution(
                output: try render(result: result.result, jsonOutput: jsonOutput),
                exitCode: result.exitCode
            )
        }

        let result = SetupInstallerResult(
            applied: false,
            outcome: .failed,
            plannedChanges: [],
            changedFiles: [],
            warnings: [contextWarning],
            nextSteps: [
                "Open a Toastty terminal pane and run the setup command from there.",
            ]
        )
        return SetupInstallerExecution(
            output: try render(result: result, jsonOutput: jsonOutput),
            exitCode: 1
        )
    }

    private static func installerResult(
        command: SetupCommand,
        environment: [String: String],
        fileManager: FileManager
    ) throws -> (result: SetupInstallerResult, exitCode: Int32) {
        switch command {
        case .installShellIntegration(let shell, let apply):
            return try shellIntegrationResult(
                shell: shell,
                apply: apply,
                environment: environment,
                fileManager: fileManager
            )

        case .installHooks(let agent, let apply):
            return try hooksResult(
                agent: agent,
                apply: apply,
                environment: environment,
                fileManager: fileManager
            )

        case .guide, .skillsList:
            throw ToasttyCLIError.runtime("not an installer command")
        }
    }

    private static func shellIntegrationResult(
        shell: ProfileShellIntegrationShell?,
        apply: Bool,
        environment: [String: String],
        fileManager: FileManager
    ) throws -> (result: SetupInstallerResult, exitCode: Int32) {
        let installer = ProfileShellIntegrationInstaller(
            homeDirectoryPath: homeDirectoryPath(environment: environment),
            fileManager: fileManager,
            environment: environment,
            shellPathProvider: shell.map { selectedShell in
                { selectedShell.probeShellPath }
            }
        )

        do {
            let plan = try installer.installationPlan()
            let status = try installer.installationStatus(plan: plan)
            if apply {
                let result = try installer.install(plan: plan)
                let changedFiles = shellIntegrationChangedFiles(result)
                return (
                    SetupInstallerResult(
                        applied: true,
                        outcome: .applied,
                        plannedChanges: shellIntegrationPlannedChanges(status),
                        changedFiles: changedFiles,
                        warnings: [],
                        nextSteps: changedFiles.isEmpty
                            ? ["Shell integration was already current."]
                            : ["Open a fresh Toastty pane to confirm titles and restore behavior."]
                    ),
                    0
                )
            }

            let plannedChanges = shellIntegrationPlannedChanges(status)
            return (
                SetupInstallerResult(
                    applied: false,
                    outcome: .dryRun,
                    plannedChanges: plannedChanges,
                    changedFiles: [],
                    warnings: [],
                    nextSteps: plannedChanges.isEmpty
                        ? ["Shell integration is already current."]
                        : ["Review the planned files, then rerun with --apply to install shell integration."]
                ),
                0
            )
        } catch ProfileShellIntegrationInstallerError.runtimeHomeUnsupported(let path) {
            return (
                SetupInstallerResult(
                    applied: false,
                    outcome: .noChanges,
                    plannedChanges: [],
                    changedFiles: [],
                    warnings: [
                        "Shell integration is disabled while Toastty is running with runtime isolation enabled at \(path).",
                    ],
                    nextSteps: [
                        "Open a normal Toastty pane outside a dev/test runtime and rerun this setup command.",
                    ]
                ),
                0
            )
        }
    }

    private static func hooksResult(
        agent: AgentKind,
        apply: Bool,
        environment: [String: String],
        fileManager: FileManager
    ) throws -> (result: SetupInstallerResult, exitCode: Int32) {
        guard agent == .codex else {
            return (
                SetupInstallerResult(
                    applied: false,
                    outcome: .noChanges,
                    plannedChanges: [],
                    changedFiles: [],
                    warnings: [
                        "\(agent.displayName) does not need global status hooks. Toastty injects status reporting into managed launches for supported non-Codex agents.",
                    ],
                    nextSteps: [
                        "Use install-hooks only for Codex, or launch \(agent.displayName) through Toastty so per-session status integration is injected.",
                    ]
                ),
                0
            )
        }

        let installer = CodexStatusHookInstaller(
            homeDirectoryPath: homeDirectoryPath(environment: environment),
            fileManager: fileManager
        )
        let status = try installer.installationStatus()
        let plannedChanges = codexHookPlannedChanges(status)
        if apply {
            let result = try installer.install()
            let changedFiles = codexHookChangedFiles(result)
            return (
                SetupInstallerResult(
                    applied: true,
                    outcome: .applied,
                    plannedChanges: plannedChanges,
                    changedFiles: changedFiles,
                    warnings: [
                        "Codex may ask you to trust the updated hooks the next time it starts.",
                    ],
                    nextSteps: changedFiles.isEmpty
                        ? ["Codex status hooks were already current."]
                        : ["Start a fresh Codex session in Toastty and approve any Codex trust prompt."]
                ),
                0
            )
        }

        return (
            SetupInstallerResult(
                applied: false,
                outcome: .dryRun,
                plannedChanges: plannedChanges,
                changedFiles: [],
                warnings: [
                    "Codex may ask you to trust the updated hooks after --apply.",
                ],
                nextSteps: plannedChanges.isEmpty
                    ? ["Codex status hooks are already current."]
                    : ["Review the planned files, then rerun with --apply to install Codex status hooks."]
            ),
            0
        )
    }

    private static func render(result: SetupInstallerResult, jsonOutput: Bool) throws -> String {
        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            guard let string = String(data: data, encoding: .utf8) else {
                throw ToasttyCLIError.runtime("failed to encode setup installer response")
            }
            return string
        }

        let summary: String
        switch result.outcome {
        case .dryRun:
            summary = "Dry run. No files were changed."
        case .applied:
            summary = "Applied setup changes."
        case .noChanges:
            summary = "No setup changes were needed."
        case .failed:
            summary = "Setup apply failed; no files were changed."
        }
        var lines: [String] = [summary]
        appendSection("Planned changes", result.plannedChanges, to: &lines)
        appendSection("Changed files", result.changedFiles, to: &lines)
        appendSection("Warnings", result.warnings, to: &lines)
        appendSection("Next steps", result.nextSteps, to: &lines)
        return lines.joined(separator: "\n")
    }

    private static func appendSection(_ title: String, _ values: [String], to lines: inout [String]) {
        guard values.isEmpty == false else { return }
        lines.append("")
        lines.append("\(title):")
        lines.append(contentsOf: values.map { "- \($0)" })
    }

    private static func missingPaneContextWarning(environment: [String: String]) -> String? {
        let hasCLIPath = nonEmpty(environment[ToasttyLaunchContextEnvironment.cliPathKey]) != nil
        let hasPanelID = nonEmpty(environment[ToasttyLaunchContextEnvironment.panelIDKey]) != nil
        guard hasCLIPath, hasPanelID else {
            return "Setup installers must be run from a Toastty terminal pane so Toastty can provide TOASTTY_CLI_PATH and TOASTTY_PANEL_ID."
        }
        return nil
    }

    private static func homeDirectoryPath(environment: [String: String]) -> String {
        nonEmpty(environment["HOME"]) ?? NSHomeDirectory()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value,
              value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return value
    }

    private static func shellIntegrationPlannedChanges(
        _ status: ProfileShellIntegrationInstallStatus
    ) -> [String] {
        var changes: [String] = []
        if status.needsManagedSnippetWrite {
            changes.append("Write managed \(status.plan.shell.displayName) snippet at \(status.plan.managedSnippetURL.path)")
        }
        if status.needsInitFileUpdate {
            let action = status.createsInitFile ? "Create" : "Update"
            changes.append("\(action) \(status.plan.initFileURL.path) to source Toastty's managed snippet")
        }
        return changes
    }

    private static func shellIntegrationChangedFiles(
        _ result: ProfileShellIntegrationInstallResult
    ) -> [String] {
        var files: [String] = []
        if result.updatedManagedSnippet {
            files.append(result.plan.managedSnippetURL.path)
        }
        if result.updatedInitFile || result.createdInitFile {
            files.append(result.plan.initFileURL.path)
        }
        return files
    }

    private static func codexHookPlannedChanges(
        _ status: CodexStatusHookInstallStatus
    ) -> [String] {
        switch status.state {
        case .installed:
            return []
        case .notInstalled:
            return [
                "Write Toastty Codex hook forwarder at \(status.forwarderScriptURL.path)",
                "Update Codex hooks file at \(status.hooksFileURL.path)",
            ]
        case .needsUpdate:
            return [
                "Refresh Toastty Codex hook forwarder at \(status.forwarderScriptURL.path)",
                "Update existing Toastty Codex hook entries in \(status.hooksFileURL.path)",
            ]
        }
    }

    private static func codexHookChangedFiles(
        _ result: CodexStatusHookInstallResult
    ) -> [String] {
        var files: [String] = []
        if result.forwarderScriptChanged {
            files.append(result.status.forwarderScriptURL.path)
        }
        if result.hooksFileChanged {
            files.append(result.status.hooksFileURL.path)
        }
        return files
    }
}

private extension ProfileShellIntegrationShell {
    var probeShellPath: String {
        switch self {
        case .zsh:
            return "/bin/zsh"
        case .bash:
            return "/bin/bash"
        case .fish:
            return "/usr/bin/fish"
        }
    }
}
