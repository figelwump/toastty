import CoreState
import Foundation

enum TerminalCommandClickTarget: Equatable, Sendable {
    case localDocumentFile(path: String, lineNumber: Int?, placement: WebPanelPlacement)
    case localDirectory(path: String)
    case localBrowserFile(URL)
    case externalLocalItem(URL)
    case unresolvedLocalDocument(URL, LocalFileLinkResolver.UnresolvedLocalDocumentIssue)
    case passthrough(URL)
}

enum TerminalCommandClickTargetResolver {
    static func resolve(
        hoveredURL: URL,
        cwd: String?,
        useAlternatePlacement: Bool,
        localDocumentPreferences: LocalDocumentRoutingPreferences = LocalDocumentRoutingPreferences(),
        fileManager: FileManager = .default
    ) -> TerminalCommandClickTarget {
        if let localDocumentTarget = LocalFileLinkResolver.resolvedLocalDocumentTarget(
            for: hoveredURL,
            cwd: cwd,
            fileManager: fileManager
        ) {
            let placement = localDocumentPreferences
                .resolvedPlacement(alternateOpen: useAlternatePlacement)
                .webPanelPlacement
            return .localDocumentFile(
                path: localDocumentTarget.path,
                lineNumber: localDocumentTarget.lineNumber,
                placement: placement
            )
        }

        if let localBrowserFileURL = LocalBrowserFileLinkResolver.resolvedLocalBrowserFileURL(
            for: hoveredURL,
            cwd: cwd,
            fileManager: fileManager
        ) {
            return .localBrowserFile(localBrowserFileURL)
        }

        if let externalLocalItemURL = LocalFileLinkResolver.existingLocalItemURLForExternalOpen(
            for: hoveredURL,
            cwd: cwd,
            fileManager: fileManager
        ) {
            return .externalLocalItem(externalLocalItemURL)
        }

        if let localDirectoryPath = LocalFileLinkResolver.normalizedLocalDirectoryPath(
            for: hoveredURL,
            cwd: cwd,
            fileManager: fileManager
        ) {
            return .localDirectory(path: localDirectoryPath)
        }

        if let issue = LocalFileLinkResolver.unresolvedLocalDocumentIssue(
            for: hoveredURL,
            cwd: cwd,
            fileManager: fileManager
        ) {
            return .unresolvedLocalDocument(hoveredURL, issue)
        }

        return .passthrough(hoveredURL)
    }
}
