import Foundation

/// Blocking loopback TCP client used off the main actor, so tests exercise
/// the gateway's own framing independently of the Network shim.
final class RawTCPConnection: @unchecked Sendable {
    private let fd: Int32
    private var buffer = [UInt8]()

    init(port: UInt16) throws {
        fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            Glibc.close(fd)
            throw RawSocketError.connectFailed(errno)
        }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func write(_ data: Data) throws {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Glibc.send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            guard written > 0 else { throw RawSocketError.writeFailed(errno) }
            offset += written
        }
    }

    /// Reads at least `count` bytes beyond what is buffered; returns false on EOF.
    private func fill(minimum count: Int) throws -> Bool {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while buffer.count < count {
            let read = Glibc.read(fd, &chunk, chunk.count)
            if read == 0 { return false }
            guard read > 0 else { throw RawSocketError.readFailed(errno) }
            buffer.append(contentsOf: chunk[0..<read])
        }
        return true
    }

    func readUntil(_ delimiter: [UInt8]) throws -> [UInt8] {
        while true {
            if let range = buffer.firstRange(of: delimiter) {
                let head = Array(buffer[..<range.upperBound])
                buffer.removeFirst(range.upperBound)
                return head
            }
            guard try fill(minimum: buffer.count + 1) else { throw RawSocketError.unexpectedEOF }
        }
    }

    func readExactly(_ count: Int) throws -> [UInt8] {
        guard try fill(minimum: count) else { throw RawSocketError.unexpectedEOF }
        let head = Array(buffer[..<count])
        buffer.removeFirst(count)
        return head
    }

    func readToEnd() throws -> [UInt8] {
        while try fill(minimum: buffer.count + 1) {}
        defer { buffer.removeAll() }
        return buffer
    }

    func close() {
        Glibc.close(fd)
    }
}

enum RawSocketError: Error {
    case connectFailed(Int32)
    case writeFailed(Int32)
    case readFailed(Int32)
    case unexpectedEOF
    case badResponse(String)
}

struct RawHTTPClient: Sendable {
    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    let port: UInt16

    /// `requestLine` is "METHOD /path". One request per connection.
    func request(_ requestLine: String, headers: [String: String] = [:], body: Data? = nil) async throws -> Response {
        let port = port
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    let connection = try RawTCPConnection(port: port)
                    defer { connection.close() }
                    var head = "\(requestLine) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n"
                    for (name, value) in headers { head += "\(name): \(value)\r\n" }
                    head += "Content-Length: \(body?.count ?? 0)\r\n\r\n"
                    try connection.write(Data(head.utf8) + (body ?? Data()))
                    let responseHead = String(decoding: try connection.readUntil(Array("\r\n\r\n".utf8)), as: UTF8.self)
                    let lines = responseHead.components(separatedBy: "\r\n")
                    let statusParts = lines.first?.split(separator: " ") ?? []
                    guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
                        throw RawSocketError.badResponse(responseHead)
                    }
                    var responseHeaders: [String: String] = [:]
                    for line in lines.dropFirst() where line.contains(":") {
                        let parts = line.split(separator: ":", maxSplits: 1)
                        responseHeaders[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
                    }
                    let bodyBytes: [UInt8]
                    if let length = responseHeaders["content-length"].flatMap(Int.init) {
                        bodyBytes = try connection.readExactly(length)
                    } else {
                        bodyBytes = try connection.readToEnd()
                    }
                    return Response(status: status, headers: responseHeaders, body: Data(bodyBytes))
                })
            }
        }
    }
}

/// Minimal RFC 6455 client: masked frames out, unmasked text frames in.
final class RawWebSocketClient: @unchecked Sendable {
    private let connection: RawTCPConnection

    private init(connection: RawTCPConnection) {
        self.connection = connection
    }

    static func connect(port: UInt16, path: String, headers: [String: String]) async throws -> RawWebSocketClient {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    let connection = try RawTCPConnection(port: port)
                    let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
                    var head = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    head += "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
                    for (name, value) in headers { head += "\(name): \(value)\r\n" }
                    head += "\r\n"
                    try connection.write(Data(head.utf8))
                    let response = String(decoding: try connection.readUntil(Array("\r\n\r\n".utf8)), as: UTF8.self)
                    guard response.hasPrefix("HTTP/1.1 101") else {
                        connection.close()
                        throw RawSocketError.badResponse(response)
                    }
                    return RawWebSocketClient(connection: connection)
                })
            }
        }
    }

    enum Frame: Sendable, Equatable {
        case text(String)
        case close(code: UInt16?)
    }

    /// The next text or close frame (pings/pongs are skipped).
    func receiveFrame() async throws -> Frame {
        let connection = connection
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    while true {
                        let header = try connection.readExactly(2)
                        let opcode = header[0] & 0x0F
                        var length = Int(header[1] & 0x7F)
                        if length == 126 {
                            let extended = try connection.readExactly(2)
                            length = Int(extended[0]) << 8 | Int(extended[1])
                        } else if length == 127 {
                            let extended = try connection.readExactly(8)
                            length = extended.reduce(0) { $0 << 8 | Int($1) }
                        }
                        let payload = try connection.readExactly(length)
                        switch opcode {
                        case 0x1: return .text(String(decoding: payload, as: UTF8.self))
                        case 0x8: return .close(code: payload.count >= 2 ? UInt16(payload[0]) << 8 | UInt16(payload[1]) : nil)
                        default: continue
                        }
                    }
                })
            }
        }
    }

    /// The next text frame's payload (control frames are skipped).
    func receiveText(timeout: TimeInterval) async throws -> String {
        let connection = connection
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    while true {
                        let header = try connection.readExactly(2)
                        let opcode = header[0] & 0x0F
                        var length = Int(header[1] & 0x7F)
                        if length == 126 {
                            let extended = try connection.readExactly(2)
                            length = Int(extended[0]) << 8 | Int(extended[1])
                        } else if length == 127 {
                            let extended = try connection.readExactly(8)
                            length = extended.reduce(0) { $0 << 8 | Int($1) }
                        }
                        let payload = try connection.readExactly(length)
                        if opcode == 0x1 {
                            return String(decoding: payload, as: UTF8.self)
                        }
                        if opcode == 0x8 { throw RawSocketError.unexpectedEOF }
                    }
                })
            }
        }
    }

    func close() {
        // Masked close frame, code 1000.
        let mask: [UInt8] = [1, 2, 3, 4]
        let payload: [UInt8] = [0x03, 0xE8]
        let masked = payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        try? connection.write(Data([0x88, 0x80 | UInt8(payload.count)] + mask + masked))
        connection.close()
    }
}
