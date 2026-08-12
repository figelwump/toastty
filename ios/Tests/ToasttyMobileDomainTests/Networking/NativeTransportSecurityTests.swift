import Foundation
@testable import ToasttyMobileDomain
import XCTest

final class NativeTransportSecurityTests: XCTestCase {
    func testHTTPRedirectDelegateRejectsRedirect() throws {
        let delegate = RedirectBlockingURLSessionDelegate()
        try assertRedirectIsRejected { response, request, completion in
            delegate.urlSession(
                .shared,
                task: URLSession.shared.dataTask(with: request),
                willPerformHTTPRedirection: response,
                newRequest: request,
                completionHandler: completion
            )
        }
    }

    func testWebSocketDelegateRejectsRedirect() throws {
        let delegate = URLSessionWebSocketOpenDelegate(openGate: WebSocketOpenGate())
        try assertRedirectIsRejected { response, request, completion in
            delegate.urlSession(
                .shared,
                task: URLSession.shared.dataTask(with: request),
                willPerformHTTPRedirection: response,
                newRequest: request,
                completionHandler: completion
            )
        }
    }

    private func assertRedirectIsRejected(
        invoke: (
            HTTPURLResponse,
            URLRequest,
            @escaping (URLRequest?) -> Void
        ) -> Void
    ) throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://mac.tail.ts.net/api/sessions"))
        let redirectedURL = try XCTUnwrap(URL(string: "https://attacker.example/steal"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: sourceURL,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirectedURL.absoluteString]
            )
        )
        let capture = RedirectCapture()
        invoke(response, URLRequest(url: redirectedURL)) { request in
            capture.record(request)
        }
        XCTAssertTrue(capture.wasInvoked)
        XCTAssertNil(capture.request)
    }
}

private final class RedirectCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedInvocation = false
    private var storedRequest: URLRequest?

    var wasInvoked: Bool { lock.withLock { storedInvocation } }
    var request: URLRequest? { lock.withLock { storedRequest } }

    func record(_ request: URLRequest?) {
        lock.withLock {
            storedInvocation = true
            storedRequest = request
        }
    }
}
