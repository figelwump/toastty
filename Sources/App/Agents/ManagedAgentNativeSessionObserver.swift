import CoreState
import Foundation

struct ManagedAgentNativeSessionObservationContext: Equatable, Sendable {
    var managedSessionID: String
    var agent: AgentKind
    var panelID: UUID
    var cwd: String
    var launchStart: Date
    /// Set when the launch command already names the native session it resumes.
    /// Observation then only confirms that session; scan candidates with any
    /// other ID are discarded so a same-cwd neighbor can never be claimed.
    var expectedNativeSessionID: String? = nil
    /// Log-dedup marker: set once this observation has reported discarding
    /// every scanned candidate because none matched `expectedNativeSessionID`.
    var didLogExpectedNativeSessionIDMismatch: Bool = false
}

struct ManagedAgentNativeSessionCandidate: Equatable, Sendable {
    var agent: AgentKind
    var nativeSessionID: String
    var sessionFilePath: String
    var cwd: String
    var updatedAt: Date

    var claimKey: String {
        [
            agent.rawValue,
            nativeSessionID,
            sessionFilePath,
        ].joined(separator: "\u{0}")
    }
}

struct ManagedAgentNativeSessionScanResult: Equatable, Sendable {
    var candidates: [ManagedAgentNativeSessionCandidate]
    var summary: ManagedAgentNativeSessionScanSummary
}

struct ManagedAgentNativeSessionScanSummary: Equatable, Sendable {
    var candidateCount: Int
    var codexSnapshotFileCount: Int?
    var codexSnapshotCandidateCount: Int?
    var claudeSessionFileCount: Int?
    var claudeSessionCandidateCount: Int?

    var loggingMetadata: [String: String] {
        var metadata = [
            "last_candidate_count": String(candidateCount),
        ]
        if let codexSnapshotFileCount {
            metadata["codex_snapshot_file_count"] = String(codexSnapshotFileCount)
        }
        if let codexSnapshotCandidateCount {
            metadata["codex_snapshot_candidate_count"] = String(codexSnapshotCandidateCount)
        }
        if let claudeSessionFileCount {
            metadata["claude_session_file_count"] = String(claudeSessionFileCount)
        }
        if let claudeSessionCandidateCount {
            metadata["claude_session_candidate_count"] = String(claudeSessionCandidateCount)
        }
        return metadata
    }
}

struct ManagedAgentNativeSessionResumeRecordOwner: Equatable, Sendable {
    var panelID: UUID
    var hasActiveSameAgentSession: Bool

    init(panelID: UUID, hasActiveSameAgentSession: Bool = false) {
        self.panelID = panelID
        self.hasActiveSameAgentSession = hasActiveSameAgentSession
    }
}

protocol ManagedAgentNativeSessionScanning: Sendable {
    func candidates(for observation: ManagedAgentNativeSessionObservationContext) async -> [ManagedAgentNativeSessionCandidate]
    func scan(for observation: ManagedAgentNativeSessionObservationContext) async -> ManagedAgentNativeSessionScanResult
}

extension ManagedAgentNativeSessionScanning {
    func scan(for observation: ManagedAgentNativeSessionObservationContext) async -> ManagedAgentNativeSessionScanResult {
        let candidates = await candidates(for: observation)
        return ManagedAgentNativeSessionScanResult(
            candidates: candidates,
            summary: ManagedAgentNativeSessionScanSummary(candidateCount: candidates.count)
        )
    }
}

@MainActor
protocol ManagedAgentNativeSessionObserving: AnyObject {
    func startObservation(_ observation: ManagedAgentNativeSessionObservationContext)
    func cancelObservation(sessionID: String)
}

struct ManagedAgentNativeSessionObserverTiming {
    var pollIntervalNanoseconds: UInt64
    var timeout: TimeInterval
    var sleep: @Sendable (UInt64) async -> Void

    init(
        pollIntervalNanoseconds: UInt64 = 1_000_000_000,
        timeout: TimeInterval = 90,
        sleep: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.timeout = timeout
        self.sleep = sleep
    }
}

@MainActor
final class ManagedAgentNativeSessionObserverRegistry: ManagedAgentNativeSessionObserving {
    typealias ResumeRecordHandler = @MainActor (String, UUID, ManagedAgentResumeRecord) -> Void

    typealias ResumeRecordOwnerResolver = @MainActor (AgentKind, String) -> ManagedAgentNativeSessionResumeRecordOwner?

    private var observationsBySessionID: [String: ManagedAgentNativeSessionObservationContext] = [:]
    private var scanCountBySessionID: [String: Int] = [:]
    private var latestScanSummaryBySessionID: [String: ManagedAgentNativeSessionScanSummary] = [:]
    private var refusedOwnedClaimKeysBySessionID: [String: Set<String>] = [:]
    private var observationLoopTask: Task<Void, Never>?
    private var observationLoopGeneration = 0
    private let scanner: any ManagedAgentNativeSessionScanning
    private let timing: ManagedAgentNativeSessionObserverTiming
    private let nowProvider: @Sendable () -> Date
    private let resumeRecordOwnerResolver: ResumeRecordOwnerResolver?
    private let recordHandler: ResumeRecordHandler

    init(
        scanner: any ManagedAgentNativeSessionScanning,
        timing: ManagedAgentNativeSessionObserverTiming = ManagedAgentNativeSessionObserverTiming(),
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        resumeRecordOwnerResolver: ResumeRecordOwnerResolver? = nil,
        recordHandler: @escaping ResumeRecordHandler
    ) {
        self.scanner = scanner
        self.timing = timing
        self.nowProvider = nowProvider
        self.resumeRecordOwnerResolver = resumeRecordOwnerResolver
        self.recordHandler = recordHandler
    }

    convenience init(
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore? = nil,
        fileManager: FileManager = .default,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            scanner: ManagedAgentNativeSessionFileScanner(),
            nowProvider: nowProvider,
            resumeRecordOwnerResolver: { [weak store, weak sessionRuntimeStore] agent, nativeSessionID in
                guard let panelID = store?.state.panelIDOwningManagedAgentResumeRecord(
                    agent: agent,
                    nativeSessionID: nativeSessionID
                ) else {
                    return nil
                }
                let activeOwnerSession = sessionRuntimeStore?.sessionRegistry.activeSession(for: panelID)
                return ManagedAgentNativeSessionResumeRecordOwner(
                    panelID: panelID,
                    hasActiveSameAgentSession: activeOwnerSession?.agent == agent
                )
            },
            recordHandler: { [weak store, weak sessionRuntimeStore] managedSessionID, panelID, record in
                guard let scopedRecord = Self.resumeRecord(
                    record,
                    applyingScopeFrom: sessionRuntimeStore,
                    managedSessionID: managedSessionID,
                    panelID: panelID
                ) else {
                    return
                }
                _ = store?.send(.updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: scopedRecord))
            }
        )
        _ = fileManager
    }

    static func resumeRecord(
        _ record: ManagedAgentResumeRecord,
        applyingScopeFrom sessionRuntimeStore: SessionRuntimeStore?,
        managedSessionID: String,
        panelID: UUID
    ) -> ManagedAgentResumeRecord? {
        guard let sessionRuntimeStore else { return record }
        guard let activeSession = sessionRuntimeStore.sessionRegistry.activeSession(sessionID: managedSessionID),
              activeSession.panelID == panelID else {
            return nil
        }

        var scopedRecord = record
        scopedRecord.scopedWorkspaceIDs = activeSession.scopedWorkspaceIDs
        return scopedRecord
    }

    deinit {
        observationLoopTask?.cancel()
    }

    func startObservation(_ observation: ManagedAgentNativeSessionObservationContext) {
        guard observation.agent == .codex || observation.agent == .claude else {
            return
        }
        guard let cwd = Self.normalizedPath(observation.cwd) else {
            ToasttyLog.info(
                "Skipping managed agent native session observation because cwd is unavailable",
                category: .terminal,
                metadata: [
                    "session_id": observation.managedSessionID,
                    "agent": observation.agent.rawValue,
                    "panel_id": observation.panelID.uuidString,
                ]
            )
            return
        }

        var normalizedObservation = observation
        normalizedObservation.cwd = cwd
        observationsBySessionID[observation.managedSessionID] = normalizedObservation
        scanCountBySessionID[observation.managedSessionID] = 0
        latestScanSummaryBySessionID.removeValue(forKey: observation.managedSessionID)
        refusedOwnedClaimKeysBySessionID.removeValue(forKey: observation.managedSessionID)
        ToasttyLog.info(
            "Started managed agent native session observation",
            category: .terminal,
            metadata: [
                "session_id": observation.managedSessionID,
                "agent": observation.agent.rawValue,
                "panel_id": observation.panelID.uuidString,
                "cwd": cwd,
                "expected_native_session_id": observation.expectedNativeSessionID ?? "none",
                "timeout_seconds": Self.formattedSeconds(timing.timeout),
                "poll_interval_seconds": Self.formattedSeconds(
                    TimeInterval(timing.pollIntervalNanoseconds) / 1_000_000_000
                ),
            ]
        )
        scheduleObservationLoopIfNeeded()
    }

    func cancelObservation(sessionID: String) {
        observationsBySessionID.removeValue(forKey: sessionID)
        scanCountBySessionID.removeValue(forKey: sessionID)
        latestScanSummaryBySessionID.removeValue(forKey: sessionID)
        refusedOwnedClaimKeysBySessionID.removeValue(forKey: sessionID)
        if observationsBySessionID.isEmpty {
            observationLoopTask?.cancel()
            observationLoopTask = nil
        }
    }

    func evaluatePendingObservationsForTesting() async {
        await evaluatePendingObservations()
    }

    func expireTimedOutObservationsForTesting() {
        expireTimedOutObservations()
    }

    var activeObservationCountForTesting: Int {
        observationsBySessionID.count
    }

    var scanBookkeepingEntryCountForTesting: Int {
        scanCountBySessionID.count
            + latestScanSummaryBySessionID.count
            + refusedOwnedClaimKeysBySessionID.count
    }

    var hasObservationLoopTaskForTesting: Bool {
        observationLoopTask != nil
    }

    private func scheduleObservationLoopIfNeeded() {
        guard observationLoopTask == nil else { return }
        observationLoopGeneration += 1
        let generation = observationLoopGeneration
        observationLoopTask = Task { @MainActor [weak self] in
            await self?.runObservationLoop(generation: generation)
        }
    }

    private func runObservationLoop(generation: Int) async {
        await Task.yield()
        while Task.isCancelled == false {
            await evaluatePendingObservations()
            expireTimedOutObservations()
            guard observationsBySessionID.isEmpty == false else {
                clearObservationLoopTask(ifGeneration: generation)
                return
            }
            await timing.sleep(timing.pollIntervalNanoseconds)
        }
        clearObservationLoopTask(ifGeneration: generation)
    }

    /// A cancelled loop task can resume from a suspended scan after a newer
    /// loop has already been scheduled; only the current generation may drop
    /// the task reference, or it would orphan the live loop.
    private func clearObservationLoopTask(ifGeneration generation: Int) {
        guard generation == observationLoopGeneration else { return }
        observationLoopTask = nil
    }

    private func evaluatePendingObservations() async {
        guard observationsBySessionID.isEmpty == false else { return }

        var candidateBySessionID: [String: ManagedAgentNativeSessionCandidate] = [:]
        for observation in observationsBySessionID.values {
            let result = await scanner.scan(for: observation)
            // The observation may have been cancelled (e.g. by a hook-driven
            // capture) while the scan was suspended; writing bookkeeping for
            // it here would leak entries no cleanup path removes.
            guard observationsBySessionID[observation.managedSessionID] != nil else {
                continue
            }
            scanCountBySessionID[observation.managedSessionID, default: 0] += 1
            latestScanSummaryBySessionID[observation.managedSessionID] = result.summary
            var candidates = result.candidates
            if let expectedNativeSessionID = observation.expectedNativeSessionID {
                candidates = candidates.filter { candidate in
                    candidate.nativeSessionID.caseInsensitiveCompare(expectedNativeSessionID) == .orderedSame
                }
                if candidates.isEmpty,
                   result.candidates.isEmpty == false,
                   observation.didLogExpectedNativeSessionIDMismatch == false {
                    observationsBySessionID[observation.managedSessionID]?.didLogExpectedNativeSessionIDMismatch = true
                    ToasttyLog.info(
                        "Discarded scanned native session candidates that do not match the expected resume session",
                        category: .terminal,
                        metadata: [
                            "session_id": observation.managedSessionID,
                            "agent": observation.agent.rawValue,
                            "panel_id": observation.panelID.uuidString,
                            "expected_native_session_id": expectedNativeSessionID,
                            "discarded_candidate_count": String(result.candidates.count),
                        ]
                    )
                }
            }
            if candidates.count == 1 {
                candidateBySessionID[observation.managedSessionID] = candidates[0]
            } else if candidates.count > 1 {
                var metadata = [
                    "session_id": observation.managedSessionID,
                    "agent": observation.agent.rawValue,
                    "panel_id": observation.panelID.uuidString,
                    "cwd": observation.cwd,
                    "candidate_count": String(candidates.count),
                    "scan_count": String(scanCountBySessionID[observation.managedSessionID] ?? 0),
                ]
                metadata.merge(result.summary.loggingMetadata) { _, new in new }
                ToasttyLog.info(
                    "Leaving managed agent resume record unchanged because native session observation is ambiguous",
                    category: .terminal,
                    metadata: metadata
                )
            }
        }

        let groupedByClaim = Dictionary(grouping: candidateBySessionID) { entry in
            entry.value.claimKey
        }
        for duplicateClaim in groupedByClaim.values where duplicateClaim.count > 1 {
            for entry in duplicateClaim {
                candidateBySessionID.removeValue(forKey: entry.key)
            }
            let sessionIDs = duplicateClaim.map(\.key).sorted().joined(separator: ",")
            ToasttyLog.info(
                "Leaving managed agent resume records unchanged because a native session matched multiple observers",
                category: .terminal,
                metadata: [
                    "session_ids": sessionIDs,
                    "candidate_session_id": duplicateClaim.first?.value.nativeSessionID ?? "unknown",
                    "candidate_file": duplicateClaim.first?.value.sessionFilePath ?? "unknown",
                ]
            )
        }

        for (managedSessionID, candidate) in candidateBySessionID {
            guard let observation = observationsBySessionID[managedSessionID] else {
                continue
            }
            // A resume-shaped launch already names this native session in its
            // argv (the expected-ID filter guarantees the candidate matches),
            // which lets this pane reclaim a stale record elsewhere. It still
            // must not take a record from another live same-agent owner.
            if let owner = resumeRecordOwnerResolver?(candidate.agent, candidate.nativeSessionID),
               owner.panelID != observation.panelID,
               observation.expectedNativeSessionID == nil || owner.hasActiveSameAgentSession {
                // Another panel's resume record already claims this native
                // session; capturing it here would strip that panel's record
                // through duplicate pruning. Expected-ID launches may reclaim
                // stale records, but not records owned by a live same-agent
                // session.
                if refusedOwnedClaimKeysBySessionID[managedSessionID, default: []].insert(candidate.claimKey).inserted {
                    ToasttyLog.info(
                        "Leaving managed agent resume record unchanged because the native session is owned by another panel",
                        category: .terminal,
                        metadata: [
                            "session_id": managedSessionID,
                            "agent": candidate.agent.rawValue,
                            "panel_id": observation.panelID.uuidString,
                            "owner_panel_id": owner.panelID.uuidString,
                            "native_session_id": candidate.nativeSessionID,
                            "expected_native_session_id": observation.expectedNativeSessionID ?? "none",
                            "owner_has_active_same_agent_session": owner.hasActiveSameAgentSession ? "true" : "false",
                        ]
                    )
                }
                continue
            }
            observationsBySessionID.removeValue(forKey: managedSessionID)
            scanCountBySessionID.removeValue(forKey: managedSessionID)
            latestScanSummaryBySessionID.removeValue(forKey: managedSessionID)
            refusedOwnedClaimKeysBySessionID.removeValue(forKey: managedSessionID)
            let record = ManagedAgentResumeRecord(
                agent: candidate.agent,
                nativeSessionID: candidate.nativeSessionID,
                sessionFilePath: candidate.sessionFilePath,
                cwd: candidate.cwd,
                capturedAt: nowProvider()
            )
            recordHandler(managedSessionID, observation.panelID, record)
            ToasttyLog.info(
                "Captured managed agent native resume record",
                category: .terminal,
                metadata: [
                    "session_id": managedSessionID,
                    "agent": candidate.agent.rawValue,
                    "panel_id": observation.panelID.uuidString,
                    "native_session_id": candidate.nativeSessionID,
                    "session_file": candidate.sessionFilePath,
                    "cwd": candidate.cwd,
                ]
            )
        }
    }

    private func expireTimedOutObservations() {
        let now = nowProvider()
        let timedOutSessionIDs = observationsBySessionID.values.compactMap { observation -> String? in
            guard now.timeIntervalSince(observation.launchStart) >= timing.timeout else {
                return nil
            }
            return observation.managedSessionID
        }
        for sessionID in timedOutSessionIDs {
            guard let observation = observationsBySessionID.removeValue(forKey: sessionID) else {
                continue
            }
            let elapsedSeconds = now.timeIntervalSince(observation.launchStart)
            var metadata = [
                "session_id": sessionID,
                "agent": observation.agent.rawValue,
                "panel_id": observation.panelID.uuidString,
                "cwd": observation.cwd,
                "expected_native_session_id": observation.expectedNativeSessionID ?? "none",
                "elapsed_seconds": Self.formattedSeconds(elapsedSeconds),
                "timeout_seconds": Self.formattedSeconds(timing.timeout),
                "scan_count": String(scanCountBySessionID[sessionID] ?? 0),
            ]
            if let summary = latestScanSummaryBySessionID[sessionID] {
                metadata.merge(summary.loggingMetadata) { _, new in new }
            }
            scanCountBySessionID.removeValue(forKey: sessionID)
            latestScanSummaryBySessionID.removeValue(forKey: sessionID)
            refusedOwnedClaimKeysBySessionID.removeValue(forKey: sessionID)
            ToasttyLog.info(
                "Leaving managed agent resume record unchanged because native session observation timed out",
                category: .terminal,
                metadata: metadata
            )
        }
    }

    private static func normalizedPath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let normalized = (expanded as NSString).standardizingPath
        guard normalized.isEmpty == false else { return nil }
        return normalized
    }

    private static func formattedSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds)
    }
}

actor ManagedAgentNativeSessionFileScanner: ManagedAgentNativeSessionScanning {
    private let codexSessionsDirectory: URL
    private let codexShellSnapshotsDirectory: URL
    private let claudeProjectsDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        codexSessionsDirectory = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        codexShellSnapshotsDirectory = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("shell_snapshots", isDirectory: true)
        claudeProjectsDirectory = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    init(
        codexSessionsDirectory: URL,
        claudeProjectsDirectory: URL,
        codexShellSnapshotsDirectory: URL? = nil
    ) {
        self.codexSessionsDirectory = codexSessionsDirectory
        self.codexShellSnapshotsDirectory = codexShellSnapshotsDirectory
            ?? codexSessionsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("shell_snapshots", isDirectory: true)
        self.claudeProjectsDirectory = claudeProjectsDirectory
    }

    func candidates(for observation: ManagedAgentNativeSessionObservationContext) async -> [ManagedAgentNativeSessionCandidate] {
        await scan(for: observation).candidates
    }

    func scan(for observation: ManagedAgentNativeSessionObservationContext) async -> ManagedAgentNativeSessionScanResult {
        switch observation.agent {
        case .codex:
            return codexScanResult(for: observation)
        case .claude:
            return claudeScanResult(for: observation)
        default:
            return ManagedAgentNativeSessionScanResult(
                candidates: [],
                summary: ManagedAgentNativeSessionScanSummary(candidateCount: 0)
            )
        }
    }
}

private extension ManagedAgentNativeSessionFileScanner {
    static let codexSnapshotLaunchTolerance: TimeInterval = 2
    static let codexSnapshotCaptureWindow: TimeInterval = 90
    static let codexNativeSessionIDPattern = try! NSRegularExpression(
        pattern: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
    )

    func codexScanResult(
        for observation: ManagedAgentNativeSessionObservationContext
    ) -> ManagedAgentNativeSessionScanResult {
        // Codex identity comes from hook events first; shell snapshots are the
        // only scan evidence strong enough to act on (they name this pane's
        // TOASTTY session). There is deliberately no cwd-only fallback: an
        // idle resumed session never touches its JSONL while a busy same-cwd
        // neighbor does, so cwd matching misattributes sessions and the
        // resulting duplicate pruning destroys the rightful pane's record.
        // Timing out is safer than claiming another pane's session.
        let snapshotFiles = codexShellSnapshotFiles(for: observation)
        let snapshotCandidates = deduplicatedCandidates(
            codexShellSnapshotCandidates(from: snapshotFiles, for: observation)
        )
        return ManagedAgentNativeSessionScanResult(
            candidates: snapshotCandidates,
            summary: ManagedAgentNativeSessionScanSummary(
                candidateCount: snapshotCandidates.count,
                codexSnapshotFileCount: snapshotFiles.count,
                codexSnapshotCandidateCount: snapshotCandidates.count
            )
        )
    }

    func claudeScanResult(
        for observation: ManagedAgentNativeSessionObservationContext
    ) -> ManagedAgentNativeSessionScanResult {
        let projectDirectoryName = claudeProjectDirectoryName(for: observation.cwd)
        let projectDirectoryURL = claudeProjectsDirectory.appendingPathComponent(projectDirectoryName, isDirectory: true)
        let sessionFiles = jsonlFiles(
            under: projectDirectoryURL,
            modifiedAtOrAfter: observation.launchStart
        )
        let sessionCandidates = sessionFiles.compactMap { fileURL -> ManagedAgentNativeSessionCandidate? in
            guard let metadata = claudeSessionMetadata(from: fileURL, cwd: observation.cwd) else {
                return nil
            }
            return ManagedAgentNativeSessionCandidate(
                agent: .claude,
                nativeSessionID: metadata.sessionID,
                sessionFilePath: fileURL.path,
                cwd: observation.cwd,
                updatedAt: metadata.updatedAt
            )
        }
        return ManagedAgentNativeSessionScanResult(
            candidates: sessionCandidates,
            summary: ManagedAgentNativeSessionScanSummary(
                candidateCount: sessionCandidates.count,
                claudeSessionFileCount: sessionFiles.count,
                claudeSessionCandidateCount: sessionCandidates.count
            )
        )
    }

    func codexShellSnapshotCandidates(
        for observation: ManagedAgentNativeSessionObservationContext
    ) -> [ManagedAgentNativeSessionCandidate] {
        codexShellSnapshotCandidates(from: codexShellSnapshotFiles(for: observation), for: observation)
    }

    func codexShellSnapshotCandidates(
        from snapshotURLs: [URL],
        for observation: ManagedAgentNativeSessionObservationContext
    ) -> [ManagedAgentNativeSessionCandidate] {
        snapshotURLs.flatMap { snapshotURL -> [ManagedAgentNativeSessionCandidate] in
            guard let nativeSessionID = codexNativeSessionID(fromShellSnapshotURL: snapshotURL),
                  codexShellSnapshot(snapshotURL, matches: observation),
                  let updatedAt = contentUpdatedAt(snapshotURL) else {
                return []
            }
            return codexSessionMetadataMatching(sessionID: nativeSessionID).map { metadata in
                ManagedAgentNativeSessionCandidate(
                    agent: .codex,
                    nativeSessionID: metadata.sessionID,
                    sessionFilePath: metadata.sessionFilePath,
                    cwd: observation.cwd,
                    updatedAt: updatedAt
                )
            }
        }
    }

    func codexShellSnapshotFiles(for observation: ManagedAgentNativeSessionObservationContext) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: codexShellSnapshotsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
        guard urls.isEmpty == false else {
            return []
        }

        let lowerBound = observation.launchStart.addingTimeInterval(-Self.codexSnapshotLaunchTolerance)
        let upperBound = observation.launchStart.addingTimeInterval(Self.codexSnapshotCaptureWindow)

        return urls
            .filter { fileURL in
                guard fileURL.pathExtension == "sh",
                      codexNativeSessionID(fromShellSnapshotURL: fileURL) != nil,
                      let updatedAt = contentUpdatedAt(fileURL),
                      updatedAt >= lowerBound,
                      updatedAt <= upperBound else {
                    return false
                }
                return true
            }
            .sorted { lhs, rhs in
                (contentUpdatedAt(lhs) ?? .distantPast) < (contentUpdatedAt(rhs) ?? .distantPast)
            }
    }

    func codexNativeSessionID(fromShellSnapshotURL fileURL: URL) -> String? {
        let filename = fileURL.lastPathComponent
        guard filename.hasSuffix(".sh") else { return nil }

        let stem = String(filename.dropLast(3))
        let parts = stem.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[1].isEmpty == false,
              parts[1].allSatisfy(\.isNumber) else {
            return nil
        }

        let sessionID = String(parts[0])
        let range = NSRange(sessionID.startIndex..<sessionID.endIndex, in: sessionID)
        guard Self.codexNativeSessionIDPattern.firstMatch(in: sessionID, options: [], range: range) != nil else {
            return nil
        }
        return sessionID.lowercased()
    }

    func codexShellSnapshot(_ fileURL: URL, matches observation: ManagedAgentNativeSessionObservationContext) -> Bool {
        guard let snapshotSessionID = shellSnapshotExportValue("TOASTTY_SESSION_ID", from: fileURL),
              snapshotSessionID == observation.managedSessionID,
              let snapshotPanelID = shellSnapshotExportValue("TOASTTY_PANEL_ID", from: fileURL),
              snapshotPanelID.caseInsensitiveCompare(observation.panelID.uuidString) == .orderedSame else {
            return false
        }
        return true
    }

    func shellSnapshotExportValue(_ key: String, from fileURL: URL) -> String? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        let prefix = "export \(key)="
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix(prefix) else { continue }
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    func codexSessionMetadataMatching(sessionID: String) -> [(sessionID: String, sessionFilePath: String, cwd: String)] {
        guard let normalizedSessionID = normalizedNonEmpty(sessionID)?.lowercased() else {
            return []
        }
        return jsonlFiles(under: codexSessionsDirectory, filenameContaining: normalizedSessionID)
            .compactMap { fileURL -> (sessionID: String, sessionFilePath: String, cwd: String)? in
                guard let metadata = codexSessionMetadata(from: fileURL),
                      metadata.sessionID.lowercased() == normalizedSessionID else {
                    return nil
                }
                return (
                    sessionID: metadata.sessionID,
                    sessionFilePath: fileURL.path,
                    cwd: metadata.cwd
                )
            }
    }

    func deduplicatedCandidates(
        _ candidates: [ManagedAgentNativeSessionCandidate]
    ) -> [ManagedAgentNativeSessionCandidate] {
        var seenClaimKeys = Set<String>()
        var result: [ManagedAgentNativeSessionCandidate] = []
        for candidate in candidates.sorted(by: { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.sessionFilePath < rhs.sessionFilePath
            }
            return lhs.updatedAt < rhs.updatedAt
        }) {
            guard seenClaimKeys.insert(candidate.claimKey).inserted else { continue }
            result.append(candidate)
        }
        return result
    }

    func jsonlFiles(under directoryURL: URL, modifiedAtOrAfter launchStart: Date) -> [URL] {
        jsonlFiles(under: directoryURL).filter { fileURL in
            guard let updatedAt = contentUpdatedAt(fileURL) else {
                return false
            }
            return updatedAt >= launchStart
        }
    }

    func jsonlFiles(under directoryURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(atPath: directoryURL.path) else {
            return []
        }

        var urls: [URL] = []
        for case let relativePath as String in enumerator {
            guard relativePath.hasSuffix(".jsonl") else {
                continue
            }
            urls.append(directoryURL.appendingPathComponent(relativePath, isDirectory: false))
        }
        return urls.sorted { lhs, rhs in
            (contentUpdatedAt(lhs) ?? .distantPast) < (contentUpdatedAt(rhs) ?? .distantPast)
        }
    }

    func jsonlFiles(under directoryURL: URL, filenameContaining needle: String) -> [URL] {
        let normalizedNeedle = needle.lowercased()
        guard normalizedNeedle.isEmpty == false,
              let enumerator = FileManager.default.enumerator(atPath: directoryURL.path) else {
            return []
        }

        var urls: [URL] = []
        for case let relativePath as String in enumerator {
            let filename = (relativePath as NSString).lastPathComponent.lowercased()
            guard filename.hasSuffix(".jsonl"),
                  filename.contains(normalizedNeedle) else {
                continue
            }
            urls.append(directoryURL.appendingPathComponent(relativePath, isDirectory: false))
        }
        return urls.sorted { $0.path < $1.path }
    }

    func codexSessionMetadata(from fileURL: URL) -> (sessionID: String, cwd: String, updatedAt: Date)? {
        for object in jsonObjects(fromPrefixOf: fileURL, maxLines: 20) {
            guard object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any],
                  let sessionID = normalizedNonEmpty(payload["id"] as? String),
                  let cwd = normalizedPath(payload["cwd"] as? String),
                  let updatedAt = contentUpdatedAt(fileURL) else {
                continue
            }
            return (sessionID, cwd, updatedAt)
        }
        return nil
    }

    func claudeSessionMetadata(from fileURL: URL, cwd: String) -> (sessionID: String, updatedAt: Date)? {
        let fallbackSessionID = normalizedNonEmpty(fileURL.deletingPathExtension().lastPathComponent)
        for object in jsonObjects(fromPrefixOf: fileURL, maxLines: 20) {
            guard let sessionID = normalizedNonEmpty(object["sessionId"] as? String) ?? fallbackSessionID,
                  let updatedAt = contentUpdatedAt(fileURL) else {
                continue
            }
            return (sessionID, updatedAt)
        }
        guard let fallbackSessionID,
              let updatedAt = contentUpdatedAt(fileURL) else {
            return nil
        }
        return (fallbackSessionID, updatedAt)
    }

    func jsonObjects(fromPrefixOf fileURL: URL, maxLines: Int) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return []
        }
        defer {
            try? handle.close()
        }

        let data = (try? handle.read(upToCount: 65_536)) ?? Data()
        guard data.isEmpty == false else {
            return []
        }
        let text = String(decoding: data, as: UTF8.self)
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(maxLines)
            .compactMap { line in
                guard let lineData = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    return nil
                }
                return object
            }
    }

    func contentUpdatedAt(_ fileURL: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else {
            return nil
        }
        let modificationDate = attributes[.modificationDate] as? Date
        let creationDate = attributes[.creationDate] as? Date
        switch (modificationDate, creationDate) {
        case (.some(let modificationDate), .some(let creationDate)):
            return max(modificationDate, creationDate)
        case (.some(let modificationDate), .none):
            return modificationDate
        case (.none, .some(let creationDate)):
            return creationDate
        case (.none, .none):
            return nil
        }
    }

    func claudeProjectDirectoryName(for cwd: String) -> String {
        cwd.replacingOccurrences(of: "/", with: "-")
    }

    func normalizedPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let normalized = (expanded as NSString).standardizingPath
        guard normalized.isEmpty == false else { return nil }
        return normalized
    }

    func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
