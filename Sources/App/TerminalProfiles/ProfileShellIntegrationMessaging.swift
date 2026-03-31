import Foundation

enum ProfileShellIntegrationMessaging {
    static let restartNotice = """
    New shells will pick it up automatically. Existing tmux or zmx sessions may need to restart or re-source that init file before live titles update. Pane-local history applies to shells launched after Toastty injects the pane history environment, so older multiplexer sessions usually need a restart.
    """

    static func managedSnippetPlanLine(for status: ProfileShellIntegrationInstallStatus) -> String {
        if status.needsManagedSnippetWrite {
            return "Toastty will write the managed snippet to \(status.plan.managedSnippetURL.path)."
        }
        return "Toastty will use the existing managed snippet at \(status.plan.managedSnippetURL.path)."
    }

    static func initFilePlanLine(for status: ProfileShellIntegrationInstallStatus) -> String {
        if status.needsInitFileUpdate {
            if status.createsInitFile {
                return "Toastty will create \(status.plan.initFileURL.path) and add one source line to it."
            }
            return "Toastty will add one source line to \(status.plan.initFileURL.path)."
        }
        return "\(status.plan.initFileURL.path) already references that snippet."
    }

    static func managedSnippetResultLine(for result: ProfileShellIntegrationInstallResult) -> String {
        if result.updatedManagedSnippet {
            return "Wrote \(result.plan.managedSnippetURL.path)."
        }
        return "\(result.plan.managedSnippetURL.path) was already up to date."
    }

    static func initFileResultLine(for result: ProfileShellIntegrationInstallResult) -> String {
        if result.updatedInitFile {
            if result.createdInitFile {
                return "Created \(result.plan.initFileURL.path)."
            }
            return "Updated \(result.plan.initFileURL.path)."
        }
        return "\(result.plan.initFileURL.path) already referenced the managed snippet."
    }

    static func alreadyInstalledSummary(for status: ProfileShellIntegrationInstallStatus) -> String {
        """
        Toastty shell integration is already installed for \(status.plan.shell.displayName).

        Init file: \(status.plan.initFileURL.path)
        Managed snippet: \(status.plan.managedSnippetURL.path)
        """
    }

    static func installationPlanSummary(for status: ProfileShellIntegrationInstallStatus) -> String {
        """
        Toastty detected \(status.plan.shell.displayName).

        \(managedSnippetPlanLine(for: status))

        \(initFilePlanLine(for: status))

        \(restartNotice)
        """
    }

    static func installationCompletionSummary(for result: ProfileShellIntegrationInstallResult) -> String {
        """
        \(managedSnippetResultLine(for: result))
        \(initFileResultLine(for: result))

        \(restartNotice)
        """
    }
}
