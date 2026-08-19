import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// Deterministic in-process substitute for the live hook process runner.
/// `autoComplete` resolves every invocation immediately with a fixed result;
/// `gated` holds invocations open until the test releases them, which lets
/// tests observe queueing, ordering, and concurrency behavior.
actor ControlledHookRunner: AgentHookProcessRunning {
    private enum Mode {
        case autoComplete(AgentHookRunResult)
        case gated
    }

    private let mode: Mode
    private(set) var requests: [AgentHookInvocationRequest] = []
    private var concurrentRunCount = 0
    private(set) var peakConcurrentRunCount = 0
    private var gateContinuations: [CheckedContinuation<AgentHookRunResult, Never>] = []
    private var bankedReleases: [AgentHookRunResult] = []

    init(result: AgentHookRunResult = .exited(code: 0)) {
        mode = .autoComplete(result)
    }

    init(gated: ()) {
        mode = .gated
    }

    func run(_ request: AgentHookInvocationRequest) async -> AgentHookRunResult {
        requests.append(request)
        concurrentRunCount += 1
        peakConcurrentRunCount = max(peakConcurrentRunCount, concurrentRunCount)
        defer { concurrentRunCount -= 1 }

        switch mode {
        case .autoComplete(let result):
            return result
        case .gated:
            if bankedReleases.isEmpty == false {
                return bankedReleases.removeFirst()
            }
            return await withCheckedContinuation { continuation in
                gateContinuations.append(continuation)
            }
        }
    }

    func releaseOne(_ result: AgentHookRunResult = .exited(code: 0)) {
        if gateContinuations.isEmpty == false {
            gateContinuations.removeFirst().resume(returning: result)
        } else {
            bankedReleases.append(result)
        }
    }

    func releaseAll(count: Int, result: AgentHookRunResult = .exited(code: 0)) {
        for _ in 0..<count {
            releaseOne(result)
        }
    }

    func requestCount() -> Int {
        requests.count
    }
}

enum AgentHookTestSupport {
    /// Creates a temporary executable shell script so dispatcher path
    /// validation passes; the controlled runner intercepts before any real
    /// process launch.
    static func makeTemporaryExecutableScript(
        contents: String = "#!/bin/sh\nexit 0\n"
    ) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-agent-hook-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let scriptURL = directoryURL.appendingPathComponent("hook.sh", isDirectory: false)
        try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }

    static func decodeHookPayload(_ request: AgentHookInvocationRequest) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: request.stdinData)
        return try #require(object as? [String: Any])
    }

    /// Recorded (event, sessionID) pairs decoded from stdin payloads, in
    /// invocation order.
    static func recordedEventNames(_ requests: [AgentHookInvocationRequest]) throws -> [String] {
        try requests.map { request in
            let payload = try decodeHookPayload(request)
            return try #require(payload["event"] as? String)
        }
    }

    @MainActor
    static func waitForRequestCount(
        _ runner: ControlledHookRunner,
        expected: Int,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async {
        let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
        while await runner.requestCount() < expected && Date() < deadline {
            await Task.yield()
        }
    }
}
