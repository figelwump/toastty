import CoreState
import CryptoKit
import Foundation

struct SetupInstallerExecution {
    var output: String
    var exitCode: Int32
}

struct SetupInstallerResult: Codable, Equatable {
    var applied: Bool
    var plannedChanges: [String]
    var changedFiles: [String]
    var warnings: [String]
    var nextSteps: [String]
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

        var lines: [String] = [result.applied ? "Applied setup changes." : "Dry run. No files were changed."]
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
    var runtime: SetupSkillRuntime
    var rootURL: URL
    var rootDisplayPath: String
    var skillDirectoryURL: URL
    var skillDisplayPath: String
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
        let targets = targets(for: runtime, skillName: name)
        var plannedChanges: [String] = []
        var changedFiles: [String] = []
        var warnings: [String] = []
        var nextSteps: [String] = []
        var refused = false
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

        if apply, refused == false {
            for plan in plans {
                changedFiles.append(contentsOf: try applySkillPlan(plan))
            }
        }

        if apply, refused {
            nextSteps.append("Resolve conflicts, move the existing skill directory aside, or reinstall after backing up local edits.")
        } else if apply, changedFiles.isEmpty, warnings.isEmpty {
            nextSteps.append("Skill \(name) was already current.")
        } else if apply {
            nextSteps.append("Start a fresh agent session so it can load updated skills.")
        } else if refused {
            nextSteps.append("Resolve conflicts before rerunning with --apply.")
        } else if plannedChanges.isEmpty {
            nextSteps.append("Skill \(name) is already current for \(runtime.rawValue).")
        } else {
            nextSteps.append("Review the planned files, then rerun with --apply to install the skill.")
        }

        return (
            SetupInstallerResult(
                applied: apply && refused == false,
                plannedChanges: plannedChanges,
                changedFiles: changedFiles,
                warnings: warnings,
                nextSteps: Array(NSOrderedSet(array: nextSteps)) as? [String] ?? nextSteps
            ),
            apply && refused ? 1 : 0
        )
    }

    private struct SkillPlan {
        var target: SkillInstallTarget
        var files: [SkillInstallFile]
        var manifest: SkillInstallManifest
        var staleRelativePaths: [String]
        var plannedChanges: [String]
        var warnings: [String]
        var nextSteps: [String]
        var hasConflict: Bool
    }

    private func planInstall(
        skillName: String,
        sourceURL: URL,
        target: SkillInstallTarget
    ) throws -> SkillPlan {
        let files = try desiredFiles(skillName: skillName, sourceURL: sourceURL, target: target)
        let desiredHash = contentHash(files)
        let manifest = SkillInstallManifest(name: skillName, version: 1, contentHash: desiredHash)
        let currentManifest = try readManifest(in: target.skillDirectoryURL)
        let currentHash = try currentContentHash(in: target.skillDirectoryURL)
        let directoryExists = fileManager.fileExists(atPath: target.skillDirectoryURL.path)
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
                staleRelativePaths: [],
                plannedChanges: [],
                warnings: warnings,
                nextSteps: nextSteps,
                hasConflict: true
            )
        }

        let desiredRelativePaths = Set(files.map(\.relativePath))
        let staleRelativePaths = existingFilePaths
            .filter { $0 != ".toastty-skill.json" }
            .filter { desiredRelativePaths.contains($0) == false }
        var plannedChanges: [String] = []
        for relativePath in staleRelativePaths {
            plannedChanges.append(
                "Remove \(target.skillDirectoryURL.appendingPathComponent(relativePath, isDirectory: false).path)"
            )
        }
        for file in files {
            let targetURL = target.skillDirectoryURL.appendingPathComponent(file.relativePath, isDirectory: false)
            let existingData = try? Data(contentsOf: targetURL)
            if existingData != file.contents {
                let action = existingData == nil ? "Write" : "Update"
                plannedChanges.append("\(action) \(targetURL.path)")
            }
        }
        if currentManifest != manifest {
            plannedChanges.append("Write \(target.skillDirectoryURL.appendingPathComponent(".toastty-skill.json").path)")
        }

        return SkillPlan(
            target: target,
            files: files,
            manifest: manifest,
            staleRelativePaths: staleRelativePaths,
            plannedChanges: plannedChanges,
            warnings: warnings,
            nextSteps: nextSteps,
            hasConflict: false
        )
    }

    private func applySkillPlan(_ plan: SkillPlan) throws -> [String] {
        var changedFiles: [String] = []
        for relativePath in plan.staleRelativePaths {
            let targetURL = plan.target.skillDirectoryURL.appendingPathComponent(relativePath, isDirectory: false)
            guard fileManager.fileExists(atPath: targetURL.path) else { continue }
            try fileManager.removeItem(at: targetURL)
            changedFiles.append(targetURL.path)
        }

        for file in plan.files {
            let targetURL = plan.target.skillDirectoryURL.appendingPathComponent(file.relativePath, isDirectory: false)
            let existingData = try? Data(contentsOf: targetURL)
            guard existingData != file.contents else { continue }
            try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.contents.write(to: targetURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: file.isExecutable ? 0o755 : 0o644],
                ofItemAtPath: targetURL.path
            )
            changedFiles.append(targetURL.path)
        }

        let manifestURL = plan.target.skillDirectoryURL.appendingPathComponent(".toastty-skill.json", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(plan.manifest)
        let existingManifestData = try? Data(contentsOf: manifestURL)
        if existingManifestData != manifestData {
            try fileManager.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manifestData.write(to: manifestURL, options: .atomic)
            changedFiles.append(manifestURL.path)
        }
        return changedFiles
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
            runtimes = [.claude, .codex]
        case .claude, .codex:
            runtimes = [runtime]
        }
        return runtimes.map { runtime in
            let rootPath: String
            let displayRootPath: String
            switch runtime {
            case .claude:
                rootPath = ".agents/skills"
                displayRootPath = "~/.agents/skills"
            case .codex:
                rootPath = ".codex/skills"
                displayRootPath = "~/.codex/skills"
            case .all:
                preconditionFailure("all is expanded before target creation")
            }
            let rootURL = homeURL.appendingPathComponent(rootPath, isDirectory: true)
            return SkillInstallTarget(
                runtime: runtime,
                rootURL: rootURL,
                rootDisplayPath: displayRootPath,
                skillDirectoryURL: rootURL.appendingPathComponent(skillName, isDirectory: true),
                skillDisplayPath: "\(displayRootPath)/\(skillName)"
            )
        }
    }

    private var homeDirectoryPath: String {
        guard let home = environment["HOME"],
              home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return NSHomeDirectory()
        }
        return home
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
