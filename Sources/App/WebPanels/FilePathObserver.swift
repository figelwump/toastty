import Darwin
import CoreState
import Foundation

// FilePathObserver serializes all mutable state onto eventQueue so the observer
// can receive dispatch-source callbacks without hopping shared state between
// executors.
final class FilePathObserver: @unchecked Sendable {
    typealias ChangeHandler = @Sendable () -> Void
    private static let defaultMissingNotificationDelay: DispatchTimeInterval = .milliseconds(200)

    private struct FileSnapshot: Equatable {
        let exists: Bool
        let fileNumber: UInt64?
        let modificationDate: Date?
        let size: UInt64?

        static let missing = FileSnapshot(
            exists: false,
            fileNumber: nil,
            modificationDate: nil,
            size: nil
        )
    }

    private let eventQueue: DispatchQueue
    private let changeHandler: ChangeHandler
    private let queueKey = DispatchSpecificKey<Void>()
    private let missingNotificationDelay: DispatchTimeInterval
    private var observedPath: String?
    private var snapshot = FileSnapshot.missing
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var pendingMissingNotification: DispatchWorkItem?
    private var isInvalidated = false

    init(
        path: String,
        eventQueue: DispatchQueue = DispatchQueue(
            label: "dev.toastty.file-path-observer",
            qos: .utility
        ),
        // Atomic-save editors can briefly remove the file before recreating it.
        // Hold missing-file notifications long enough to avoid flashing the
        // fallback document during an ordinary save.
        missingNotificationDelay: DispatchTimeInterval = FilePathObserver.defaultMissingNotificationDelay,
        changeHandler: @escaping ChangeHandler
    ) {
        self.eventQueue = eventQueue
        self.missingNotificationDelay = missingNotificationDelay
        self.changeHandler = changeHandler
        self.eventQueue.setSpecific(key: queueKey, value: ())
        update(path: path)
    }

    deinit {
        performStateMutation {
            observedPath = nil
            snapshot = .missing
            isInvalidated = true
            cancelPendingMissingNotification()
            invalidateSources()
        }
    }

    func update(path: String?) {
        let normalizedPath = Self.normalizedPath(path)
        performStateMutation {
            guard isInvalidated == false else { return }
            guard normalizedPath != observedPath else { return }

            observedPath = normalizedPath
            snapshot = Self.snapshot(for: normalizedPath)
            rebuildSources()
        }
    }

    func invalidate() {
        performStateMutation {
            guard isInvalidated == false else { return }
            isInvalidated = true
            observedPath = nil
            snapshot = .missing
            cancelPendingMissingNotification()
            invalidateSources()
        }
    }
}

private extension FilePathObserver {
    func performStateMutation(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            body()
            return
        }

        eventQueue.sync(execute: body)
    }

    static func fileEventMask() -> DispatchSource.FileSystemEvent {
        [
            .write,
            .extend,
            .attrib,
            .link,
            .rename,
            .delete,
            .revoke,
        ]
    }

    static func directoryEventMask() -> DispatchSource.FileSystemEvent {
        [
            .write,
            .rename,
            .delete,
        ]
    }

    static func normalizedPath(_ path: String?) -> String? {
        guard let trimmed = WebPanelState.normalizedFilePath(path) else {
            return nil
        }

        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private static func snapshot(for path: String?) -> FileSnapshot {
        guard let path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return .missing
        }

        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let modificationDate = attributes[.modificationDate] as? Date
        let size = (attributes[.size] as? NSNumber)?.uint64Value

        return FileSnapshot(
            exists: true,
            fileNumber: fileNumber,
            modificationDate: modificationDate,
            size: size
        )
    }

    func rebuildSources() {
        invalidateSources()

        guard let observedPath else { return }

        if let directoryPath = parentDirectoryPath(for: observedPath) {
            directorySource = makeSource(
                path: directoryPath,
                eventMask: Self.directoryEventMask()
            )
        }

        if snapshot.exists {
            fileSource = makeSource(
                path: observedPath,
                eventMask: Self.fileEventMask()
            )
        }
    }

    func parentDirectoryPath(for path: String) -> String? {
        let directoryPath = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .standardizedFileURL
            .path

        guard FileManager.default.fileExists(atPath: directoryPath) else {
            return nil
        }

        return directoryPath
    }

    func makeSource(
        path: String,
        eventMask: DispatchSource.FileSystemEvent
    ) -> DispatchSourceFileSystemObject? {
        let fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return nil
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: eventMask,
            queue: eventQueue
        )
        source.setEventHandler { [weak self] in
            self?.handleFilesystemEvent()
        }
        source.setCancelHandler {
            close(fileDescriptor)
        }
        source.resume()
        return source
    }

    func handleFilesystemEvent() {
        dispatchPrecondition(condition: .onQueue(eventQueue))
        guard let observedPath else { return }
        let refreshedSnapshot = Self.snapshot(for: observedPath)
        applyRefreshedSnapshot(
            refreshedSnapshot,
            for: observedPath
        )
    }

    private func applyRefreshedSnapshot(_ refreshedSnapshot: FileSnapshot, for path: String) {
        guard isInvalidated == false,
              observedPath == path else {
            return
        }

        let previousSnapshot = snapshot
        snapshot = refreshedSnapshot

        if previousSnapshot.exists != refreshedSnapshot.exists ||
            previousSnapshot.fileNumber != refreshedSnapshot.fileNumber {
            rebuildSources()
        }

        guard refreshedSnapshot != previousSnapshot else {
            return
        }

        if refreshedSnapshot.exists == false {
            scheduleMissingNotification(for: path)
            return
        }

        cancelPendingMissingNotification()
        changeHandler()
    }

    func scheduleMissingNotification(for path: String) {
        cancelPendingMissingNotification()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isInvalidated == false,
                  self.observedPath == path,
                  self.snapshot.exists == false else {
                return
            }

            self.pendingMissingNotification = nil
            self.changeHandler()
        }

        pendingMissingNotification = workItem
        eventQueue.asyncAfter(deadline: .now() + missingNotificationDelay, execute: workItem)
    }

    func cancelPendingMissingNotification() {
        pendingMissingNotification?.cancel()
        pendingMissingNotification = nil
    }

    func invalidateSources() {
        fileSource?.cancel()
        fileSource = nil
        directorySource?.cancel()
        directorySource = nil
    }
}
