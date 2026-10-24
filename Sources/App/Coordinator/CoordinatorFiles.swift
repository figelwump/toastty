import CoreState
import Darwin
import Foundation

/// The coordinator's files in Toastty's config directory: `events.jsonl`,
/// the cards it posted, and `routing.md`, its notes on where requests go.
/// Both outlive any one coordinator session, so a fresh session rebuilds
/// from them and the task records.
struct CoordinatorFiles {
    static let routingTemplate = """
    # Coordinator routing notes

    The coordinator reads this file before it routes a request to a project,
    and adds to it when you pick or move a project. Edit it freely.

    ## Projects

    ## Picks

    ## Past tasks

    """

    let directoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    init(runtimePaths: ToasttyRuntimePaths) {
        self.init(directoryURL: runtimePaths.configDirectoryURL.appending(path: "coordinator", directoryHint: .isDirectory))
    }

    var eventsFileURL: URL {
        directoryURL.appending(path: "events.jsonl", directoryHint: .notDirectory)
    }

    var routingFileURL: URL {
        directoryURL.appending(path: "routing.md", directoryHint: .notDirectory)
    }

    /// Creates the directory, and `routing.md` from its template when it is
    /// missing. An existing file is never changed.
    func prepare(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: routingFileURL.path) == false else { return }
        do {
            // `.withoutOverwriting` keeps a file another process wrote first.
            try Data(Self.routingTemplate.utf8).write(to: routingFileURL, options: .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            return
        }
    }

    /// Appends one event as one line. A single `write` with `O_APPEND` keeps
    /// lines whole even if another writer appends at the same time.
    func append(_ event: CoordinatorEvent) throws {
        try prepare()
        var line = try event.jsonLine()
        line.append(UInt8(ascii: "\n"))
        let descriptor = open(eventsFileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: eventsFileURL.path])
        }
        defer { close(descriptor) }
        let written = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == line.count else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: eventsFileURL.path])
        }
    }

    func events() -> [CoordinatorEvent] {
        guard let data = try? Data(contentsOf: eventsFileURL) else { return [] }
        return CoordinatorEvent.decodeLog(data)
    }
}
