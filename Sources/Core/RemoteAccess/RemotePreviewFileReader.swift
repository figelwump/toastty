import CryptoKit
import Darwin
import Foundation
import RemoteProtocol

/// Filesystem policy shared by preview bodies and HTML subresources. Paths are
/// resolved off the main actor; caller-supplied paths never create a grant.
public enum RemotePreviewFileReader {
    public static let maximumDocumentBytes = 2 * 1024 * 1024
    public static let maximumAssetBytes = 5 * 1024 * 1024

    public struct Snapshot: Equatable, Sendable {
        public var canonicalPath: String
        public var data: Data
        public var revision: String
    }

    public static func canonicalPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096 else {
            throw RemotePreviewError.denied
        }
        // Foundation deliberately preserves some macOS aliases (notably
        // /var), which are unsuitable for O_NOFOLLOW traversal. realpath is
        // the filesystem's canonical spelling, including system aliases.
        guard let resolved = path.withCString({ Darwin.realpath($0, nil) }) else {
            throw errno == ENOENT || errno == ENOTDIR
                ? RemotePreviewError.missing : RemotePreviewError.denied
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A recorded path is an authority boundary, not a request to follow its
    /// current symlink destination. Desktop state does not persist a symlink's
    /// original target, so only the fixed macOS system aliases may redirect it.
    public static func authorityPath(_ recordedPath: String) throws -> String {
        guard recordedPath.hasPrefix("/"), !recordedPath.utf8.contains(0),
            recordedPath.utf8.count <= 4096
        else { throw RemotePreviewError.denied }
        var components = recordedPath.split(separator: "/").map(String.init)
        if let first = components.first, ["tmp", "var", "etc"].contains(first) {
            components.insert("private", at: 0)
        }
        var normalized: [String] = []
        for component in components {
            switch component {
            case ".": continue
            case "..":
                if !normalized.isEmpty { normalized.removeLast() }
            default: normalized.append(component)
            }
        }
        let literal = "/" + normalized.joined(separator: "/")
        // Resolve the ORIGINAL expression as well. Collapsing symlink/.. first
        // could otherwise authorize a different file from the recorded path.
        guard try canonicalPath(recordedPath) == literal else { throw RemotePreviewError.denied }
        return literal
    }

    public static func projectRoot(recordedCWD: String) throws -> String {
        let cwd = try authorityPath(recordedCWD)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &directory),
            directory.boolValue
        else {
            throw RemotePreviewError.stale
        }
        let root = try authorityPath(RepositoryRootLocator.inferRepoRoot(from: cwd) ?? cwd)
        guard try authorityPath(recordedCWD) == cwd,
            cwd == root || isWithin(cwd, root: root)
        else { throw RemotePreviewError.stale }
        let home = try canonicalPath(NSHomeDirectory())
        guard root != "/", root != home else { throw RemotePreviewError.denied }
        return root
    }

    public static func resolveFile(
        reference: String, recordedCWD: String?, explicitlyOpenPaths: [String]
    ) throws -> String {
        guard !reference.isEmpty, reference.utf8.count <= 4096, !reference.utf8.contains(0) else {
            throw RemotePreviewError.denied
        }
        let path: String
        if reference.hasPrefix("/") {
            path = try canonicalPath(reference)
        } else {
            guard let recordedCWD else { throw RemotePreviewError.denied }
            let cwd = try authorityPath(recordedCWD)
            path = try canonicalPath(
                URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(
                    reference
                ).path)
        }
        if explicitlyOpenPaths.contains(where: { (try? authorityPath($0)) == path }) {
            return path
        }
        guard let recordedCWD else { throw RemotePreviewError.denied }
        let root = try projectRoot(recordedCWD: recordedCWD)
        guard isWithin(path, root: root) else { throw RemotePreviewError.denied }
        return path
    }

    public static func resourcePath(relativePath: String, entryPath: String) throws -> (
        path: String, mimeType: String
    ) {
        guard !relativePath.isEmpty, relativePath.utf8.count <= 4096,
            !relativePath.hasPrefix("/"), !relativePath.contains("\\"),
            !relativePath.contains(":"), !relativePath.utf8.contains(0)
        else {
            throw RemotePreviewError.denied
        }
        // The native scheme handler supplies a decoded URL path, without query
        // or fragment. Reject hidden files even when their extension looks safe.
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else {
            throw RemotePreviewError.denied
        }
        guard assetMIMETypes[URL(fileURLWithPath: relativePath).pathExtension.lowercased()] != nil
        else {
            throw RemotePreviewError.denied
        }
        let root = try authorityPath(
            URL(fileURLWithPath: entryPath).deletingLastPathComponent().path)
        let path = try canonicalPath(
            URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(relativePath).path)
        guard isWithin(path, root: root),
            let mimeType = assetMIMETypes[URL(fileURLWithPath: path).pathExtension.lowercased()]
        else {
            throw RemotePreviewError.denied
        }
        return (path, mimeType)
    }

    public static func isWithin(_ path: String, root: String) -> Bool {
        path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Opens every canonical component without following symlinks, then reads
    /// only a bounded regular file. A descriptor pins the object during reads;
    /// path and metadata checks detect replacement/rename and in-place changes.
    public static func read(path: String, maximumBytes: Int) throws -> Snapshot {
        try Task.checkCancellation()
        let canonical = try canonicalPath(path)
        guard canonical == path else {
            // The caller authorized this canonical path before entering read.
            // A newly inserted symlink must not redirect that grant.
            throw RemotePreviewError.stale
        }
        let components = canonical.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw RemotePreviewError.denied }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw RemotePreviewError.denied }
        defer { Darwin.close(descriptor) }
        for (index, component) in components.enumerated() {
            try Task.checkCancellation()
            let flags =
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                | (index == components.count - 1 ? 0 : O_DIRECTORY)
            let next = component.withCString { Darwin.openat(descriptor, $0, flags) }
            guard next >= 0 else {
                throw errno == ENOENT ? RemotePreviewError.missing : RemotePreviewError.denied
            }
            Darwin.close(descriptor)
            descriptor = next
        }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            throw RemotePreviewError.denied
        }
        guard before.st_size >= 0, before.st_size <= maximumBytes else {
            throw RemotePreviewError.tooLarge
        }
        guard try descriptorPath(descriptor) == canonical else { throw RemotePreviewError.stale }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(
                    descriptor, $0.baseAddress, min($0.count, maximumBytes + 1 - data.count))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw RemotePreviewError.missing
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw RemotePreviewError.tooLarge }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
            before.st_dev == after.st_dev, before.st_ino == after.st_ino,
            before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
            try descriptorPath(descriptor) == canonical,
            try canonicalPath(path) == canonical
        else { throw RemotePreviewError.stale }
        return Snapshot(
            canonicalPath: canonical, data: data,
            revision: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private static func descriptorPath(_ descriptor: Int32) throws -> String {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &bytes) == 0 else { throw RemotePreviewError.stale }
        return String(
            decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static let assetMIMETypes: [String: String] = [
        "css": "text/css", "js": "text/javascript", "mjs": "text/javascript",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "svg": "image/svg+xml", "webp": "image/webp", "avif": "image/avif", "ico": "image/x-icon",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "mp3": "audio/mpeg", "wav": "audio/wav", "ogg": "audio/ogg", "m4a": "audio/mp4",
        "mp4": "video/mp4", "webm": "video/webm", "wasm": "application/wasm",
    ]
}
