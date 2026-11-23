import CoreState
import Foundation
import RemoteProtocol

/// Process-local response authority. Provider resolution and hook liveness are
/// separate: losing the hook closes mobile input without claiming Claude answered.
struct ClaudeQuestionBroker {
    struct Identity: Hashable {
        var sessionID: String
        var bindingID: UUID
        var panelID: UUID
        var nativeSessionID: String
        var transcriptPath: String
    }
    struct Entry {
        var identity: Identity
        var providerCallID: String
        var promptID: String?
        var questions: [RemoteInteractionQuestion]
        var registeredAt: Date
        var responseID: String?
        var deadline: Date?
        var leaseExpiry: Date?
        var submission: RemoteQuestionAnswerRequest?
        var delivered = false
        var closedAt: Date?
        var closed: Bool { closedAt != nil }
        var resolved = false
        /// Set for a tool permission request; its one question is the decision.
        var permission: RemotePermissionRequestDetail?
    }
    /// A recent main-agent tool call. Claude's PermissionRequest payload has
    /// no call ID, so a permission request binds to the one call that matches.
    struct ToolCall {
        var identity: Identity
        var callID: String
        var toolName: String
        var inputDigest: String
        var promptID: String?
        var registeredAt: Date
    }
    struct Change {
        var identity: Identity
        var providerCallID: String
        var responseID: String?
        var payload: ProviderObservationPayload
    }
    private(set) var entries: [Entry] = []
    private(set) var recentToolCalls: [ToolCall] = []
    /// Sessions whose tool-call ring dropped a call this turn. A dropped call
    /// could be the one a permission request is for, so binding waits for the
    /// next turn rather than trusting an incomplete candidate set.
    private var overflowedToolCallIdentities: Set<Identity> = []
    private var changes: [Change] = []
    static let maximumEntries = 256
    static let maximumRecentToolCalls = 64
    static let registrationTTL: TimeInterval = 60
    static let responseLifetime = ClaudeQuestionValidation.maximumWaitSeconds
    static let leaseLifetime = ClaudeQuestionValidation.leaseSeconds
    static let confirmationLifetime: TimeInterval = 300
    static let closedRetention: TimeInterval = 360

    mutating func drainChanges() -> [Change] {
        defer { changes.removeAll() }
        return changes
    }

    mutating func invalidate(sessionID: String, reason: RemoteQuestionAnswerRejectionReason, at now: Date = Date()) {
        for index in entries.indices where entries[index].identity.sessionID == sessionID {
            close(index, reason: reason, at: now)
        }
    }

    mutating func clear(sessionID: String? = nil) {
        entries.removeAll { sessionID == nil || $0.identity.sessionID == sessionID }
        recentToolCalls.removeAll { sessionID == nil || $0.identity.sessionID == sessionID }
        overflowedToolCallIdentities = overflowedToolCallIdentities.filter { sessionID != nil && $0.sessionID != sessionID }
    }

    mutating func expire(at now: Date) {
        for index in entries.indices where !entries[index].closed && entries[index].responseID != nil {
            if entries[index].deadline.map({ $0 <= now }) == true ||
                (!entries[index].delivered && entries[index].leaseExpiry.map({ $0 <= now }) == true) {
                close(index, reason: entries[index].delivered ? .notPending : .expired, at: now)
            }
        }
        entries.removeAll {
            ($0.responseID == nil && now.timeIntervalSince($0.registeredAt) > Self.registrationTTL) ||
                ($0.closedAt.map { now.timeIntervalSince($0) > Self.closedRetention } == true)
        }
        recentToolCalls.removeAll { now.timeIntervalSince($0.registeredAt) > Self.registrationTTL }
    }

    mutating func handle(_ request: ClaudeQuestionHookRequest, identity: Identity, at now: Date) -> ClaudeQuestionHookReply {
        expire(at: now)
        switch request.phase {
        case .observe:
            guard let event = request.event, matches(event, identity: identity), event.subagentID == nil else {
                return .init(status: .unavailable)
            }
            switch event.eventName {
            case .preToolUse where event.toolName != nil:
                guard let callID = event.providerCallID, !callID.isEmpty,
                      let toolName = event.toolName, let digest = event.toolInputDigest else {
                    return .init(status: .unavailable)
                }
                recentToolCalls.removeAll { $0.identity == identity && $0.callID == callID }
                recentToolCalls.append(ToolCall(identity: identity, callID: callID, toolName: toolName,
                                                inputDigest: digest, promptID: event.promptID, registeredAt: now))
                if recentToolCalls.count > Self.maximumRecentToolCalls {
                    overflowedToolCallIdentities.insert(recentToolCalls.removeFirst().identity)
                }
            case .preToolUse:
                guard let callID = event.providerCallID, !callID.isEmpty,
                      let questions = event.questions,
                      ClaudeQuestionValidation.validateQuestions(questions) else { return .init(status: .unavailable) }
                if let index = entries.firstIndex(where: { $0.identity == identity && $0.providerCallID == callID }) {
                    guard entries[index].promptID == event.promptID, entries[index].questions == questions else {
                        close(index, reason: .notPending, at: now)
                        return .init(status: .unavailable)
                    }
                } else {
                    guard entries.count < Self.maximumEntries else { return .init(status: .unavailable) }
                    entries.append(Entry(identity: identity, providerCallID: callID, promptID: event.promptID,
                                         questions: questions, registeredAt: now))
                }
            case .postToolUse, .postToolUseFailure:
                guard let callID = event.providerCallID,
                      let index = entries.firstIndex(where: { $0.identity == identity && $0.providerCallID == callID }),
                      !entries[index].resolved else { return .init(status: .observed) }
                let answers = event.answers.flatMap {
                    ClaudeQuestionValidation.answersFromProvider($0, for: entries[index].questions)
                }
                entries[index].resolved = true
                entries[index].closedAt = entries[index].closedAt ?? now
                changes.append(Change(identity: identity, providerCallID: callID, responseID: entries[index].responseID,
                    payload: .transcript(.interactionResolved(.init(
                        interactionID: .init(rawValue: "claude:call:\(callID)"),
                        resolution: event.eventName == .postToolUse ? .resolved : .superseded,
                        answers: answers)))))
            case .userPromptSubmit, .stop, .sessionEnd:
                for index in entries.indices where entries[index].identity == identity {
                    close(index, reason: .notPending, at: now)
                }
                entries.removeAll { $0.identity == identity && $0.responseID == nil }
                recentToolCalls.removeAll { $0.identity == identity }
                overflowedToolCallIdentities.remove(identity)
            case .permissionRequest:
                break
            }
            return .init(status: .observed)
        case .begin:
            if let event = request.event, let permission = event.permission {
                return beginPermission(request, event: event, permission: permission, identity: identity, at: now)
            }
            guard let event = request.event, event.eventName == .permissionRequest,
                  event.subagentID == nil, matches(event, identity: identity),
                  let questions = event.questions, let responseID = request.responseID,
                  UUID(uuidString: responseID) != nil,
                  !entries.contains(where: { $0.responseID == responseID }) else { return .init(status: .unavailable) }
            let candidates = entries.indices.filter {
                let entry = entries[$0]
                return entry.identity == identity && entry.responseID == nil && !entry.closed &&
                    entry.promptID == event.promptID && entry.questions == questions
            }
            guard candidates.count == 1, let index = candidates.first else { return .init(status: .unavailable) }
            entries[index].responseID = responseID
            entries[index].deadline = now.addingTimeInterval(Self.responseLifetime)
            entries[index].leaseExpiry = now.addingTimeInterval(Self.leaseLifetime)
            let entry = entries[index]
            changes.append(Change(identity: identity, providerCallID: entry.providerCallID, responseID: responseID,
                payload: .interactionPresented(.init(kind: .question, providerCallID: entry.providerCallID,
                    prompt: questions.first?.question ?? "", questions: questions,
                    responseID: responseID, responseExpiresAt: entry.deadline))))
            return .init(status: .pending, responseID: responseID, providerCallID: entry.providerCallID, expiresAt: entry.deadline)
        case .poll, .end:
            guard let responseID = request.responseID,
                  let index = entries.firstIndex(where: { $0.identity == identity && $0.responseID == responseID }) else {
                return .init(status: .unavailable)
            }
            if request.phase == .end {
                close(index, reason: request.endReason == .expired ? .expired : .notPending, at: now)
                return .init(status: .finished, responseID: responseID)
            }
            guard !entries[index].closed else { return .init(status: .finished, responseID: responseID) }
            entries[index].leaseExpiry = now.addingTimeInterval(Self.leaseLifetime)
            if let submission = entries[index].submission {
                if !entries[index].delivered, let deadline = entries[index].deadline {
                    // Once the hook has the answer, only provider confirmation
                    // remains. Do not retain an abandoned delivery for a day.
                    entries[index].deadline = min(deadline, now.addingTimeInterval(Self.confirmationLifetime))
                }
                entries[index].delivered = true
                return .init(status: .answer, responseID: responseID, providerCallID: entries[index].providerCallID,
                             answers: submission.answers, expiresAt: entries[index].deadline)
            }
            return .init(status: .pending, responseID: responseID, expiresAt: entries[index].deadline)
        }
    }

    mutating func reconcile(_ observations: [ProviderTranscriptObservation], identity: Identity, at now: Date) {
        for observation in observations {
            // A tool result names its call, and Claude's transcript parser
            // identifies it by that call ID rather than by the session.
            if case .transcript(.toolFinished(let finished)) = observation.payload {
                recentToolCalls.removeAll { $0.identity == identity && $0.callID == finished.callID }
                for index in entries.indices where entries[index].identity == identity && !entries[index].closed &&
                    entries[index].providerCallID == finished.callID && observation.timestamp >= entries[index].registeredAt {
                    close(index, reason: .notPending, at: now)
                }
                continue
            }
            guard observation.providerIdentity == nil || observation.providerIdentity == identity.nativeSessionID else { continue }
            switch observation.payload {
            case .turnStarted, .turnEnded:
                recentToolCalls.removeAll { $0.identity == identity && observation.timestamp >= $0.registeredAt }
                overflowedToolCallIdentities.remove(identity)
                for index in entries.indices where entries[index].identity == identity && !entries[index].closed &&
                    observation.timestamp >= entries[index].registeredAt {
                    close(index, reason: .notPending, at: now)
                }
            default:
                break
            }
        }
    }

    mutating func submit(_ request: RemoteQuestionAnswerRequest, identity: Identity, at now: Date) -> RemoteQuestionAnswerResult {
        expire(at: now)
        guard let index = entries.firstIndex(where: { $0.identity == identity && $0.responseID == request.responseID &&
            request.interactionID.rawValue == "claude:call:\($0.providerCallID)" }) else { return .rejected(reason: .notPending) }
        guard !request.clientRequestID.isEmpty, request.clientRequestID.utf8.count <= 128 else {
            return .rejected(reason: .invalidAnswers)
        }
        guard let answers = ClaudeQuestionValidation.canonicalAnswers(request.answers, for: entries[index].questions) else {
            return .rejected(reason: .invalidAnswers)
        }
        if entries[index].permission != nil {
            guard let question = entries[index].questions.first,
                  ClaudePermissionDecision.decision(from: answers, for: question) != nil else {
                return .rejected(reason: .invalidAnswers)
            }
        }
        var submission = request
        submission.answers = answers
        if let previous = entries[index].submission {
            return previous == submission ? .duplicate : .rejected(reason: .alreadySubmitted)
        }
        guard !entries[index].closed else { return .rejected(reason: .expired) }
        entries[index].submission = submission
        return .submitted
    }

    private func matches(_ event: ClaudeQuestionHookEvent, identity: Identity) -> Bool {
        event.nativeSessionID == identity.nativeSessionID && event.transcriptPath == identity.transcriptPath
    }

    private mutating func beginPermission(
        _ request: ClaudeQuestionHookRequest,
        event: ClaudeQuestionHookEvent,
        permission: ClaudePermissionHookPresentation,
        identity: Identity,
        at now: Date
    ) -> ClaudeQuestionHookReply {
        let decision = permission.decision
        guard event.eventName == .permissionRequest, event.subagentID == nil, matches(event, identity: identity),
              let toolName = event.toolName, toolName == permission.detail.toolName,
              let digest = event.toolInputDigest,
              decision.id == ClaudePermissionDecision.questionID, decision.multiSelect == false,
              ClaudeQuestionValidation.validateQuestions([decision]),
              decision.options.allSatisfy({ ClaudePermissionDecision(optionID: $0.id) != nil }),
              let responseID = request.responseID, UUID(uuidString: responseID) != nil,
              !entries.contains(where: { $0.responseID == responseID }),
              entries.count < Self.maximumEntries,
              !overflowedToolCallIdentities.contains(identity) else { return .init(status: .unavailable) }
        // Identical parallel calls are indistinguishable here. Leave those to
        // the desktop rather than bind the answer to the wrong call.
        let candidates = recentToolCalls.indices.filter {
            let call = recentToolCalls[$0]
            return call.identity == identity && call.toolName == toolName && call.inputDigest == digest &&
                call.promptID == event.promptID &&
                !entries.contains(where: { $0.identity == identity && $0.providerCallID == call.callID })
        }
        guard candidates.count == 1, let callIndex = candidates.first else { return .init(status: .unavailable) }
        let call = recentToolCalls.remove(at: callIndex)
        let deadline = now.addingTimeInterval(Self.responseLifetime)
        entries.append(Entry(identity: identity, providerCallID: call.callID, promptID: event.promptID,
                             questions: [decision], registeredAt: call.registeredAt, responseID: responseID,
                             deadline: deadline, leaseExpiry: now.addingTimeInterval(Self.leaseLifetime),
                             permission: permission.detail))
        changes.append(Change(identity: identity, providerCallID: call.callID, responseID: responseID,
            payload: .interactionPresented(.init(kind: .permission, providerCallID: call.callID,
                prompt: permission.summary, questions: [decision], responseID: responseID,
                responseExpiresAt: deadline, permission: permission.detail))))
        return .init(status: .pending, responseID: responseID, providerCallID: call.callID, expiresAt: deadline)
    }

    private mutating func close(_ index: Int, reason: RemoteQuestionAnswerRejectionReason, at now: Date) {
        guard !entries[index].closed else { return }
        entries[index].closedAt = now
        guard entries[index].responseID != nil else { return }
        let entry = entries[index]
        // The hook already handed the phone's decision to Claude, which settles
        // the prompt. The transcript's tool result resolves the interaction,
        // perhaps after a long-running tool; meanwhile the phone keeps showing
        // its sent decision rather than a closed response window. No provider
        // fact says which answer won if the desktop answered at the same time.
        if entry.permission != nil, entry.delivered { return }
        changes.append(Change(identity: entry.identity, providerCallID: entry.providerCallID, responseID: entry.responseID,
            payload: .transcript(.interactionResponseClosed(.init(
                interactionID: .init(rawValue: "claude:call:\(entry.providerCallID)"), reason: reason)))))
    }
}
