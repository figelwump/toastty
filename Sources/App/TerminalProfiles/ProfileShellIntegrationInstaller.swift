import CoreState
import Darwin
import Foundation

enum ProfileShellIntegrationShell: CaseIterable, Equatable {
    case zsh
    case bash

    var displayName: String {
        switch self {
        case .zsh:
            return "Zsh"
        case .bash:
            return "Bash"
        }
    }

    var managedSnippetFileName: String {
        switch self {
        case .zsh:
            return "toastty-profile-shell-integration.zsh"
        case .bash:
            return "toastty-profile-shell-integration.bash"
        }
    }

    var managedSnippetRelativePath: String {
        ".toastty/shell/\(managedSnippetFileName)"
    }

    var defaultInitFileName: String {
        switch self {
        case .zsh:
            return ".zshrc"
        case .bash:
            return ".bash_profile"
        }
    }

    var candidateInitFileNames: [String] {
        switch self {
        case .zsh:
            return [".zshrc"]
        case .bash:
            return [".bash_profile", ".profile"]
        }
    }

    var sourceLine: String {
        "source \"$HOME/\(managedSnippetRelativePath)\""
    }

    var managedSnippetContents: String {
        switch self {
        case .zsh:
            return """
            # Toastty terminal profile shell integration.
            # - idle prompt: cwd
            # - running command: command
            _toastty_restore_agent_shim_path() {
            \tlocal shim_dir="${TOASTTY_AGENT_SHIM_DIR:-}"
            \t[[ -n "$shim_dir" ]] || return

            \ttypeset -gaU path
            \tpath=("$shim_dir" "${(@)path:#$shim_dir}")
            \texport PATH
            }

            _toastty_configure_pane_history() {
            \tlocal pane_history_file="${TOASTTY_PANE_HISTORY_FILE:-}"
            \t[[ -n "$pane_history_file" ]] || return

            \tlocal pane_history_dir="${pane_history_file:h}"
            \tcommand mkdir -p "$pane_history_dir" 2>/dev/null || return

            \tif [[ -z ${_TOASTTY_PANE_HISTORY_INITIALIZED:-} ]]; then
            \t\tfc -p "$pane_history_file" 2>/dev/null || return
            \t\ttypeset -g _TOASTTY_PANE_HISTORY_INITIALIZED=1
            \tfi
            }

            _toastty_emit_title() {
            \t[[ -t 1 ]] || return
            \t[[ -w /dev/tty ]] || return

            \tlocal title="$1"
            \ttitle="${title//$'\\e'/}"
            \ttitle="${title//$'\\a'/}"
            \ttitle="${title//$'\\r'/}"
            \ttitle="${title//$'\\n'/ }"

            \tprintf '\\033]2;%s\\a' "$title" > /dev/tty
            }

            _toastty_precmd() {
            \tif [[ -n ${_TOASTTY_PANE_HISTORY_INITIALIZED:-} ]]; then
            \t\tfc -AI
            \tfi
            \tlocal cwd="${PWD/#$HOME/~}"
            \t_toastty_emit_title "$cwd"
            }

            _toastty_preexec() {
            \tlocal cmd="${1%%$'\\n'*}"
            \t_toastty_emit_title "$cmd"
            }

            if [[ -o interactive ]]; then
            \t_toastty_restore_agent_shim_path
            \t_toastty_configure_pane_history
            \tif [[ -z ${_TOASTTY_TITLE_HOOKS_INSTALLED:-} ]]; then
            \t\tautoload -Uz add-zsh-hook
            \t\tadd-zsh-hook precmd _toastty_precmd
            \t\tadd-zsh-hook preexec _toastty_preexec
            \t\ttypeset -g _TOASTTY_TITLE_HOOKS_INSTALLED=1
            \tfi
            fi
            """
        case .bash:
            return """
            # Toastty terminal profile shell integration.
            # Updates the pane title to the current directory whenever the prompt returns.
            _toastty_restore_agent_shim_path() {
            \tlocal shim_dir="${TOASTTY_AGENT_SHIM_DIR:-}"
            \t[[ -n "$shim_dir" ]] || return

            \tlocal entry=""
            \tlocal old_path="${PATH:-}"
            \tlocal IFS=':'
            \tlocal -a path_entries=()
            \tread -r -a path_entries <<< "$old_path"

            \tPATH="$shim_dir"
            \tfor entry in "${path_entries[@]}"; do
            \t\t[[ -n "$entry" && "$entry" != "$shim_dir" ]] || continue
            \t\tPATH+=":$entry"
            \tdone
            \texport PATH
            }

            _toastty_configure_pane_history() {
            \tlocal pane_history_file="${TOASTTY_PANE_HISTORY_FILE:-}"
            \t[[ -n "$pane_history_file" ]] || return

            \tlocal pane_history_dir="${pane_history_file%/*}"
            \tcommand mkdir -p "$pane_history_dir" 2>/dev/null || return

            \tif [[ -z "${_TOASTTY_PANE_HISTORY_INITIALIZED:-}" ]]; then
            \t\tHISTFILE="$pane_history_file"
            \t\texport HISTFILE
            \t\thistory -c
            \t\thistory -r "$HISTFILE" 2>/dev/null || true
            \t\t_TOASTTY_PANE_HISTORY_INITIALIZED=1
            \tfi
            }

            _toastty_emit_title() {
            \t[[ $- == *i* ]] || return
            \t[[ -t 1 ]] || return
            \t[[ -w /dev/tty ]] || return

            \tlocal title="$1"
            \ttitle="${title//$'\\e'/}"
            \ttitle="${title//$'\\a'/}"
            \ttitle="${title//$'\\r'/}"
            \ttitle="${title//$'\\n'/ }"

            \tprintf '\\033]2;%s\\a' "$title" > /dev/tty
            }

            _toastty_prompt_command() {
            \tif [[ -n "${_TOASTTY_PANE_HISTORY_INITIALIZED:-}" ]]; then
            \t\thistory -a
            \tfi
            \tlocal cwd="${PWD/#$HOME/~}"
            \t_toastty_emit_title "$cwd"
            }

            if [[ $- == *i* ]]; then
            \t_toastty_restore_agent_shim_path
            \t_toastty_configure_pane_history
            \tif [[ -z "${_TOASTTY_TITLE_HOOKS_INSTALLED:-}" ]]; then
            \t\tPROMPT_COMMAND="_toastty_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
            \t\t_TOASTTY_TITLE_HOOKS_INSTALLED=1
            \tfi
            fi
            """
        }
    }

    func preferredInitFileURL(homeDirectoryURL: URL, fileManager: FileManager) -> URL {
        switch self {
        case .zsh:
            return homeDirectoryURL.appendingPathComponent(defaultInitFileName)
        case .bash:
            let candidates = [".bash_profile", ".profile"]
            for candidate in candidates {
                let candidateURL = homeDirectoryURL.appendingPathComponent(candidate)
                var isDirectory = ObjCBool(false)
                if fileManager.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory),
                   isDirectory.boolValue == false {
                    return candidateURL
                }
            }
            return homeDirectoryURL.appendingPathComponent(defaultInitFileName)
        }
    }

    func candidateInitFileURLs(homeDirectoryURL: URL) -> [URL] {
        candidateInitFileNames.map { homeDirectoryURL.appendingPathComponent($0) }
    }
}

struct ProfileShellIntegrationInstallPlan: Equatable {
    let shell: ProfileShellIntegrationShell
    let initFileURL: URL
    let managedSnippetURL: URL

    var sourceLine: String {
        shell.sourceLine
    }
}

struct ProfileShellIntegrationInstallStatus: Equatable {
    let plan: ProfileShellIntegrationInstallPlan
    let needsManagedSnippetWrite: Bool
    let needsInitFileUpdate: Bool
    let createsInitFile: Bool

    var isInstalled: Bool {
        needsManagedSnippetWrite == false && needsInitFileUpdate == false
    }
}

struct ProfileShellIntegrationInstallResult: Equatable {
    let plan: ProfileShellIntegrationInstallPlan
    let updatedManagedSnippet: Bool
    let updatedInitFile: Bool
    let createdInitFile: Bool
}

enum ProfileShellIntegrationInstallerError: LocalizedError, Equatable {
    case unsupportedShell(shellPath: String?)
    case runtimeHomeUnsupported(path: String)
    case unableToReadFile(path: String, reason: String)
    case unableToWriteFile(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedShell(let shellPath):
            let resolvedShell = shellPath?.isEmpty == false ? shellPath! : "unknown"
            return """
            Toastty can install shell integration for zsh and bash only. Detected shell: \(resolvedShell)

            For other shells, add an equivalent OSC 2 title hook manually in your shell init file.
            """
        case .runtimeHomeUnsupported(let path):
            return """
            Shell integration is disabled while Toastty is running with runtime isolation enabled at \(path).

            Sandboxed dev/test runs must not rewrite your login shell files.
            """
        case .unableToReadFile(let path, let reason):
            return "Unable to read \(path): \(reason)"
        case .unableToWriteFile(let path, let reason):
            return "Unable to write \(path): \(reason)"
        }
    }
}

final class ProfileShellIntegrationInstaller {
    private static let managedSourceCommentLines = [
        "# Added by Toastty terminal profile shell integration",
        "# Keep this near the end of this file, after all other PATH and history-file changes,",
        "# so Toastty can restore its managed shim directory and pane-local history settings.",
    ]

    private let fileManager: FileManager
    private let homeDirectoryURL: URL
    private let environment: [String: String]
    private let shellPathProvider: () -> String?

    init(
        homeDirectoryPath: String? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shellPathProvider: @escaping () -> String? = ProfileShellIntegrationInstaller.defaultShellPath
    ) {
        self.fileManager = fileManager
        if let homeDirectoryPath {
            homeDirectoryURL = URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
        } else {
            homeDirectoryURL = fileManager.homeDirectoryForCurrentUser
        }
        self.environment = environment
        self.shellPathProvider = shellPathProvider
    }

    func installationPlan() throws -> ProfileShellIntegrationInstallPlan {
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: environment
        )
        if let runtimeHomeURL = runtimePaths.runtimeHomeURL {
            throw ProfileShellIntegrationInstallerError.runtimeHomeUnsupported(path: runtimeHomeURL.path)
        }

        let shellPath = shellPathProvider()
        guard let shell = Self.detectedShell(from: shellPath) else {
            throw ProfileShellIntegrationInstallerError.unsupportedShell(shellPath: shellPath)
        }

        return ProfileShellIntegrationInstallPlan(
            shell: shell,
            initFileURL: shell.preferredInitFileURL(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager),
            managedSnippetURL: homeDirectoryURL.appendingPathComponent(shell.managedSnippetRelativePath)
        )
    }

    func install() throws -> ProfileShellIntegrationInstallResult {
        try install(plan: installationPlan())
    }

    func refreshManagedSnippetIfInstalled() throws -> Bool {
        var updated = false

        for shell in ProfileShellIntegrationShell.allCases {
            let plan = ProfileShellIntegrationInstallPlan(
                shell: shell,
                initFileURL: shell.preferredInitFileURL(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager),
                managedSnippetURL: homeDirectoryURL.appendingPathComponent(shell.managedSnippetRelativePath)
            )
            guard try shouldRefreshManagedSnippet(for: plan) else {
                continue
            }

            try ensureDirectoryExists(at: plan.managedSnippetURL.deletingLastPathComponent())
            if try writeManagedSnippet(for: plan) {
                updated = true
            }
        }

        return updated
    }

    func installationStatus() throws -> ProfileShellIntegrationInstallStatus {
        try installationStatus(plan: installationPlan())
    }

    func installationStatus(
        plan: ProfileShellIntegrationInstallPlan
    ) throws -> ProfileShellIntegrationInstallStatus {
        let initFileExists = fileManager.fileExists(atPath: plan.initFileURL.path)
        let initFileContents = try readFileIfPresent(at: plan.initFileURL)
        let managedSnippetContents = try readFileIfPresent(at: plan.managedSnippetURL)

        return ProfileShellIntegrationInstallStatus(
            plan: plan,
            needsManagedSnippetWrite: managedSnippetContents != expectedManagedSnippetContents(for: plan),
            needsInitFileUpdate: contents(initFileContents, referencesManagedSnippetFor: plan) == false,
            createsInitFile: initFileExists == false
        )
    }

    func install(plan: ProfileShellIntegrationInstallPlan) throws -> ProfileShellIntegrationInstallResult {
        try ensureDirectoryExists(at: plan.managedSnippetURL.deletingLastPathComponent())
        let updatedManagedSnippet = try writeManagedSnippet(for: plan)
        let initFileUpdate = try installSourceLine(for: plan)

        return ProfileShellIntegrationInstallResult(
            plan: plan,
            updatedManagedSnippet: updatedManagedSnippet,
            updatedInitFile: initFileUpdate.updated,
            createdInitFile: initFileUpdate.created
        )
    }

    private static func defaultShellPath() -> String? {
        resolvedShellPath(
            environment: ProcessInfo.processInfo.environment,
            loginShellPath: loginShellPath()
        )
    }

    private func shouldRefreshManagedSnippet(
        for plan: ProfileShellIntegrationInstallPlan
    ) throws -> Bool {
        if fileManager.fileExists(atPath: plan.managedSnippetURL.path) {
            return true
        }

        for initFileURL in plan.shell.candidateInitFileURLs(homeDirectoryURL: homeDirectoryURL) {
            let initFileContents = try readFileIfPresent(at: initFileURL)
            if contents(initFileContents, referencesManagedSnippetFor: plan) {
                return true
            }
        }

        return false
    }

    static func resolvedShellPath(
        environment: [String: String],
        loginShellPath: String?
    ) -> String? {
        if let loginShellPath, loginShellPath.isEmpty == false {
            return loginShellPath
        }
        if let environmentShell = environment["SHELL"], environmentShell.isEmpty == false {
            return environmentShell
        }
        return nil
    }

    private static func loginShellPath() -> String? {
        guard let passwdEntry = getpwuid(getuid()),
              let shellPointer = passwdEntry.pointee.pw_shell else {
            return nil
        }

        let shellPath = String(cString: shellPointer)
        return shellPath.isEmpty ? nil : shellPath
    }

    private static func detectedShell(from shellPath: String?) -> ProfileShellIntegrationShell? {
        guard let shellPath, shellPath.isEmpty == false else { return nil }
        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
        let normalizedShellName = shellName.hasPrefix("-")
            ? String(shellName.dropFirst()).lowercased()
            : shellName.lowercased()

        if normalizedShellName.hasPrefix("zsh") {
            return .zsh
        }
        if normalizedShellName.hasPrefix("bash") {
            return .bash
        }
        return nil
    }

    private func ensureDirectoryExists(at directoryURL: URL) throws {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw ProfileShellIntegrationInstallerError.unableToWriteFile(
                path: directoryURL.path,
                reason: error.localizedDescription
            )
        }
    }

    private func writeManagedSnippet(for plan: ProfileShellIntegrationInstallPlan) throws -> Bool {
        let managedContents = expectedManagedSnippetContents(for: plan)
        do {
            if fileManager.fileExists(atPath: plan.managedSnippetURL.path) {
                let existingContents = try String(contentsOf: plan.managedSnippetURL, encoding: .utf8)
                if existingContents == managedContents {
                    return false
                }
            }

            try managedContents.write(to: plan.managedSnippetURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            throw ProfileShellIntegrationInstallerError.unableToWriteFile(
                path: plan.managedSnippetURL.path,
                reason: error.localizedDescription
            )
        }
    }

    private func expectedManagedSnippetContents(for plan: ProfileShellIntegrationInstallPlan) -> String {
        plan.shell.managedSnippetContents.appending("\n")
    }

    private func installSourceLine(
        for plan: ProfileShellIntegrationInstallPlan
    ) throws -> (updated: Bool, created: Bool) {
        let initFileURL = plan.initFileURL
        let initFileExisted = fileManager.fileExists(atPath: initFileURL.path)

        let existingContents: String
        if initFileExisted {
            do {
                existingContents = try String(contentsOf: initFileURL, encoding: .utf8)
            } catch {
                throw ProfileShellIntegrationInstallerError.unableToReadFile(
                    path: initFileURL.path,
                    reason: error.localizedDescription
                )
            }
        } else {
            existingContents = ""
        }

        if contents(existingContents, referencesManagedSnippetFor: plan) {
            return (updated: false, created: false)
        }

        let separator: String
        if existingContents.isEmpty {
            separator = ""
        } else if existingContents.hasSuffix("\n") {
            separator = "\n"
        } else {
            separator = "\n\n"
        }

        let updatedContents = existingContents
            + separator
            + Self.managedSourceCommentLines.joined(separator: "\n")
            + "\n"
            + plan.sourceLine
            + "\n"

        do {
            try updatedContents.write(to: initFileURL, atomically: true, encoding: .utf8)
        } catch {
            throw ProfileShellIntegrationInstallerError.unableToWriteFile(
                path: initFileURL.path,
                reason: error.localizedDescription
            )
        }

        return (updated: true, created: initFileExisted == false)
    }

    private func contents(
        _ contents: String,
        referencesManagedSnippetFor plan: ProfileShellIntegrationInstallPlan
    ) -> Bool {
        let fileName = plan.managedSnippetURL.lastPathComponent
        let markers = [
            plan.sourceLine,
            plan.managedSnippetURL.path,
            "$HOME/.toastty/shell/\(fileName)",
            "~/.toastty/shell/\(fileName)",
        ]

        return contents
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && $0.hasPrefix("#") == false }
            .contains { line in
                markers.contains(where: line.contains)
            }
    }

    private func readFileIfPresent(at fileURL: URL) throws -> String {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return ""
        }

        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw ProfileShellIntegrationInstallerError.unableToReadFile(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
    }
}
