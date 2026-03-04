import Dispatch
import Foundation
import Darwin

enum DirectoryWatcherError: Error {
    case openFailed(path: String, errnoCode: Int32)
}

final class DirectoryWatcher {
    private let fileDescriptor: Int32
    private let source: DispatchSourceFileSystemObject
    private var invalidated = false

    init(
        directoryURL: URL,
        queue: DispatchQueue,
        onChange: @escaping @Sendable () -> Void
    ) throws {
        let path = directoryURL.path(percentEncoded: false)
        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            throw DirectoryWatcherError.openFailed(path: path, errnoCode: errno)
        }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib, .link, .revoke],
            queue: queue
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { [fileDescriptor] in
            _ = close(fileDescriptor)
        }
        source.resume()
    }

    func invalidate() {
        guard invalidated == false else { return }
        invalidated = true
        source.cancel()
    }

    deinit {
        invalidate()
    }
}
