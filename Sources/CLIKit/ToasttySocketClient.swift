import CoreState
import Darwin
import Foundation

struct ToasttySocketClient {
    let socketPath: String
    let timeoutInterval: TimeInterval

    init(socketPath: String, timeoutInterval: TimeInterval = 10) {
        self.socketPath = socketPath
        self.timeoutInterval = timeoutInterval
    }

    func send<T: Encodable>(_ envelope: T) throws -> AutomationResponseEnvelope {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(envelope) + Data([0x0A])
        let responseData = try send(payload: payload)
        return try JSONDecoder().decode(AutomationResponseEnvelope.self, from: responseData)
    }

    private func send(payload: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ToasttyCLIError.runtime("socket() failed: \(socketErrorMessage())")
        }
        defer { close(fd) }

        try configureTimeouts(for: fd)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxPathLength else {
            throw ToasttyCLIError.runtime("socket path too long: \(socketPath)")
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                if let destinationAddress = buffer.baseAddress, let sourceAddress = source.baseAddress {
                    memcpy(destinationAddress, sourceAddress, pathBytes.count)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw ToasttyCLIError.runtime("connect() failed: \(socketErrorMessage())")
        }

        try writeAll(payload, to: fd)

        var response = Data()
        var byte: UInt8 = 0
        while true {
            let bytesRead = read(fd, &byte, 1)
            if bytesRead == 0 {
                break
            }
            if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw ToasttyCLIError.runtime("read() timed out waiting for Toastty response")
                }
                throw ToasttyCLIError.runtime("read() failed: \(socketErrorMessage())")
            }
            if byte == 0x0A {
                return response
            }
            response.append(byte)
        }

        throw ToasttyCLIError.runtime("socket response did not include a newline terminator")
    }

    private func writeAll(_ payload: Data, to fileDescriptor: Int32) throws {
        try payload.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }

            let payloadSize = buffer.count
            var totalBytesWritten = 0
            while totalBytesWritten < payloadSize {
                let nextPointer = baseAddress.advanced(by: totalBytesWritten)
                let bytesWritten = write(fileDescriptor, nextPointer, payloadSize - totalBytesWritten)
                if bytesWritten < 0 {
                    if errno == EINTR {
                        continue
                    }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw ToasttyCLIError.runtime("write() timed out waiting for Toastty")
                    }
                    throw ToasttyCLIError.runtime("write() failed: \(socketErrorMessage())")
                }
                guard bytesWritten > 0 else {
                    throw ToasttyCLIError.runtime("write() returned 0 bytes")
                }
                totalBytesWritten += bytesWritten
            }
        }
    }

    private func configureTimeouts(for fileDescriptor: Int32) throws {
        let normalizedInterval = max(timeoutInterval, 0.1)
        let wholeSeconds = Int(normalizedInterval.rounded(.down))
        let fractionalSeconds = normalizedInterval - Double(wholeSeconds)
        let microseconds = Int((fractionalSeconds * 1_000_000).rounded())
        var timeout = timeval(tv_sec: wholeSeconds, tv_usec: __darwin_suseconds_t(microseconds))
        try setSocketOption(SO_RCVTIMEO, timeout: &timeout, for: fileDescriptor, label: "read")
        try setSocketOption(SO_SNDTIMEO, timeout: &timeout, for: fileDescriptor, label: "write")
    }

    private func setSocketOption(
        _ option: Int32,
        timeout: inout timeval,
        for fileDescriptor: Int32,
        label: String
    ) throws {
        let result = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                option,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard result == 0 else {
            throw ToasttyCLIError.runtime("failed to configure socket \(label) timeout: \(socketErrorMessage())")
        }
    }

    private func socketErrorMessage() -> String {
        String(cString: strerror(errno))
    }
}
