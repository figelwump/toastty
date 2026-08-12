import Foundation

public struct HTTPTransportResponse: Equatable, Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPTransportResponse
}

public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let ownsSession: Bool

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(
            configuration: configuration,
            delegate: RedirectBlockingURLSessionDelegate(),
            delegateQueue: nil
        )
        ownsSession = true
    }

    /// Explicit injection seam for tests or a caller-owned URLSession. The
    /// caller owns that session's redirect and persistence policy.
    public init(session: URLSession) {
        self.session = session
        ownsSession = false
    }

    deinit {
        if ownsSession {
            session.invalidateAndCancel()
        }
    }

    public func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        let (body, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLSessionHTTPTransportError.nonHTTPResponse
        }
        let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let name = entry.key as? String else { return }
            result[name.lowercased()] = String(describing: entry.value)
        }
        return HTTPTransportResponse(statusCode: httpResponse.statusCode, headers: headers, body: body)
    }
}

final class RedirectBlockingURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public enum URLSessionHTTPTransportError: Error, Equatable, Sendable {
    case nonHTTPResponse
}
