import AppKit
import CoreState
import Foundation

/// One event waiting to send to one webhook.
struct TaskWebhookOutboxEntry: Codable, Equatable, Sendable {
    var eventID: UUID
    var webhookID: UUID
    var taskID: UUID
    var type: TaskWebhookEventType
    var createdAt: Date
    /// The encoded payload, kept as sent, so every retry sends the same
    /// bytes.
    var body: Data
    var attempts: Int = 0
    var nextAttemptAt: Date
}

/// Sends task events to the webhooks the user approved, and to the
/// coordinator.
///
/// About once a second, while an approved webhook or a coordinator exists,
/// it reads every task's stage from the task board, turns changes into
/// events (`TaskWebhookEventDetector`), and adds one outbox entry for each
/// webhook whose filters match. The outbox is saved before the first send.
/// Each webhook sends one request at a time, oldest first, and retries with
/// backoff for up to a day. `task list --changed-since` stays the source of
/// truth; an event only wakes the receiver.
///
/// A webhook added through the socket waits for approval, which only the
/// app's UI gives (`approve(id:)`): no socket command calls it.
///
/// The coordinator is one more destination of the same events, inside
/// Toastty: its changes wait in one digest that is typed at its open
/// prompt. See `TaskWebhookService+Coordinator.swift`.
@MainActor
final class TaskWebhookService: ObservableObject {
    struct Timing: Sendable {
        var passInterval: Duration = .seconds(1)
        /// Lets workspaces and agent sessions restore before the first pass
        /// after launch, so a task space that is still opening does not
        /// count as a change.
        var startupDelay: TimeInterval = 10
        var settleInterval: TimeInterval = TaskWebhookEventDetector.defaultSettleInterval
    }

    @Published private(set) var webhooks: [TaskWebhook] {
        didSet { updatePolling() }
    }

    /// Every task's current state; set by the app from the task board.
    var taskStates: @MainActor () -> [UUID: TaskWebhookTaskState] = { [:] }

    private let webhooksFileURL: URL?
    private let outboxFileURL: URL?
    private let secrets: any TaskWebhookSecretStoring
    private let transport: any TaskWebhookTransport
    let now: () -> Date
    private let timing: Timing
    private let userAgent: String
    private let startedAt: Date

    /// The Keychain items, read once at launch and kept current by every
    /// write, so a pass never waits on the Keychain.
    private var keychainItems: [UUID: TaskWebhookKeychainItem] = [:]
    var detector: TaskWebhookEventDetector
    private(set) var entries: [TaskWebhookOutboxEntry]
    /// The coordinator that gets a digest of the events, once the app has
    /// one. Set with `attach(coordinator:)`.
    weak var coordinator: CoordinatorController?
    /// What waits for the coordinator, and its timer. `nil` while there is
    /// no coordinator.
    var coordinatorWake: CoordinatorWakeState?
    /// Events being sent now, one per webhook at most.
    private var inFlight: [UUID: UUID] = [:]
    /// The settings and secret each in-flight send used. A refusal of an
    /// older configuration must not stop a newer one.
    private var inFlightConfiguration: [UUID: String] = [:]
    /// Webhooks whose Keychain item could not be read, such as while the
    /// Keychain is locked. They stay as they are and are read again later.
    private var unreadKeychainItems: Set<UUID> = []
    private var started = false
    private var loop: Task<Void, Never>?
    private var wakeObserver: (any NSObjectProtocol)?

    init(
        webhooksFileURL: URL?,
        outboxFileURL: URL?,
        secrets: any TaskWebhookSecretStoring,
        transport: any TaskWebhookTransport = TaskWebhookClient(),
        now: @escaping () -> Date = Date.init,
        timing: Timing = Timing(),
        userAgent: String = TaskWebhookService.defaultUserAgent
    ) {
        self.webhooksFileURL = webhooksFileURL
        self.outboxFileURL = outboxFileURL
        self.secrets = secrets
        self.transport = transport
        self.now = now
        self.timing = timing
        self.userAgent = userAgent
        self.startedAt = now()
        webhooks = Self.load(TaskWebhooksSnapshot.self, from: webhooksFileURL)?.webhooks ?? []
        let outbox = Self.load(TaskWebhookOutboxSnapshot.self, from: outboxFileURL)
        detector = outbox?.detector ?? TaskWebhookEventDetector()
        entries = outbox?.entries ?? []
        coordinatorWake = outbox?.coordinator
        loadKeychainItems()
    }

    convenience init(runtimePaths: ToasttyRuntimePaths) {
        self.init(
            webhooksFileURL: runtimePaths.taskWebhooksFileURL,
            outboxFileURL: runtimePaths.taskWebhookOutboxFileURL,
            secrets: KeychainTaskWebhookSecretStore(
                service: KeychainTaskWebhookSecretStore.service(
                    bundleIdentifier: Bundle.main.bundleIdentifier,
                    runtimeHomeURL: runtimePaths.runtimeHomeURL
                )
            )
        )
    }

    static var defaultUserAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Toastty/\(version)"
    }

    var pendingWebhooks: [TaskWebhook] {
        webhooks.filter { $0.status == .pendingApproval }
    }

    /// Webhooks Toastty stopped after the receiver refused them.
    var stoppedWebhooks: [TaskWebhook] {
        webhooks.filter { $0.status == .disabled }
    }

    /// Whether Toastty holds the webhook's key, so the approval sheet asks
    /// for one only when it is missing.
    func hasSecret(_ id: UUID) -> Bool {
        keychainItems[id]?.secret != nil
    }

    func webhook(named name: String) -> TaskWebhook? {
        webhooks.first { $0.name == name }
    }

    /// Whether events go to this webhook now: the user approved exactly
    /// these settings.
    func isActive(_ webhook: TaskWebhook) -> Bool {
        webhook.status == .approved && keychainItems[webhook.id]?.approvedDigest == webhook.settingsDigest
    }

    private var activeWebhooks: [TaskWebhook] {
        webhooks.filter(isActive)
    }

    // MARK: - Lifecycle

    /// Whether the once-a-second pass runs.
    var isPolling: Bool { loop != nil }

    func start() {
        started = true
        updatePolling()
    }

    func stop() {
        started = false
        updatePolling()
    }

    /// The pass runs only while a webhook is approved or a coordinator
    /// exists, so a Mac with neither does no work for them after launch.
    /// Events for changes made while it was stopped are not sent: approval
    /// starts from now.
    func updatePolling() {
        let needed = started && (webhooks.contains { $0.status == .approved } || coordinator?.location != nil)
        if needed, loop == nil {
            startPolling()
        } else if needed == false, loop != nil {
            loop?.cancel()
            loop = nil
            if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
            wakeObserver = nil
        }
    }

    private func startPolling() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryNowAfterWake() }
        }
        loop = Task { [weak self] in
            while Task.isCancelled == false {
                guard let interval = self?.timing.passInterval else { return }
                try? await Task.sleep(for: interval)
                self?.pass()
            }
        }
    }

    /// One pass: detect changes, queue their events, and start sends.
    /// Internal so tests can drive passes without the timer.
    func pass() {
        let at = now()
        if unreadKeychainItems.isEmpty == false { loadKeychainItems() }
        guard at.timeIntervalSince(startedAt) >= timing.startupDelay else { return }
        let active = activeWebhooks
        let before = detector
        let wakeBefore = coordinatorWake
        followCoordinator(at: at)
        guard active.isEmpty == false || coordinatorWake != nil else {
            if coordinatorWake != wakeBefore { saveOutbox() }
            return
        }
        let states = taskStates()
        let changes = detector.observe(states, now: at, settleInterval: timing.settleInterval)
        var queued = false
        for change in changes {
            for type in change.events {
                for webhook in active where webhook.events.contains(type)
                    && webhook.matches(projectRoot: change.state.projectRoot, externalRefID: change.state.externalRef?.id) {
                    enqueue(type: type, taskID: change.taskID, state: change.state, webhook: webhook, at: at)
                    queued = true
                }
            }
            coordinatorWake?.record(change, at: at)
        }
        coordinatorWake?.startFollowing()
        // One write records the changes as seen and as waiting, before
        // anything is sent or typed.
        if queued || detector != before || coordinatorWake != wakeBefore {
            saveOutbox()
        }
        deliverDue(at: at)
        wakeCoordinator(at: at)
    }

    private func enqueue(type: TaskWebhookEventType, taskID: UUID, state: TaskWebhookTaskState, webhook: TaskWebhook, at: Date) {
        let eventID = UUID()
        let payload = TaskWebhookPayload(eventID: eventID, type: type, occurredAt: at, webhook: webhook.name, taskID: taskID, state: state)
        guard let body = try? payload.encoded() else { return }
        if type.isTransient {
            // A newer stage replaces one still waiting, so a long outage ends
            // in one current event per task, not a replay of old stages.
            let sending = inFlight[webhook.id]
            entries.removeAll { entry in
                entry.webhookID == webhook.id && entry.taskID == taskID && entry.type.isTransient && entry.eventID != sending
            }
        }
        entries.append(TaskWebhookOutboxEntry(
            eventID: eventID, webhookID: webhook.id, taskID: taskID, type: type, createdAt: at, body: body, nextAttemptAt: at
        ))
        ToasttyLog.info("Queued a task webhook event", category: .tasks, metadata: [
            "webhook": webhook.name,
            "event_id": eventID.uuidString,
            "event_type": type.rawValue,
            "task_id": taskID.uuidString,
        ])
    }

    private func dropExpiredEntries(at: Date) -> Bool {
        let expired = entries.filter { at.timeIntervalSince($0.createdAt) > TaskWebhookRetryPolicy.maximumAge && inFlight[$0.webhookID] != $0.eventID }
        guard expired.isEmpty == false else { return false }
        let ids = Set(expired.map(\.eventID))
        entries.removeAll { ids.contains($0.eventID) }
        for entry in expired {
            ToasttyLog.warning("Dropped a task webhook event after a day of failed sends", category: .tasks, metadata: [
                "webhook": webhook(id: entry.webhookID)?.name ?? "removed",
                "event_id": entry.eventID.uuidString,
            ])
        }
        return true
    }

    private func webhook(id: UUID) -> TaskWebhook? {
        webhooks.first { $0.id == id }
    }

    private func deliverDue(at: Date) {
        if dropExpiredEntries(at: at) { saveOutbox() }
        for webhook in activeWebhooks where inFlight[webhook.id] == nil {
            guard let entry = entries.first(where: { $0.webhookID == webhook.id }), entry.nextAttemptAt <= at,
                  let url = URL(string: webhook.url) else { continue }
            inFlight[webhook.id] = entry.eventID
            inFlightConfiguration[webhook.id] = configuration(of: webhook)
            let request = TaskWebhookClient.request(
                url: url,
                auth: webhook.auth,
                secret: keychainItems[webhook.id]?.secret,
                eventID: entry.eventID,
                body: entry.body,
                timestamp: Int(at.timeIntervalSince1970),
                userAgent: userAgent
            )
            let transport = transport
            Task { [weak self] in
                let result = await transport.send(request)
                self?.finishSend(webhookID: webhook.id, eventID: entry.eventID, result: result)
            }
        }
    }

    /// What a send depends on: the approved settings and the secret.
    private func configuration(of webhook: TaskWebhook) -> String {
        webhook.settingsDigest + "|" + (keychainItems[webhook.id]?.secret.map { TaskWebhookSignature.header(secret: $0, timestamp: 0, body: Data()) } ?? "")
    }

    private func finishSend(webhookID: UUID, eventID: UUID, result: TaskWebhookSendResult) {
        let sentConfiguration = inFlightConfiguration[webhookID]
        if inFlight[webhookID] == eventID {
            inFlight[webhookID] = nil
            inFlightConfiguration[webhookID] = nil
        }
        let at = now()
        guard let webhookIndex = webhooks.firstIndex(where: { $0.id == webhookID }) else {
            entries.removeAll { $0.webhookID == webhookID }
            saveOutbox()
            return
        }
        let name = webhooks[webhookIndex].name
        var metadata = [
            "webhook": name,
            "host": webhooks[webhookIndex].host,
            "event_id": eventID.uuidString,
            "result": result.statusCode.map { "HTTP \($0)" } ?? result.errorClass ?? "no response",
        ]
        webhooks[webhookIndex].lastDelivery = TaskWebhookDelivery(at: at, statusCode: result.statusCode, error: result.errorClass)
        var outcome = TaskWebhookRetryPolicy.outcome(statusCode: result.statusCode)
        if case .disable = outcome, sentConfiguration != configuration(of: webhooks[webhookIndex]) {
            // The settings or secret changed while this request was out: its
            // refusal says nothing about the new ones, so try again with them.
            outcome = .retry
        }
        switch outcome {
        case .delivered:
            entries.removeAll { $0.eventID == eventID }
            ToasttyLog.info("Delivered a task webhook event", category: .tasks, metadata: metadata)
        case .retry:
            if let entry = entries.first(where: { $0.eventID == eventID }), entry.type.isTransient,
               entries.contains(where: { $0.webhookID == webhookID && $0.taskID == entry.taskID && $0.type.isTransient && $0.createdAt > entry.createdAt }) {
                // A newer stage for the same task waits behind it.
                entries.removeAll { $0.eventID == eventID }
            } else if let index = entries.firstIndex(where: { $0.eventID == eventID }) {
                entries[index].attempts += 1
                let delay = TaskWebhookRetryPolicy.delay(afterAttempts: entries[index].attempts)
                entries[index].nextAttemptAt = at.addingTimeInterval(delay)
                metadata["retry_in_seconds"] = String(Int(delay))
            }
            ToasttyLog.info("A task webhook send failed; it will retry", category: .tasks, metadata: metadata)
        case .disable(let reason):
            webhooks[webhookIndex].status = .disabled
            webhooks[webhookIndex].disabledReason = reason
            // The receiver refused the webhook, so its queued events go too.
            // The coordinator catches up with task list --changed-since.
            entries.removeAll { $0.webhookID == webhookID }
            ToasttyLog.warning("Stopped a task webhook: the receiver refused it", category: .tasks, metadata: metadata)
        case .drop:
            entries.removeAll { $0.eventID == eventID }
            ToasttyLog.warning("A task webhook receiver refused an event; it was dropped", category: .tasks, metadata: metadata)
        }
        saveWebhooks()
        saveOutbox()
        deliverDue(at: at)
    }

    private func retryNowAfterWake() {
        let at = now()
        for index in entries.indices where entries[index].nextAttemptAt > at {
            entries[index].nextAttemptAt = at
        }
        deliverDue(at: at)
    }

    // MARK: - Changes from the socket

    struct Settings {
        var url: String?
        var events: [TaskWebhookEventType]?
        var roots: [String]?
        /// `.some(nil)` clears the filter.
        var externalRefPrefix: String??
        var auth: TaskWebhookAuth?
        /// `.some(nil)` clears the hint.
        var secretHint: String??
    }

    func add(name: String, settings: Settings, secret: String?, requester: TaskWebhookRequester) throws -> TaskWebhook {
        try TaskWebhookValidation.validateName(name)
        guard webhook(named: name) == nil else {
            throw TaskWebhookValidationError("A webhook named \(name) exists. Change it with webhook set, or remove it first.")
        }
        guard pendingWebhooks.count < TaskWebhook.maximumPending else {
            throw TaskWebhookValidationError("\(TaskWebhook.maximumPending) webhooks already wait for approval in Toastty. Approve or deny one first.")
        }
        guard let rawURL = settings.url else { throw TaskWebhookValidationError("A webhook needs a URL.") }
        var webhook = TaskWebhook(
            name: name,
            url: try TaskWebhookValidation.validateURL(rawURL),
            auth: settings.auth ?? .hmac,
            requestedAt: now(),
            requestedBy: requester
        )
        try apply(settings, to: &webhook)
        try checkSecret(secret)
        try writeKeychainItem(TaskWebhookKeychainItem(secret: secret, approvedDigest: nil), for: webhook.id)
        webhooks.append(webhook)
        saveWebhooks()
        ToasttyLog.info("A task webhook waits for approval", category: .tasks, metadata: [
            "webhook": webhook.name,
            "host": webhook.host,
            "requested_by_agent": webhook.requestedBy.isAgentSession ? "true" : "false",
        ])
        return webhook
    }

    /// Changes a webhook. A change to where events go, which events, the
    /// filters or the auth mode needs approval again.
    func update(name: String, settings: Settings, secret: String?, requester: TaskWebhookRequester) throws -> TaskWebhook {
        guard let index = webhooks.firstIndex(where: { $0.name == name }) else {
            throw TaskWebhookValidationError("No webhook is named \(name).")
        }
        let wasActive = activeWebhooks.isEmpty == false
        var webhook = webhooks[index]
        if let url = settings.url { webhook.url = try TaskWebhookValidation.validateURL(url) }
        try apply(settings, to: &webhook)
        var item = keychainItems[webhook.id] ?? TaskWebhookKeychainItem()
        try checkSecret(secret)
        if let secret { item.secret = secret }
        if webhook.settingsDigest != webhooks[index].settingsDigest {
            guard webhooks[index].status == .pendingApproval || pendingWebhooks.count < TaskWebhook.maximumPending else {
                throw TaskWebhookValidationError("\(TaskWebhook.maximumPending) webhooks already wait for approval in Toastty. Approve or deny one first.")
            }
            webhook.status = .pendingApproval
            webhook.approvedAt = nil
            webhook.disabledReason = nil
            webhook.requestedAt = now()
            webhook.requestedBy = requester
            item.approvedDigest = nil
        } else if secret != nil, webhook.status == .disabled {
            webhook.status = .approved
            webhook.disabledReason = nil
        }
        try writeKeychainItem(item, for: webhook.id)
        if webhook.status != .approved {
            entries.removeAll { $0.webhookID == webhook.id }
            saveOutbox()
        }
        webhooks[index] = webhook
        startDetectingIfNoneWasActive(wasActive)
        saveWebhooks()
        return webhook
    }

    func remove(name: String) throws {
        guard let webhook = webhook(named: name) else {
            throw TaskWebhookValidationError("No webhook is named \(name).")
        }
        try remove(id: webhook.id)
    }

    // MARK: - Approval (UI only)

    /// Approves the webhook's current settings. Only the approval sheet
    /// calls this.
    /// `shownDigest` is the `settingsDigest` of the webhook the sheet showed;
    /// settings that changed since are refused. `secret` is a key the user
    /// entered in the sheet; it replaces the saved one. A stopped webhook
    /// is approved again the same way, usually with a new key.
    func approve(id: UUID, shownDigest: String, secret: String? = nil) throws {
        guard let index = webhooks.firstIndex(where: { $0.id == id }),
              webhooks[index].status == .pendingApproval || webhooks[index].status == .disabled else {
            throw TaskWebhookValidationError("This webhook changed or was removed. Close the sheet and review it again.")
        }
        guard webhooks[index].settingsDigest == shownDigest else {
            throw TaskWebhookValidationError("This webhook's settings changed while you reviewed it. Close the sheet and review it again.")
        }
        // Settings read from the file were never checked by add or set.
        _ = try TaskWebhookValidation.validateURL(webhooks[index].url)
        try TaskWebhookValidation.validateAuth(webhooks[index].auth, url: webhooks[index].url)
        try checkSecret(secret)
        if webhooks[index].auth.needsSecret, secret == nil, keychainItems[id]?.secret == nil {
            throw TaskWebhookValidationError("Paste the key for this webhook, then approve it.")
        }
        let wasActive = activeWebhooks.isEmpty == false
        var item = keychainItems[id] ?? TaskWebhookKeychainItem()
        if let secret { item.secret = secret }
        item.approvedDigest = webhooks[index].settingsDigest
        try writeKeychainItem(item, for: id)
        unreadKeychainItems.remove(id)
        webhooks[index].status = .approved
        webhooks[index].disabledReason = nil
        webhooks[index].approvedAt = now()
        startDetectingIfNoneWasActive(wasActive)
        saveWebhooks()
        ToasttyLog.info("Approved a task webhook", category: .tasks, metadata: [
            "webhook": webhooks[index].name, "host": webhooks[index].host,
        ])
    }

    /// Denying removes the webhook and its secret.
    func deny(id: UUID) throws {
        try remove(id: id)
    }

    private func remove(id: UUID) throws {
        try secrets.removeItem(for: id)
        keychainItems[id] = nil
        let name = webhook(id: id)?.name ?? ""
        webhooks.removeAll { $0.id == id }
        entries.removeAll { $0.webhookID == id }
        saveWebhooks()
        saveOutbox()
        ToasttyLog.info("Removed a task webhook", category: .tasks, metadata: ["webhook": name])
    }

    // MARK: - Test

    /// Sends a `task.test` event now, outside the outbox.
    func sendTest(name: String) async throws -> TaskWebhookDelivery {
        guard let webhook = webhook(named: name) else {
            throw TaskWebhookValidationError("No webhook is named \(name).")
        }
        guard isActive(webhook) else {
            if webhook.status == .disabled {
                throw TaskWebhookValidationError("Webhook \(name) is stopped (\(webhook.disabledReason ?? "refused")). Enter a new key in Toastty's Tasks view, or run webhook rotate-secret.")
            }
            throw TaskWebhookValidationError("Webhook \(name) is waiting for approval in Toastty; it cannot send events yet.")
        }
        guard let url = URL(string: webhook.url) else { throw TaskWebhookValidationError("The webhook URL is not valid.") }
        let at = now()
        let eventID = UUID()
        let body = try TaskWebhookPayload.test(eventID: eventID, occurredAt: at, webhook: webhook.name).encoded()
        let request = TaskWebhookClient.request(
            url: url,
            auth: webhook.auth,
            secret: keychainItems[webhook.id]?.secret,
            eventID: eventID,
            body: body,
            timestamp: Int(at.timeIntervalSince1970),
            userAgent: userAgent
        )
        let result = await transport.send(request)
        let delivery = TaskWebhookDelivery(at: now(), statusCode: result.statusCode, error: result.errorClass)
        if let index = webhooks.firstIndex(where: { $0.id == webhook.id }) {
            webhooks[index].lastDelivery = delivery
            saveWebhooks()
        }
        ToasttyLog.info("Sent a task webhook test event", category: .tasks, metadata: [
            "webhook": webhook.name, "host": webhook.host, "result": delivery.summary,
        ])
        return delivery
    }

    // MARK: - Helpers

    private func apply(_ settings: Settings, to webhook: inout TaskWebhook) throws {
        if let events = settings.events {
            guard events.isEmpty == false else { throw TaskWebhookValidationError("A webhook needs at least one event.") }
            webhook.events = TaskWebhookEventType.allCases.filter(events.contains)
        }
        if let roots = settings.roots {
            webhook.roots = Array(Set(roots.map { TasksConfigFile.normalizedPath($0) })).sorted()
        }
        if let prefix = settings.externalRefPrefix {
            webhook.externalRefPrefix = prefix.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let auth = settings.auth { webhook.auth = auth }
        try TaskWebhookValidation.validateAuth(webhook.auth, url: webhook.url)
        if let hint = settings.secretHint {
            webhook.secretHint = try hint.flatMap(TaskWebhookValidation.validateSecretHint)
        }
    }

    /// A webhook may wait for approval without its key: the user then
    /// enters it in the approval sheet.
    private func checkSecret(_ secret: String?) throws {
        if let secret { try TaskWebhookValidation.validateSecret(secret) }
    }

    /// Detection starts from now when the first webhook becomes active:
    /// changes made while no webhook listened are not sent.
    private func startDetectingIfNoneWasActive(_ wasActive: Bool) {
        // A coordinator already follows the changes: its baseline stays.
        guard wasActive == false, activeWebhooks.isEmpty == false, coordinatorWake == nil else { return }
        detector.reset()
        saveOutbox()
    }

    private func writeKeychainItem(_ item: TaskWebhookKeychainItem, for id: UUID) throws {
        do {
            try secrets.setItem(item, for: id)
        } catch {
            throw TaskWebhookValidationError("Toastty could not save the webhook secret in the Keychain: \(error.localizedDescription)")
        }
        keychainItems[id] = item
    }

    private func loadKeychainItems() {
        var changed = false
        for index in webhooks.indices {
            let id = webhooks[index].id
            do {
                keychainItems[id] = try secrets.item(for: id)
                unreadKeychainItems.remove(id)
            } catch {
                // A locked or unavailable Keychain says nothing about the
                // approval: keep the webhook as it is, and read it again later.
                if unreadKeychainItems.insert(id).inserted {
                    ToasttyLog.warning("Could not read a task webhook's Keychain item", category: .tasks, metadata: [
                        "webhook": webhooks[index].name, "error": error.localizedDescription,
                    ])
                }
                continue
            }
            // Settings that differ from what the user approved, such as an
            // edit of the file, need approval again.
            if webhooks[index].status != .pendingApproval,
               keychainItems[id]?.approvedDigest != webhooks[index].settingsDigest {
                webhooks[index].status = .pendingApproval
                webhooks[index].approvedAt = nil
                // Events queued under the old settings must not go to the new
                // ones once approved.
                entries.removeAll { $0.webhookID == id }
                changed = true
                ToasttyLog.warning("A task webhook's settings differ from its approval; it waits for approval again", category: .tasks, metadata: [
                    "webhook": webhooks[index].name,
                ])
            }
        }
        if changed {
            saveWebhooks()
            saveOutbox()
        }
    }

    private func saveWebhooks() {
        Self.save(TaskWebhooksSnapshot(version: 1, webhooks: webhooks), to: webhooksFileURL)
    }

    func saveOutbox() {
        Self.save(
            TaskWebhookOutboxSnapshot(version: 1, detector: detector, entries: entries, coordinator: coordinatorWake),
            to: outboxFileURL
        )
    }

    private static func load<Snapshot: Decodable>(_ type: Snapshot.Type, from url: URL?) -> Snapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            ToasttyLog.warning("Could not read a task webhook file", category: .tasks, metadata: [
                "path": url.path, "error": error.localizedDescription,
            ])
            return nil
        }
    }

    private static func save<Snapshot: Encodable>(_ snapshot: Snapshot, to url: URL?) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            ToasttyLog.warning("Could not save a task webhook file", category: .tasks, metadata: [
                "path": url.path, "error": error.localizedDescription,
            ])
        }
    }
}

private struct TaskWebhooksSnapshot: Codable {
    var version: Int
    var webhooks: [TaskWebhook]
}

private struct TaskWebhookOutboxSnapshot: Codable {
    var version: Int
    var detector: TaskWebhookEventDetector
    var entries: [TaskWebhookOutboxEntry]
    /// Absent in a file written before the coordinator had wakes.
    var coordinator: CoordinatorWakeState?
}

extension TaskWebhookService {
    /// Every recorded task's state, from the stages the task board works out.
    static func taskStates(_ items: [TaskBoardItem]) -> [UUID: TaskWebhookTaskState] {
        var states: [UUID: TaskWebhookTaskState] = [:]
        for item in items {
            guard let record = item.record else { continue }
            var attention: String?
            if case .needsYou(let reason) = item.stage { attention = reason.name }
            states[record.id] = TaskWebhookTaskState(
                key: .init(group: "\(item.stage.group)", attention: attention, merged: item.hasMerged),
                title: record.title,
                projectRoot: record.projectRoot,
                externalRef: record.externalRef,
                question: record.replyRequest?.question,
                pullRequestURL: record.pullRequestURL,
                mergedAt: record.mergedAt
            )
        }
        return states
    }
}
