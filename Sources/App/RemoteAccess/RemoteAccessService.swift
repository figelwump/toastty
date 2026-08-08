import Combine
import CoreState
import Foundation

/// Thread-safe value box implementing the read facade for v0.
///
/// The main-actor service rebuilds the conversation summaries from the session
/// registry and pushes them here; the gateway reads snapshots through the
/// facade protocol. v0 summaries are presentation-derived and therefore always
/// read-only (`unknownProviderState`) — display status never authorizes input.
final class RemoteSessionListSnapshotFacade: RemoteSessionFacade, @unchecked Sendable {
    let runID = RemoteProjectionRunID()
    private let lock = NSLock()
    private var conversations: [RemoteConversationSummary] = []

    func update(conversations: [RemoteConversationSummary]) {
        lock.lock()
        defer { lock.unlock() }
        self.conversations = conversations
    }

    func sessionList(at date: Date) -> RemoteSessionListSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return RemoteSessionListSnapshot(
            projectionRunID: runID,
            conversations: conversations,
            generatedAt: date
        )
    }

    func conversationSnapshot(for conversationID: RemoteConversationID, at date: Date) -> RemoteConversationSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let summary = conversations.first(where: { $0.conversationID == conversationID }) else {
            return nil
        }
        return RemoteConversationSnapshot(summary: summary, pendingInteractions: [])
    }

    func conversationEvents(
        for conversationID: RemoteConversationID,
        after cursor: ConversationEventCursor?,
        limit: Int
    ) -> ConversationEventPageOutcome {
        // Transcript paging arrives with the v0.5 projection wiring.
        .conversationNotFound
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
/// audit log, request handler, loopback listener, and the session-registry
/// adapter feeding the read facade.
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
    private let facade = RemoteSessionListSnapshotFacade()
    private let handler: RemoteGatewayRequestHandler
    private let server: RemoteAccessGatewayServer
    private let port: UInt16
    private var cancellables: Set<AnyCancellable> = []

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
            facade: facade,
            configuration: RemoteGatewayConfiguration(allowedOrigins: [])
        )
        self.server = RemoteAccessGatewayServer(handler: handler)
        self.devices = deviceStore.devices

        server.onWebSocketCountChanged = { [weak self] count in
            guard let self else { return }
            let previousCount = self.connectedClientCount
            self.connectedClientCount = count
            if count > previousCount {
                // A fresh subscriber gets the current snapshot immediately
                // instead of waiting for the next registry change.
                self.publishSessionList()
            }
        }

        sessionRuntimeStore.$sessionRegistry
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.publishSessionList()
            }
            .store(in: &cancellables)

        refreshHandlerConfiguration()
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
            publishSessionList(broadcast: false)
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

    // MARK: - Session list adapter

    private func publishSessionList(broadcast: Bool = true) {
        let conversations = buildConversationSummaries()
        facade.update(conversations: conversations)
        guard broadcast, isEnabled else { return }
        server.broadcast(.sessionList(facade.sessionList(at: Date())))
    }

    private func buildConversationSummaries() -> [RemoteConversationSummary] {
        let registry = sessionRuntimeStore.sessionRegistry
        var summaries: [RemoteConversationSummary] = []

        for sessionID in registry.sessionOrder {
            guard let record = registry.sessionsByID[sessionID],
                  record.isActive,
                  record.agent != .processWatch,
                  registry.activeSessionIDByPanelID[record.panelID] == sessionID else {
                continue
            }
            guard let workspace = store.state.workspacesByID[record.workspaceID],
                  case .terminal(let terminalState) = workspace.panels[record.panelID] else {
                continue
            }

            let conversationID: RemoteConversationID
            if let existing = terminalState.remoteConversationID {
                conversationID = existing
            } else {
                let minted = RemoteConversationID()
                guard store.send(.updateTerminalPanelRemoteConversationID(
                    panelID: record.panelID,
                    remoteConversationID: minted
                )) else {
                    continue
                }
                conversationID = minted
            }

            summaries.append(RemoteConversationSummary(
                conversationID: conversationID,
                provider: record.agent,
                title: record.displayTitleOverride ?? terminalState.displayPanelLabel,
                placement: RemoteConversationPlacement(
                    workspaceID: record.workspaceID,
                    workspaceTitle: workspace.title,
                    panelID: record.panelID
                ),
                cwd: record.cwd,
                state: record.status.map { Self.remoteState(for: $0.kind) } ?? .starting,
                inputAvailability: .unavailable(reason: .unknownProviderState),
                latestSequence: 0,
                updatedAt: record.updatedAt
            ))
        }
        return summaries
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
