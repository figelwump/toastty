import CoreState
import Foundation
import RemoteProtocol

enum RemotePushSendOutcome: Equatable, Sendable {
    case accepted
    case registrationUnavailable
    /// The relay refused this alert's content (HTTP 400). A relay deployed
    /// before task alerts refuses every task alert this way, and accepted
    /// none of it, so the caller can send an older alert kind instead.
    case unsupportedAlert
    case dropped
}

protocol RemotePushRelaying: Sendable {
    func send(_ notification: RemotePushSessionNotification, to registration: RemoteDevicePushRegistration) async -> RemotePushSendOutcome
    func send(_ notification: RemotePushTaskNotification, to registration: RemoteDevicePushRegistration) async -> RemotePushSendOutcome
    func revoke(_ registration: RemoteDevicePushRegistration) async -> Bool
}

/// Each event gets one attempt. A transport failure can follow successful
/// delivery, so this client must not automatically repeat notification sends.
final class RemotePushRelayClient: RemotePushRelaying {
    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
    }

    static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration, delegate: PushRedirectRefusal(), delegateQueue: nil)
    }

    func send(_ notification: RemotePushSessionNotification, to registration: RemoteDevicePushRegistration) async -> RemotePushSendOutcome {
        await sendNotification(try? JSONEncoder().encode(notification), to: registration)
    }

    func send(_ notification: RemotePushTaskNotification, to registration: RemoteDevicePushRegistration) async -> RemotePushSendOutcome {
        await sendNotification(try? JSONEncoder().encode(notification), to: registration)
    }

    private func sendNotification(_ body: Data?, to registration: RemoteDevicePushRegistration) async -> RemotePushSendOutcome {
        guard !Task.isCancelled, let body, body.count <= RemotePushPolicy.maximumBodyBytes else { return .dropped }
        let request = request(method: "POST", registration: registration, suffix: "/notifications", body: body)
        guard let status = await status(for: request) else { return .dropped }
        if (200...299).contains(status) { return .accepted }
        if [401, 404, 410].contains(status) { return .registrationUnavailable }
        // The relay validates the body before it reserves the event or
        // contacts Apple, so a 400 never delivered anything.
        if status == 400 { return .unsupportedAlert }
        return .dropped
    }

    func revoke(_ registration: RemoteDevicePushRegistration) async -> Bool {
        guard !Task.isCancelled,
              let status = await status(for: request(method: "DELETE", registration: registration)) else { return false }
        return (200...299).contains(status) || status == 404 || status == 410
    }

    private func request(method: String, registration: RemoteDevicePushRegistration, suffix: String = "", body: Data? = nil) -> URLRequest {
        let url = registration.relayURL.appending(path: "/v1/registrations/\(registration.registrationID.uuidString.lowercased())\(suffix)")
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(registration.sendToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func status(for request: URLRequest) async -> Int? {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse,
                  response.url?.scheme == "https", response.url?.host == request.url?.host else { return nil }
            return response.statusCode
        } catch {
            // Do not expose URLSession errors: they can contain private URLs,
            // authorization headers, and notification content.
            return nil
        }
    }
}

private final class PushRedirectRefusal: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

extension RemotePushConfiguration {
    static func configured(bundle: Bundle = .main) -> RemotePushConfiguration? {
        guard let rawURL = bundle.object(forInfoDictionaryKey: "ToasttyPushRelayURL") as? String,
              let url = URL(string: rawURL),
              let relayID = bundle.object(forInfoDictionaryKey: "ToasttyPushRelayID") as? String,
              let rawEnvironment = bundle.object(forInfoDictionaryKey: "ToasttyPushAPNsEnvironment") as? String,
              let environment = RemotePushAPNsEnvironment(rawValue: rawEnvironment) else { return nil }
        return RemotePushConfiguration(relayURL: url, relayID: relayID, apnsEnvironment: environment)
    }
}
