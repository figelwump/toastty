import Foundation
import Observation
import RemoteProtocol
import ToasttyMobileDomain

/// What the phone learned from asking the Mac what it can start.
enum ToasttySessionStartOptionsOutcome: Equatable, Sendable {
    case loaded(RemoteSessionStartOptionsResponse)
    /// The request failed or was never sent.
    case unreachable
}

/// What the phone learned from asking the Mac to start a session.
enum ToasttySessionStartOutcome: Equatable, Sendable {
    case answered(RemoteSessionStartResult)
    /// No answer: the request failed on the way or was never sent. The Mac
    /// may still have started the session, so a retry must reuse the same
    /// request ID.
    case unconfirmed
}

/// The parts of the app the new-session sheet talks to.
@MainActor
protocol ToasttyNewSessionHost: AnyObject {
    func sessionStartOptions(workspaceID: UUID) async -> ToasttySessionStartOptionsOutcome
    func startSession(_ request: RemoteSessionStartRequest) async -> ToasttySessionStartOutcome
    func conversation(id: UUID) -> MobileConversation?
}

extension HomeScreenController: ToasttyNewSessionHost {}

/// Presentation state for the "New session" sheet: the options the Mac
/// offers, the user's picks, and the start request's lifecycle.
@MainActor
@Observable
final class ToasttyNewSessionModel: Identifiable {
    enum Phase: Equatable {
        case loading
        /// The options could not be loaded.
        case unreachable
        case form
        /// A start request is on its way, or the Mac started the session and
        /// the phone is waiting for it to reach the session list.
        case starting
        case finished(Finish)
    }

    enum Finish: Equatable {
        /// The new session is in the list; open it.
        case open(conversationID: UUID)
        /// The Mac started the session, but it has not reached the list.
        case startedPending(agentName: String)
    }

    static let unreachableMessage = "Couldn't reach your Mac. Your message is still here. Tap Start to try again."
    static let unrecognizedAnswerMessage = "Your Mac sent an answer this app doesn't understand. Check the session list before you try again, and update Toastty Mobile."
    static let messageTooLongMessage = "That message is too long to send. Shorten it and tap Start again."
    static let invalidModelMessage = "That isn't a model ID the Mac can use. Use one word with no spaces that doesn't start with a dash."

    let id = UUID()
    let workspaceID: UUID
    let workspaceTitle: String

    private(set) var phase: Phase = .loading
    private(set) var options: RemoteSessionStartOptionsResponse?
    private(set) var selectedAgentID: String?
    /// `nil` sends no model, so the profile's default applies.
    private(set) var model: String?
    /// `nil` sends no effort, so the profile's default applies.
    private(set) var effort: String?
    private(set) var message = ""
    /// Why the last start or edit did not work. Cleared by any edit.
    private(set) var errorMessage: String?
    /// The agent of the request in flight, for the waiting state.
    private(set) var startingAgentName: String?

    @ObservationIgnored private let host: any ToasttyNewSessionHost
    @ObservationIgnored private let preferences: ToasttyNewSessionPreferences
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let makeRequestID: () -> String
    @ObservationIgnored private let startedSessionTimeout: Duration
    @ObservationIgnored private let pollInterval: Duration
    /// A request the Mac did not answer. The Mac drops repeats of one key,
    /// so starting again with it can never launch a second session.
    @ObservationIgnored private var unconfirmedRequest: (id: String, firstSentAt: Date)?

    init(
        workspaceID: UUID,
        workspaceTitle: String,
        host: any ToasttyNewSessionHost,
        preferences: ToasttyNewSessionPreferences,
        now: @escaping () -> Date = Date.init,
        makeRequestID: @escaping () -> String = { UUID().uuidString },
        startedSessionTimeout: Duration = .seconds(10),
        pollInterval: Duration = .milliseconds(200)
    ) {
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.host = host
        self.preferences = preferences
        self.now = now
        self.makeRequestID = makeRequestID
        self.startedSessionTimeout = startedSessionTimeout
        self.pollInterval = pollInterval
    }

    // MARK: - Derived presentation

    var agents: [RemoteSessionStartAgent] {
        options?.agents ?? []
    }

    var selectedAgent: RemoteSessionStartAgent? {
        agents.first { $0.profileID == selectedAgentID }
    }

    var showsModel: Bool {
        selectedAgent?.supportsModel == true
    }

    var effortChoices: [String] {
        selectedAgent?.reasoningEfforts ?? []
    }

    var showsEffort: Bool {
        effortChoices.isEmpty == false
    }

    /// The phone's own recent picks for the agent, most recent first, then
    /// the Mac's suggestions. A value the Mac would refuse is left out.
    var modelChoices: [String] {
        guard let agent = selectedAgent, agent.supportsModel else { return [] }
        var seen = Set<String>()
        let candidates = [model].compactMap { $0 }
            + preferences.recentModels(forAgent: agent.profileID)
            + agent.recentModels
        return candidates.filter { Self.isValidModel($0) && seen.insert($0).inserted }
    }

    /// A reason the Mac gave in the options that rules out any start.
    var blockingMessage: String? {
        guard let options else { return nil }
        switch options.permission {
        case .allowed:
            break
        case .startDisabled:
            return "Starting sessions was turned off for this iPhone. Turn it back on in Toastty → Settings → Remote Access on your Mac."
        case .sendDisabled:
            return "This iPhone can't send messages, and a new session starts with one. Turn on sending in Toastty → Settings → Remote Access on your Mac."
        case .unknown:
            return "Your Mac isn't accepting new sessions from this iPhone right now."
        }
        switch options.workspace {
        case .available:
            return nil
        case .notFound:
            return "This workspace is no longer open in Toastty on your Mac."
        case .noDirectory:
            return "Toastty doesn't know this workspace's folder yet. Open a terminal in it on your Mac, then try again."
        case .unknown:
            return "This workspace can't take a new session right now."
        }
    }

    /// One line per agent that cannot start, with the Mac's reason.
    var unavailableAgentNotes: [String] {
        guard options != nil else { return [] }
        guard agents.isEmpty == false else {
            return ["Your Mac has no agent profiles to start."]
        }
        return agents.compactMap(Self.unavailableReason)
    }

    var canStart: Bool {
        phase == .form
            && blockingMessage == nil
            && selectedAgent?.availability == .available
            && trimmedMessage.isEmpty == false
    }

    var sheetTitle: String {
        switch phase {
        case .starting, .finished:
            "New \(startingAgentName ?? "agent") session"
        case .loading, .unreachable, .form:
            "New session"
        }
    }

    var messagePlaceholder: String {
        "What should \(selectedAgent?.displayName ?? "the agent") do?"
    }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Loading

    func loadOptions() async {
        guard phase == .loading || phase == .unreachable else { return }
        phase = .loading
        switch await host.sessionStartOptions(workspaceID: workspaceID) {
        case .loaded(let response):
            options = response
            let available = response.agents.filter { $0.availability == .available }
            let remembered = preferences.lastAgentID.flatMap { last in
                available.first { $0.profileID == last }
            }
            applyAgent((remembered ?? available.first)?.profileID)
            phase = .form
        case .unreachable:
            phase = .unreachable
        }
    }

    // MARK: - Editing

    func selectAgent(_ profileID: String) {
        guard profileID != selectedAgentID,
              agents.contains(where: { $0.profileID == profileID && $0.availability == .available }) else {
            return
        }
        applyAgent(profileID)
        draftDidChange()
    }

    func selectModel(_ newModel: String?) {
        guard newModel != model else { return }
        model = newModel
        draftDidChange()
    }

    /// Uses a typed model ID. Returns false, and says why, when the Mac
    /// would refuse it.
    @discardableResult
    func useCustomModel(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidModel(trimmed) else {
            errorMessage = Self.invalidModelMessage
            return false
        }
        selectModel(trimmed)
        return true
    }

    func selectEffort(_ newEffort: String?) {
        guard newEffort != effort else { return }
        effort = newEffort
        draftDidChange()
    }

    func updateMessage(_ text: String) {
        guard text != message else { return }
        message = text
        draftDidChange()
    }

    // MARK: - Starting

    func start() async {
        guard canStart, let agent = selectedAgent else { return }
        let requestID: String
        let firstSentAt: Date
        if let unconfirmedRequest,
           now().timeIntervalSince(unconfirmedRequest.firstSentAt) < RemoteSessionStartPolicy.duplicateRequestWindow {
            requestID = unconfirmedRequest.id
            firstSentAt = unconfirmedRequest.firstSentAt
        } else {
            requestID = makeRequestID()
            firstSentAt = now()
        }
        let sentModel = agent.supportsModel ? model : nil
        let sentEffort = effort.flatMap { agent.reasoningEfforts.contains($0) ? $0 : nil }
        let request = RemoteSessionStartRequest(
            clientRequestID: requestID,
            workspaceID: workspaceID,
            profileID: agent.profileID,
            model: sentModel,
            reasoningEffort: sentEffort,
            text: trimmedMessage
        )
        // The Mac refuses a larger request before it reads it. Sending one
        // would look like a lost connection that Start could never fix.
        guard let encoded = try? ConversationEventCoding.makeEncoder().encode(request),
              encoded.count <= RemoteGatewayProtocol.maximumRequestBodyBytes else {
            errorMessage = Self.messageTooLongMessage
            return
        }
        unconfirmedRequest = (requestID, firstSentAt)
        errorMessage = nil
        startingAgentName = agent.displayName
        phase = .starting

        switch await host.startSession(request) {
        case .answered(.started(let conversationID)):
            unconfirmedRequest = nil
            preferences.recordStart(agentID: agent.profileID, model: sentModel, effort: sentEffort)
            await waitForStartedConversation(conversationID.rawValue, agentName: agent.displayName)
        case .answered(.rejected(let reason)):
            // Nothing was launched, so the next start is a new request.
            unconfirmedRequest = nil
            errorMessage = Self.message(for: reason, agentName: agent.displayName)
            phase = .form
        case .answered(.unrecognized):
            // The Mac's answer could mean a session started. Keep the
            // request ID, so another Start cannot launch a second one.
            errorMessage = Self.unrecognizedAnswerMessage
            phase = .form
        case .unconfirmed:
            errorMessage = Self.unreachableMessage
            phase = .form
        }
    }

    /// The Mac answers once the agent command is sent; the session enters
    /// the list when the agent reports itself, usually a moment later.
    /// Polling the host keeps this independent of how the list updates.
    private func waitForStartedConversation(_ conversationID: UUID, agentName: String) async {
        let deadline = ContinuousClock.now.advanced(by: startedSessionTimeout)
        while host.conversation(id: conversationID) == nil {
            guard ContinuousClock.now < deadline, Task.isCancelled == false else {
                phase = .finished(.startedPending(agentName: agentName))
                return
            }
            try? await Task.sleep(for: pollInterval)
        }
        phase = .finished(.open(conversationID: conversationID))
    }

    // MARK: - Helpers

    private func applyAgent(_ profileID: String?) {
        selectedAgentID = profileID
        guard let agent = selectedAgent else {
            model = nil
            effort = nil
            return
        }
        let lastModel = preferences.lastModel(forAgent: agent.profileID)
        model = agent.supportsModel ? lastModel.flatMap { Self.isValidModel($0) ? $0 : nil } : nil
        let lastEffort = preferences.lastEffort(forAgent: agent.profileID)
        effort = lastEffort.flatMap { agent.reasoningEfforts.contains($0) ? $0 : nil }
    }

    /// Any edit makes a different request, which needs its own key.
    private func draftDidChange() {
        unconfirmedRequest = nil
        errorMessage = nil
    }

    private static func isValidModel(_ value: String) -> Bool {
        RemoteSessionStartPolicy.isValidSelectionValue(
            value,
            maximumLength: RemoteSessionStartPolicy.maximumModelLength
        )
    }

    static func unavailableReason(_ agent: RemoteSessionStartAgent) -> String? {
        switch agent.availability {
        case .available: nil
        case .notInstalled: "\(agent.displayName) isn't installed on your Mac."
        case .firstMessageUnsupported: "\(agent.displayName) can't take a first message."
        case .unknown: "\(agent.displayName) can't be started from this iPhone."
        }
    }

    static func message(for reason: RemoteSessionStartRejectionReason, agentName: String) -> String {
        switch reason {
        case .permissionDenied:
            "Your Mac didn't let this iPhone start a session. Check Toastty → Settings → Remote Access on your Mac."
        case .workspaceNotFound:
            "This workspace is no longer open in Toastty on your Mac."
        case .workspaceUnavailable:
            "Toastty doesn't know this workspace's folder yet. Open a terminal in it on your Mac, then try again."
        case .agentUnavailable:
            "\(agentName) can't be started on your Mac. Check that it's installed, then try again."
        case .invalidRequest:
            "Your Mac couldn't use this request. Check the model and effort, then try again."
        case .launchFailed:
            "\(agentName) didn't start on your Mac. Try again."
        case .busy:
            "Your Mac is still starting another session from this iPhone. Try again in a moment."
        case .unknown:
            "Your Mac didn't start the session. Try again."
        }
    }
}
