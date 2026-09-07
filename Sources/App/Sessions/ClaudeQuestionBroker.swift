import CoreState
import Foundation
import RemoteProtocol

/// Process-local response authority. Provider resolution and hook liveness are
/// separate: losing the hook closes mobile input without claiming Claude answered.
struct ClaudeQuestionBroker {
    struct Identity: Equatable {
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
        var closed = false
        var resolved = false
    }
    struct Change {
        var identity: Identity
        var providerCallID: String
        var responseID: String?
        var payload: ProviderObservationPayload
    }
    private(set) var entries: [Entry] = []
    private var changes: [Change] = []
    static let maximumEntries = 256
    static let registrationTTL: TimeInterval = 60
    static let responseLifetime: TimeInterval = 300
    static let leaseLifetime: TimeInterval = 10

    mutating func drainChanges() -> [Change] {
        defer { changes.removeAll() }
        return changes
    }

    mutating func invalidate(sessionID: String, reason: RemoteQuestionAnswerRejectionReason) {
        for index in entries.indices where entries[index].identity.sessionID == sessionID {
            close(index, reason: reason)
        }
    }

    mutating func clear(sessionID: String? = nil) {
        entries.removeAll { sessionID == nil || $0.identity.sessionID == sessionID }
    }

    mutating func expire(at now: Date) {
        for index in entries.indices where !entries[index].closed && entries[index].responseID != nil {
            if entries[index].deadline.map({ $0 <= now }) == true ||
                (!entries[index].delivered && entries[index].leaseExpiry.map({ $0 <= now }) == true) {
                close(index, reason: .expired)
            }
        }
        entries.removeAll {
            ($0.responseID == nil && now.timeIntervalSince($0.registeredAt) > Self.registrationTTL) ||
                ($0.closed && now.timeIntervalSince($0.registeredAt) > Self.responseLifetime + 60)
        }
    }

    mutating func handle(_ request: ClaudeQuestionHookRequest, identity: Identity, at now: Date) -> ClaudeQuestionHookReply {
        expire(at: now)
        switch request.phase {
        case .observe:
            guard let event = request.event, matches(event, identity: identity), event.subagentID == nil else {
                return .init(status: .unavailable)
            }
            switch event.eventName {
            case .preToolUse:
                guard let callID = event.providerCallID, !callID.isEmpty,
                      let questions = event.questions,
                      ClaudeQuestionValidation.validateQuestions(questions) else { return .init(status: .unavailable) }
                if let index = entries.firstIndex(where: { $0.identity == identity && $0.providerCallID == callID }) {
                    guard entries[index].promptID == event.promptID, entries[index].questions == questions else {
                        close(index, reason: .notPending)
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
                entries[index].closed = true
                changes.append(Change(identity: identity, providerCallID: callID, responseID: entries[index].responseID,
                    payload: .transcript(.interactionResolved(.init(
                        interactionID: .init(rawValue: "claude:call:\(callID)"),
                        resolution: event.eventName == .postToolUse ? .resolved : .superseded,
                        answers: answers)))))
            case .userPromptSubmit, .stop, .sessionEnd:
                for index in entries.indices where entries[index].identity == identity {
                    close(index, reason: .notPending)
                }
                entries.removeAll { $0.identity == identity && $0.responseID == nil }
            case .permissionRequest:
                break
            }
            return .init(status: .observed)
        case .begin:
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
                close(index, reason: .notPending)
                return .init(status: .finished, responseID: responseID)
            }
            guard !entries[index].closed else { return .init(status: .finished, responseID: responseID) }
            entries[index].leaseExpiry = now.addingTimeInterval(Self.leaseLifetime)
            if let submission = entries[index].submission {
                entries[index].delivered = true
                return .init(status: .answer, responseID: responseID, providerCallID: entries[index].providerCallID,
                             answers: submission.answers, expiresAt: entries[index].deadline)
            }
            return .init(status: .pending, responseID: responseID, expiresAt: entries[index].deadline)
        }
    }

    mutating func reconcile(_ observations: [ProviderTranscriptObservation], identity: Identity) {
        for observation in observations {
            guard observation.providerIdentity == nil || observation.providerIdentity == identity.nativeSessionID else { continue }
            for index in entries.indices where entries[index].identity == identity && !entries[index].closed &&
                observation.timestamp >= entries[index].registeredAt {
                switch observation.payload {
                case .transcript(.toolFinished(let finished)) where finished.callID == entries[index].providerCallID:
                    close(index, reason: .notPending)
                case .turnStarted, .turnEnded:
                    close(index, reason: .notPending)
                default:
                    break
                }
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

    private mutating func close(_ index: Int, reason: RemoteQuestionAnswerRejectionReason) {
        guard !entries[index].closed else { return }
        entries[index].closed = true
        guard entries[index].responseID != nil else { return }
        let entry = entries[index]
        changes.append(Change(identity: entry.identity, providerCallID: entry.providerCallID, responseID: entry.responseID,
            payload: .transcript(.interactionResponseClosed(.init(
                interactionID: .init(rawValue: "claude:call:\(entry.providerCallID)"), reason: reason)))))
    }
}
