import Dispatch
import Foundation
#if canImport(Glibc)
import Glibc
#endif

// Darwin's vnode dispatch source (`DispatchSource.makeFileSystemObjectSource`,
// kqueue EVFILT_VNODE) over inotify. The source watches the path the file
// descriptor refers to (resolved through /proc/self/fd), so callers keep the
// Darwin shape: open the path with O_EVTONLY, create the source, close the
// descriptor in the cancel handler.

/// Darwin's open(2) flag for event-only descriptors. Linux has no
/// equivalent; a read-only descriptor works for files and directories.
public let O_EVTONLY: Int32 = O_RDONLY | O_CLOEXEC

public protocol DispatchSourceFileSystemObject: AnyObject {
    var data: DispatchSource.FileSystemEvent { get }
    var mask: DispatchSource.FileSystemEvent { get }
    var isCancelled: Bool { get }
    func setEventHandler(handler: @escaping @Sendable () -> Void)
    func setCancelHandler(handler: @escaping @Sendable () -> Void)
    func resume()
    func cancel()
}

extension DispatchSource {
    public static func makeFileSystemObjectSource(
        fileDescriptor: Int32,
        eventMask: DispatchSource.FileSystemEvent,
        queue: DispatchQueue? = nil
    ) -> any DispatchSourceFileSystemObject {
        InotifyFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: eventMask, queue: queue ?? .global())
    }
}

final class InotifyFileSystemObjectSource: DispatchSourceFileSystemObject, @unchecked Sendable {
    let mask: DispatchSource.FileSystemEvent
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var inotifyFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var eventHandler: (@Sendable () -> Void)?
    private var cancelHandler: (@Sendable () -> Void)?
    private var pendingData: DispatchSource.FileSystemEvent = []
    private var cancelled = false
    private var resumed = false

    init(fileDescriptor: Int32, eventMask: DispatchSource.FileSystemEvent, queue: DispatchQueue) {
        mask = eventMask
        self.queue = queue
        guard let path = Self.path(forDescriptor: fileDescriptor) else { return }
        let fd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard fd >= 0 else { return }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let watchMask = Self.inotifyMask(for: eventMask, isDirectory: isDirectory.boolValue)
        guard inotify_add_watch(fd, path, watchMask) >= 0 else {
            close(fd)
            return
        }
        inotifyFD = fd
    }

    var data: DispatchSource.FileSystemEvent {
        lock.withLock { pendingData }
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func setEventHandler(handler: @escaping @Sendable () -> Void) {
        lock.withLock { eventHandler = handler }
    }

    func setCancelHandler(handler: @escaping @Sendable () -> Void) {
        lock.withLock { cancelHandler = handler }
    }

    func resume() {
        let fd: Int32 = lock.withLock {
            guard resumed == false, cancelled == false else { return -1 }
            resumed = true
            return inotifyFD
        }
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { close(fd) }
        lock.withLock { readSource = source }
        source.resume()
    }

    func cancel() {
        let (source, handler, fd): (DispatchSourceRead?, (@Sendable () -> Void)?, Int32) = lock.withLock {
            guard cancelled == false else { return (nil, nil, -1) }
            cancelled = true
            let result = (readSource, cancelHandler, readSource == nil ? inotifyFD : -1)
            readSource = nil
            eventHandler = nil
            cancelHandler = nil
            inotifyFD = -1
            return result
        }
        source?.cancel()
        if fd >= 0 { close(fd) }
        if let handler {
            queue.async(execute: handler)
        }
    }

    private func drain() {
        let fd = lock.withLock { inotifyFD }
        guard fd >= 0 else { return }
        var events: DispatchSource.FileSystemEvent = []
        let bufferSize = 16 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let count = read(fd, &buffer, bufferSize)
            guard count > 0 else { break }
            var offset = 0
            while offset + MemoryLayout<inotify_event>.size <= count {
                let (eventMask, nameLength) = buffer.withUnsafeBytes { raw -> (UInt32, UInt32) in
                    let base = raw.baseAddress!.advanced(by: offset)
                    return (
                        base.loadUnaligned(fromByteOffset: 4, as: UInt32.self),
                        base.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
                    )
                }
                events.formUnion(Self.dispatchEvents(forInotifyMask: eventMask))
                offset += MemoryLayout<inotify_event>.size + Int(nameLength)
            }
        }
        let relevant = events.intersection(mask)
        guard relevant.isEmpty == false else { return }
        let handler: (@Sendable () -> Void)? = lock.withLock {
            pendingData = relevant
            return cancelled ? nil : eventHandler
        }
        handler?()
    }

    static func path(forDescriptor fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink("/proc/self/fd/\(fd)", &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        buffer[count] = 0
        return String(cString: buffer)
    }

    static func inotifyMask(for events: DispatchSource.FileSystemEvent, isDirectory: Bool) -> UInt32 {
        var mask: UInt32 = 0
        if events.contains(.write) || events.contains(.extend) {
            mask |= UInt32(IN_MODIFY) | UInt32(IN_CLOSE_WRITE)
            if isDirectory {
                // kqueue NOTE_WRITE on a directory: an entry was added/removed.
                mask |= UInt32(IN_CREATE) | UInt32(IN_DELETE) | UInt32(IN_MOVED_FROM) | UInt32(IN_MOVED_TO)
            }
        }
        if events.contains(.attrib) || events.contains(.link) { mask |= UInt32(IN_ATTRIB) }
        if events.contains(.rename) { mask |= UInt32(IN_MOVE_SELF) }
        if events.contains(.delete) { mask |= UInt32(IN_DELETE_SELF) }
        if events.contains(.revoke) { mask |= UInt32(IN_UNMOUNT) }
        return mask
    }

    static func dispatchEvents(forInotifyMask mask: UInt32) -> DispatchSource.FileSystemEvent {
        var events: DispatchSource.FileSystemEvent = []
        if mask & (UInt32(IN_MODIFY) | UInt32(IN_CLOSE_WRITE)) != 0 { events.formUnion([.write, .extend]) }
        if mask & (UInt32(IN_CREATE) | UInt32(IN_DELETE) | UInt32(IN_MOVED_FROM) | UInt32(IN_MOVED_TO)) != 0 {
            events.insert(.write)
        }
        if mask & UInt32(IN_ATTRIB) != 0 { events.formUnion([.attrib, .link]) }
        if mask & UInt32(IN_MOVE_SELF) != 0 { events.insert(.rename) }
        if mask & (UInt32(IN_DELETE_SELF) | UInt32(IN_IGNORED)) != 0 { events.insert(.delete) }
        if mask & UInt32(IN_UNMOUNT) != 0 { events.insert(.revoke) }
        return events
    }
}
