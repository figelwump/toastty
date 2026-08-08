import Combine
import CoreState
import Foundation

/// Facade handed to the gateway request handler. The gateway server is
/// main-actor bound, so every call arrives on the main actor; this bridge
/// makes that contract explicit and forwards into the service's isolated
/// state. `assumeIsolated` traps loudly if a future transport ever calls the
/// facade off the main actor.
final class RemoteAccessFacadeBridge: RemoteSessionFacade, @unchecked Sendable {
    weak var service: RemoteAccessService?

    func sessionList(at date: Date) -> RemoteSessionListSnapshot {
        MainActor.assumeIsolated {
            service?.facadeSessionList(at: date)
                ?? RemoteSessionListSnapshot(
                    projectionRunID: RemoteProjectionRunID(),
                    conversations: [],
                    generatedAt: date
                )
        }
    }

    func conversationSnapshot(for conversationID: RemoteConversationID, at date: Date) -> RemoteConversationSnapshot? {
        MainActor.assumeIsolated {
            service?.facadeConversationSnapshot(for: conversationID, at: date)
        }
    }

    func conversationEvents(
        for conversationID: RemoteConversationID,
        after cursor: ConversationEventCursor?,
        limit: Int
    ) -> ConversationEventPageOutcome {
        MainActor.assumeIsolated {
            service?.facadeConversationEvents(for: conversationID, after: cursor, limit: limit)
                ?? .conversationNotFound
        }
    }
}

enum RemoteAccessPreferences {
    static let defaultPort: UInt16 = 42871
    private static let enabledKey = "toastty.remoteAccess.enabled"
    private static let portKey = "toastty.remoteAccess.port"
    private static let tailnetOriginKey = "toastty.remoteAccess.tailnetOrigin"

    static func loadEnabled(userDefaults: UserDefaults = ToasttyAppDefaults.current) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    static func persistEnabled(_ enabled: Bool, userDefaults: UserDefaults = ToasttyAppDefaults.current) {
        userDefaults.set(enabled, forKey: enabledKey)
    }

    static func loadPort(userDefaults: UserDefaults = ToasttyAppDefaults.current) -> UInt16 {
        let stored = userDefaults.integer(forKey: portKey)
        guard stored > 0, stored <= UInt16.max, stored >= 1024 else { return defaultPort }
        return UInt16(stored)
    }

    static func loadTailnetOrigin(userDefaults: UserDefaults = ToasttyAppDefaults.current) -> String? {
        let value = userDefaults.string(forKey: tailnetOriginKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, value.isEmpty == false else { return nil }
        return value
    }

    static func persistTailnetOrigin(_ origin: String?, userDefaults: UserDefaults = ToasttyAppDefaults.current) {
        let trimmed = origin?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, trimmed.isEmpty == false {
            userDefaults.set(trimmed, forKey: tailnetOriginKey)
        } else {
            userDefaults.removeObject(forKey: tailnetOriginKey)
        }
    }
}

/// Long-lived host service composing the remote-access gateway: device store,
/// audit log, request handler, loopback listener, the session-registry
/// adapter, and — for Codex conversations — the live transcript projection
/// fed by rollout-file tailers.
@MainActor
final class RemoteAccessService: ObservableObject {
    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var listeningPort: UInt16?
    @Published private(set) var startupError: String?
    @Published private(set) var currentPairingCode: RemotePairingCode?
    @Published private(set) var devices: [RemoteDeviceRecord] = []
    @Published private(set) var connectedClientCount: Int = 0
    @Published var tailnetOrigin: String {
        didSet {
            RemoteAccessPreferences.persistTailnetOrigin(tailnetOrigin)
            refreshHandlerConfiguration()
        }
    }

    private let store: AppStore
    private let sessionRuntimeStore: SessionRuntimeStore
    private let deviceStore: RemoteDeviceStore
    private let auditLog: RemoteAccessAuditLog
    private let projectionStore = RemoteConversationProjectionStore()
    private let facadeBridge = RemoteAccessFacadeBridge()
    private let handler: RemoteGatewayRequestHandler
    private let server: RemoteAccessGatewayServer
    private let port: UInt16
    private var cancellables: Set<AnyCancellable> = []

    private var tailersByConversationID: [RemoteConversationID: RemoteTranscriptTailer] = [:]
    private var activeSessionIDByConversationID: [RemoteConversationID: String] = [:]

    init(
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        runtimePaths: ToasttyRuntimePaths
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.port = RemoteAccessPreferences.loadPort()
        self.tailnetOrigin = RemoteAccessPreferences.loadTailnetOrigin() ?? ""
        self.deviceStore = RemoteDeviceStore(fileURL: runtimePaths.remoteAccessDevicesFileURL)
        self.auditLog = RemoteAccessAuditLog(fileURL: runtimePaths.remoteAccessAuditFileURL)
        self.handler = RemoteGatewayRequestHandler(
            deviceStore: deviceStore,
            auditLog: auditLog,
            facade: facadeBridge,
            configuration: RemoteGatewayConfiguration(allowedOrigins: [])
        )
        self.server = RemoteAccessGatewayServer(handler: handler)
        self.devices = deviceStore.devices
        facadeBridge.service = self

        server.onWebSocketCountChanged = { [weak self] count in
            guard let self else { return }
            let previousCount = self.connectedClientCount
            self.connectedClientCount = count
            if count > previousCount {
                // A fresh subscriber gets the current snapshot immediately
                // instead of waiting for the next registry change.
                self.broadcastSessionList()
            }
        }

        sessionRuntimeStore.$sessionRegistry
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncConversations()
            }
            .store(in: &cancellables)

        // Resume-record and conversation-identity changes mutate panel state
        // without touching the session registry; without this observer a
        // rollout-path change would never restart the transcript tailer.
        store.addActionAppliedObserver { [weak self] action, _, _ in
            switch action {
            case .updateTerminalPanelResumeRecord, .updateTerminalPanelRemoteConversationID:
                self?.syncConversations()
            default:
                break
            }
        }

        refreshHandlerConfiguration()
        syncConversations(broadcast: false)
        if RemoteAccessPreferences.loadEnabled() {
            setEnabled(true, persist: false)
        }
    }

    // MARK: - Kill switch

    func setEnabled(_ enabled: Bool, persist: Bool = true) {
        if persist {
            RemoteAccessPreferences.persistEnabled(enabled)
        }
        startupError = nil
        if enabled {
            syncConversations(broadcast: false)
            do {
                try server.start(port: port)
                isEnabled = true
                listeningPort = port
                auditLog.record(RemoteAccessAuditEntry(at: Date(), action: .remoteAccessEnabled))
            } catch {
                isEnabled = false
                listeningPort = nil
                startupError = "Could not listen on 127.0.0.1:\(port): \(error.localizedDescription)"
                ToasttyLog.error(
                    "Remote access gateway failed to start",
                    category: .automation,
                    metadata: ["error": "\(error)", "port": "\(port)"]
                )
            }
        } else {
            server.stop()
            isEnabled = false
            listeningPort = nil
            invalidatePairingCode()
            auditLog.record(RemoteAccessAuditEntry(at: Date(), action: .remoteAccessDisabled))
        }
    }

    // MARK: - Pairing and devices

    func issuePairingCode() {
        let code = deviceStore.issuePairingCode(at: Date())
        currentPairingCode = code
        auditLog.record(RemoteAccessAuditEntry(at: Date(), action: .pairingCodeIssued))
    }

    func invalidatePairingCode() {
        deviceStore.invalidatePairingCode()
        currentPairingCode = nil
    }

    func refreshDevices() {
        devices = deviceStore.devices
    }

    func revokeDevice(_ deviceID: UUID) {
        guard deviceStore.revokeDevice(deviceID, at: Date()) else { return }
        auditLog.record(RemoteAccessAuditEntry(at: Date(), action: .deviceRevoked, deviceID: deviceID))
        refreshDevices()
    }

    func revokeAllDevices() {
        deviceStore.revokeAllDevices(at: Date())
        auditLog.record(RemoteAccessAuditEntry(at: Date(), action: .allDevicesRevoked))
        currentPairingCode = nil
        refreshDevices()
    }

    func recentAuditEntries(limit: Int = 50) -> [RemoteAccessAuditEntry] {
        auditLog.recentEntries(limit: limit)
    }

    // MARK: - Facade surface (main-actor entry points for the bridge)

    func facadeSessionList(at date: Date) -> RemoteSessionListSnapshot {
        RemoteSessionListSnapshot(
            projectionRunID: projectionStore.runID,
            conversations: buildConversationSummaries(),
            generatedAt: date
        )
    }

    func facadeConversationSnapshot(for conversationID: RemoteConversationID, at date: Date) -> RemoteConversationSnapshot? {
        if let snapshot = projectionStore.conversationSnapshot(for: conversationID, at: date) {
            var snapshot = snapshot
            // The projection store has no descriptor context for placement
            // titles; overlay the registry-derived summary when available.
            if let summary = buildConversationSummaries().first(where: { $0.conversationID == conversationID }) {
                snapshot.summary = summary
            }
            return snapshot
        }
        guard let summary = buildConversationSummaries().first(where: { $0.conversationID == conversationID }) else {
            return nil
        }
        return RemoteConversationSnapshot(summary: summary, pendingInteractions: [])
    }

    func facadeConversationEvents(
        for conversationID: RemoteConversationID,
        after cursor: ConversationEventCursor?,
        limit: Int
    ) -> ConversationEventPageOutcome {
        projectionStore.conversationEvents(for: conversationID, after: cursor, limit: limit)
    }

    // MARK: - Conversation sync

    /// One row of the panel scan: a panel that currently represents (or last
    /// represented) a managed agent conversation.
    private struct ConversationCandidate {
        var conversationID: RemoteConversationID
        var provider: AgentKind
        var title: String
        var workspaceID: UUID
        var workspaceTitle: String
        var panelID: UUID
        var cwd: String?
        var activeSessionID: String?
        var registryState: RemoteSessionState
        var updatedAt: Date
        var transcriptPath: String?
    }

    private func syncConversations(broadcast: Bool = true) {
        let candidates = scanConversationCandidates(mintingIDs: true)
        var seenConversationIDs: Set<RemoteConversationID> = []
        var listChanged = false

        for candidate in candidates {
            seenConversationIDs.insert(candidate.conversationID)
            guard ProviderTranscriptSupport.isSupported(candidate.provider),
                  let rolloutPath = candidate.transcriptPath else {
                // Providers without a transcript parser stay registry-derived.
                continue
            }

            let isNewRegistration = projectionStore.isConversationRegistered(candidate.conversationID) == false
            if isNewRegistration {
                projectionStore.registerConversation(
                    candidate.conversationID,
                    descriptor: RemoteConversationProjectionStore.ConversationDescriptor(
                        provider: candidate.provider,
                        title: candidate.title,
                        placement: RemoteConversationPlacement(
                            workspaceID: candidate.workspaceID,
                            workspaceTitle: candidate.workspaceTitle,
                            panelID: candidate.panelID
                        ),
                        cwd: candidate.cwd
                    ),
                    bindingID: UUID(),
                    runtimeBound: false,
                    at: Date()
                )
                listChanged = true
            }

            let previousActiveSessionID = activeSessionIDByConversationID[candidate.conversationID]
            if let activeSessionID = candidate.activeSessionID {
                if previousActiveSessionID != activeSessionID {
                    // A runtime (newly or re-)bound to this conversation.
                    let reason: ConversationBindingChangeReason =
                        (previousActiveSessionID == nil && isNewRegistration == false) || previousActiveSessionID != nil
                            ? .runtimeResumed
                            : .runtimeBound
                    let emitted = projectionStore.noteBinding(
                        for: candidate.conversationID,
                        reason: reason,
                        providerSessionFilePath: rolloutPath,
                        bindingID: UUID(),
                        at: Date()
                    )
                    broadcastEvents(emitted, for: candidate.conversationID)
                    activeSessionIDByConversationID[candidate.conversationID] = activeSessionID
                    listChanged = true
                }
            } else if previousActiveSessionID != nil {
                let emitted = projectionStore.noteBinding(
                    for: candidate.conversationID,
                    reason: .runtimeEnded,
                    bindingID: UUID(),
                    at: Date()
                )
                broadcastEvents(emitted, for: candidate.conversationID)
                activeSessionIDByConversationID[candidate.conversationID] = nil
                listChanged = true
            }

            ensureTailer(for: candidate.conversationID, provider: candidate.provider, path: rolloutPath)
        }

        // Conversations whose panels disappeared: delete their cache entries.
        for conversationID in tailersByConversationID.keys where seenConversationIDs.contains(conversationID) == false {
            tailersByConversationID[conversationID]?.stop()
            tailersByConversationID[conversationID] = nil
            projectionStore.removeConversation(conversationID)
            activeSessionIDByConversationID[conversationID] = nil
            listChanged = true
        }

        if broadcast, listChanged || candidates.isEmpty == false {
            broadcastSessionList()
        }
    }

    private func scanConversationCandidates(mintingIDs: Bool) -> [ConversationCandidate] {
        let registry = sessionRuntimeStore.sessionRegistry
        var candidates: [ConversationCandidate] = []
        var seenPanelIDs: Set<UUID> = []

        for workspace in store.state.workspacesByID.values {
            for (panelID, panelState) in workspace.panels {
                guard case .terminal(let terminalState) = panelState else { continue }

                let activeSessionID = registry.activeSessionIDByPanelID[panelID]
                let activeRecord = activeSessionID.flatMap { registry.sessionsByID[$0] }
                let hasLiveAgent = activeRecord.map { $0.isActive && $0.agent != .processWatch } ?? false
                let restorableProvider = terminalState.resumeRecord?.agent
                let hasRestorableTranscript = terminalState.remoteConversationID != nil
                    && restorableProvider.map(ProviderTranscriptSupport.isSupported) == true
                guard hasLiveAgent || hasRestorableTranscript else { continue }
                guard seenPanelIDs.insert(panelID).inserted else { continue }

                let conversationID: RemoteConversationID
                if let existing = terminalState.remoteConversationID {
                    conversationID = existing
                } else if mintingIDs {
                    let minted = RemoteConversationID()
                    guard store.send(.updateTerminalPanelRemoteConversationID(
                        panelID: panelID,
                        remoteConversationID: minted
                    )) else {
                        continue
                    }
                    conversationID = minted
                } else {
                    continue
                }

                let provider = activeRecord?.agent ?? terminalState.resumeRecord?.agent ?? .codex
                // Both Codex rollout files and Claude transcript files are
                // recorded as the resume record's sessionFilePath.
                let transcriptPath = ProviderTranscriptSupport.isSupported(provider)
                    ? terminalState.resumeRecord?.sessionFilePath
                    : nil

                candidates.append(ConversationCandidate(
                    conversationID: conversationID,
                    provider: provider,
                    title: activeRecord?.displayTitleOverride ?? terminalState.displayPanelLabel,
                    workspaceID: workspace.id,
                    workspaceTitle: workspace.title,
                    panelID: panelID,
                    cwd: activeRecord?.cwd ?? terminalState.resumeRecord?.cwd,
                    activeSessionID: hasLiveAgent ? activeSessionID : nil,
                    registryState: activeRecord.flatMap { record in
                        record.status.map { Self.remoteState(for: $0.kind) }
                    } ?? (hasLiveAgent ? .starting : .offline),
                    updatedAt: activeRecord?.updatedAt ?? terminalState.resumeRecord?.capturedAt ?? Date(),
                    transcriptPath: transcriptPath
                ))
            }
        }

        return candidates.sorted { lhs, rhs in
            (lhs.workspaceTitle, lhs.title, lhs.conversationID.rawValue.uuidString)
                < (rhs.workspaceTitle, rhs.title, rhs.conversationID.rawValue.uuidString)
        }
    }

    private func buildConversationSummaries() -> [RemoteConversationSummary] {
        scanConversationCandidates(mintingIDs: false).map { candidate in
            // Codex conversations with a live projection report
            // transcript-derived state; everything else stays
            // presentation-derived and read-only.
            if let projector = projectionStore.projectorState(for: candidate.conversationID) {
                return RemoteConversationSummary(
                    conversationID: candidate.conversationID,
                    provider: candidate.provider,
                    title: candidate.title,
                    placement: RemoteConversationPlacement(
                        workspaceID: candidate.workspaceID,
                        workspaceTitle: candidate.workspaceTitle,
                        panelID: candidate.panelID
                    ),
                    cwd: candidate.cwd,
                    state: projector.state,
                    inputAvailability: projector.inputAvailability,
                    projectionGeneration: projector.generation,
                    latestSequence: projector.latestSequence,
                    updatedAt: max(projector.updatedAt, candidate.updatedAt)
                )
            }
            return RemoteConversationSummary(
                conversationID: candidate.conversationID,
                provider: candidate.provider,
                title: candidate.title,
                placement: RemoteConversationPlacement(
                    workspaceID: candidate.workspaceID,
                    workspaceTitle: candidate.workspaceTitle,
                    panelID: candidate.panelID
                ),
                cwd: candidate.cwd,
                state: candidate.registryState,
                inputAvailability: .unavailable(reason: .unknownProviderState),
                latestSequence: 0,
                updatedAt: candidate.updatedAt
            )
        }
    }

    private static func remoteState(for kind: SessionStatusKind) -> RemoteSessionState {
        switch kind {
        case .idle, .ready:
            return .ready
        case .working:
            return .working
        case .needsApproval:
            return .awaitingInput
        case .error:
            return .error
        }
    }

    // MARK: - Transcript tailers

    private func ensureTailer(for conversationID: RemoteConversationID, provider: AgentKind, path: String) {
        if let existing = tailersByConversationID[conversationID] {
            if existing.fileURL.path == path {
                return
            }
            existing.stop()
            tailersByConversationID[conversationID] = nil
        }
        startTailer(for: conversationID, provider: provider, path: path)
    }

    private func startTailer(for conversationID: RemoteConversationID, provider: AgentKind, path: String) {
        let tailer = RemoteTranscriptTailer(
            conversationID: conversationID,
            fileURL: URL(filePath: path),
            provider: provider,
            makeParser: {
                ProviderTranscriptSupport.makeParser(for: provider) ?? CodexRolloutTranscriptParser()
            }
        ) { [weak self] conversationID, event in
            self?.handleTailerEvent(conversationID, event)
        }
        tailersByConversationID[conversationID] = tailer
        tailer.start()
    }

    private func handleTailerEvent(_ conversationID: RemoteConversationID, _ event: RemoteTranscriptTailer.Event) {
        switch event {
        case .observations(let observations):
            let emitted = projectionStore.ingest(observations, for: conversationID)
            broadcastEvents(emitted, for: conversationID)

        case .fileReplaced:
            // Unreconcilable rewrite: discard this conversation's sequence
            // space and re-read the file from the start under a fresh
            // generation.
            guard let tailer = tailersByConversationID[conversationID] else { return }
            let path = tailer.fileURL.path
            let provider = tailer.provider
            tailer.stop()
            tailersByConversationID[conversationID] = nil
            projectionStore.forceResnapshot(for: conversationID, bindingID: UUID(), at: Date())
            if isEnabled {
                server.broadcast(.resnapshotRequired(conversationID: conversationID))
            }
            startTailer(for: conversationID, provider: provider, path: path)
            broadcastSessionList()
        }
    }

    // MARK: - Broadcasting

    private func broadcastEvents(_ events: [ConversationEvent], for conversationID: RemoteConversationID) {
        guard events.isEmpty == false else { return }
        guard isEnabled, let projector = projectionStore.projectorState(for: conversationID) else {
            return
        }
        server.broadcast(.conversationEvents(ConversationEventPage(
            conversationID: conversationID,
            projectionRunID: projectionStore.runID,
            projectionGeneration: projector.generation,
            events: events,
            latestSequence: projector.latestSequence
        )))
        // Status-bearing events change the list rows too.
        if events.contains(where: { $0.kind == .statusChanged || $0.kind == .sessionBindingChanged }) {
            broadcastSessionList()
        }
    }

    private func broadcastSessionList() {
        guard isEnabled else { return }
        server.broadcast(.sessionList(facadeSessionList(at: Date())))
    }

    // MARK: - Configuration

    private func refreshHandlerConfiguration() {
        var origins: Set<String> = [
            "http://127.0.0.1:\(port)",
            "http://localhost:\(port)",
        ]
        if tailnetOrigin.isEmpty == false {
            var normalized = tailnetOrigin
            if normalized.hasSuffix("/") {
                normalized = String(normalized.dropLast())
            }
            if normalized.contains("://") == false {
                normalized = "https://" + normalized
            }
            origins.insert(normalized)
        }
        handler.updateConfiguration(RemoteGatewayConfiguration(
            allowedOrigins: origins,
            staticResources: Self.loadWebClientResources()
        ))
    }

    static func loadWebClientResources(bundle: Bundle = .main) -> [String: RemoteGatewayStaticResource] {
        guard let clientDirectory = bundle.resourceURL?
            .appending(path: "RemoteWebClient", directoryHint: .isDirectory) else {
            return [:]
        }
        let contentTypesByExtension = [
            "html": "text/html; charset=utf-8",
            "js": "text/javascript; charset=utf-8",
            "css": "text/css; charset=utf-8",
            "svg": "image/svg+xml",
        ]
        var resources: [String: RemoteGatewayStaticResource] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: clientDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files {
            guard let contentType = contentTypesByExtension[file.pathExtension.lowercased()],
                  let data = try? Data(contentsOf: file) else {
                continue
            }
            resources["/\(file.lastPathComponent)"] = RemoteGatewayStaticResource(
                contentType: contentType,
                data: data
            )
        }
        return resources
    }
}
