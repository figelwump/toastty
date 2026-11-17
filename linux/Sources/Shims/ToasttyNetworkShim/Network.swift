import Dispatch
import Foundation
#if canImport(Glibc)
import Glibc
#endif

// The Network.framework subset Toastty's Remote Access gateway uses: a TCP
// listener and byte-stream connections (the gateway does HTTP and WebSocket
// framing itself). Implemented over non-blocking POSIX sockets and dispatch
// sources. Callbacks run on the queue passed to `start(queue:)`, like
// Network.framework.

public enum NWError: Error, Equatable, Sendable, CustomDebugStringConvertible {
    case posix(POSIXErrorCode)
    case dns(Int32)
    case tls(Int32)

    static func current() -> NWError {
        .posix(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    public var debugDescription: String {
        switch self {
        case .posix(let code): "POSIXErrorCode(\(code.rawValue)): \(String(cString: strerror(code.rawValue)))"
        case .dns(let code): "DNS error \(code)"
        case .tls(let code): "TLS error \(code)"
        }
    }
}

public struct IPv4Address: Hashable, Sendable {
    public let rawValue: Data
    public init?(_ rawValue: Data) {
        guard rawValue.count == 4 else { return nil }
        self.rawValue = rawValue
    }

    public init?(_ string: String) {
        var address = in_addr()
        guard inet_pton(AF_INET, string, &address) == 1 else { return nil }
        rawValue = withUnsafeBytes(of: &address) { Data($0) }
    }

    public static let loopback = IPv4Address("127.0.0.1")!
    public static let any = IPv4Address("0.0.0.0")!
}

public struct IPv6Address: Hashable, Sendable {
    public let rawValue: Data
    public init?(_ string: String) {
        var address = in6_addr()
        guard inet_pton(AF_INET6, string, &address) == 1 else { return nil }
        rawValue = withUnsafeBytes(of: &address) { Data($0) }
    }

    public static let loopback = IPv6Address("::1")!
    public static let any = IPv6Address("::")!
}

public enum NWEndpoint: Hashable, Sendable {
    case hostPort(host: Host, port: Port)

    public enum Host: Hashable, Sendable {
        case name(String, String?)
        case ipv4(IPv4Address)
        case ipv6(IPv6Address)
    }

    public struct Port: Hashable, Sendable, RawRepresentable {
        public let rawValue: UInt16
        public init?(rawValue: UInt16) { self.rawValue = rawValue }
        public static let any = Port(rawValue: 0)!
    }
}

public final class NWParameters: @unchecked Sendable {
    public var allowLocalEndpointReuse = false
    public var requiredLocalEndpoint: NWEndpoint?

    public init() {}

    /// A fresh TCP parameter object (Network.framework returns a new one too).
    public static var tcp: NWParameters { NWParameters() }
}

/// Resolved socket address for an endpoint.
struct SocketAddress {
    var storage = sockaddr_storage()
    var length: socklen_t = 0
    var family: Int32 = AF_INET

    init(endpoint: NWEndpoint) throws {
        guard case .hostPort(let host, let port) = endpoint else { throw NWError.posix(.EINVAL) }
        switch host {
        case .ipv4(let address):
            try self.init(ipv4: address.rawValue, port: port.rawValue)
        case .ipv6(let address):
            try self.init(ipv6: address.rawValue, port: port.rawValue)
        case .name(let name, _):
            if name == "localhost" {
                try self.init(ipv4: IPv4Address.loopback.rawValue, port: port.rawValue)
            } else if let v4 = IPv4Address(name) {
                try self.init(ipv4: v4.rawValue, port: port.rawValue)
            } else if let v6 = IPv6Address(name) {
                try self.init(ipv6: v6.rawValue, port: port.rawValue)
            } else {
                throw NWError.dns(-2)
            }
        }
    }

    private init(ipv4 raw: Data, port: UInt16) throws {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        _ = withUnsafeMutableBytes(of: &address.sin_addr) { raw.copyBytes(to: $0) }
        withUnsafeMutableBytes(of: &storage) { target in
            withUnsafeBytes(of: &address) { target.copyMemory(from: $0) }
        }
        length = socklen_t(MemoryLayout<sockaddr_in>.size)
        family = AF_INET
    }

    private init(ipv6 raw: Data, port: UInt16) throws {
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        _ = withUnsafeMutableBytes(of: &address.sin6_addr) { raw.copyBytes(to: $0) }
        withUnsafeMutableBytes(of: &storage) { target in
            withUnsafeBytes(of: &address) { target.copyMemory(from: $0) }
        }
        length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        family = AF_INET6
    }

    func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var storage = storage
        return withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }
}

private func setNonBlocking(_ fd: Int32) -> Bool {
    let flags = fcntl(fd, F_GETFL)
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
}

private func makeStreamSocket(family: Int32) -> Int32 {
    socket(family, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
}

// MARK: - Listener

public final class NWListener: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case setup
        case waiting(NWError)
        case ready
        case failed(NWError)
        case cancelled
    }

    public var newConnectionHandler: ((NWConnection) -> Void)? {
        get { lock.withLock { storedNewConnectionHandler } }
        set { lock.withLock { storedNewConnectionHandler = newValue } }
    }

    public var stateUpdateHandler: ((State) -> Void)? {
        get { lock.withLock { storedStateUpdateHandler } }
        set { lock.withLock { storedStateUpdateHandler = newValue } }
    }

    public private(set) var port: NWEndpoint.Port?

    private let parameters: NWParameters
    private let requestedPort: NWEndpoint.Port?
    private let lock = NSLock()
    private var storedNewConnectionHandler: ((NWConnection) -> Void)?
    private var storedStateUpdateHandler: ((State) -> Void)?
    private var queue: DispatchQueue?
    private var fd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var state: State = .setup

    public init(using parameters: NWParameters, on port: NWEndpoint.Port? = nil) throws {
        self.parameters = parameters
        requestedPort = port
    }

    public func start(queue: DispatchQueue) {
        self.queue = queue
        queue.async { self.open() }
    }

    public func cancel() {
        guard let queue else {
            transition(to: .cancelled)
            return
        }
        queue.async { self.close(final: .cancelled) }
    }

    private func open() {
        guard state == .setup else { return }
        let endpoint: NWEndpoint
        if let required = parameters.requiredLocalEndpoint {
            endpoint = required
        } else {
            endpoint = .hostPort(host: .ipv4(.any), port: requestedPort ?? .any)
        }
        let address: SocketAddress
        do {
            address = try SocketAddress(endpoint: endpoint)
        } catch {
            transition(to: .failed(error as? NWError ?? .posix(.EINVAL)))
            return
        }
        let fd = makeStreamSocket(family: address.family)
        guard fd >= 0 else {
            transition(to: .failed(.current()))
            return
        }
        var yes: Int32 = 1
        if parameters.allowLocalEndpointReuse {
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        }
        let bound = address.withSockaddr { bind(fd, $0, $1) }
        guard bound == 0, listen(fd, 128) == 0, setNonBlocking(fd) else {
            let error = NWError.current()
            Glibc.close(fd)
            transition(to: .failed(error))
            return
        }
        var boundAddress = sockaddr_storage()
        var boundLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &boundLength) }
        }
        let boundPort: UInt16 = withUnsafeBytes(of: &boundAddress) { raw in
            // sin_port and sin6_port share the offset after the family field.
            UInt16(bigEndian: raw.load(fromByteOffset: 2, as: UInt16.self))
        }
        port = NWEndpoint.Port(rawValue: boundPort)
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { Glibc.close(fd) }
        acceptSource = source
        source.resume()
        transition(to: .ready)
    }

    private func acceptPending() {
        while fd >= 0 {
            let client = Glibc.accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            guard setNonBlocking(client) else {
                Glibc.close(client)
                continue
            }
            var yes: Int32 = 1
            _ = setsockopt(client, Int32(IPPROTO_TCP), TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
            let connection = NWConnection(acceptedFileDescriptor: client)
            if let handler = newConnectionHandler {
                handler(connection)
            } else {
                connection.cancel()
            }
        }
    }

    private func close(final: State) {
        if let acceptSource {
            acceptSource.cancel()
            self.acceptSource = nil
        } else if fd >= 0 {
            Glibc.close(fd)
        }
        fd = -1
        transition(to: final)
    }

    private func transition(to newState: State) {
        if state == .cancelled { return }
        if case .failed = state, newState != .cancelled { return }
        state = newState
        stateUpdateHandler?(newState)
    }
}

// MARK: - Connection

public final class NWConnection: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case setup
        case waiting(NWError)
        case preparing
        case ready
        case failed(NWError)
        case cancelled
    }

    public final class ContentContext: @unchecked Sendable {
        public let identifier: String
        public let isFinal: Bool
        public init(identifier: String, isFinal: Bool = false) {
            self.identifier = identifier
            self.isFinal = isFinal
        }
        public static let defaultMessage = ContentContext(identifier: "default")
        public static let finalMessage = ContentContext(identifier: "final", isFinal: true)
        public static let defaultStream = ContentContext(identifier: "stream")
    }

    public enum SendCompletion: Sendable {
        case contentProcessed(@Sendable (NWError?) -> Void)
        case idempotent
    }

    public var stateUpdateHandler: ((State) -> Void)? {
        get { lock.withLock { storedStateUpdateHandler } }
        set { lock.withLock { storedStateUpdateHandler = newValue } }
    }

    public let endpoint: NWEndpoint?

    private struct PendingReceive: @unchecked Sendable {
        let minimum: Int
        let maximum: Int
        let completion: (Data?, ContentContext?, Bool, NWError?) -> Void
    }

    private struct PendingSend: @unchecked Sendable {
        var data: Data
        let completion: SendCompletion
        let closesWrite: Bool
    }

    private let lock = NSLock()
    private var storedStateUpdateHandler: ((State) -> Void)?
    private var queue: DispatchQueue?
    private var fd: Int32
    private var state: State = .setup
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var readSourceSuspended = true
    private var writeSourceSuspended = true
    private var pendingReceives: [PendingReceive] = []
    private var pendingSends: [PendingSend] = []
    private var inbound = Data()
    private var reachedEOF = false
    private var writeClosed = false

    init(acceptedFileDescriptor fd: Int32) {
        self.fd = fd
        endpoint = nil
    }

    deinit {
        // libdispatch traps when a suspended source is released, so resume
        // before cancelling. The cancel handlers close the descriptor.
        if let readSource {
            if readSourceSuspended { readSource.resume() }
            readSource.cancel()
        }
        if let writeSource {
            if writeSourceSuspended { writeSource.resume() }
            writeSource.cancel()
        }
        if readSource == nil, writeSource == nil, fd >= 0 {
            Glibc.close(fd)
        }
    }

    public init(host: NWEndpoint.Host, port: NWEndpoint.Port, using parameters: NWParameters) {
        _ = parameters
        fd = -1
        endpoint = .hostPort(host: host, port: port)
    }

    public convenience init(to endpoint: NWEndpoint, using parameters: NWParameters) {
        guard case .hostPort(let host, let port) = endpoint else {
            self.init(host: .ipv4(.loopback), port: .any, using: parameters)
            return
        }
        self.init(host: host, port: port, using: parameters)
    }

    public func start(queue: DispatchQueue) {
        self.queue = queue
        queue.async { self.open() }
    }

    public func cancel() {
        guard let queue else {
            if fd >= 0 { Glibc.close(fd); fd = -1 }
            transition(to: .cancelled)
            return
        }
        queue.async { self.tearDown(final: .cancelled, error: .posix(.ECANCELED)) }
    }

    public func receive(
        minimumIncompleteLength: Int,
        maximumLength: Int,
        completion: @escaping (Data?, ContentContext?, Bool, NWError?) -> Void
    ) {
        let pending = PendingReceive(
            minimum: max(1, minimumIncompleteLength),
            maximum: max(1, maximumLength),
            completion: completion
        )
        perform {
            guard self.isTerminal == false else {
                pending.completion(nil, nil, false, .posix(.ECANCELED))
                return
            }
            self.pendingReceives.append(pending)
            self.serviceReceives()
        }
    }

    public func send(
        content: Data?,
        contentContext: ContentContext = .defaultMessage,
        isComplete: Bool = true,
        completion: SendCompletion
    ) {
        let pending = PendingSend(
            data: content ?? Data(),
            completion: completion,
            closesWrite: contentContext.isFinal && isComplete
        )
        perform {
            guard self.isTerminal == false else {
                if case .contentProcessed(let completion) = pending.completion {
                    completion(.posix(.ECANCELED))
                }
                return
            }
            self.pendingSends.append(pending)
            self.serviceSends()
        }
    }

    // MARK: Internals (connection queue only)

    private func perform(_ body: @escaping @Sendable () -> Void) {
        if let queue {
            queue.async(execute: body)
        } else {
            // Not started: Network.framework queues work until start(queue:).
            let fallback = DispatchQueue(label: "toastty.nwconnection.unstarted")
            self.queue = fallback
            fallback.async { self.open(); body() }
        }
    }

    private func open() {
        guard state == .setup else { return }
        if fd < 0 {
            transition(to: .preparing)
            guard let endpoint else {
                transition(to: .failed(.posix(.EINVAL)))
                return
            }
            let address: SocketAddress
            do {
                address = try SocketAddress(endpoint: endpoint)
            } catch {
                transition(to: .failed(error as? NWError ?? .posix(.EINVAL)))
                return
            }
            let socketFD = makeStreamSocket(family: address.family)
            guard socketFD >= 0 else {
                transition(to: .failed(.current()))
                return
            }
            let connected = address.withSockaddr { Glibc.connect(socketFD, $0, $1) }
            guard connected == 0, setNonBlocking(socketFD) else {
                let error = NWError.current()
                Glibc.close(socketFD)
                transition(to: .failed(error))
                return
            }
            var yes: Int32 = 1
            _ = setsockopt(socketFD, Int32(IPPROTO_TCP), TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
            fd = socketFD
        }
        let fd = fd
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        read.setEventHandler { [weak self] in self?.readAvailable() }
        let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        write.setEventHandler { [weak self] in self?.serviceSends() }
        // The read source owns the descriptor: close after both are cancelled.
        let group = DispatchGroup()
        group.enter()
        group.enter()
        read.setCancelHandler { group.leave() }
        write.setCancelHandler { group.leave() }
        group.notify(queue: queue ?? .global()) { Glibc.close(fd) }
        readSource = read
        writeSource = write
        transition(to: .ready)
        serviceReceives()
        serviceSends()
    }

    private func readAvailable() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Glibc.read(fd, &buffer, buffer.count)
            if count > 0 {
                inbound.append(contentsOf: buffer[0..<count])
                if count < buffer.count { break }
                continue
            }
            if count == 0 {
                reachedEOF = true
                break
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            let error = NWError.current()
            failPendingReceives(error)
            tearDown(final: .failed(error), error: error)
            return
        }
        serviceReceives()
    }

    private func serviceReceives() {
        guard state == .ready else { return }
        while let next = pendingReceives.first {
            if inbound.count >= next.minimum || (reachedEOF && inbound.isEmpty == false) {
                let count = min(next.maximum, inbound.count)
                let chunk = inbound.prefix(count)
                inbound.removeFirst(count)
                pendingReceives.removeFirst()
                let complete = reachedEOF && inbound.isEmpty
                next.completion(Data(chunk), .defaultStream, complete, nil)
                continue
            }
            if reachedEOF {
                pendingReceives.removeFirst()
                next.completion(nil, .defaultStream, true, nil)
                continue
            }
            break
        }
        setReadSourceActive(pendingReceives.isEmpty == false && reachedEOF == false)
    }

    private func serviceSends() {
        guard state == .ready, fd >= 0 else { return }
        while var next = pendingSends.first {
            while next.data.isEmpty == false {
                let written = next.data.withUnsafeBytes { raw in
                    Glibc.send(fd, raw.baseAddress, raw.count, Int32(MSG_NOSIGNAL))
                }
                if written > 0 {
                    next.data.removeFirst(written)
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    pendingSends[0] = next
                    setWriteSourceActive(true)
                    return
                }
                let error = NWError.current()
                tearDown(final: .failed(error), error: error)
                return
            }
            pendingSends.removeFirst()
            if next.closesWrite && writeClosed == false {
                writeClosed = true
                _ = shutdown(fd, Int32(SHUT_WR))
            }
            if case .contentProcessed(let completion) = next.completion {
                completion(nil)
            }
        }
        setWriteSourceActive(false)
    }

    private func setReadSourceActive(_ active: Bool) {
        guard let readSource else { return }
        if active && readSourceSuspended {
            readSourceSuspended = false
            readSource.resume()
        } else if active == false && readSourceSuspended == false {
            readSourceSuspended = true
            readSource.suspend()
        }
    }

    private func setWriteSourceActive(_ active: Bool) {
        guard let writeSource else { return }
        if active && writeSourceSuspended {
            writeSourceSuspended = false
            writeSource.resume()
        } else if active == false && writeSourceSuspended == false {
            writeSourceSuspended = true
            writeSource.suspend()
        }
    }

    private func failPendingReceives(_ error: NWError) {
        let receives = pendingReceives
        pendingReceives.removeAll()
        for receive in receives {
            receive.completion(nil, nil, false, error)
        }
    }

    private func tearDown(final: State, error: NWError) {
        if state == .cancelled { return }
        let sends = pendingSends
        pendingSends.removeAll()
        for send in sends {
            if case .contentProcessed(let completion) = send.completion {
                completion(error)
            }
        }
        failPendingReceives(error)
        if let readSource, let writeSource {
            // Cancelling a suspended source never runs its cancel handler.
            if readSourceSuspended { readSourceSuspended = false; readSource.resume() }
            if writeSourceSuspended { writeSourceSuspended = false; writeSource.resume() }
            readSource.cancel()
            writeSource.cancel()
        } else if fd >= 0 {
            Glibc.close(fd)
        }
        readSource = nil
        writeSource = nil
        fd = -1
        transition(to: final)
    }

    private var isTerminal: Bool {
        switch state {
        case .cancelled, .failed: true
        default: false
        }
    }

    private func transition(to newState: State) {
        guard state != newState, state != .cancelled else { return }
        state = newState
        stateUpdateHandler?(newState)
    }
}
