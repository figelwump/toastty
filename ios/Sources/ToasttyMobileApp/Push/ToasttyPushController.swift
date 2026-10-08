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
    private var context: Context?
    private var revision: UInt64 = 0
    private var isForeground = true
    private var reconciling = false
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
        if storedState?.pending != nil || storedState?.active?.stage != .enabled { return .pending }
        return .enabled
    }

    init(configuration: ToasttyPushConfiguration?, vault: any AppSessionCredentialVault,
         store: any MobilePushStateStoring = KeychainMobilePushStateStore(),
         notifications: any ToasttyPushNotificationClient = ToasttySystemPushNotificationClient(),
         installation: any ToasttyPushInstallationIdentifying = ToasttyPushInstallationMarker(),
         bridge: ToasttyPushNotificationBridge? = nil,
         relayFactory: @escaping @Sendable (URL) -> any PushRelayClientProtocol = { PushRelayClient(baseURL: $0) },
         nativeFactory: @escaping @Sendable (URL, any GatewayCredentialProvider) -> any NativePushClientProtocol = {
             NativePushClient(baseURL: $0, credentialProvider: $1)
         }, now: @escaping @Sendable () -> Date = Date.init,
         buildID: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
         automaticallyReconciles: Bool = true) {
        self.configuration = configuration; self.vault = vault; self.store = store
        self.notifications = notifications; self.installation = installation
        self.relayFactory = relayFactory; self.nativeFactory = nativeFactory; self.now = now; self.buildID = buildID
        self.automaticallyReconciles = automaticallyReconciles
        token = bridge?.deviceToken
    }

    /// Attach only after SwiftUI retains its State controller. Root view
    /// construction can otherwise replace these handlers with a discarded
    /// controller during a later body update.
    func attachBridge(_ bridge: ToasttyPushNotificationBridge) {
        if let token = bridge.deviceToken { receivedToken(token) }
        bridge.onToken = { [weak self] in self?.receivedToken($0) }
        bridge.onRegistrationFailure = { [weak self] in
            guard let self, self.desired, self.isForeground else { return }
            self.requestedToken = false
            self.errorMessage = "Couldn’t connect to Apple notifications. Try again."
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
            installation.installationID = state.installationID
            let proofs = queuedProofs
            queuedProofs.removeAll()
            for payload in proofs { Task { await acceptProof(payload) } }
        } catch {
            errorMessage = error as? MobilePushStoreFailure == .locked
                ? "Unlock this iPhone to finish notification setup."
                : "Couldn’t save notification settings. Try again."
        }
    }

    func updateConnection(gatewayURL: URL?, pairingID: UUID?, connected: Bool, supported: Bool) {
        let next = gatewayURL.flatMap { url in pairingID.map { Context(gatewayURL: url, pairingID: $0, connected: connected, supported: supported) } }
        if context != next {
            revision &+= 1
            configurationMatches = false
            if context?.pairingID != next?.pairingID { pendingConversationID = nil }
        }
        context = next
        if !connected { configurationMatches = false }
        if let next {
            let queued = queuedTaps
            queuedTaps.removeAll()
            for payload in queued where payload.pairingID == next.pairingID { receiveTap(payload) }
        }
        scheduleReconcile()
    }

    func enteredBackground() { isForeground = false; revision &+= 1 }
    func enteredForeground() { isForeground = true; requestedToken = false; scheduleReconcile() }
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

    func deferIntroduction() {
        do { try persist { $0.introHandled = true } }
        catch { errorMessage = "Couldn’t save notification settings. Try again." }
    }

    func setDesired(_ value: Bool) async {
        errorMessage = nil
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
            do { try persist { $0.desired = false; $0.queueCleanup(); $0.needsMacClear = true } }
            catch { errorMessage = "Couldn’t save notification settings. Try again."; return }
            revision &+= 1
        }
        scheduleReconcile()
    }

    func retry() {
        if storedState?.blockedDeviceToken == token, storedState?.blockedBuildID == buildID { return }
        if storedState?.retryAfter.map({ now() < $0 }) == true { return }
        errorMessage = nil
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
        guard KeychainMobilePushStateStore.isDeviceToken(value) else { return }
        let changed = token != value
        token = value
        if changed { revision &+= 1; scheduleReconcile() }
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
        guard isForeground else { return }
        guard !reconciling else { reconcileAgain = true; return }
        reconciling = true
        defer {
            reconciling = false
            if reconcileAgain { reconcileAgain = false; scheduleReconcile() }
        }
        await restore()
        guard storedState != nil else { return }
        await cleanupRegistrations()
        guard isForeground, let configuration, let context, context.connected, context.supported else { return }
        let operationRevision = revision
        let generation = await vault.currentGeneration()
        guard let credential = await vault.currentCredential(), credential.gatewayURL == context.gatewayURL,
              credential.device.id == context.pairingID,
              await isCurrent(operationRevision, generation: generation) else { return }
        let native = nativeFactory(context.gatewayURL, ToasttyPushCredentialProvider(vault: vault,
            gatewayURL: context.gatewayURL, pairingID: context.pairingID, generation: generation))
        var operationRegistration: MobilePushRegistration?
        do {
            try abandonOtherPairing(context)
            await cleanupRegistrations()
            let host = try await native.configuration()
            guard await isCurrent(operationRevision, generation: generation) else { return }
            configurationMatches = host.relayID == configuration.relayID && host.apnsEnvironment == configuration.apnsEnvironment
            if !desired {
                if storedState?.needsMacClear == true || host.registrationID != nil {
                    _ = try await native.setRegistration(nil)
                    guard await isCurrent(operationRevision, generation: generation) else { return }
                    try persist { $0.needsMacClear = false }
                }
                permission = await notifications.permission()
                return
            }
            guard configurationMatches else {
                if desired { errorMessage = "Notification settings on this iPhone and Mac do not match." }
                return
            }
            permission = await notifications.permission()
            guard await isCurrent(operationRevision, generation: generation) else { return }
            guard permission == .allowed else { return }
            if !requestedToken { requestedToken = true; notifications.register() }
            let delivered = await notifications.deliveredPayloads()
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
            guard await isCurrent(operationRevision, generation: generation), let token else { return }
            if storedState?.blockedDeviceToken == token && storedState?.blockedBuildID == buildID {
                errorMessage = "Apple could not use this notification token. Check this app’s notification build settings."
                return
            }
            if storedState?.retryAfter.map({ now() < $0 }) == true {
                errorMessage = "Notification setup is busy. Try again later."
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
                let status = try await relayFactory(active.relayURL).status(active)
                guard await isCurrent(operationRevision, generation: generation) else { return }
                if status.state == "active" {
                    if host.registrationID != active.registrationID {
                        _ = try await native.setRegistration(grant(active))
                        guard await isCurrent(operationRevision, generation: generation) else { return }
                    }
                    active.stage = .enabled
                    try persist { $0.active = active }
                    errorMessage = nil
                    return
                }
                try persist { $0.cleanup.append(active); $0.active = nil }
            }
            if let pending = storedState?.pending,
               pending.deviceToken != token || pending.relayURL != configuration.relayURL
                || pending.relayID != configuration.relayID
                || (pending.stage == .pending && pending.nonce == nil && now().timeIntervalSince(pending.createdAt) >= 300) {
                try persist { $0.cleanup.append(pending); $0.pending = nil }
            }
            if storedState?.pending == nil {
                guard (storedState?.cleanup.count ?? 0) < 124 else {
                    errorMessage = "Finish turning off older alerts before enabling notifications again."
                    return
                }
                let attempt = MobilePushRegistration(pairingID: context.pairingID, gatewayURL: context.gatewayURL,
                    relayURL: configuration.relayURL, relayID: configuration.relayID, deviceToken: token,
                    managementToken: try KeychainMobilePushStateStore.randomCapability(),
                    sendToken: try KeychainMobilePushStateStore.randomCapability(), createdAt: now())
                try persist { $0.pending = attempt }
            }
            guard let attempt = storedState?.pending else { return }
            if attempt.stage == .pending {
                if attempt.nonce != nil { await finishProof(attempt, operationRevision: operationRevision, generation: generation) }
                else if attempt.expiresAt == nil {
                    operationRegistration = attempt
                    let result = try await relayFactory(attempt.relayURL).begin(attempt)
                    guard await isCurrent(operationRevision, generation: generation), storedState?.pending?.registrationID == attempt.registrationID else { return }
                    try persist { state in
                        guard var current = state.pending, current.stage == .pending else { return }
                        current.expiresAt = result.expiresAt.map(Date.init(timeIntervalSince1970:))
                        if result.state == "active" { current.stage = .relayActive }
                        state.pending = current
                    }
                }
            }
            guard let ready = storedState?.pending, ready.stage == .relayActive,
                  await isCurrent(operationRevision, generation: generation) else { return }
            operationRegistration = ready
            _ = try await native.setRegistration(grant(ready))
            guard await isCurrent(operationRevision, generation: generation), storedState?.pending?.registrationID == ready.registrationID else { return }
            try persist { state in
                if let old = state.active { state.cleanup.append(old) }
                var enabled = ready; enabled.stage = .enabled; enabled.nonce = nil
                state.active = enabled; state.pending = nil; state.needsMacClear = false
            }
            errorMessage = nil
        } catch {
            let current = await isCurrent(operationRevision, generation: generation)
            if current || operationRegistration.map(isStoredRegistration) == true {
                handleFailure(error, registration: operationRegistration, displayError: current)
            }
        }
    }

    private func acceptProof(_ payload: RemotePushPayload) async {
        guard payload.isValid, payload.kind == .verification else { return }
        guard storedState != nil else {
            queuedProofs = Array((queuedProofs.filter { $0.registrationID != payload.registrationID } + [payload]).suffix(8))
            return
        }
        guard let attempt = storedState?.pending, attempt.stage == .pending,
              attempt.registrationID == payload.registrationID, attempt.pairingID == payload.pairingID,
              let nonce = payload.nonce, desired else { return }
        do { try persist { $0.pending?.nonce = nonce } }
        catch { handleFailure(error); return }
        guard isForeground, context?.connected == true, context?.pairingID == payload.pairingID, configurationMatches else { return }
        let operationRevision = revision
        let generation = await vault.currentGeneration()
        guard let current = storedState?.pending, current.registrationID == payload.registrationID else { return }
        await finishProof(current, operationRevision: operationRevision, generation: generation)
        scheduleReconcile()
    }

    private func finishProof(_ attempt: MobilePushRegistration, operationRevision: UInt64,
                             generation: MobileCredentialGeneration) async {
        guard let nonce = attempt.nonce, attempt.stage == .pending,
              proofOperations.insert(attempt.registrationID).inserted else { return }
        defer { proofOperations.remove(attempt.registrationID) }
        guard await isCurrent(operationRevision, generation: generation),
              context?.pairingID == attempt.pairingID,
              storedState?.pending?.registrationID == attempt.registrationID,
              storedState?.pending?.stage == .pending else { return }
        do {
            let response = try await relayFactory(attempt.relayURL).complete(attempt, nonce: nonce)
            guard response.state == "active", response.pairingID == attempt.pairingID else {
                throw PushRelayFailure.invalidResponse
            }
            guard await isCurrent(operationRevision, generation: generation),
                  storedState?.pending?.registrationID == attempt.registrationID else { return }
            try persist { $0.pending?.stage = .relayActive; $0.pending?.nonce = nil }
            errorMessage = nil
        } catch {
            guard storedState?.pending?.registrationID == attempt.registrationID else { return }
            let current = await isCurrent(operationRevision, generation: generation)
            handleFailure(error, registration: attempt, displayError: current)
        }
    }

    private func cleanupRegistrations() async {
        guard storedState?.cleanupRetryAfter.map({ now() >= $0 }) ?? true else { return }
        for item in Array((storedState?.cleanup ?? []).prefix(4)) {
            guard isForeground else { return }
            do {
                try await relayFactory(item.relayURL).revoke(item)
                try persist { $0.cleanup.removeAll { $0.registrationID == item.registrationID } }
            } catch {
                let delay: TimeInterval
                if case .rateLimited(let retry)? = error as? PushRelayFailure { delay = retry }
                else { delay = 30 }
                try? persist { state in
                    state.cleanupRetryAfter = now().addingTimeInterval(delay)
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
    }
    private func scheduleReconcile() {
        guard isForeground, automaticallyReconciles else { return }
        Task { [weak self] in await self?.reconcile() }
    }
    private func isStoredRegistration(_ registration: MobilePushRegistration) -> Bool {
        storedState?.pending?.registrationID == registration.registrationID
            || storedState?.active?.registrationID == registration.registrationID
    }
    private func handleFailure(_ error: Error, registration: MobilePushRegistration? = nil, displayError: Bool = true) {
        let message: String
        switch error as? PushRelayFailure {
        case .invalidDeviceToken:
            try? persist { $0.blockedDeviceToken = registration?.deviceToken ?? token; $0.blockedBuildID = buildID }
            message = "Apple could not use this notification token. Check this app’s notification build settings."
        case .rateLimited(let delay):
            try? persist { $0.retryAfter = now().addingTimeInterval(delay) }
            message = "Notification setup is busy. Try again later."
        case .expired:
            if let pending = storedState?.pending, registration == nil || pending.registrationID == registration?.registrationID {
                try? persist { $0.cleanup.append(pending); $0.pending = nil }
            } else if let active = storedState?.active, registration == nil || active.registrationID == registration?.registrationID {
                try? persist { $0.cleanup.append(active); $0.active = nil }
            }
            message = "Notification setup expired. Try again."
        default:
            message = "Couldn’t finish notification setup. Retry when connected."
        }
        if displayError && isForeground { errorMessage = message }
    }
    private struct Context: Equatable {
        let gatewayURL: URL; let pairingID: UUID; let connected: Bool; let supported: Bool
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
