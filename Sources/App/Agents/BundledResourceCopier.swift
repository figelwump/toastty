import Foundation

/// Copies a bundled resource (a file or a directory tree) into a location
/// Toastty owns, keeping permission bits but not ownership.
///
/// On Linux, corelibs Foundation's `copyItem` preserves each directory's
/// owner with `fchown`, which fails with `EPERM` when the source is owned by
/// another user. Bundled resources are root-owned in an AppImage (its
/// squashfs) and in an installed `.deb` (`/usr/lib/toastty`), so copying the
/// agent plugins from there failed and Codex and Claude launched without
/// Toastty's skills. macOS keeps `copyItem`.
enum BundledResourceCopier {
    static func copyItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManager) throws {
        #if os(Linux)
        try copyKeepingMode(at: sourceURL, to: destinationURL, fileManager: fileManager)
        #else
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        #endif
    }

    #if os(Linux)
    private static func copyKeepingMode(at sourceURL: URL, to destinationURL: URL, fileManager: FileManager) throws {
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory?:
            try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: false)
            for name in try fileManager.contentsOfDirectory(atPath: sourceURL.path) {
                try copyKeepingMode(
                    at: sourceURL.appendingPathComponent(name),
                    to: destinationURL.appendingPathComponent(name),
                    fileManager: fileManager
                )
            }
            // Applied after the children so a read-only source directory
            // does not block filling its copy.
            if let permissions = attributes[.posixPermissions] {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destinationURL.path)
            }
        case .typeSymbolicLink?:
            try fileManager.createSymbolicLink(
                atPath: destinationURL.path,
                withDestinationPath: fileManager.destinationOfSymbolicLink(atPath: sourceURL.path)
            )
        default:
            // A single-file copy keeps the mode and does not fail on ownership.
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }
    #endif
}
