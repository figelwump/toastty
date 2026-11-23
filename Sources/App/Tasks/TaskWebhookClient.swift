import CoreState
import Foundation

/// What one POST returned. `statusCode` is `nil` when no response came;
/// `errorClass` then says why, without the URL.
struct TaskWebhookSendResult: Equatable, Sendable {
    var statusCode: Int?
    var errorClass: String?
}

protocol TaskWebhookTransport: Sendable {
    func send(_ request: URLRequest) async -> TaskWebhookSendResult
}

/// POSTs webhook events. Unlike the push relay client, a caller may send an
/// event again: the event ID lets the receiver drop a duplicate.
final class TaskWebhookClient: TaskWebhookTransport {
    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: TaskWebhookRedirectRefusal(), delegateQueue: nil)
    }

    func send(_ request: URLRequest) async -> TaskWebhookSendResult {
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return TaskWebhookSendResult(statusCode: nil, errorClass: "invalid response")
            }
            return TaskWebhookSendResult(statusCode: http.statusCode, errorClass: nil)
        } catch {
            // URLSession errors can hold the URL, which may hold a token, so
            // only a class of failure leaves this function.
            return TaskWebhookSendResult(statusCode: nil, errorClass: Self.errorClass(error))
        }
    }

    static func errorClass(_ error: any Error) -> String {
        guard let urlError = error as? URLError else { return "request failed" }
        switch urlError.code {
        case .timedOut: return "timeout"
        case .cannotFindHost, .dnsLookupFailed: return "host not found"
        case .cannotConnectToHost: return "connection refused"
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "offline"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return "TLS failure"
        case .cancelled: return "cancelled"
        default: return "network error \(urlError.code.rawValue)"
        }
    }

    /// The request for one event, signed or carrying the key as the webhook's
    /// auth mode says.
    static func request(
        url: URL,
        auth: TaskWebhookAuth,
        secret: String?,
        eventID: UUID,
        body: Data,
        timestamp: Int,
        userAgent: String
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(eventID.uuidString.lowercased(), forHTTPHeaderField: "Toastty-Event-ID")
        request.setValue(String(timestamp), forHTTPHeaderField: "Toastty-Timestamp")
        switch auth {
        case .bearer:
            if let secret { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        case .header(let name):
            if let secret { request.setValue(secret, forHTTPHeaderField: name) }
        case .hmac:
            if let secret {
                request.setValue(
                    TaskWebhookSignature.header(secret: secret, timestamp: timestamp, body: body),
                    forHTTPHeaderField: "Toastty-Signature"
                )
            }
        case .none:
            break
        }
        return request
    }
}

/// A redirect could send the key to another host, so none is followed.
private final class TaskWebhookRedirectRefusal: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
