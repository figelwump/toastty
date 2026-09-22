import Foundation
import RemoteProtocol
import Darwin

/// Private, bounded files whose lifetime outlasts terminal delivery. Use from
/// a serial worker/actor: no filesystem work belongs in the final input gate.
public actor RemoteMessageAttachmentStore {
    public struct Staged: Sendable {
        public let directory: URL
        public let files: [URL]

        public func deliveryText(for request: RemoteMessageSendRequest) -> String {
            let paths = files.map { TerminalDropPayloadBuilder.shellEscapedPath($0.path) }.joined(separator: "\n")
            return [request.text, "Read the following files attached to this message on this Mac:\n" + paths]
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
    }

    public enum StorageError: Error { case unavailable, invalidAttachments }
    public static let retention: TimeInterval = 7 * 24 * 60 * 60
    public static let maximumStoredBytes = 256 * 1024 * 1024
    private let root: URL
    private let maximumBytes: Int

    public init(root: URL, maximumBytes: Int = maximumStoredBytes) {
        self.root = root
        self.maximumBytes = maximumBytes
    }

    public func stage(_ attachments: [RemoteMessageAttachment], at date: Date = Date()) throws -> Staged {
        guard !attachments.isEmpty, RemoteAttachmentPolicy.validationError(for: attachments) == nil else {
            throw StorageError.invalidAttachments
        }
        try prepareRoot()
        let used = try sweepAndMeasure(at: date)
        guard attachments.reduce(used, { $0 + $1.data.count }) <= maximumBytes else { throw StorageError.unavailable }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw StorageError.unavailable }
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: directory) } }
        var files: [URL] = []
        for attachment in attachments {
            let ext = (attachment.filename as NSString).pathExtension.lowercased()
            let file = directory.appendingPathComponent(UUID().uuidString + "." + ext)
            let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw StorageError.unavailable }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: attachment.data)
            try handle.close()
            files.append(file)
        }
        success = true
        return Staged(directory: directory, files: files)
    }

    public func discard(_ staged: Staged) {
        guard staged.directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              UUID(uuidString: staged.directory.lastPathComponent) != nil,
              isOwnedDirectory(staged.directory) else { return }
        try? FileManager.default.removeItem(at: staged.directory)
    }

    public func cleanup(at date: Date = Date()) throws {
        try prepareRoot()
        _ = try sweepAndMeasure(at: date)
    }

    private func prepareRoot() throws {
        // Runtime paths choose the parent; only this leaf is attachment-owned.
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if mkdir(root.path, 0o700) != 0 && errno != EEXIST { throw StorageError.unavailable }
        guard isOwnedDirectory(root), chmod(root.path, 0o700) == 0 else { throw StorageError.unavailable }
    }

    private func isOwnedDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
    }

    private func sweepAndMeasure(at date: Date) throws -> Int {
        var total = 0
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: directory.lastPathComponent) != nil, isOwnedDirectory(directory) else { continue }
            var info = stat()
            guard lstat(directory.path, &info) == 0 else { throw StorageError.unavailable }
            if date.timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) > Self.retention {
                // Foundation removes symlinks themselves; it does not traverse
                // their targets. Only generated direct-child directories qualify.
                try FileManager.default.removeItem(at: directory)
                continue
            }
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                var fileInfo = stat()
                guard lstat(file.path, &fileInfo) == 0,
                      (fileInfo.st_mode & S_IFMT) == S_IFREG,
                      fileInfo.st_uid == getuid(), fileInfo.st_size >= 0 else { throw StorageError.unavailable }
                guard fileInfo.st_size <= Self.maximumStoredBytes else { throw StorageError.unavailable }
                total += Int(fileInfo.st_size)
            }
        }
        return total
    }
}
