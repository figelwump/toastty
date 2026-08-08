import Foundation
import CryptoKit

/// Minimal HTTP/1.1 request model for the remote-access gateway.
///
/// The gateway speaks plain HTTP on loopback only; Tailscale Serve terminates
/// HTTPS in front of it. Parsing is deliberately strict and small: one request
/// per buffer read, bounded sizes, no chunked bodies, no pipelining.
public struct RemoteGatewayHTTPRequest: Equatable, Sendable {
    public static let maximumHeaderBytes = 16 * 1024
    public static let maximumBodyBytes = 64 * 1024

    public var method: String
    /// Path only, query string stripped.
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup (headers are stored lowercased).
    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public var cookies: [String: String] {
        guard let cookieHeader = header("cookie") else { return [:] }
        var cookies: [String: String] = [:]
        for pair in cookieHeader.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            cookies[name] = value
        }
        return cookies
    }

    public enum ParseOutcome: Equatable, Sendable {
        /// A full request was parsed; `consumedBytes` may be less than the
        /// buffer when trailing bytes follow the body.
        case request(RemoteGatewayHTTPRequest, consumedBytes: Int)
        /// More data is needed for a complete head or body.
        case needMoreData
        /// The buffer can never become a valid request; close the connection.
        case invalid
    }

    /// Parses one request from the start of `buffer`.
    public static func parse(_ buffer: Data) -> ParseOutcome {
        let separator = Data("\r\n\r\n".utf8)
        guard let headEndRange = buffer.range(of: separator) else {
            return buffer.count > maximumHeaderBytes ? .invalid : .needMoreData
        }
        guard headEndRange.lowerBound <= maximumHeaderBytes else { return .invalid }

        guard let headText = String(data: buffer[buffer.startIndex..<headEndRange.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        var lines = headText.components(separatedBy: "\r\n")
        guard lines.isEmpty == false else { return .invalid }
        let requestLine = lines.removeFirst()
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count == 3,
              requestParts[2].hasPrefix("HTTP/1.") else {
            return .invalid
        }
        let method = String(requestParts[0])
        let target = String(requestParts[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target

        var headers: [String: String] = [:]
        for line in lines where line.isEmpty == false {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return .invalid }
            headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                parts[1].trimmingCharacters(in: .whitespaces)
        }

        let bodyStart = headEndRange.upperBound
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard contentLength >= 0, contentLength <= maximumBodyBytes else { return .invalid }
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else {
            return .needMoreData
        }
        let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: contentLength)])
        let consumed = buffer.distance(from: buffer.startIndex, to: bodyStart) + contentLength
        return .request(
            RemoteGatewayHTTPRequest(method: method, path: path, headers: headers, body: body),
            consumedBytes: consumed
        )
    }
}

/// HTTP response builder with the gateway's fixed security headers.
public struct RemoteGatewayHTTPResponse: Equatable, Sendable {
    public var status: Int
    public var reason: String
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, reason: String, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.reason = reason
        self.headers = headers
        self.body = body
    }

    public static func == (lhs: RemoteGatewayHTTPResponse, rhs: RemoteGatewayHTTPResponse) -> Bool {
        lhs.status == rhs.status
            && lhs.reason == rhs.reason
            && lhs.body == rhs.body
            && lhs.headers.elementsEqual(rhs.headers, by: ==)
    }

    public static func json(status: Int = 200, reason: String = "OK", body: Data, extraHeaders: [(String, String)] = []) -> RemoteGatewayHTTPResponse {
        RemoteGatewayHTTPResponse(
            status: status,
            reason: reason,
            headers: [("Content-Type", "application/json; charset=utf-8")] + extraHeaders,
            body: body
        )
    }

    public static func text(status: Int, reason: String, _ message: String) -> RemoteGatewayHTTPResponse {
        RemoteGatewayHTTPResponse(
            status: status,
            reason: reason,
            headers: [("Content-Type", "text/plain; charset=utf-8")],
            body: Data(message.utf8)
        )
    }

    /// Serializes with security headers appropriate for a same-origin app
    /// shell: no caching, no sniffing, no framing, and a conservative CSP.
    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var allHeaders = headers
        allHeaders.append(("Content-Length", String(body.count)))
        allHeaders.append(("Cache-Control", "no-store"))
        allHeaders.append(("X-Content-Type-Options", "nosniff"))
        allHeaders.append(("X-Frame-Options", "DENY"))
        allHeaders.append(("Referrer-Policy", "no-referrer"))
        allHeaders.append(("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'"))
        allHeaders.append(("Connection", "close"))
        for (name, value) in allHeaders {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// RFC 6455 handshake helpers.
public enum RemoteGatewayWebSocketHandshake {
    public static func isUpgradeRequest(_ request: RemoteGatewayHTTPRequest) -> Bool {
        request.method == "GET"
            && request.header("upgrade")?.lowercased() == "websocket"
            && request.header("sec-websocket-key") != nil
    }

    public static func acceptKey(forClientKey clientKey: String) -> String {
        let magic = clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }

    /// The 101 response completing the upgrade. Serialized manually because it
    /// must not carry Connection: close.
    public static func upgradeResponseData(forClientKey clientKey: String) -> Data {
        let head = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(acceptKey(forClientKey: clientKey))\r\n"
            + "\r\n"
        return Data(head.utf8)
    }
}
