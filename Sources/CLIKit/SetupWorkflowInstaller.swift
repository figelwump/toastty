import CoreState
import Foundation

/// Copies a bundled workflow's example skill packages into the user skills
/// directory. Installs are all-or-nothing per workflow and never overwrite an
/// existing package: a package that already matches the bundled copy is left
/// alone, and one that differs (often a personal customization) blocks the
/// install until the user moves it aside.
struct SetupWorkflowInstaller {
    let workflow: ToasttyWorkflowDescriptor
    let packagesDirectoryURL: URL
    let userSkillsDirectoryURL: URL
    let fileManager: FileManager

    func result(apply: Bool) throws -> (result: SetupInstallerResult, exitCode: Int32) {
        let plans = try workflow.packageNames.map(plan(packageName:))
        let conflicts = plans.compactMap { plan -> String? in
            guard case .conflict(let reason) = plan.state else { return nil }
            return "\(plan.name) at \(plan.destinationURL.path) \(reason); Toastty will not overwrite it."
        }
        let installs = plans.filter { $0.state == .install }
        let plannedChanges = installs.map { plan in
            "Install \(plan.name) at \(plan.destinationURL.path) (\(plan.files.count) files)"
        }
        let currentNotes = plans
            .filter { $0.state == .current }
            .map { "\($0.name) is already installed and matches the bundled version." }

        if conflicts.isEmpty == false {
            let resolution = "Nothing is installed while any package conflicts. Move or rename each conflicting package (for example, add a -previous suffix), rerun the command, then copy over any personal changes you want to keep."
            return (
                SetupInstallerResult(
                    applied: false,
                    outcome: apply ? .refused : .dryRun,
                    plannedChanges: plannedChanges,
                    changedFiles: [],
                    warnings: conflicts,
                    nextSteps: [resolution]
                ),
                apply ? 1 : 0
            )
        }

        guard apply else {
            let nextSteps = installs.isEmpty
                ? ["The \(workflow.name) workflow is already installed."]
                : ["Review the planned packages, then rerun with --apply to install them."]
            return (
                SetupInstallerResult(
                    applied: false,
                    outcome: .dryRun,
                    plannedChanges: plannedChanges,
                    changedFiles: [],
                    warnings: [],
                    nextSteps: currentNotes + nextSteps + [workflow.requirements]
                ),
                0
            )
        }

        guard installs.isEmpty == false else {
            return (
                SetupInstallerResult(
                    applied: true,
                    outcome: .noChanges,
                    plannedChanges: [],
                    changedFiles: [],
                    warnings: discoveryWarnings(),
                    nextSteps: currentNotes + ["The \(workflow.name) workflow is already installed."]
                ),
                0
            )
        }

        let changedFiles: [String]
        do {
            changedFiles = try install(installs)
        } catch {
            return (
                SetupInstallerResult(
                    applied: false,
                    outcome: .failed,
                    plannedChanges: plannedChanges,
                    changedFiles: [],
                    warnings: ["Failed to install the \(workflow.name) workflow: \(error.localizedDescription)"],
                    nextSteps: ["No packages were installed. Resolve the failure and retry."]
                ),
                1
            )
        }

        return (
            SetupInstallerResult(
                applied: true,
                outcome: .applied,
                plannedChanges: plannedChanges,
                changedFiles: changedFiles,
                warnings: discoveryWarnings(),
                nextSteps: [
                    "Start a new managed agent session in Toastty to load the workflow skills; running sessions keep the skills they launched with.",
                    "Confirm discovery with \"$TOASTTY_CLI_PATH\" setup skills list.",
                    workflow.requirements,
                ]
            ),
            0
        )
    }

    // MARK: - Planning

    private enum PackageState: Equatable {
        case install
        case current
        case conflict(String)
    }

    private struct PackageFile: Equatable {
        var relativePath: String
        var contents: Data
        var isExecutable: Bool
    }

    private struct PackagePlan {
        var name: String
        var destinationURL: URL
        var files: [PackageFile]
        var state: PackageState
    }

    private func plan(packageName name: String) throws -> PackagePlan {
        let sourceURL = packagesDirectoryURL.appendingPathComponent(name, isDirectory: true)
        guard fileManager.fileExists(
            atPath: sourceURL.appendingPathComponent("SKILL.md", isDirectory: false).path
        ) else {
            throw ToasttyCLIError.runtime(
                "This Toastty build is missing the bundled \(name) package at \(sourceURL.path). Reinstall or update Toastty."
            )
        }
        let files: [PackageFile]
        do {
            files = try readPackage(at: sourceURL)
        } catch PackageReadError.symbolicLink(let path) {
            throw ToasttyCLIError.runtime("The bundled \(name) package contains a symbolic link at \(path).")
        }
        let destinationURL = userSkillsDirectoryURL.appendingPathComponent(name, isDirectory: true)
        return PackagePlan(
            name: name,
            destinationURL: destinationURL,
            files: files,
            state: try destinationState(destinationURL, desiredFiles: files)
        )
    }

    private func destinationState(_ url: URL, desiredFiles: [PackageFile]) throws -> PackageState {
        // attributesOfItem does not follow symlinks, so a symlinked package is
        // seen as one rather than as its target.
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return .install
        }
        switch type {
        case .typeDirectory:
            break
        case .typeSymbolicLink:
            return .conflict("is a symbolic link")
        default:
            return .conflict("exists and is not a directory")
        }
        let existingFiles: [PackageFile]
        do {
            existingFiles = try readPackage(at: url)
        } catch PackageReadError.symbolicLink {
            return .conflict("contains a symbolic link")
        }
        // Executable bits count: the skills run their scripts directly.
        let matches = existingFiles == desiredFiles
        return matches ? .current : .conflict("differs from the bundled version")
    }

    private enum PackageReadError: Error {
        case symbolicLink(String)
    }

    /// Regular files under a package, sorted by relative path. Hidden entries
    /// and Python bytecode caches are skipped on both sides so Finder metadata
    /// or a run of the package's own tests does not register as a change.
    private func readPackage(at rootURL: URL) throws -> [PackageFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        // The enumerator skips unreadable directories unless told otherwise,
        // which would install a package without some of its files.
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ToasttyCLIError.runtime("failed to read \(rootURL.path)")
        }
        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        var files: [PackageFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw PackageReadError.symbolicLink(url.path)
            }
            if values.isDirectory == true {
                if url.lastPathComponent == "__pycache__" {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path
            let relativePath = String(filePath.dropFirst(rootPath.count + 1))
            let permissions = (try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
                .uint16Value ?? 0
            files.append(PackageFile(
                relativePath: relativePath,
                contents: try Data(contentsOf: url),
                isExecutable: permissions & 0o111 != 0
            ))
        }
        if let enumerationError {
            throw enumerationError
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    // MARK: - Apply

    /// Writes every package into a hidden staging directory beside its final
    /// location first, then renames each into place. If any write or rename
    /// fails, packages already renamed by this call are removed, so the
    /// workflow ends up fully installed or not at all. A rename also fails if
    /// something appeared at a destination after planning, and that failure
    /// rolls back the same way.
    private func install(_ plans: [PackagePlan]) throws -> [String] {
        try fileManager.createDirectory(at: userSkillsDirectoryURL, withIntermediateDirectories: true)
        var staged: [(plan: PackagePlan, stagingURL: URL)] = []
        var published: [URL] = []
        do {
            for plan in plans {
                let stagingURL = userSkillsDirectoryURL.appendingPathComponent(
                    ".\(plan.name).toastty-install-\(UUID().uuidString)",
                    isDirectory: true
                )
                staged.append((plan, stagingURL))
                try write(plan.files, into: stagingURL)
            }
            for (plan, stagingURL) in staged {
                try fileManager.moveItem(at: stagingURL, to: plan.destinationURL)
                published.append(plan.destinationURL)
            }
        } catch {
            for url in published {
                try? fileManager.removeItem(at: url)
            }
            for (_, stagingURL) in staged {
                try? fileManager.removeItem(at: stagingURL)
            }
            throw error
        }
        return published.map(\.path)
    }

    private func write(_ files: [PackageFile], into directoryURL: URL) throws {
        for file in files {
            let fileURL = directoryURL.appendingPathComponent(file.relativePath, isDirectory: false)
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.contents.write(to: fileURL)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: file.isExecutable ? 0o755 : 0o644)],
                ofItemAtPath: fileURL.path
            )
        }
    }

    private func discoveryWarnings() -> [String] {
        let state = ToasttyUserSkillValidator(fileManager: fileManager)
            .scan(userSkillsDirectoryURL: userSkillsDirectoryURL)
            .state
        var warnings = state.globalDiagnostics.map {
            "User skills are excluded: \($0.displayMessage)"
        }
        for package in state.packages where workflow.packageNames.contains(package.name) {
            if case .excluded(let diagnostic) = package.status {
                warnings.append("\(package.name) was installed but is excluded: \(diagnostic.displayMessage)")
            }
        }
        return warnings
    }
}
