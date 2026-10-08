import Foundation

public struct PushRelayBeginResponse: Codable, Equatable, Sendable {
    public var registrationID: UUID
    public var state: String
    public var expiresAt: TimeInterval?
    public init(registrationID: UUID, state: String, expiresAt: TimeInterval? = nil) {
        self.registrationID = registrationID; self.state = state; self.expiresAt = expiresAt
    }
}

public struct PushRelayStatus: Codable, Equatable, Sendable {
    public var registrationID: UUID
    public var pairingID: UUID
    public var state: String
    public init(registrationID: UUID, pairingID: UUID, state: String) {
        self.registrationID = registrationID; self.pairingID = pairingID; self.state = state
    }
}

public enum PushRelayFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidResponse
    case network
    case unavailable
    case expired
    case invalidDeviceToken
    case rateLimited(retryAfter: TimeInterval)
    public var description: String { "<redacted push relay failure>" }
}

public protocol PushRelayClientProtocol: Sendable {
    func begin(_ registration: MobilePushRegistration) async throws -> PushRelayBeginResponse
    func complete(_ registration: MobilePushRegistration, nonce: String) async throws -> PushRelayStatus
    func status(_ registration: MobilePushRegistration) async throws -> PushRelayStatus
    func revoke(_ registration: MobilePushRegistration) async throws
}

public struct PushRelayClient: PushRelayClientProtocol {
    public let baseURL: URL
    private let transport: any HTTPTransport
    public init(baseURL: URL, transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.baseURL = baseURL; self.transport = transport
    }

    public static func isValidOrigin(_ url: URL) -> Bool {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return value.scheme == "https" && value.host?.isEmpty == false
            && value.user == nil && value.password == nil && value.query == nil && value.fragment == nil
            && (value.path.isEmpty || value.path == "/") && (value.port == nil || value.port == 443)
    }

    public func begin(_ registration: MobilePushRegistration) async throws -> PushRelayBeginResponse {
        let body = Begin(registrationID: registration.registrationID.uuidString.lowercased(), deviceToken: registration.deviceToken,
                         pairingID: registration.pairingID.uuidString.lowercased(), managementToken: registration.managementToken,
                         sendToken: registration.sendToken)
        let response = try await send(method: "POST", path: "/v1/registrations", token: nil, body: body)
        let value: PushRelayBeginResponse = try decode(response.body)
        guard value.registrationID == registration.registrationID,
              value.state == "pending" || value.state == "active",
              value.state == "active" || (value.expiresAt.map { $0.isFinite && $0 > 0 } ?? false)
        else { throw PushRelayFailure.invalidResponse }
        return value
    }

    public func complete(_ registration: MobilePushRegistration, nonce: String) async throws -> PushRelayStatus {
        guard KeychainMobilePushStateStore.isCapability(nonce) else { throw PushRelayFailure.invalidResponse }
        let response = try await send(method: "POST", path: path(registration) + "/complete",
                                      token: registration.managementToken, body: Proof(nonce: nonce))
        let value = try validatedStatus(response.body, registration: registration)
        guard value.state == "active" else { throw PushRelayFailure.invalidResponse }
        return value
    }

    public func status(_ registration: MobilePushRegistration) async throws -> PushRelayStatus {
        let response = try await send(method: "GET", path: path(registration),
                                      token: registration.managementToken, body: Optional<Proof>.none)
        return try validatedStatus(response.body, registration: registration)
    }

    public func revoke(_ registration: MobilePushRegistration) async throws {
        do {
            _ = try await send(method: "DELETE", path: path(registration),
                               token: registration.managementToken, body: Optional<Proof>.none)
        } catch PushRelayFailure.expired { return }
    }

    private func validatedStatus(_ body: Data, registration: MobilePushRegistration) throws -> PushRelayStatus {
        let value: PushRelayStatus = try decode(body)
        guard value.registrationID == registration.registrationID, value.pairingID == registration.pairingID,
              ["active", "pending"].contains(value.state) else { throw PushRelayFailure.invalidResponse }
        return value
    }

    private func path(_ value: MobilePushRegistration) -> String {
        "/v1/registrations/" + value.registrationID.uuidString.lowercased()
    }

    private func send<Body: Encodable>(method: String, path: String, token: String?, body: Body?) async throws -> HTTPTransportResponse {
        guard Self.isValidOrigin(baseURL), var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw PushRelayFailure.invalidResponse
        }
        components.path = path
        guard let url = components.url else { throw PushRelayFailure.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            let data = try JSONEncoder().encode(body)
            guard data.count <= 4096 else { throw PushRelayFailure.invalidResponse }
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let response: HTTPTransportResponse
        do { response = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw PushRelayFailure.network }
        guard (200..<300).contains(response.statusCode) else {
            let object = response.body.count <= 4096 ? (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] : nil
            let code = object?["error"] as? String
            if response.statusCode == 429 {
                let parsed = TimeInterval(response.header("retry-after") ?? "")
                let seconds = parsed.flatMap { $0.isFinite ? $0 : nil } ?? 60
                throw PushRelayFailure.rateLimited(retryAfter: max(1, min(seconds, 86_400)))
            }
            if code == "invalid_device_token" {
                throw PushRelayFailure.invalidDeviceToken
            }
            if [404, 409, 410].contains(response.statusCode) || code == "challenge_expired" {
                throw PushRelayFailure.expired
            }
            throw PushRelayFailure.unavailable
        }
        guard response.body.count <= 4096 else { throw PushRelayFailure.invalidResponse }
        return response
    }

    private func decode<Value: Decodable>(_ body: Data) throws -> Value {
        guard let value = try? JSONDecoder().decode(Value.self, from: body) else { throw PushRelayFailure.invalidResponse }
        return value
    }

    private struct Begin: Encodable {
        let registrationID: String; let deviceToken: String; let pairingID: String
        let managementToken: String; let sendToken: String
    }
    private struct Proof: Encodable { let nonce: String }
}
