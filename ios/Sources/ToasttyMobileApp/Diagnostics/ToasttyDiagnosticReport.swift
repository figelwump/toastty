import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The file schema accepts only categorical diagnostics. Never add connection
/// state, identifiers, raw errors, tokens, or URLs to this projection.
struct ToasttyDiagnosticReport: Codable, Equatable, Sendable {
    struct App: Codable, Equatable, Sendable {
        let bundleID: String
        let version: String
        let build: String

        static var current: Self {
            let bundle = Bundle.main
            return Self(bundleID: bundle.bundleIdentifier ?? "com.giantthings.toastty.mobile",
                        version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                        build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
        }
    }

    struct Event: Codable, Equatable, Sendable {
        struct PushDetails: Codable, Equatable, Sendable {
            let registrationNumber: UInt64?
            let statusCode: Int?
            let code: String?
            let rateLimitSource: String?
            let providerRefreshAttempted: Bool?
            let retryAfterSeconds: UInt32?

            init(_ details: ToasttyPushDiagnosticDetails) {
                registrationNumber = details.registrationNumber
                statusCode = details.relay?.statusCode
                code = details.relay?.code?.rawValue
                rateLimitSource = details.relay?.rateLimitSource?.rawValue
                providerRefreshAttempted = details.relay?.providerRefreshAttempted
                retryAfterSeconds = details.retryAfterSeconds
            }
        }

        let sequence: UInt64
        let recordedAt: Date
        let event: String
        let pushDetails: PushDetails?
        let pushSnapshot: ToasttyPushSetupSnapshot?

        init(_ entry: ToasttyConnectionDiagnosticEntry) {
            sequence = entry.sequence
            recordedAt = entry.recordedAt
            event = entry.event.rawValue
            pushDetails = entry.pushDetails.map(PushDetails.init)
            pushSnapshot = entry.pushSnapshot
        }
    }

    enum FlushReason: String, Codable, Sendable {
        case coalesced
        case background
        case explicit
    }

    let schemaVersion: Int
    let app: App
    let runID: UUID
    let runStartedAt: Date
    let capturedAt: Date
    let lastFlushReason: FlushReason
    let events: [Event]
    let truncatedCount: Int
    let push: ToasttyPushSetupSnapshot?
}

/// The lock protects one latest observation and its scheduling flag. File access
/// belongs to `queue`. A blocked write cannot accumulate captured ring copies in
/// queued work. The recorder never appends a separate event ring.
final class ToasttyDiagnosticRecorder: @unchecked Sendable {
    static let shared = ToasttyDiagnosticRecorder(
        directoryURL: URL.applicationSupportDirectory.appendingPathComponent("ToasttyDiagnostics", isDirectory: true)
    )

    private let queue = DispatchQueue(label: "com.giantthings.toastty.mobile.diagnostic-report", qos: .utility)
    private let directoryURL: URL
    private let app: ToasttyDiagnosticReport.App
    private let runID: UUID
    private let runStartedAt: Date
    private let coalescingInterval: TimeInterval
    static let maximumReportBytes = 256 * 1_024
    private let byteBudget: Int
    private let lock = NSLock()
    private struct Observation {
        var log = ToasttyConnectionDiagnosticLog()
        var push: ToasttyPushSetupSnapshot?
        var capturedAt: Date
        var revision: UInt64 = 0
    }
    private var latest: Observation
    private var workerScheduled = true
    // Only queue reads and changes these fields.
    private var hasWrittenThisRun = false
    private var writtenRevision: UInt64?

    init(directoryURL: URL, app: ToasttyDiagnosticReport.App = .current,
         runID: UUID = UUID(), runStartedAt: Date = .now,
         coalescingInterval: TimeInterval = 1,
         byteBudget: Int = ToasttyDiagnosticRecorder.maximumReportBytes) {
        self.directoryURL = directoryURL
        self.app = app
        self.runID = runID
        self.runStartedAt = runStartedAt
        self.latest = Observation(capturedAt: runStartedAt)
        self.coalescingInterval = coalescingInterval
        self.byteBudget = max(1, min(byteBudget, Self.maximumReportBytes))
        enqueueWorker()
    }

    func submit(log: ToasttyConnectionDiagnosticLog) {
        submit(log: log, push: nil)
    }

    func updatePushSnapshot(_ snapshot: ToasttyPushSetupSnapshot, log: ToasttyConnectionDiagnosticLog) {
        submit(log: log, push: snapshot)
    }

    private func submit(log: ToasttyConnectionDiagnosticLog, push: ToasttyPushSetupSnapshot?) {
        let observedAt = Date.now
        let shouldSchedule = lock.withLock {
            latest.log = log
            if let push { latest.push = push }
            latest.capturedAt = observedAt
            latest.revision &+= 1
            guard !workerScheduled else { return false }
            workerScheduled = true
            return true
        }
        if shouldSchedule { enqueueWorker() }
    }

    /// Writes the latest observation after all earlier calls to submit. A
    /// protected or unavailable container is a nonfatal, retryable failure.
    @discardableResult
    func flush(reason: ToasttyDiagnosticReport.FlushReason = .explicit) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let observation = lock.withLock { latest }
                continuation.resume(returning: write(observation, reason: reason))
            }
        }
    }

    private func enqueueWorker() {
        queue.asyncAfter(deadline: .now() + coalescingInterval) { [weak self] in
            guard let self else { return }
            let observation = lock.withLock { latest }
            _ = write(observation, reason: .coalesced)
            let shouldSchedule = lock.withLock {
                // If callbacks arrived during file I/O, keep one worker for
                // their final value. Failed writes retry on the next submit.
                guard latest.revision == observation.revision else { return true }
                workerScheduled = false
                return false
            }
            if shouldSchedule { enqueueWorker() }
        }
    }

    private func encode(_ observation: Observation, reason: ToasttyDiagnosticReport.FlushReason) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var eventCount = min(observation.log.count, ToasttyConnectionDiagnosticLog.defaultCapacity)
        while true {
            let report = ToasttyDiagnosticReport(schemaVersion: 1, app: app, runID: runID,
                runStartedAt: runStartedAt, capturedAt: observation.capturedAt, lastFlushReason: reason,
                events: observation.log.entries.suffix(eventCount).map(ToasttyDiagnosticReport.Event.init),
                truncatedCount: observation.log.count - eventCount, push: observation.push)
            let data = try encoder.encode(report)
            if data.count <= byteBudget { return data }
            // Keep the newest entries and the current push snapshot. A future
            // schema expansion must still respect the collector's byte limit.
            guard eventCount > 0 else { throw CocoaError(.fileWriteOutOfSpace) }
            eventCount -= max(1, eventCount / 4)
        }
    }

    private func write(_ observation: Observation, reason: ToasttyDiagnosticReport.FlushReason) -> Bool {
        guard writtenRevision != observation.revision else { return true }
        do {
            let data = try encode(observation, reason: reason)
            let manager = FileManager.default
            try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            var directory = directoryURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let current = directoryURL.appendingPathComponent("current.json")
            if !hasWrittenThisRun, manager.fileExists(atPath: current.path) {
                // Copy atomically before replacing current. A failed write keeps
                // the prior evidence in current, previous, or both.
                let prior = try Data(contentsOf: current)
                try prior.write(to: directoryURL.appendingPathComponent("previous.json"), options: Self.writeOptions)
            }
            try data.write(to: current, options: Self.writeOptions)
            hasWrittenThisRun = true
            writtenRevision = observation.revision
            return true
        } catch {
            // Diagnostics must not change app behavior or expose raw I/O errors.
            return false
        }
    }

    /// A short grace window includes teardown callbacks that follow the scene
    /// transition. Suspension, expiration, or termination can still interrupt it.
    @discardableResult
    func flushBackgroundChanges(gracePeriod: Duration = .seconds(1)) async -> Bool {
        _ = await flush(reason: .background)
        try? await Task.sleep(for: gracePeriod)
        return await flush(reason: .background)
    }

    private static var writeOptions: Data.WritingOptions {
#if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
#else
        [.atomic]
#endif
    }

#if canImport(UIKit)
    @MainActor
    func flushInBackground() {
        let lease = ToasttyDiagnosticBackgroundLease()
        lease.identifier = UIApplication.shared.beginBackgroundTask(withName: "Toastty diagnostic report") {
            MainActor.assumeIsolated { lease.end() }
        }
        Task {
            await flushBackgroundChanges()
            lease.end()
        }
    }
#endif
}

#if canImport(UIKit)
@MainActor
private final class ToasttyDiagnosticBackgroundLease {
    var identifier: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
