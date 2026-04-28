import CoreState
import Foundation

enum LocalBrowserFileLinkResolver {
    private static let supportedFilenameExtensions: Set<String> = ["htm", "html"]

    static func resolvedLocalBrowserFileURL(
        for url: URL,
        cwd: String? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let localFilePath = LocalFileLinkResolver.resolvedLocalFilePath(for: url, cwd: cwd) else {
            return nil
        }

        guard let normalizedPath = LocalFileLinkResolver.normalizedRecoveredPath(
            for: localFilePath,
            fileManager: fileManager,
            exactMatcher: normalizedExistingLocalBrowserFilePath
        ) else {
            return nil
        }

        return URL(fileURLWithPath: normalizedPath)
    }

    private static func normalizedExistingLocalBrowserFilePath(
        _ path: String,
        fileManager: FileManager
    ) -> String? {
        // Keep this opt-in by the clicked/recovered path, not just by the
        // symlink target, so a visible `.md` link to generated HTML does not
        // silently change from document handling to browser handling.
        let clickedPathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard supportedFilenameExtensions.contains(clickedPathExtension) else {
            return nil
        }

        let resolvedURL = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedPath = resolvedURL.path
        guard resolvedPath.isEmpty == false else {
            return nil
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
              isDirectory.boolValue == false else {
            return nil
        }

        let pathExtension = resolvedURL.pathExtension.lowercased()
        guard supportedFilenameExtensions.contains(pathExtension) else {
            return nil
        }

        guard let normalizedPath = WebPanelState.normalizedFilePath(resolvedPath) else {
            return nil
        }

        return normalizedPath
    }
}
