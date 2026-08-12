import Foundation
import RemoteProtocol

public enum GatewayCredential: Equatable, Sendable, CustomStringConvertible {
    case cookie(name: String, value: String)
    case bearer(token: String)

    public var description: String { "<redacted gateway credential>" }
}

public protocol GatewayCredentialProvider: Sendable {
    func credential() async throws -> GatewayCredential?
}

public struct StaticGatewayCredentialProvider: GatewayCredentialProvider {
    private let storedCredential: GatewayCredential?

    public init(_ credential: GatewayCredential?) {
        storedCredential = credential
    }

    public func credential() async throws -> GatewayCredential? { storedCredential }
}

public enum GatewayAPIErrorCode: String, Equatable, Sendable {
    case invalidBody = "invalid_body"
    case invalidCode = "invalid_code"
    case notFound = "not_found"
    case originDenied = "origin_denied"
    case originRequired = "origin_required"
    case persistenceFailed = "persistence_failed"
    case rateLimited = "rate_limited"
    case unauthorized
    case upgradeRequired = "upgrade_required"
}

public enum GatewayFailure: Error, Equatable, Sendable {
    case network
    case unauthenticated(code: GatewayAPIErrorCode?, message: String?)
    case authorizationDenied(code: GatewayAPIErrorCode?, message: String?)
    case rateLimited(message: String?)
    case server(statusCode: Int, code: GatewayAPIErrorCode?, message: String?)
    case http(statusCode: Int, code: GatewayAPIErrorCode?, message: String?)
    case protocolMismatch(version: String)
    case operationCompatibility(GatewayCompatibilityError)
    case invalidResponse

    public var isRetryable: Bool {
        switch self {
        case .network, .server:
            true
        case .unauthenticated, .authorizationDenied, .rateLimited, .http,
             .protocolMismatch, .operationCompatibility, .invalidResponse:
            false
        }
    }
}

public protocol GatewayClientProtocol: Sendable {
    func hello() async throws -> RemoteGatewayHelloResponse
    func pair(_ request: RemoteGatewayPairRequest) async throws -> RemoteGatewayPairResponse
    func sessions() async throws -> CompatibleSessionListSnapshot
    func events(
        conversationID: RemoteConversationID,
        cursor: ConversationEventCursor?,
        limit: Int?
    ) async throws -> CompatibleGatewayEventsResponse
    func send(_ request: RemoteMessageSendRequest) async throws -> RemoteMessageSendResult
}

public struct GatewayClient: GatewayClientProtocol, Sendable {
    public let baseURL: URL

    private let transport: any HTTPTransport
    private let credentialProvider: any GatewayCredentialProvider
    private let compatibilityDecoder: GatewayCompatibilityDecoder

    public init(
        baseURL: URL,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        credentialProvider: any GatewayCredentialProvider = StaticGatewayCredentialProvider(nil),
        compatibilityDecoder: GatewayCompatibilityDecoder = GatewayCompatibilityDecoder()
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.credentialProvider = credentialProvider
        self.compatibilityDecoder = compatibilityDecoder
    }

    public func hello() async throws -> RemoteGatewayHelloResponse {
        let response = try await perform(method: "GET", path: "/api/hello", authenticated: false)
        return try mapCompatibility { try compatibilityDecoder.decodeHello(response.body) }
    }

    public func pair(_ request: RemoteGatewayPairRequest) async throws -> RemoteGatewayPairResponse {
        let response = try await perform(
            method: "POST",
            path: "/api/pair",
            body: try encode(request),
            authenticated: false,
            sendsOrigin: true
        )
        return try mapCompatibility { try compatibilityDecoder.decodePairResponse(response.body) }
    }

    public func sessions() async throws -> CompatibleSessionListSnapshot {
        let response = try await perform(method: "GET", path: "/api/sessions")
        return try mapCompatibility { try compatibilityDecoder.decodeSessionListResponse(response.body) }
    }

    public func events(
        conversationID: RemoteConversationID,
        cursor: ConversationEventCursor? = nil,
        limit: Int? = nil
    ) async throws -> CompatibleGatewayEventsResponse {
        let body = try encode(RemoteGatewayEventsRequest(
            conversationID: conversationID,
            cursor: cursor,
            limit: limit
        ))
        let response = try await perform(
            method: "POST",
            path: "/api/conversation.events.get",
            body: body,
            sendsOrigin: true
        )
        return try mapCompatibility { try compatibilityDecoder.decodeEventsResponse(response.body) }
    }

    public func send(_ request: RemoteMessageSendRequest) async throws -> RemoteMessageSendResult {
        let urlRequest = try await makeRequest(
            method: "POST",
            path: "/api/conversation.message.send",
            body: try encode(request),
            authenticated: true,
            sendsOrigin: true
        )
        let response = try await sendTransportRequest(urlRequest)

        if response.statusCode == 403, Self.isSendResultEnvelope(response.body) {
            let result = try mapCompatibility { try compatibilityDecoder.decodeSendResult(response.body) }
            if result == .rejected(reason: .sendScopeDenied) {
                return result
            }
        }
        guard (200..<300).contains(response.statusCode) else {
            throw try classifyHTTPError(response)
        }
        return try mapCompatibility { try compatibilityDecoder.decodeSendResult(response.body) }
    }

    private func perform(
        method: String,
        path: String,
        body: Data? = nil,
        authenticated: Bool = true,
        sendsOrigin: Bool = false
    ) async throws -> HTTPTransportResponse {
        let request = try await makeRequest(
            method: method,
            path: path,
            body: body,
            authenticated: authenticated,
            sendsOrigin: sendsOrigin
        )
        let response = try await sendTransportRequest(request)
        guard (200..<300).contains(response.statusCode) else {
            throw try classifyHTTPError(response)
        }
        return response
    }

    private func makeRequest(
        method: String,
        path: String,
        body: Data?,
        authenticated: Bool,
        sendsOrigin: Bool
    ) async throws -> URLRequest {
        guard let url = endpointURL(path: path) else { throw GatewayFailure.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if sendsOrigin {
            guard let origin = gatewayOrigin else { throw GatewayFailure.invalidResponse }
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        if authenticated, let credential = try await credentialProvider.credential() {
            Self.apply(credential, to: &request)
        }
        return request
    }

    private func sendTransportRequest(_ request: URLRequest) async throws -> HTTPTransportResponse {
        do {
            return try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as GatewayFailure {
            throw failure
        } catch {
            throw GatewayFailure.network
        }
    }

    private func classifyHTTPError(_ response: HTTPTransportResponse) throws -> GatewayFailure {
        let isServerFailure = (500...599).contains(response.statusCode)
        let errorBody = try decodeErrorBody(
            response.body,
            toleratesUnsupportedCode: isServerFailure
        )
        switch response.statusCode {
        case 401:
            return .unauthenticated(code: errorBody?.code, message: errorBody?.message)
        case 403:
            return .authorizationDenied(code: errorBody?.code, message: errorBody?.message)
        case 429:
            return .rateLimited(message: errorBody?.message)
        case 500...599:
            return .server(statusCode: response.statusCode, code: errorBody?.code, message: errorBody?.message)
        default:
            return .http(statusCode: response.statusCode, code: errorBody?.code, message: errorBody?.message)
        }
    }

    private func decodeErrorBody(
        _ data: Data,
        toleratesUnsupportedCode: Bool = false
    ) throws -> (code: GatewayAPIErrorCode?, message: String?)? {
        guard data.isEmpty == false else { return nil }
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawCode = value["code"] as? String else {
            return nil
        }
        if let version = value["protocolVersion"] as? String,
           version != RemoteGatewayProtocol.version {
            throw GatewayFailure.protocolMismatch(version: version)
        }
        guard let code = GatewayAPIErrorCode(rawValue: rawCode) else {
            if toleratesUnsupportedCode {
                return (nil, value["message"] as? String)
            }
            throw GatewayFailure.operationCompatibility(.unsupportedAPIErrorCode(rawCode))
        }
        return (code, value["message"] as? String)
    }

    private func mapCompatibility<Value>(_ operation: () throws -> Value) throws -> Value {
        do {
            return try operation()
        } catch GatewayCompatibilityError.unsupportedProtocolVersion(let version) {
            throw GatewayFailure.protocolMismatch(version: version)
        } catch let error as GatewayCompatibilityError {
            throw GatewayFailure.operationCompatibility(error)
        } catch {
            throw GatewayFailure.invalidResponse
        }
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            return try ConversationEventCoding.makeEncoder().encode(value)
        } catch {
            throw GatewayFailure.invalidResponse
        }
    }

    private func endpointURL(path: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme == "http" || components.scheme == "https",
              components.host != nil else { return nil }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private var gatewayOrigin: String? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme == "http" || components.scheme == "https",
              components.host != nil else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func isSendResultEnvelope(_ data: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return value["status"] is String
    }

    static func apply(_ credential: GatewayCredential, to request: inout URLRequest) {
        switch credential {
        case .cookie(let name, let value):
            request.setValue("\(name)=\(value)", forHTTPHeaderField: "Cookie")
        case .bearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
}
