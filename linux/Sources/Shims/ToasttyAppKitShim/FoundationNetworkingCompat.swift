import Foundation
import FoundationNetworking

/// The part of Darwin's `URLSession.AsyncBytes` shared code uses (`task`).
public struct LinuxURLSessionBytes: @unchecked Sendable {
    public let task: URLSessionTask
}

extension URLSession {
    /// Darwin's `bytes(for:)`, for callers that only need the response head:
    /// returns once headers arrive. Redirects are decided by this session's
    /// delegate (`urlSession(_:task:willPerformHTTPRedirection:...)`) exactly
    /// as Darwin does; corelibs would otherwise follow them silently for
    /// completion-handler tasks.
    public func bytes(for request: URLRequest) async throws -> (LinuxURLSessionBytes, URLResponse) {
        let forwarder = HeadResponseDelegate(redirectDelegate: delegate as? URLSessionTaskDelegate)
        let session = URLSession(configuration: configuration, delegate: forwarder, delegateQueue: nil)
        let task = session.dataTask(with: request)
        let response: URLResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                forwarder.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        session.finishTasksAndInvalidate()
        return (LinuxURLSessionBytes(task: task), response)
    }
}

private final class HeadResponseDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let redirectDelegate: URLSessionTaskDelegate?
    private var pending: CheckedContinuation<URLResponse, any Error>?

    init(redirectDelegate: URLSessionTaskDelegate?) {
        self.redirectDelegate = redirectDelegate
    }

    var continuation: CheckedContinuation<URLResponse, any Error>? {
        get { lock.withLock { pending } }
        set { lock.withLock { pending = newValue } }
    }

    private func finish(_ result: Result<URLResponse, any Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<URLResponse, any Error>? in
            defer { pending = nil }
            return pending
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        finish(.success(response))
        completionHandler(.cancel)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let redirectDelegate else {
            completionHandler(request)
            return
        }
        redirectDelegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request,
            completionHandler: completionHandler
        )
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let response = task.response {
            finish(.success(response))
        } else {
            finish(.failure(error ?? URLError(.badServerResponse)))
        }
    }
}
