import RemoteProtocol
import Foundation
import CryptoKit

/// Minimal HTTP/1.1 request model for the remote-access gateway.
///
/// The gateway speaks plain HTTP on loopback only; Tailscale Serve terminates
/// HTTPS in front of it. Parsing is deliberately strict and small: one request
/// per buffer read, bounded sizes, no chunked bodies, no pipelining.
public struct RemoteGatewayHTTPRequest: Equatable, Sendable {
    public static let maximumHeaderBytes = 16 * 1024
    public static let maximumBodyBytes = RemoteGatewayProtocol.maximumRequestBodyBytes

    public var method: String
    /// Path only, query string stripped.
    public var path: String
    public var headers: [String: String]
    public var body: Data

    /// All values for each header name, preserving repeated fields so callers
    /// can reject ambiguous security-sensitive input. `headers` remains the
    /// convenient single-value view for existing callers.
    private var repeatedHeaderValues: [String: [String]]

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.init(
            method: method,
            path: path,
            headerFields: headers.map { ($0.key, $0.value) },
            body: body
        )
    }

    /// Field-list initializer used by the parser and security-focused tests.
    /// Unlike the dictionary initializer, it preserves duplicate fields.
    public init(
        method: String,
        path: String,
        headerFields: [(String, String)],
        body: Data
    ) {
        var values: [String: [String]] = [:]
        for (name, value) in headerFields {
            values[name.lowercased(), default: []].append(value)
        }
        self.init(method: method, path: path, headerValues: values, body: body)
    }

    private init(
        method: String,
        path: String,
        headerValues: [String: [String]],
        body: Data
    ) {
        self.method = method
        self.path = path
        self.repeatedHeaderValues = headerValues
        self.headers = headerValues.compactMapValues(\.last)
        self.body = body
    }

    /// Case-insensitive header lookup (headers are stored lowercased).
    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Returns every separately presented field value for `name`.
    public func headerValues(_ name: String) -> [String] {
        repeatedHeaderValues[name.lowercased()] ?? []
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
    public static func parse(_ buffer: Data, headersOnly: Bool = false) -> ParseOutcome {
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
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard requestParts.count == 3,
              requestParts.allSatisfy({ $0.isEmpty == false }),
              isHTTPToken(requestParts[0]),
              requestParts[2] == "HTTP/1.0" || requestParts[2] == "HTTP/1.1" else {
            return .invalid
        }
        let method = String(requestParts[0])
        let target = String(requestParts[1])
        guard target.first == "/",
              target.contains("#") == false,
              target.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
            return .invalid
        }
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target

        var headerValues: [String: [String]] = [:]
        for line in lines where line.isEmpty == false {
            // Reject obsolete line folding and whitespace before the colon;
            // security-sensitive duplicates must remain unambiguous.
            guard line.first != " ", line.first != "\t",
                  let colon = line.firstIndex(of: ":") else { return .invalid }
            let rawName = line[..<colon]
            guard rawName.isEmpty == false, isHTTPToken(rawName) else { return .invalid }
            let rawValue = line[line.index(after: colon)...]
            guard isValidHTTPFieldValue(rawValue) else { return .invalid }
            let name = rawName.lowercased()
            headerValues[name, default: []].append(trimHTTPWhitespace(rawValue))
        }

        let bodyStart = headEndRange.upperBound
        guard headerValues["host"]?.count ?? 0 <= 1,
              headerValues["content-length"]?.count ?? 0 <= 1,
              headerValues["transfer-encoding"] == nil else { return .invalid }
        let contentLength: Int
        if let rawContentLength = headerValues["content-length"]?.first {
            guard rawContentLength.isEmpty == false,
                  rawContentLength.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
                  let parsedContentLength = Int(rawContentLength) else {
                return .invalid
            }
            contentLength = parsedContentLength
        } else {
            contentLength = 0
        }
        let isAttachmentRoute = path == RemoteAttachmentPolicy.sendPath
        guard !isAttachmentRoute || headerValues["content-length"] != nil else { return .invalid }
        let limit = isAttachmentRoute ? RemoteAttachmentPolicy.maximumEncodedBodyBytes : maximumBodyBytes
        guard contentLength >= 0, contentLength <= limit else { return .invalid }
        if headersOnly {
            return .request(RemoteGatewayHTTPRequest(method: method, path: path, headerValues: headerValues, body: Data()),
                            consumedBytes: buffer.distance(from: buffer.startIndex, to: bodyStart))
        }
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else {
            return .needMoreData
        }
        let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: contentLength)])
        let consumed = buffer.distance(from: buffer.startIndex, to: bodyStart) + contentLength
        return .request(
            RemoteGatewayHTTPRequest(method: method, path: path, headerValues: headerValues, body: body),
            consumedBytes: consumed
        )
    }

    private static func isHTTPToken<S: StringProtocol>(_ value: S) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 33, 35...39, 42, 43, 45, 46, 48...57, 65...90, 94...122, 124, 126:
                true
            default:
                false
            }
        }
    }

    private static func isValidHTTPFieldValue<S: StringProtocol>(_ value: S) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x09 || scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }

    private static func trimHTTPWhitespace<S: StringProtocol>(_ value: S) -> String {
        var start = value.startIndex
        var end = value.endIndex
        while start < end, value[start] == " " || value[start] == "\t" {
            start = value.index(after: start)
        }
        while start < end {
            let previous = value.index(before: end)
            guard value[previous] == " " || value[previous] == "\t" else { break }
            end = previous
        }
        return String(value[start..<end])
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
