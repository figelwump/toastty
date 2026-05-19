import CoreState
import Foundation

struct ManagedAgentNativeSessionObservationContext: Equatable, Sendable {
    var managedSessionID: String
    var agent: AgentKind
    var panelID: UUID
    var cwd: String
    var launchStart: Date
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
    var codexDirectSessionDeferred: Bool?
    var codexDirectSessionFileCount: Int?
    var codexDirectSessionCandidateCount: Int?
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
        if let codexDirectSessionDeferred {
            metadata["codex_direct_session_deferred"] = String(codexDirectSessionDeferred)
        }
        if let codexDirectSessionFileCount {
            metadata["codex_direct_session_file_count"] = String(codexDirectSessionFileCount)
        }
        if let codexDirectSessionCandidateCount {
            metadata["codex_direct_session_candidate_count"] = String(codexDirectSessionCandidateCount)
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
    typealias ResumeRecordHandler = @MainActor (UUID, ManagedAgentResumeRecord) -> Void

    private var observationsBySessionID: [String: ManagedAgentNativeSessionObservationContext] = [:]
    private var scanCountBySessionID: [String: Int] = [:]
    private var latestScanSummaryBySessionID: [String: ManagedAgentNativeSessionScanSummary] = [:]
    private var observationLoopTask: Task<Void, Never>?
    private let scanner: any ManagedAgentNativeSessionScanning
    private let timing: ManagedAgentNativeSessionObserverTiming
    private let nowProvider: @Sendable () -> Date
    private let recordHandler: ResumeRecordHandler

    init(
        scanner: any ManagedAgentNativeSessionScanning,
        timing: ManagedAgentNativeSessionObserverTiming = ManagedAgentNativeSessionObserverTiming(),
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        recordHandler: @escaping ResumeRecordHandler
    ) {
        self.scanner = scanner
        self.timing = timing
        self.nowProvider = nowProvider
        self.recordHandler = recordHandler
    }

    convenience init(
        store: AppStore,
        fileManager: FileManager = .default,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            scanner: ManagedAgentNativeSessionFileScanner(nowProvider: nowProvider),
            nowProvider: nowProvider,
            recordHandler: { [weak store] panelID, record in
                _ = store?.send(.updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: record))
            }
        )
        _ = fileManager
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
        ToasttyLog.info(
            "Started managed agent native session observation",
            category: .terminal,
            metadata: [
                "session_id": observation.managedSessionID,
                "agent": observation.agent.rawValue,
                "panel_id": observation.panelID.uuidString,
                "cwd": cwd,
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

    private func scheduleObservationLoopIfNeeded() {
        guard observationLoopTask == nil else { return }
        observationLoopTask = Task { @MainActor [weak self] in
            await self?.runObservationLoop()
        }
    }

    private func runObservationLoop() async {
        await Task.yield()
        while Task.isCancelled == false {
            await evaluatePendingObservations()
            expireTimedOutObservations()
            guard observationsBySessionID.isEmpty == false else {
                observationLoopTask = nil
                return
            }
            await timing.sleep(timing.pollIntervalNanoseconds)
        }
        observationLoopTask = nil
    }

    private func evaluatePendingObservations() async {
        guard observationsBySessionID.isEmpty == false else { return }

        var candidateBySessionID: [String: ManagedAgentNativeSessionCandidate] = [:]
        for observation in observationsBySessionID.values {
            let result = await scanner.scan(for: observation)
            scanCountBySessionID[observation.managedSessionID, default: 0] += 1
            latestScanSummaryBySessionID[observation.managedSessionID] = result.summary
            let candidates = result.candidates
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
            guard let observation = observationsBySessionID.removeValue(forKey: managedSessionID) else {
                continue
            }
            scanCountBySessionID.removeValue(forKey: managedSessionID)
            latestScanSummaryBySessionID.removeValue(forKey: managedSessionID)
            let record = ManagedAgentResumeRecord(
                agent: candidate.agent,
                nativeSessionID: candidate.nativeSessionID,
                sessionFilePath: candidate.sessionFilePath,
                cwd: candidate.cwd,
                capturedAt: nowProvider()
            )
            recordHandler(observation.panelID, record)
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
                "elapsed_seconds": Self.formattedSeconds(elapsedSeconds),
                "timeout_seconds": Self.formattedSeconds(timing.timeout),
                "scan_count": String(scanCountBySessionID[sessionID] ?? 0),
            ]
            if let summary = latestScanSummaryBySessionID[sessionID] {
                metadata.merge(summary.loggingMetadata) { _, new in new }
            }
            scanCountBySessionID.removeValue(forKey: sessionID)
            latestScanSummaryBySessionID.removeValue(forKey: sessionID)
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
    private let nowProvider: @Sendable () -> Date

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        codexSessionsDirectory = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        codexShellSnapshotsDirectory = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("shell_snapshots", isDirectory: true)
        claudeProjectsDirectory = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        self.nowProvider = nowProvider
    }

    init(
        codexSessionsDirectory: URL,
        claudeProjectsDirectory: URL,
        codexShellSnapshotsDirectory: URL? = nil,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.codexSessionsDirectory = codexSessionsDirectory
        self.codexShellSnapshotsDirectory = codexShellSnapshotsDirectory
            ?? codexSessionsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("shell_snapshots", isDirectory: true)
        self.claudeProjectsDirectory = claudeProjectsDirectory
        self.nowProvider = nowProvider
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
    static let codexDirectSessionFallbackDelay: TimeInterval = 30
    static let codexSnapshotCaptureWindow: TimeInterval = 90
    static let codexNativeSessionIDPattern = try! NSRegularExpression(
        pattern: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
    )

    func codexScanResult(
        for observation: ManagedAgentNativeSessionObservationContext
    ) -> ManagedAgentNativeSessionScanResult {
        let snapshotFiles = codexShellSnapshotFiles(for: observation)
        let snapshotCandidates = deduplicatedCandidates(
            codexShellSnapshotCandidates(from: snapshotFiles, for: observation)
        )
        if snapshotCandidates.isEmpty == false {
            return ManagedAgentNativeSessionScanResult(
                candidates: snapshotCandidates,
                summary: ManagedAgentNativeSessionScanSummary(
                    candidateCount: snapshotCandidates.count,
                    codexSnapshotFileCount: snapshotFiles.count,
                    codexSnapshotCandidateCount: snapshotCandidates.count
                )
            )
        }

        guard nowProvider() >= observation.launchStart.addingTimeInterval(Self.codexDirectSessionFallbackDelay) else {
            return ManagedAgentNativeSessionScanResult(
                candidates: [],
                summary: ManagedAgentNativeSessionScanSummary(
                    candidateCount: 0,
                    codexSnapshotFileCount: snapshotFiles.count,
                    codexSnapshotCandidateCount: 0,
                    codexDirectSessionDeferred: true
                )
            )
        }

        let sessionFiles = jsonlFiles(
            under: codexSessionsDirectory,
            modifiedAtOrAfter: observation.launchStart
        )
        let sessionCandidates = deduplicatedCandidates(sessionFiles.compactMap { fileURL -> ManagedAgentNativeSessionCandidate? in
            guard let metadata = codexSessionMetadata(from: fileURL),
                  metadata.cwd == observation.cwd else {
                return nil
            }
            return ManagedAgentNativeSessionCandidate(
                agent: .codex,
                nativeSessionID: metadata.sessionID,
                sessionFilePath: fileURL.path,
                cwd: metadata.cwd,
                updatedAt: metadata.updatedAt
            )
        })

        return ManagedAgentNativeSessionScanResult(
            candidates: sessionCandidates,
            summary: ManagedAgentNativeSessionScanSummary(
                candidateCount: sessionCandidates.count,
                codexSnapshotFileCount: snapshotFiles.count,
                codexSnapshotCandidateCount: 0,
                codexDirectSessionDeferred: false,
                codexDirectSessionFileCount: sessionFiles.count,
                codexDirectSessionCandidateCount: sessionCandidates.count
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
