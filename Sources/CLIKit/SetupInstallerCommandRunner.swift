import CoreState
import CryptoKit
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
    var skillTargets: [SetupSkillTargetResult] = []
}

enum SetupInstallerOutcome: String, Codable, Equatable {
    case dryRun
    case applied
    case noChanges
    case refused
    case failed
    case partial
}

enum SetupSkillTargetAvailability: String, Codable, Equatable {
    case missing
    case available
    case invalid
}

enum SetupSkillTargetManagement: String, Codable, Equatable {
    case none
    case toastty
    case external
}

enum SetupSkillTargetAction: String, Codable, Equatable {
    case none
    case install
    case update
    case conflict
}

enum SetupSkillTargetApplyOutcome: String, Codable, Equatable {
    case notRequested
    case notNeeded
    case applied
    case blocked
    case failed
    case notAttempted
}

struct SetupSkillTargetResult: Codable, Equatable {
    var runtimes: [SetupSkillRuntime]
    var paths: [String]
    var availability: SetupSkillTargetAvailability
    var management: SetupSkillTargetManagement
    var plannedAction: SetupSkillTargetAction
    var applyOutcome: SetupSkillTargetApplyOutcome
    var detail: String
}

enum SetupInstallerCommandRunner {
    static func execute(
        command: SetupCommand,
        jsonOutput: Bool,
        environment: [String: String],
        store: SetupResourceStore,
        fileManager: FileManager = .default
    ) throws -> SetupInstallerExecution {
        guard let contextWarning = missingPaneContextWarning(environment: environment) else {
            let result = try installerResult(
                command: command,
                environment: environment,
                store: store,
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
        store: SetupResourceStore,
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

        case .installSkill(let name, let runtime, let apply):
            return try SkillInstaller(
                store: store,
                environment: environment,
                fileManager: fileManager
            )
            .result(name: name, runtime: runtime, apply: apply)

        case .guide, .skillsList, .printSkill:
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
        case .refused:
            summary = "Setup apply was refused; no files were changed."
        case .failed:
            summary = "Setup apply failed; no files were changed."
        case .partial:
            summary = "Setup apply did not complete; some files were changed."
        }
        var lines: [String] = [summary]
        appendSection("Planned changes", result.plannedChanges, to: &lines)
        appendSection("Changed files", result.changedFiles, to: &lines)
        appendSection("Warnings", result.warnings, to: &lines)
        appendSection("Skill targets", result.skillTargets.map(renderSkillTarget), to: &lines)
        appendSection("Next steps", result.nextSteps, to: &lines)
        return lines.joined(separator: "\n")
    }

    private static func renderSkillTarget(_ target: SetupSkillTargetResult) -> String {
        let runtimes = target.runtimes.map(\.rawValue).joined(separator: ",")
        let paths = target.paths.joined(separator: ", ")
        return "\(runtimes): \(paths) [availability=\(target.availability.rawValue), management=\(target.management.rawValue), action=\(target.plannedAction.rawValue), apply=\(target.applyOutcome.rawValue)] \(target.detail)"
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

private struct SkillInstallManifest: Codable, Equatable {
    var name: String
    var version: Int
    var contentHash: String
}

private struct SkillInstallFile: Equatable {
    var relativePath: String
    var contents: Data
    var isExecutable: Bool
}

private struct SkillInstallTarget {
    var runtimes: [SetupSkillRuntime]
    var requestedDisplayPaths: [String]
    var rootDisplayPath: String
    var skillDirectoryURL: URL
}

private struct SkillInstaller {
    let store: SetupResourceStore
    let environment: [String: String]
    let fileManager: FileManager

    func result(
        name: String,
        runtime: SetupSkillRuntime,
        apply: Bool
    ) throws -> (result: SetupInstallerResult, exitCode: Int32) {
        guard StarterSkill(rawValue: name) != nil else {
            throw ToasttyCLIError.usage("unknown starter skill: \(name)")
        }

        let sourceURL = store.setupDirectoryURL
            .appendingPathComponent("starter-skills", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try validateSourceSkill(name: name, sourceURL: sourceURL)
        let targets = targets(for: runtime, skillName: name)
        var plannedChanges: [String] = []
        var changedFiles: [String] = []
        var warnings: [String] = []
        var nextSteps: [String] = []
        var refused = false
        var applyFailed = false
        var plans: [SkillPlan] = []

        for target in targets {
            let plan = try planInstall(
                skillName: name,
                sourceURL: sourceURL,
                target: target
            )
            plans.append(plan)
            plannedChanges.append(contentsOf: plan.plannedChanges)
            warnings.append(contentsOf: plan.warnings)
            nextSteps.append(contentsOf: plan.nextSteps)

            if plan.hasConflict {
                refused = true
            }
        }

        if apply, refused {
            for index in plans.indices {
                plans[index].targetResult.applyOutcome = plans[index].hasConflict
                    ? .blocked
                    : .notAttempted
            }
        } else if apply {
            for index in plans.indices {
                do {
                    try applySkillPlan(plans[index], changedFiles: &changedFiles)
                    switch plans[index].targetResult.plannedAction {
                    case .none:
                        plans[index].targetResult.applyOutcome = .notNeeded
                    case .install:
                        plans[index].targetResult.availability = .available
                        plans[index].targetResult.management = .toastty
                        plans[index].targetResult.applyOutcome = .applied
                        plans[index].targetResult.detail = "Installed the bundled skill into this runtime target."
                    case .update:
                        plans[index].targetResult.availability = .available
                        plans[index].targetResult.management = .toastty
                        plans[index].targetResult.applyOutcome = .applied
                        plans[index].targetResult.detail = "Updated the Toastty-managed skill."
                    case .conflict:
                        preconditionFailure("Conflicting plans are blocked before apply")
                    }
                } catch {
                    applyFailed = true
                    plans[index].targetResult.applyOutcome = .failed
                    plans[index].targetResult.detail = "Apply failed: \(error.localizedDescription)"
                    if index < plans.index(before: plans.endIndex) {
                        for remainingIndex in plans.index(after: index)..<plans.endIndex {
                            plans[remainingIndex].targetResult.applyOutcome = .notAttempted
                        }
                    }
                    warnings.append(
                        "Failed to apply \(name) at \(plans[index].target.skillDirectoryURL.path): \(error.localizedDescription)"
                    )
                    nextSteps.append(
                        changedFiles.isEmpty
                            ? "No skill files were changed. Resolve the failure and retry."
                            : "Some skill files changed before the failure. Review changedFiles, then retry."
                    )
                    break
                }
            }
        }

        let hasExternalTargets = plans.contains(where: { $0.isExternallyManaged })
        if applyFailed {
            nextSteps.append("The installer stopped before applying any remaining runtime targets.")
        } else if apply, refused {
            nextSteps.append("Resolve conflicts, move the existing skill directory aside, or reinstall after backing up local edits.")
        } else if apply, changedFiles.isEmpty {
            nextSteps.append(
                hasExternalTargets
                    ? "No files changed. Externally managed skills were left untouched; review the skill target status."
                    : "Skill \(name) was already current."
            )
        } else if apply {
            nextSteps.append("Start a fresh agent session so it can load updated skills.")
        } else if refused {
            nextSteps.append("Resolve conflicts before rerunning with --apply.")
        } else if plannedChanges.isEmpty {
            nextSteps.append(
                hasExternalTargets
                    ? "No Toastty-managed changes are planned. Review the externally managed skill target status."
                    : "Skill \(name) is already current for \(runtime.rawValue)."
            )
        } else {
            nextSteps.append("Review the planned files, then rerun with --apply to install the skill.")
        }

        let failed = refused || applyFailed
        let outcome: SetupInstallerOutcome
        if apply == false {
            outcome = .dryRun
        } else if refused {
            outcome = .refused
        } else if applyFailed {
            outcome = changedFiles.isEmpty ? .failed : .partial
        } else if changedFiles.isEmpty {
            outcome = .noChanges
        } else {
            outcome = .applied
        }
        return (
            SetupInstallerResult(
                applied: apply && failed == false,
                outcome: outcome,
                plannedChanges: plannedChanges,
                changedFiles: changedFiles,
                warnings: warnings,
                nextSteps: Array(NSOrderedSet(array: nextSteps)) as? [String] ?? nextSteps,
                skillTargets: plans.map(\.targetResult)
            ),
            apply && failed ? 1 : 0
        )
    }

    private struct SkillPlan {
        var target: SkillInstallTarget
        var files: [SkillInstallFile]
        var manifest: SkillInstallManifest
        var plannedChanges: [String]
        var changedFilePaths: [String]
        var warnings: [String]
        var nextSteps: [String]
        var hasConflict: Bool
        var isExternallyManaged: Bool
        var targetResult: SetupSkillTargetResult
    }

    private func planInstall(
        skillName: String,
        sourceURL: URL,
        target: SkillInstallTarget
    ) throws -> SkillPlan {
        let files = try desiredFiles(skillName: skillName, sourceURL: sourceURL, target: target)
        let desiredHash = contentHash(files)
        let manifest = SkillInstallManifest(name: skillName, version: 1, contentHash: desiredHash)

        if isSymbolicLink(at: target.skillDirectoryURL) {
            let resolvedURL = target.skillDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
            let resolvedSkillMarkdownURL = resolvedURL.appendingPathComponent("SKILL.md", isDirectory: false)
            let validExternalSkill = isRegularFile(at: resolvedSkillMarkdownURL)
            let detail = validExternalSkill
                ? "Discoverable through an existing symlink and externally managed; Toastty will not modify it."
                : "The existing skill symlink is broken or does not resolve to a regular SKILL.md."
            let warning = validExternalSkill
                ? "Leaving externally managed \(skillName) symlink at \(target.skillDirectoryURL.path) untouched."
                : "Cannot install \(skillName): \(target.skillDirectoryURL.path) is a broken or invalid skill symlink."
            let nextStep = validExternalSkill
                ? []
                : ["Repair or move \(target.skillDirectoryURL.path), then rerun the setup command."]
            return SkillPlan(
                target: target,
                files: files,
                manifest: manifest,
                plannedChanges: [],
                changedFilePaths: [],
                warnings: [warning],
                nextSteps: nextStep,
                hasConflict: validExternalSkill == false,
                isExternallyManaged: true,
                targetResult: SetupSkillTargetResult(
                    runtimes: target.runtimes,
                    paths: target.requestedDisplayPaths,
                    availability: validExternalSkill ? .available : .invalid,
                    management: .external,
                    plannedAction: validExternalSkill ? .none : .conflict,
                    applyOutcome: .notRequested,
                    detail: detail
                )
            )
        }

        let directoryExists = fileManager.fileExists(atPath: target.skillDirectoryURL.path)
        if directoryExists, try containsSymbolicLink(in: target.skillDirectoryURL) {
            let manifestURL = target.skillDirectoryURL.appendingPathComponent(
                ".toastty-skill.json",
                isDirectory: false
            )
            let hasManifest = fileManager.fileExists(atPath: manifestURL.path)
            let warning = "Refusing to update \(skillName) at \(target.skillDirectoryURL.path) because its install tree contains a symlink."
            return SkillPlan(
                target: target,
                files: files,
                manifest: manifest,
                plannedChanges: [],
                changedFilePaths: [],
                warnings: [warning],
                nextSteps: [
                    "Replace symlinked entries under \(target.skillDirectoryURL.path) with owned files or move the install aside, then retry.",
                ],
                hasConflict: true,
                isExternallyManaged: hasManifest == false,
                targetResult: SetupSkillTargetResult(
                    runtimes: target.runtimes,
                    paths: target.requestedDisplayPaths,
                    availability: .invalid,
                    management: hasManifest ? .toastty : .external,
                    plannedAction: .conflict,
                    applyOutcome: .notRequested,
                    detail: "Install tree contains a symlink; no files will be changed."
                )
            )
        }

        let currentManifest = try readManifest(in: target.skillDirectoryURL)
        let currentHash = try currentContentHash(in: target.skillDirectoryURL)
        let existingFilePaths = directoryExists
            ? try existingRelativeFilePaths(in: target.skillDirectoryURL)
            : []
        let hasExistingFiles = directoryExists
            ? existingFilePaths.isEmpty == false
            : false
        var warnings: [String] = []
        var nextSteps: [String] = []
        var hasConflict = false

        if hasExistingFiles {
            if let currentManifest {
                if currentManifest.name != skillName {
                    hasConflict = true
                } else if currentManifest.contentHash != currentHash,
                          currentHash != desiredHash {
                    hasConflict = true
                }
            } else {
                hasConflict = true
            }
        }

        if hasConflict {
            warnings.append("Refusing to overwrite modified or unmanaged \(skillName) install at \(target.skillDirectoryURL.path).")
            nextSteps.append("Back up or move \(target.skillDirectoryURL.path), then rerun the setup command.")
            return SkillPlan(
                target: target,
                files: files,
                manifest: manifest,
                plannedChanges: [],
                changedFilePaths: [],
                warnings: warnings,
                nextSteps: nextSteps,
                hasConflict: true,
                isExternallyManaged: currentManifest == nil,
                targetResult: SetupSkillTargetResult(
                    runtimes: target.runtimes,
                    paths: target.requestedDisplayPaths,
                    availability: .available,
                    management: currentManifest == nil ? .external : .toastty,
                    plannedAction: .conflict,
                    applyOutcome: .notRequested,
                    detail: "Existing install is modified, unmanaged, or has mismatched metadata."
                )
            )
        }

        let desiredRelativePaths = Set(files.map(\.relativePath))
        let staleRelativePaths = existingFilePaths
            .filter { $0 != ".toastty-skill.json" }
            .filter { desiredRelativePaths.contains($0) == false }
        var plannedChanges: [String] = []
        var changedFilePaths: [String] = []
        for relativePath in staleRelativePaths {
            let targetURL = target.skillDirectoryURL.appendingPathComponent(relativePath, isDirectory: false)
            plannedChanges.append(
                "Remove \(targetURL.path)"
            )
            changedFilePaths.append(targetURL.path)
        }
        for file in files {
            let targetURL = target.skillDirectoryURL.appendingPathComponent(file.relativePath, isDirectory: false)
            let existingData = try? Data(contentsOf: targetURL)
            if existingData != file.contents {
                let action = existingData == nil ? "Write" : "Update"
                plannedChanges.append("\(action) \(targetURL.path)")
                changedFilePaths.append(targetURL.path)
            }
        }
        if currentManifest != manifest {
            let manifestURL = target.skillDirectoryURL.appendingPathComponent(".toastty-skill.json")
            plannedChanges.append("Write \(manifestURL.path)")
            changedFilePaths.append(manifestURL.path)
        }

        let action: SetupSkillTargetAction
        if plannedChanges.isEmpty {
            action = .none
        } else if hasExistingFiles {
            action = .update
        } else {
            action = .install
        }
        let availability: SetupSkillTargetAvailability = hasExistingFiles ? .available : .missing
        let management: SetupSkillTargetManagement = currentManifest == nil ? .none : .toastty
        let detail: String
        switch action {
        case .none:
            detail = "Toastty-managed install is current."
        case .install:
            detail = "Install the bundled skill into this runtime target."
        case .update:
            detail = "Update the existing Toastty-managed skill."
        case .conflict:
            preconditionFailure("Conflicts return before building a managed plan")
        }

        return SkillPlan(
            target: target,
            files: files,
            manifest: manifest,
            plannedChanges: plannedChanges,
            changedFilePaths: changedFilePaths,
            warnings: warnings,
            nextSteps: nextSteps,
            hasConflict: false,
            isExternallyManaged: false,
            targetResult: SetupSkillTargetResult(
                runtimes: target.runtimes,
                paths: target.requestedDisplayPaths,
                availability: availability,
                management: management,
                plannedAction: action,
                applyOutcome: .notRequested,
                detail: detail
            )
        )
    }

    private func applySkillPlan(
        _ plan: SkillPlan,
        changedFiles: inout [String]
    ) throws {
        if plan.isExternallyManaged {
            let resolvedSkillMarkdownURL = plan.target.skillDirectoryURL
                .resolvingSymlinksInPath()
                .appendingPathComponent("SKILL.md", isDirectory: false)
            guard isSymbolicLink(at: plan.target.skillDirectoryURL),
                  isRegularFile(at: resolvedSkillMarkdownURL) else {
                throw ToasttyCLIError.runtime("externally managed skill target changed before apply")
            }
            return
        }
        try validateManagedTargetBeforeApply(plan.target.skillDirectoryURL)
        guard plan.changedFilePaths.isEmpty == false else { return }

        let parentURL = plan.target.skillDirectoryURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let stagingURL = parentURL.appendingPathComponent(
            ".\(plan.manifest.name).toastty-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagingURL) }
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        for file in plan.files {
            let stagedFileURL = stagingURL.appendingPathComponent(file.relativePath, isDirectory: false)
            try fileManager.createDirectory(
                at: stagedFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.contents.write(to: stagedFileURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: file.isExecutable ? 0o755 : 0o644],
                ofItemAtPath: stagedFileURL.path
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(plan.manifest)
        try manifestData.write(
            to: stagingURL.appendingPathComponent(".toastty-skill.json", isDirectory: false),
            options: .atomic
        )

        try validateManagedTargetBeforeApply(plan.target.skillDirectoryURL)
        if fileType(at: plan.target.skillDirectoryURL) == nil {
            guard renameItem(at: stagingURL, to: plan.target.skillDirectoryURL, swapping: false) else {
                throw lastPOSIXError(operation: "install staged skill")
            }
        } else {
            guard renameItem(at: stagingURL, to: plan.target.skillDirectoryURL, swapping: true) else {
                throw lastPOSIXError(operation: "replace managed skill atomically")
            }
        }
        changedFiles.append(contentsOf: plan.changedFilePaths)
    }

    private func validateManagedTargetBeforeApply(_ targetURL: URL) throws {
        guard isSymbolicLink(at: targetURL) == false else {
            throw ToasttyCLIError.runtime("skill target became a symlink before apply")
        }
        guard let targetType = fileType(at: targetURL) else { return }
        guard targetType == S_IFDIR else {
            throw ToasttyCLIError.runtime("skill target is not a directory")
        }
        guard try containsSymbolicLink(in: targetURL) == false else {
            throw ToasttyCLIError.runtime("skill target contains a symlink before apply")
        }
    }

    private func renameItem(at sourceURL: URL, to destinationURL: URL, swapping: Bool) -> Bool {
        sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                if swapping {
                    return renameatx_np(
                        AT_FDCWD,
                        sourcePath,
                        AT_FDCWD,
                        destinationPath,
                        UInt32(RENAME_SWAP)
                    ) == 0
                }
                return Darwin.rename(sourcePath, destinationPath) == 0
            }
        }
    }

    private func lastPOSIXError(operation: String) -> ToasttyCLIError {
        let message = String(cString: strerror(errno))
        return ToasttyCLIError.runtime("\(operation) failed: \(message)")
    }

    private func desiredFiles(
        skillName: String,
        sourceURL: URL,
        target: SkillInstallTarget
    ) throws -> [SkillInstallFile] {
        let sourceFiles = try existingRelativeFilePaths(in: sourceURL)
            .filter { $0 != ".toastty-skill.json" }
        return try sourceFiles.map { relativePath in
            let sourceFileURL = sourceURL.appendingPathComponent(relativePath, isDirectory: false)
            var contents = try Data(contentsOf: sourceFileURL)
            if let string = String(data: contents, encoding: .utf8) {
                contents = Data(tailorSkillText(string, skillName: skillName, target: target).utf8)
            }
            let values = try sourceFileURL.resourceValues(forKeys: [.isExecutableKey])
            return SkillInstallFile(
                relativePath: relativePath,
                contents: contents,
                isExecutable: values.isExecutable == true
            )
        }
    }

    private func tailorSkillText(
        _ text: String,
        skillName: String,
        target: SkillInstallTarget
    ) -> String {
        let scriptDirectoryPlaceholder = "__TOASTTY_SKILL_SCRIPT_DIRECTORY__/"
        return text
            .replacingOccurrences(
                of: "~/.agents/skills/\(skillName)/scripts/",
                with: scriptDirectoryPlaceholder
            )
            .replacingOccurrences(
                of: scriptDirectoryPlaceholder,
                with: "\(target.rootDisplayPath)/\(skillName)/scripts/"
            )
    }

    private func targets(for runtime: SetupSkillRuntime, skillName: String) -> [SkillInstallTarget] {
        let homeURL = URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
        let runtimes: [SetupSkillRuntime]
        switch runtime {
        case .all:
            runtimes = [.agents, .claude]
        case .agents, .claude, .codex:
            runtimes = [runtime]
        }

        var targets: [SkillInstallTarget] = []
        for runtime in runtimes {
            let rootPath: String
            let displayRootPath: String
            switch runtime {
            case .agents:
                rootPath = ".agents/skills"
                displayRootPath = "~/.agents/skills"
            case .claude:
                rootPath = ".claude/skills"
                displayRootPath = "~/.claude/skills"
            case .codex:
                rootPath = ".codex/skills"
                displayRootPath = "~/.codex/skills"
            case .all:
                preconditionFailure("all is expanded before target creation")
            }
            let rootURL = homeURL.appendingPathComponent(rootPath, isDirectory: true)
            let skillDirectoryURL = rootURL.appendingPathComponent(skillName, isDirectory: true)
            let skillDisplayPath = "\(displayRootPath)/\(skillName)"
            let resolvedIdentity = resolvedPathIdentity(for: skillDirectoryURL)
            if let existingIndex = targets.firstIndex(where: {
                resolvedPathIdentity(for: $0.skillDirectoryURL) == resolvedIdentity
            }) {
                targets[existingIndex].runtimes.append(runtime)
                targets[existingIndex].requestedDisplayPaths.append(skillDisplayPath)
                continue
            }
            targets.append(SkillInstallTarget(
                runtimes: [runtime],
                requestedDisplayPaths: [skillDisplayPath],
                rootDisplayPath: displayRootPath,
                skillDirectoryURL: skillDirectoryURL
            ))
        }
        return targets
    }

    private func resolvedPathIdentity(for url: URL) -> String {
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []

        while fileType(at: existingAncestor) == nil {
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else { break }
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor = parent
        }

        return missingComponents.reduce(
            existingAncestor.resolvingSymlinksInPath().standardizedFileURL
        ) { resolvedURL, component in
            resolvedURL.appendingPathComponent(component)
        }.standardizedFileURL.path
    }

    private var homeDirectoryPath: String {
        guard let home = environment["HOME"],
              home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return NSHomeDirectory()
        }
        return home
    }

    private func validateSourceSkill(name: String, sourceURL: URL) throws {
        let skillMarkdownURL = sourceURL.appendingPathComponent("SKILL.md", isDirectory: false)
        guard isSymbolicLink(at: sourceURL) == false,
              isRegularFile(at: skillMarkdownURL),
              try containsSymbolicLink(in: sourceURL) == false else {
            throw ToasttyCLIError.runtime(
                "bundled starter skill \(name) is missing, invalid, or contains a symlink"
            )
        }
    }

    private func containsSymbolicLink(in directoryURL: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return false }
        if isSymbolicLink(at: directoryURL) {
            return true
        }
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return false
        }
        while let fileURL = enumerator.nextObject() as? URL {
            if isSymbolicLink(at: fileURL) {
                return true
            }
        }
        return false
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        fileType(at: url) == S_IFLNK
    }

    private func isRegularFile(at url: URL) -> Bool {
        fileType(at: url) == S_IFREG
    }

    private func fileType(at url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    private func readManifest(in skillDirectoryURL: URL) throws -> SkillInstallManifest? {
        let manifestURL = skillDirectoryURL.appendingPathComponent(".toastty-skill.json", isDirectory: false)
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
        return try JSONDecoder().decode(SkillInstallManifest.self, from: Data(contentsOf: manifestURL))
    }

    private func currentContentHash(in skillDirectoryURL: URL) throws -> String? {
        guard fileManager.fileExists(atPath: skillDirectoryURL.path) else { return nil }
        let files = try existingRelativeFilePaths(in: skillDirectoryURL)
            .filter { $0 != ".toastty-skill.json" }
            .map { relativePath in
                let fileURL = skillDirectoryURL.appendingPathComponent(relativePath, isDirectory: false)
                let values = try fileURL.resourceValues(forKeys: [.isExecutableKey])
                return SkillInstallFile(
                    relativePath: relativePath,
                    contents: try Data(contentsOf: fileURL),
                    isExecutable: values.isExecutable == true
                )
            }
        return contentHash(files)
    }

    private func existingRelativeFilePaths(in directoryURL: URL) throws -> [String] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let rootPath = directoryURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return []
        }
        var paths: [String] = []
        while let fileURL = enumerator.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let filePath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard filePath.hasPrefix(rootPath + "/") else {
                continue
            }
            let relativePath = String(filePath.dropFirst(rootPath.count + 1))
            paths.append(relativePath)
        }
        return paths.sorted()
    }

    private func contentHash(_ files: [SkillInstallFile]) -> String {
        var hasher = SHA256()
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            hasher.update(data: Data(file.relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: file.contents)
            hasher.update(data: Data([file.isExecutable ? 1 : 0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
