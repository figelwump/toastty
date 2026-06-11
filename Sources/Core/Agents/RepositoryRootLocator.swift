import Dispatch
import Foundation

public struct RepositoryRootResolution: Equatable, Sendable {
    public let repoRoot: String?
    public let duration: TimeInterval
    public let timedOut: Bool

    public init(repoRoot: String?, duration: TimeInterval, timedOut: Bool) {
        self.repoRoot = repoRoot
        self.duration = duration
        self.timedOut = timedOut
    }
}

public enum RepositoryRootLocator {
    public static let defaultBestEffortTimeout: TimeInterval = 0.2
    public static let slowInferenceThreshold: TimeInterval = 0.1

    private static let bestEffortRunner = RepositoryRootBestEffortRunner(
        queue: DispatchQueue(
            label: "com.GiantThings.Toastty.RepositoryRootLocator",
            qos: .userInitiated
        )
    )

    public static func inferRepoRoot(
        from workingDirectory: String?,
        fileManager: FileManager = .default
    ) -> String? {
        guard let workingDirectory = normalizedWorkingDirectory(workingDirectory) else { return nil }

        var candidateURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        while true {
            let gitURL = candidateURL.appendingPathComponent(".git", isDirectory: false)
            if fileManager.fileExists(atPath: gitURL.path) {
                return candidateURL.path
            }

            let parentURL = candidateURL.deletingLastPathComponent()
            if parentURL.path == candidateURL.path {
                return nil
            }
            candidateURL = parentURL
        }
    }

    public static func inferRepoRootBestEffort(
        from workingDirectory: String?,
        timeout: TimeInterval = defaultBestEffortTimeout
    ) -> RepositoryRootResolution {
        guard normalizedWorkingDirectory(workingDirectory) != nil else {
            return RepositoryRootResolution(repoRoot: nil, duration: 0, timedOut: false)
        }

        return bestEffortRunner.resolve(timeout: timeout) {
            inferRepoRoot(from: workingDirectory)
        }
    }

    private static func normalizedWorkingDirectory(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

final class RepositoryRootBestEffortRunner: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var isRunning = false

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func resolve(
        timeout: TimeInterval = RepositoryRootLocator.defaultBestEffortTimeout,
        now: @escaping @Sendable () -> Date = Date.init,
        work: @escaping @Sendable () -> String?
    ) -> RepositoryRootResolution {
        guard begin() else {
            return RepositoryRootResolution(repoRoot: nil, duration: 0, timedOut: true)
        }

        let startedAt = now()
        let box = RepositoryRootResultBox()
        let semaphore = DispatchSemaphore(value: 0)

        // Keep filesystem probing off the caller's thread, and fail fast while a
        // previous probe is still running so wedged path lookups cannot accumulate.
        queue.async {
            box.store(work())
            self.finish()
            semaphore.signal()
        }

        let timeout = max(timeout, 0)
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        let duration = now().timeIntervalSince(startedAt)
        guard waitResult == .success else {
            return RepositoryRootResolution(repoRoot: nil, duration: duration, timedOut: true)
        }

        return RepositoryRootResolution(repoRoot: box.load(), duration: duration, timedOut: false)
    }

    private func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning == false else {
            return false
        }
        isRunning = true
        return true
    }

    private func finish() {
        lock.lock()
        defer { lock.unlock() }
        isRunning = false
    }
}

private final class RepositoryRootResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func store(_ newValue: String?) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
