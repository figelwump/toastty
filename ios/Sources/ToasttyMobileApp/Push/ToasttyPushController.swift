import Foundation
import Observation
import RemoteProtocol
import ToasttyMobileDomain

@MainActor
protocol ToasttyPushInstallationIdentifying: AnyObject {
    var installationID: UUID? { get set }
}

@MainActor
final class ToasttyPushInstallationMarker: ToasttyPushInstallationIdentifying {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var installationID: UUID? {
        get { defaults.string(forKey: "toastty.push.installation-id").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: "toastty.push.installation-id") }
    }
}

enum ToasttyPushPresentation: Equatable { case unavailable, off, turningOff, permissionDenied, pending, enabled }

@MainActor
@Observable
final class ToasttyPushController {
    private(set) var permission: ToasttyNotificationPermission = .undetermined
    private(set) var errorMessage: String?
    private(set) var configurationMatches = false
    private(set) var pendingConversationID: UUID?
    private(set) var storedState: MobilePushState?

    let configuration: ToasttyPushConfiguration?
    private let vault: any AppSessionCredentialVault
    private let store: any MobilePushStateStoring
    private let notifications: any ToasttyPushNotificationClient
    private let installation: any ToasttyPushInstallationIdentifying
    private let relayFactory: @Sendable (URL) -> any PushRelayClientProtocol
    private let nativeFactory: @Sendable (URL, any GatewayCredentialProvider) -> any NativePushClientProtocol
    private let now: @Sendable () -> Date
    private let buildID: String
    private let automaticallyReconciles: Bool
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var onDiagnosticRecord: @MainActor (ToasttyDiagnosticRecord) -> Void = { _ in }
    private var onDiagnosticSnapshot: @MainActor (ToasttyPushSetupSnapshot) -> Void = { _ in }
    private var lastDiagnosticSnapshot: ToasttyPushSetupSnapshot?
    private var lastRecordedDiagnosticReturn: DiagnosticReturnKey?
    private var diagnosticAction: ToasttyPushSetupSnapshot.Action?
    private var diagnosticReturn: ToasttyPushSetupSnapshot.ReturnReason?
    private var diagnosticReturnAt: Date?
    private var diagnosticResultSequence: UInt64 = 0
    private var lastVerificationRequest: (registrationID: UUID, startedAt: Date)?
    private var retryScheduledAt: Date?
    private var diagnosticRegistrations: [(id: UUID, number: UInt64)] = []
    private var nextDiagnosticRegistration: UInt64 = 1
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    private var retryWakeID: UUID?
    private var transientRetryAt: Date?
    private var relayRetryAt: Date?
    private var cleanupRetryAt: Date?
    private var consecutiveFailures = 0
    private var cleanupFailures = 0
    private var invalidToken = false
    private var reportedFailures: Set<ToasttyPushFailureDiagnosticKey> = []
    private var context: Context?
    private var revision: UInt64 = 0
    private var isForeground = true
    private var reconciling = false
    private var reconcileScheduled = false
    private var reconcileAgain = false
    private var proofOperations: Set<UUID> = []
    private var token: String?
    private var requestedToken = false
    private var queuedTaps: [RemotePushPayload] = []
    private var queuedProofs: [RemotePushPayload] = []
    private var openConversationID: UUID?

    var desired: Bool { storedState?.desired == true }
    var stateIsLoaded: Bool { storedState != nil }
    var canIntroduce: Bool {
        configuration != nil && configurationMatches && context?.connected == true && context?.supported == true
            && storedState?.introHandled == false && permission != .denied
    }
    var presentation: ToasttyPushPresentation {
        guard configuration != nil, storedState != nil else { return .unavailable }
        guard desired else { return storedState?.cleanup.isEmpty == false || storedState?.needsMacClear == true ? .turningOff : .off }
        guard permission != .denied else { return .permissionDenied }
        guard permission == .allowed else { return .off }
        if storedState?.pending != nil || storedState?.active?.stage != .enabled { return .pending }
        return .enabled
    }

    init(configuration: ToasttyPushConfiguration?, vault: any AppSessionCredentialVault,
         store: any MobilePushStateStoring = KeychainMobilePushStateStore(),
         notifications: (any ToasttyPushNotificationClient)? = nil,
         installation: any ToasttyPushInstallationIdentifying = ToasttyPushInstallationMarker(),
         bridge: ToasttyPushNotificationBridge? = nil,
         relayFactory: @escaping @Sendable (URL) -> any PushRelayClientProtocol = { PushRelayClient(baseURL: $0) },
         nativeFactory: @escaping @Sendable (URL, any GatewayCredentialProvider) -> any NativePushClientProtocol = {
             NativePushClient(baseURL: $0, credentialProvider: $1)
         }, now: @escaping @Sendable () -> Date = Date.init,
         buildID: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
         automaticallyReconciles: Bool = true,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.configuration = configuration; self.vault = vault; self.store = store
        self.notifications = notifications ?? ToasttySystemPushNotificationClient(bridge: bridge)
        self.installation = installation
        self.relayFactory = relayFactory; self.nativeFactory = nativeFactory; self.now = now; self.buildID = buildID
        self.automaticallyReconciles = automaticallyReconciles
        self.sleep = sleep
        token = bridge?.deviceToken
    }

    deinit { retryTask?.cancel() }

    func installDiagnosticEventHandler(_ handler: @escaping @MainActor (ToasttyConnectionDiagnosticEvent) -> Void) {
        onDiagnosticRecord = { handler($0.event) }
    }

    func installDiagnosticRecordHandler(_ handler: @escaping @MainActor (ToasttyDiagnosticRecord) -> Void) {
        onDiagnosticRecord = handler
    }

    var diagnosticSnapshot: ToasttyPushSetupSnapshot {
        let stage: ToasttyPushSetupSnapshot.Stage
        if storedState == nil { stage = .unavailable }
        else if let pending = storedState?.pending {
            switch pending.stage {
            case .pending: stage = pending.nonce == nil ? .awaitingProof : .proofSaved
            case .relayActive: stage = .relayActive
            case .enabled: stage = .enabled
            }
        } else if storedState?.active?.stage == .enabled { stage = .enabled }
        else { stage = .idle }
        let diagnosticPermission: ToasttyPushSetupSnapshot.Permission
        switch permission {
        case .undetermined: diagnosticPermission = .undetermined
        case .allowed: diagnosticPermission = .allowed
        case .denied: diagnosticPermission = .denied
        }
        return ToasttyPushSetupSnapshot(stage: stage, foreground: isForeground,
            reconciling: reconciling, activeRegistrationEnabled: storedState?.active?.stage == .enabled,
            permission: diagnosticPermission, connected: context?.connected == true, desired: desired, tokenPresent: token != nil,
            configurationMatches: configurationMatches, savedCooldownUntil: storedState?.retryAfter,
            cooldownUntil: relayCooldown,
            retryScheduledAt: retryScheduledAt, cleanupCount: storedState?.cleanup.count ?? 0,
            lastAction: diagnosticAction, lastReturnReason: diagnosticReturn,
            lastReturnAt: diagnosticReturnAt, resultSequence: diagnosticResultSequence)
    }

    func installDiagnosticSnapshotHandler(_ handler: @escaping @MainActor (ToasttyPushSetupSnapshot) -> Void) {
        onDiagnosticSnapshot = handler
        let snapshot = diagnosticSnapshot
        lastDiagnosticSnapshot = snapshot
        handler(snapshot)
    }

    private func publishDiagnosticSnapshot(_ snapshot: ToasttyPushSetupSnapshot? = nil) {
        let snapshot = snapshot ?? diagnosticSnapshot
        guard snapshot != lastDiagnosticSnapshot else { return }
        lastDiagnosticSnapshot = snapshot
        onDiagnosticSnapshot(snapshot)
    }

    private func diagnosticReturned(_ action: ToasttyPushSetupSnapshot.Action,
                                    _ reason: ToasttyPushSetupSnapshot.ReturnReason) {
        diagnosticAction = action
        diagnosticReturn = reason
        diagnosticReturnAt = now()
        diagnosticResultSequence &+= 1
        let snapshot = diagnosticSnapshot
        publishDiagnosticSnapshot(snapshot)
        // Repeated no-op requests must not evict proof and network evidence.
        guard reason != .background, reason != .reconcileInProgress else { return }
        let key = DiagnosticReturnKey(action: action, reason: reason, stage: snapshot.stage,
            cooldownUntil: snapshot.cooldownUntil, savedCooldownUntil: snapshot.savedCooldownUntil)
        guard key != lastRecordedDiagnosticReturn else { return }
        lastRecordedDiagnosticReturn = key
        onDiagnosticRecord(ToasttyDiagnosticRecord(event: .pushSetupReturned,
            recordedAt: diagnosticReturnAt ?? .now, pushSnapshot: snapshot))
    }

    private struct DiagnosticReturnKey: Equatable {
        let action: ToasttyPushSetupSnapshot.Action
        let reason: ToasttyPushSetupSnapshot.ReturnReason
        let stage: ToasttyPushSetupSnapshot.Stage
        let cooldownUntil: Date?
        let savedCooldownUntil: Date?
    }

    /// Attach only after SwiftUI retains its State controller. Root view
    /// construction can otherwise replace these handlers with a discarded
    /// controller during a later body update.
    func attachBridge(_ bridge: ToasttyPushNotificationBridge) {
        bridge.onDiagnosticRecord = { [weak self] record in self?.onDiagnosticRecord(record) }
        emit(.pushBridgeAttached)
        if let token = bridge.deviceToken { receivedToken(token) }
        bridge.onToken = { [weak self] in self?.receivedToken($0) }
        bridge.onRegistrationFailure = { [weak self] in
            guard let self, self.desired, self.isForeground else { return }
            self.requestedToken = false
            self.errorMessage = "Couldn’t connect to Apple notifications. Try again."
            self.transientRetryAt = self.now().addingTimeInterval(self.nextRetryDelay())
            self.armRetry()
        }
        bridge.onForeground = { [weak self] payload in
            guard let self else { return true }
            if payload.kind == .verification {
                Task { await self.acceptProof(payload) }
                return true
            }
            return await self.receiveForeground(payload)
        }
        bridge.onTap = { [weak self] in self?.receiveTap($0) }
    }

    func restore() async {
        guard storedState == nil else { return }
        var result: ToasttyPushSetupSnapshot.ReturnReason = .completed
        defer { diagnosticReturned(.restore, result) }
        do {
            let loaded = try store.load()
            var state = loaded ?? MobilePushState(installationID: installation.installationID ?? UUID())
            if loaded != nil, installation.installationID != state.installationID {
                state.queueCleanup()
                state.desired = false
                state.introHandled = false
                state.needsMacClear = true
                state.installationID = UUID()
            }
            try store.save(state)
            storedState = state
            for registration in [state.active, state.pending].compactMap({ $0 }) {
                registerDiagnosticRegistration(registration)
                emit(.pushRegistrationRestored, registration: registration)
            }
            installation.installationID = state.installationID
            let proofs = queuedProofs
            queuedProofs.removeAll()
            for payload in proofs { Task { await acceptProof(payload) } }
        } catch {
            result = .stateUnavailable
            recordFailure(.pushStateUnavailable)
            errorMessage = error as? MobilePushStoreFailure == .locked
                ? "Unlock this iPhone to finish notification setup."
                : "Couldn’t save notification settings. Try again."
            transientRetryAt = now().addingTimeInterval(nextRetryDelay())
        }
    }

    func updateConnection(gatewayURL: URL?, pairingID: UUID?, connected: Bool, supported: Bool,
                          connectionGeneration: UInt64 = 0) {
        let next = gatewayURL.flatMap { url in pairingID.map { Context(gatewayURL: url, pairingID: $0,
            connected: connected, supported: supported, connectionGeneration: connectionGeneration) } }
        guard context != next else { return }
        defer { publishDiagnosticSnapshot() }
        cancelRetry()
        if context?.pairingID != next?.pairingID || context?.gatewayURL != next?.gatewayURL {
            reportedFailures.removeAll()
        }
        consecutiveFailures = 0
        transientRetryAt = nil
        revision &+= 1
        configurationMatches = false
        if context?.pairingID != next?.pairingID { pendingConversationID = nil }
        context = next
        if let next {
            let queued = queuedTaps
            queuedTaps.removeAll()
            for payload in queued where payload.pairingID == next.pairingID { receiveTap(payload) }
        }
        scheduleReconcile()
    }

    func enteredBackground() { isForeground = false; revision &+= 1; cancelRetry(); publishDiagnosticSnapshot() }
    func enteredForeground() {
        defer { publishDiagnosticSnapshot() }
        isForeground = true
        requestedToken = false
        consecutiveFailures = 0
        transientRetryAt = nil
        scheduleReconcile()
    }
    func setOpenConversation(_ id: UUID?) { openConversationID = id }
    func consumedConversationTap() { pendingConversationID = nil }

    /// Persist intent before opening the OS prompt. Only permission blocks
    /// the intro; the delivery proof and Mac handoff run after dismissal.
    func continueIntroduction() async {
        do { try persist { $0.introHandled = true; $0.desired = true } }
        catch { errorMessage = "Couldn’t save notification settings. Try again."; return }
        do { permission = try await notifications.requestPermission() ? .allowed : .denied }
        catch { errorMessage = "Couldn’t request notification permission. Try again." }
        scheduleReconcile()
    }

    func deferIntroduction() async {
        await setDesired(false)
    }

    func setDesired(_ value: Bool) async {
        errorMessage = nil
        transientRetryAt = nil
        consecutiveFailures = 0
        if value {
            do { try persist { $0.desired = true; $0.introHandled = true } }
            catch { errorMessage = "Couldn’t save notification settings. Try again."; return }
            revision &+= 1
            let intentRevision = revision
            permission = await notifications.permission()
            if permission == .undetermined {
                do {
                    let allowed = try await notifications.requestPermission()
                    guard revision == intentRevision, desired else { return }
                    permission = allowed ? .allowed : .denied
                }
                catch { errorMessage = "Couldn’t request notification permission. Try again."; return }
            }
        } else {
            do {
                try persist {
                    $0.introHandled = true
                    $0.desired = false
                    $0.needsMacClear = $0.needsMacClear || $0.active != nil || $0.pending != nil || !$0.cleanup.isEmpty
                    $0.queueCleanup()
                }
            }
            catch { errorMessage = "Couldn’t save notification settings. Try again."; return }
            revision &+= 1
        }
        scheduleReconcile()
    }

    func retry() {
        var result: ToasttyPushSetupSnapshot.ReturnReason = .requested
        defer { diagnosticReturned(.retry, result) }
        if invalidToken || (storedState?.blockedDeviceToken == token && storedState?.blockedBuildID == buildID) {
            result = .invalidToken; return
        }
        if relayCooldown.map({ now() < $0 }) == true { result = .relayCooldown; return }
        errorMessage = nil
        transientRetryAt = nil
        consecutiveFailures = 0
        requestedToken = false
        if desired, permission == .undetermined {
            Task { await setDesired(true) }
            return
        }
        scheduleReconcile()
    }

    /// Called before the pairing credential is removed. Relay cleanup does
    /// not need that credential and survives an unreachable Mac.
    @discardableResult
    func prepareForUnpair(pairingID: UUID? = nil) async -> Bool {
        pendingConversationID = nil
        queuedTaps.removeAll()
        await restore()
        if let pairingID, let context, context.pairingID != pairingID { return true }
        do { try persist { $0.desired = false; $0.queueCleanup(); $0.needsMacClear = false } }
        catch { errorMessage = "Couldn’t save notification cleanup. Try again."; return false }
        revision &+= 1
        scheduleReconcile()
        return true
    }

    func receivedToken(_ value: String) {
        defer { publishDiagnosticSnapshot() }
        guard KeychainMobilePushStateStore.isDeviceToken(value) else { return }
        emit(.pushTokenReceived)
        let changed = token != value
        token = value
        if changed {
            invalidToken = false
            transientRetryAt = nil
            consecutiveFailures = 0
            revision &+= 1
            scheduleReconcile()
        }
    }

    func receiveForeground(_ payload: RemotePushPayload) async -> Bool {
        guard payload.isValid else { return true }
        if payload.kind == .verification {
            await acceptProof(payload)
            return true
        }
        guard context?.pairingID == payload.pairingID else { return true }
        return payload.conversationID?.rawValue == openConversationID
    }

    func receiveTap(_ payload: RemotePushPayload) {
        guard payload.isValid, payload.kind == .session else { return }
        guard let context else { queuedTaps = Array((queuedTaps + [payload]).suffix(8)); return }
        guard payload.pairingID == context.pairingID else { return }
        pendingConversationID = payload.conversationID?.rawValue
    }

    /// One reconciliation path handles foreground, connection, token, and
    /// retry events. Proof completion can run alongside a pending begin HTTP
    /// call because APNs may deliver before that HTTP call returns.
    func reconcile() async {
        var result: ToasttyPushSetupSnapshot.ReturnReason = .completed
        // Registered before the scheduling defer so the report includes the actual wake.
        defer { diagnosticReturned(.reconcile, result) }
        guard isForeground else { result = .background; return }
        guard !reconciling else { reconcileAgain = true; result = .reconcileInProgress; return }
        cancelRetry()
        reconciling = true
        publishDiagnosticSnapshot()
        defer {
            reconciling = false
            if reconcileAgain { reconcileAgain = false; scheduleReconcile() }
            else { armRetry() }
        }
        await restore()
        guard storedState != nil else { result = .stateUnavailable; return }
        await cleanupRegistrations()
        permission = await notifications.permission()
        guard isForeground else { result = .background; return }
        guard let configuration else { result = .configurationUnavailable; return }
        guard let context else { result = .unpaired; return }
        guard context.connected else { result = .disconnected; return }
        guard context.supported else { result = .unsupported; return }
        if automaticallyReconciles, transientRetryAt.map({ now() < $0 }) == true { result = .transientBackoff; return }
        transientRetryAt = nil
        let operationRevision = revision
        let generation = await vault.currentGeneration()
        guard let credential = await vault.currentCredential(), credential.gatewayURL == context.gatewayURL,
              credential.device.id == context.pairingID else { result = .credentialUnavailable; return }
        guard await isCurrent(operationRevision, generation: generation) else { result = .contextChanged; return }
        let native = nativeFactory(context.gatewayURL, ToasttyPushCredentialProvider(vault: vault,
            gatewayURL: context.gatewayURL, pairingID: context.pairingID, generation: generation))
        var operationRegistration: MobilePushRegistration?
        var operationDiagnostic: PushRelayDiagnostic?
        var failedOperation = ToasttyConnectionDiagnosticEvent.pushStateUnavailable
        do {
            try abandonOtherPairing(context)
            await cleanupRegistrations()
            failedOperation = .pushMacConfigurationFailed
            let host = try await native.configuration()
            guard await isCurrent(operationRevision, generation: generation) else { result = .contextChanged; return }
            configurationMatches = host.relayID == configuration.relayID && host.apnsEnvironment == configuration.apnsEnvironment
            if !desired {
                if storedState?.needsMacClear == true || host.registrationID != nil {
                    failedOperation = .pushMacRegistrationFailed
                    _ = try await native.setRegistration(nil)
                    guard await isCurrent(operationRevision, generation: generation) else { result = .contextChanged; return }
                    try persist { $0.needsMacClear = false }
                }
                result = .alertsOff
                return
            }
            guard configurationMatches else {
                if desired { errorMessage = "Notification settings on this iPhone and Mac do not match." }
                result = .configurationMismatch
                return
            }
            guard await isCurrent(operationRevision, generation: generation) else { result = .contextChanged; return }
            guard permission == .allowed else { result = .permissionRequired; return }
            if !requestedToken { requestedToken = true; emit(.pushTokenRequested); notifications.register() }
            let pending = storedState?.pending
            let requestTime = lastVerificationRequest.flatMap {
                $0.registrationID == pending?.registrationID ? $0.startedAt : nil
            }
            let delivered = await notifications.deliveredPayloads(context: .init(
                pendingRegistrationID: pending?.registrationID, pairingID: context.pairingID,
                referenceAt: requestTime ?? pending?.createdAt,
                referenceKind: requestTime != nil ? .requestStarted : pending != nil ? .pendingCreated : .none))
            for payload in delivered where payload.kind == .verification { await acceptProof(payload) }
            let consumedProofs = delivered.filter { payload in
                guard payload.kind == .verification else { return false }
                guard let pending = storedState?.pending, pending.registrationID == payload.registrationID else {
                    return true
                }
                // Keep the delivered proof if saving its nonce failed. It is
                // the only recovery source after a later app restart.
                return pending.nonce != nil || pending.stage != .pending
            }
            await notifications.removeVerificationNotifications(registrationIDs: Set(consumedProofs.map(\.registrationID)))
            guard await isCurrent(operationRevision, generation: generation) else { result = .contextChanged; return }
            guard let token else { result = .tokenPending; return }
            if invalidToken || (storedState?.blockedDeviceToken == token && storedState?.blockedBuildID == buildID) {
                errorMessage = "Apple could not use this notification token. Check this app’s notification build settings."
                result = .invalidToken
                return
            }
            if relayCooldown.map({ now() < $0 }) == true {
                errorMessage = "Notification setup is busy. Try again later."
                result = .relayCooldown
                return
            }
            if storedState?.blockedDeviceToken != nil {
                try persist { state in
                    if let pending = state.pending { state.cleanup.append(pending); state.pending = nil }
                    state.blockedDeviceToken = nil; state.blockedBuildID = nil; state.retryAfter = nil
                }
            }
            if var active = storedState?.active,
               active.deviceToken == token, active.relayURL == configuration.relayURL,
               active.relayID == configuration.relayID, storedState?.pending == nil {
                operationRegistration = active
                failedOperation = .pushRelayStatusFailed
                let status = try await relayFactory(active.relayURL).status(active)
                guard await isCurrent(operationRevision, generation: generation) else { result = .contextChanged; return }
                if status.state == "active" {
                    if host.registrationID != active.registrationID {
                        failedOperation = .pushMacRegistrationFailed
                        _ = try await native.setRegistration(grant(active))
                        guard await isCurrent(operationRevision, generation: generation) else { result = .contextChanged; return }
                    }
                    active.stage = .enabled
                    try persist { $0.active = active; $0.retryAfter = nil }
                    errorMessage = nil
                    succeeded(.pushRegistrationReused, registration: active)
                    return
                }
                try persist { $0.cleanup.append(active); $0.active = nil }
            }
            if let pending = storedState?.pending,
               pending.deviceToken != token || pending.relayURL != configuration.relayURL
                || pending.relayID != configuration.relayID
                || (pending.stage == .pending && pending.nonce == nil && now().timeIntervalSince(pending.createdAt) >= 300) {
                emit(pending.deviceToken != token ? .pushTokenChanged
                    : pending.relayURL != configuration.relayURL || pending.relayID != configuration.relayID
                        ? .pushRelayChanged : .pushProofExpired, registration: pending)
                try persist { $0.cleanup.append(pending); $0.pending = nil }
            }
            if storedState?.pending == nil {
                guard (storedState?.cleanup.count ?? 0) < 124 else {
                    errorMessage = "Finish turning off older alerts before enabling notifications again."
                    result = .cleanupFull
                    return
                }
                let attempt = MobilePushRegistration(pairingID: context.pairingID, gatewayURL: context.gatewayURL,
                    relayURL: configuration.relayURL, relayID: configuration.relayID, deviceToken: token,
                    managementToken: try KeychainMobilePushStateStore.randomCapability(),
                    sendToken: try KeychainMobilePushStateStore.randomCapability(), createdAt: now())
                try persist { $0.pending = attempt }
                registerDiagnosticRegistration(attempt)
                if let active = storedState?.active {
                    emit(active.deviceToken != token ? .pushTokenChanged
                        : active.relayURL != configuration.relayURL || active.relayID != configuration.relayID
                            ? .pushRelayChanged : .pushRegistrationMissing, registration: attempt)
                } else { emit(.pushRegistrationMissing, registration: attempt) }
            }
            guard let attempt = storedState?.pending else { result = .contextChanged; return }
            if attempt.stage == .pending {
                if attempt.nonce != nil { await finishProof(attempt, operationRevision: operationRevision, generation: generation) }
                else if attempt.expiresAt == nil {
                    operationRegistration = attempt
                    failedOperation = .pushRelayBeginFailed
                    let capture = ToasttyPushDiagnosticCapture()
                    lastVerificationRequest = (attempt.registrationID, now())
                    emit(.pushVerificationStarted, registration: attempt)
                    let response: PushRelayBeginResponse
                    do {
                        response = try await relayFactory(attempt.relayURL).begin(attempt, onDiagnostic: capture.record)
                        operationDiagnostic = capture.value
                        emit(.pushVerificationResponse, registration: attempt, relay: operationDiagnostic)
                    } catch {
                        operationDiagnostic = capture.value
                        if operationDiagnostic != nil {
                            emit(.pushVerificationResponse, registration: attempt, relay: operationDiagnostic)
                        }
                        throw error
                    }
                    guard await isCurrent(operationRevision, generation: generation), storedState?.pending?.registrationID == attempt.registrationID else {
                        emit(.pushSetupContextChanged, registration: attempt)
                        result = .contextChanged
                        return
                    }
                    try persist { state in
                        guard var current = state.pending, current.stage == .pending else { return }
                        current.expiresAt = response.expiresAt.map(Date.init(timeIntervalSince1970:))
                        if response.state == "active" { current.stage = .relayActive }
                        state.pending = current
                    }
                    consecutiveFailures = 0
                }
            }
            guard let ready = storedState?.pending, ready.stage == .relayActive,
                  await isCurrent(operationRevision, generation: generation) else {
                if storedState?.pending == nil || storedState?.pending?.stage == .relayActive { result = .contextChanged }
                else if relayCooldown.map({ now() < $0 }) == true { result = .relayCooldown }
                else if storedState?.pending?.nonce != nil { result = .proofCompletionPending }
                else { result = .awaitingProof }
                return
            }
            operationRegistration = ready
            failedOperation = .pushMacRegistrationFailed
            operationDiagnostic = nil
            emit(.pushMacHandoffStarted, registration: ready)
            _ = try await native.setRegistration(grant(ready))
            guard await isCurrent(operationRevision, generation: generation), storedState?.pending?.registrationID == ready.registrationID else { result = .contextChanged; return }
            try persist { state in
                if let old = state.active { state.cleanup.append(old) }
                var enabled = ready; enabled.stage = .enabled; enabled.nonce = nil
                state.active = enabled; state.pending = nil; state.needsMacClear = false; state.retryAfter = nil
            }
            errorMessage = nil
            succeeded(.pushRegistrationEnabled, registration: ready)
        } catch {
            guard !Self.isCancellation(error) else { result = .cancelled; return }
            let current = await isCurrent(operationRevision, generation: generation)
            result = current ? .operationFailed : .contextChanged
            if !current { emit(.pushSetupContextChanged, registration: operationRegistration) }
            if current || operationRegistration.map(isStoredRegistration) == true {
                if current { recordFailure(error is MobilePushStoreFailure ? .pushStateUnavailable : failedOperation,
                    registration: operationRegistration) }
                handleFailure(error, registration: operationRegistration, displayError: current, relay: operationDiagnostic)
            }
        }
    }

    private func acceptProof(_ payload: RemotePushPayload) async {
        guard payload.kind == .verification else { return }
        // Unknown payload IDs never create a diagnostic registration number.
        emit(.pushProofReceived, registrationID: payload.registrationID)
        guard payload.isValid else { emit(.pushProofInvalid, registrationID: payload.registrationID); return }
        guard storedState != nil else {
            emit(.pushProofBuffered)
            queuedProofs = Array((queuedProofs.filter { $0.registrationID != payload.registrationID } + [payload]).suffix(8))
            return
        }
        guard let attempt = storedState?.pending else {
            emit(storedState?.active?.registrationID == payload.registrationID ? .pushProofAlreadyVerified : .pushProofNoPending,
                registrationID: payload.registrationID)
            return
        }
        guard attempt.stage == .pending else { emit(.pushProofAlreadyVerified, registration: attempt); return }
        guard attempt.registrationID == payload.registrationID else {
            emit(.pushProofOtherRegistration, registrationID: payload.registrationID)
            return
        }
        guard attempt.pairingID == payload.pairingID else { emit(.pushProofOtherPairing, registration: attempt); return }
        guard let nonce = payload.nonce else { emit(.pushProofInvalid, registration: attempt); return }
        guard desired else { emit(.pushProofDisabled, registration: attempt); return }
        do { try persist { $0.pending?.nonce = nonce } }
        catch {
            emit(.pushProofSaveFailed, registration: attempt)
            handleFailure(error)
            return
        }
        guard isForeground else { emit(.pushProofDeferredBackground, registration: attempt); return }
        guard context?.connected == true else { emit(.pushProofDeferredDisconnected, registration: attempt); return }
        guard context?.pairingID == payload.pairingID else { emit(.pushProofDeferredPairing, registration: attempt); return }
        guard configurationMatches else { emit(.pushProofDeferredConfiguration, registration: attempt); return }
        let operationRevision = revision
        transientRetryAt = nil
        let generation = await vault.currentGeneration()
        guard let current = storedState?.pending, current.registrationID == payload.registrationID else { return }
        await finishProof(current, operationRevision: operationRevision, generation: generation)
        if storedState?.pending?.stage == .relayActive { scheduleReconcile() }
        else { armRetry() }
    }

    private func finishProof(_ attempt: MobilePushRegistration, operationRevision: UInt64,
                             generation: MobileCredentialGeneration) async {
        guard relayCooldown.map({ now() >= $0 }) ?? true else { return }
        guard let nonce = attempt.nonce, attempt.stage == .pending,
              proofOperations.insert(attempt.registrationID).inserted else { return }
        defer { proofOperations.remove(attempt.registrationID) }
        guard await isCurrent(operationRevision, generation: generation),
              context?.pairingID == attempt.pairingID,
              storedState?.pending?.registrationID == attempt.registrationID,
              storedState?.pending?.stage == .pending else { return }
        do {
            emit(.pushProofCompletionStarted, registration: attempt)
            let response = try await relayFactory(attempt.relayURL).complete(attempt, nonce: nonce)
            guard response.state == "active", response.pairingID == attempt.pairingID else {
                throw PushRelayFailure.invalidResponse
            }
            guard await isCurrent(operationRevision, generation: generation),
                  storedState?.pending?.registrationID == attempt.registrationID else { return }
            try persist { $0.pending?.stage = .relayActive; $0.pending?.nonce = nil }
            emit(.pushProofCompleted, registration: attempt)
            consecutiveFailures = 0
            errorMessage = nil
        } catch {
            guard !Self.isCancellation(error) else { return }
            guard storedState?.pending?.registrationID == attempt.registrationID else {
                emit(.pushSetupContextChanged, registration: attempt)
                return
            }
            let current = await isCurrent(operationRevision, generation: generation)
            if !current { emit(.pushSetupContextChanged, registration: attempt) }
            if current { recordFailure(.pushRelayCompleteFailed, registration: attempt) }
            handleFailure(error, registration: attempt, displayError: current)
        }
    }

    private func cleanupRegistrations() async {
        guard cleanupCooldown.map({ now() >= $0 }) ?? true else { return }
        for item in Array((storedState?.cleanup ?? []).prefix(4)) {
            guard isForeground else { return }
            do {
                try await relayFactory(item.relayURL).revoke(item)
                try persist { $0.cleanup.removeAll { $0.registrationID == item.registrationID } }
                cleanupFailures = 0
                cleanupRetryAt = nil
            } catch {
                guard !Self.isCancellation(error) else { return }
                recordFailure(.pushRelayRevokeFailed)
                let delay: TimeInterval
                if case .rateLimited(let retry)? = error as? PushRelayFailure { delay = retry }
                else {
                    delay = min(600, 30 * pow(2, Double(cleanupFailures)))
                    cleanupFailures = min(cleanupFailures + 1, 5)
                }
                let deadline = now().addingTimeInterval(delay)
                cleanupRetryAt = deadline
                persistFailureState { state in
                    state.cleanupRetryAfter = deadline
                    if let index = state.cleanup.firstIndex(where: { $0.registrationID == item.registrationID }) {
                        let failed = state.cleanup.remove(at: index)
                        state.cleanup.append(failed)
                    }
                }
                if !desired { errorMessage = "Notifications are waiting to turn off. Retry when connected." }
                break
            }
        }
    }

    private func abandonOtherPairing(_ context: Context) throws {
        let mismatched = [storedState?.active, storedState?.pending].compactMap { $0 }.filter {
            $0.pairingID != context.pairingID || $0.gatewayURL != context.gatewayURL
        }
        guard !mismatched.isEmpty else { return }
        emit(.pushPairingChanged)
        try persist { state in
            state.cleanup.append(contentsOf: mismatched)
            if mismatched.contains(where: { $0.registrationID == state.active?.registrationID }) { state.active = nil }
            if mismatched.contains(where: { $0.registrationID == state.pending?.registrationID }) { state.pending = nil }
        }
    }

    private func grant(_ value: MobilePushRegistration) -> RemoteGatewayPushRegistration {
        RemoteGatewayPushRegistration(registrationID: value.registrationID, sendToken: value.sendToken, relayID: value.relayID)
    }
    private func isCurrent(_ operationRevision: UInt64, generation: MobileCredentialGeneration) async -> Bool {
        guard isForeground, revision == operationRevision else { return false }
        return await vault.currentGeneration() == generation
    }
    private func persist(_ update: (inout MobilePushState) -> Void) throws {
        guard var state = storedState else { throw MobilePushStoreFailure.unavailable }
        update(&state)
        var seen: Set<UUID> = []
        state.cleanup = state.cleanup.compactMap { value in
            guard seen.insert(value.registrationID).inserted else { return nil }
            var clean = value; clean.nonce = nil; return clean
        }
        try store.save(state)
        storedState = state
        publishDiagnosticSnapshot()
    }
    private func scheduleReconcile() {
        guard isForeground, automaticallyReconciles, !reconcileScheduled else { return }
        reconcileScheduled = true
        Task { [weak self] in
            guard let self else { return }
            self.reconcileScheduled = false
            await self.reconcile()
        }
    }

    private func cancelRetry() {
        retryWakeID = nil
        retryTask?.cancel()
        retryTask = nil
        retryScheduledAt = nil
    }

    private var relayCooldown: Date? { [storedState?.retryAfter, relayRetryAt].compactMap { $0 }.max() }
    private var cleanupCooldown: Date? { [storedState?.cleanupRetryAfter, cleanupRetryAt].compactMap { $0 }.max() }

    /// Session snapshots are not a retry clock. Keep one foreground wake for
    /// incomplete work, including cleanup after the pairing has been removed.
    private func armRetry() {
        defer { publishDiagnosticSnapshot() }
        cancelRetry()
        guard isForeground, automaticallyReconciles else { return }
        var deadlines: [Date] = []
        if storedState?.cleanup.isEmpty == false {
            deadlines.append(cleanupCooldown ?? now().addingTimeInterval(1))
        }
        if configuration != nil, let context, context.connected, context.supported {
            if let transientRetryAt { deadlines.append(transientRetryAt) }
            let blocked = invalidToken || (storedState?.blockedDeviceToken == token && storedState?.blockedBuildID == buildID)
            if desired, permission == .allowed, configurationMatches, token != nil, !blocked {
                if let cooldown = relayCooldown, now() < cooldown { deadlines.append(cooldown) }
                else if transientRetryAt == nil, let pending = storedState?.pending {
                    if pending.stage == .pending, pending.nonce == nil, pending.expiresAt != nil {
                        deadlines.append(pending.createdAt.addingTimeInterval(300))
                    } else {
                        deadlines.append(now().addingTimeInterval(30))
                    }
                }
            }
        }
        guard let deadline = deadlines.min() else { return }
        let delay = max(1, deadline.timeIntervalSince(now()))
        let wakeID = UUID()
        retryWakeID = wakeID
        retryScheduledAt = now().addingTimeInterval(delay)
        retryTask = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, self.retryWakeID == wakeID else { return }
            self.retryTask = nil
            self.retryWakeID = nil
            self.retryScheduledAt = nil
            self.publishDiagnosticSnapshot()
            // The wake never owns network work, so re-arming cannot cancel it.
            self.scheduleReconcile()
        }
    }

    private func nextRetryDelay() -> TimeInterval {
        let delay = min(600, 30 * pow(2, Double(consecutiveFailures)))
        consecutiveFailures = min(consecutiveFailures + 1, 5)
        return delay
    }

    private func registerDiagnosticRegistration(_ registration: MobilePushRegistration) {
        guard !diagnosticRegistrations.contains(where: { $0.id == registration.registrationID }) else { return }
        diagnosticRegistrations.append((registration.registrationID, nextDiagnosticRegistration))
        nextDiagnosticRegistration &+= 1
        if diagnosticRegistrations.count > 8,
           let index = diagnosticRegistrations.firstIndex(where: {
               $0.id != storedState?.active?.registrationID && $0.id != storedState?.pending?.registrationID
           }) {
            diagnosticRegistrations.remove(at: index)
        }
    }

    private func diagnosticNumber(for id: UUID?) -> UInt64? {
        id.flatMap { id in diagnosticRegistrations.first { $0.id == id }?.number }
    }

    private func emit(_ event: ToasttyConnectionDiagnosticEvent, registration: MobilePushRegistration? = nil,
                      registrationID: UUID? = nil, relay: PushRelayDiagnostic? = nil, retryAfter: TimeInterval? = nil) {
        publishDiagnosticSnapshot()
        let number = diagnosticNumber(for: registration?.registrationID ?? registrationID)
        let details = ToasttyPushDiagnosticDetails(registrationNumber: number, relay: relay, retryAfter: retryAfter)
        onDiagnosticRecord(ToasttyDiagnosticRecord(event: event, pushDetails: details))
    }

    private func recordFailure(_ event: ToasttyConnectionDiagnosticEvent, registration: MobilePushRegistration? = nil,
                               relay: PushRelayDiagnostic? = nil, retryAfter: TimeInterval? = nil) {
        let number = diagnosticNumber(for: registration?.registrationID)
        // Every actual cooldown response matters: the next response may apply
        // a different delay even for the same pending registration.
        if event == .pushRateLimited {
            emit(event, registration: registration, relay: relay, retryAfter: retryAfter)
            return
        }
        if reportedFailures.count >= 128 { reportedFailures.removeAll() }
        if reportedFailures.insert(ToasttyPushFailureDiagnosticKey(event: event, registrationNumber: number)).inserted {
            emit(event, registration: registration, relay: relay, retryAfter: retryAfter)
        }
    }

    private func succeeded(_ event: ToasttyConnectionDiagnosticEvent, registration: MobilePushRegistration) {
        consecutiveFailures = 0
        transientRetryAt = nil
        relayRetryAt = nil
        reportedFailures.removeAll()
        emit(event, registration: registration)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
    private func isStoredRegistration(_ registration: MobilePushRegistration) -> Bool {
        storedState?.pending?.registrationID == registration.registrationID
            || storedState?.active?.registrationID == registration.registrationID
    }
    private func handleFailure(_ error: Error, registration: MobilePushRegistration? = nil, displayError: Bool = true,
                               relay: PushRelayDiagnostic? = nil) {
        guard !Self.isCancellation(error) else { return }
        if error is MobilePushStoreFailure { recordFailure(.pushStateUnavailable) }
        let message: String
        switch error as? PushRelayFailure {
        case .invalidDeviceToken:
            if (registration?.deviceToken ?? token) == token {
                invalidToken = true
                transientRetryAt = nil
                persistFailureState { $0.blockedDeviceToken = token; $0.blockedBuildID = buildID }
            }
            message = "Apple could not use this notification token. Check this app’s notification build settings."
        case .rateLimited(let delay):
            let deadline = now().addingTimeInterval(delay)
            relayRetryAt = deadline
            transientRetryAt = nil
            persistFailureState { $0.retryAfter = deadline }
            recordFailure(.pushRateLimited, registration: registration, relay: relay, retryAfter: delay)
            message = "Notification setup is busy. Try again later."
        case .expired:
            recordFailure(.pushRegistrationExpired)
            if displayError { transientRetryAt = now().addingTimeInterval(nextRetryDelay()) }
            if let pending = storedState?.pending, pending.registrationID == registration?.registrationID {
                persistFailureState { $0.cleanup.append(pending); $0.pending = nil }
            } else if let active = storedState?.active, active.registrationID == registration?.registrationID {
                persistFailureState { $0.cleanup.append(active); $0.active = nil }
            }
            message = "Notification setup expired. Try again."
        default:
            if displayError { transientRetryAt = now().addingTimeInterval(nextRetryDelay()) }
            message = "Couldn’t finish notification setup. Retry when connected."
        }
        if displayError && isForeground { errorMessage = message }
        armRetry()
    }

    private func persistFailureState(_ update: (inout MobilePushState) -> Void) {
        do { try persist(update) }
        catch { recordFailure(.pushStateUnavailable) }
    }
    private struct Context: Equatable {
        let gatewayURL: URL; let pairingID: UUID; let connected: Bool; let supported: Bool
        let connectionGeneration: UInt64
    }
}

/// Check identity and generation before returning a token. A completion
/// guard alone cannot stop a new pairing token going to an old gateway.
struct ToasttyPushCredentialProvider: GatewayCredentialProvider {
    let vault: any AppSessionCredentialVault
    let gatewayURL: URL
    let pairingID: UUID
    let generation: MobileCredentialGeneration
    func credential() async throws -> GatewayCredential? {
        guard await vault.currentGeneration() == generation,
              let credential = await vault.currentCredential(),
              credential.gatewayURL == gatewayURL, credential.device.id == pairingID,
              await vault.currentGeneration() == generation else {
            throw NativeGatewayFailure.unauthenticated(operation: .pushRegistration, reason: .credentialInvalid)
        }
        return .bearer(token: credential.bearerToken)
    }
}
