import CoreState
import Foundation

extension TaskCoordinator {
    private func openApproval(taskID: UUID, questionID: UUID, at: Date) throws -> (TaskRecord, TaskReplyRequest) {
        guard let record = records.record(id: taskID), finishedReason(record) == nil,
              let request = record.replyRequest, request.approvalID == questionID, request.approvalOrigin != nil,
              at < request.askedAt.addingTimeInterval(TaskApprovalAnswer.questionLifetime) else {
            throw TaskError("This approval question is no longer open.")
        }
        guard record.lastApprovalAnswer?.questionID != questionID else {
            throw TaskError("This approval question already has an answer.")
        }
        if let session = liveAgentSession(of: record, ownAgentOnly: true), expects(session, for: request) == false {
            throw TaskError("This approval question belongs to an earlier conversation.")
        }
        return (record, request)
    }

    private func expects(_ session: TaskSessionInfo, for request: TaskReplyRequest) -> Bool {
        request.approvalOrigin?.matches(
            sessionID: session.sessionID, conversationID: session.nativeConversationID, provider: session.agent.rawValue
        ) == true
    }

    /// Entered only from the native Coordinator card. The automation
    /// socket can submit a signed bot answer, but cannot create a grant.
    func grantFleetAnswers(taskID: UUID, questionID: UUID, grant: TaskFleetAnswerGrant) throws {
        let (record, request) = try openApproval(taskID: taskID, questionID: questionID, at: now())
        guard request.fleetChecks == grant.scope,
              webhooks?.fleetAnswerGrantIsCurrent(grant, task: record) == true else {
            throw TaskError("The bot or question changed. Review the grant again.")
        }
        try saveMergeState(taskID: taskID) { $0.fleetAnswerGrant = grant }
    }

    func revokeFleetAnswers(taskID: UUID, grant: TaskFleetAnswerGrant) throws {
        guard records.record(id: taskID)?.fleetAnswerGrant == grant else { return }
        try saveMergeState(taskID: taskID) { $0.fleetAnswerGrant = nil }
        evaluateWatches()
    }

    @discardableResult
    func answerApproval(
        taskID: UUID, questionID: UUID, decision: TaskApprovalAnswer.Decision,
        bot: (webhookID: UUID, signature: String)? = nil
    ) throws -> TaskApprovalAnswer {
        let at = now()
        let (record, request) = try openApproval(taskID: taskID, questionID: questionID, at: at)
        let grant: TaskFleetAnswerGrant?
        if let bot {
            guard let current = record.fleetAnswerGrant, current.webhookID == bot.webhookID,
                  current.scope == request.fleetChecks,
                  webhooks?.verifiesFleetAnswer(bot.signature, grant: current, task: record, questionID: questionID, decision: decision) == true else {
                throw TaskError("The bot has no valid grant and signature for this question.")
            }
            grant = current
        } else {
            grant = nil
        }
        let question = request.fleetChecks.map { "\($0.question) \($0.detail)" } ?? request.question ?? ""
        let answer = TaskApprovalAnswer(questionID: questionID, decision: decision, answeredAt: at, question: question, grant: grant)
        try saveMergeState(taskID: taskID) { $0.lastApprovalAnswer = answer }
        evaluateWatches()
        startWatchMonitorIfNeeded()
        return records.record(id: taskID)?.lastApprovalAnswer ?? answer
    }

    func deliverApprovalAnswers(at: Date) {
        for record in records.records {
            guard var answer = record.lastApprovalAnswer, answer.delivery == .queued else { continue }
            guard let request = record.replyRequest, request.approvalID == answer.questionID,
                  finishedReason(record) == nil,
                  at < request.askedAt.addingTimeInterval(TaskApprovalAnswer.questionLifetime) else {
                settleApprovalAnswer(.cancelled, answer: answer, taskID: record.id)
                continue
            }
            if let grant = answer.grant {
                guard record.fleetAnswerGrant == grant else {
                    settleApprovalAnswer(.cancelled, answer: answer, taskID: record.id)
                    continue
                }
                // Launch reconciliation can run before the webhook store is
                // attached. A locked Keychain can likewise become readable.
                guard let webhooks, webhooks.fleetAnswerKeyIsUnavailable(grant) == false else { continue }
                guard webhooks.fleetAnswerGrantIsCurrent(grant, task: record) else {
                    settleApprovalAnswer(.cancelled, answer: answer, taskID: record.id)
                    continue
                }
            }
            guard let session = liveAgentSession(of: record, ownAgentOnly: true) else { continue }
            // It goes before a waiting `--steer` message, whose turn would
            // clear the question.
            guard wasInterruptedAtQuit(record) == false,
                  let turnEnd = automaticPromptTurnEnd(for: session, yieldsToSteer: false) else { continue }
            guard expects(session, for: request) else {
                if let origin = request.approvalOrigin, origin.conversationID != nil,
                   origin.provider == session.agent.rawValue, session.nativeConversationID == nil {
                    continue
                }
                settleApprovalAnswer(.cancelled, answer: answer, taskID: record.id, closeQuestion: true)
                continue
            }
            answer.sessionID = session.sessionID
            // Save before typing. After a crash or uncertain Return, a
            // second copy could join the first at the prompt.
            guard settleApprovalAnswer(.sentUnconfirmed, answer: answer, taskID: record.id) else { continue }
            let decision = answer.decision == .approve ? "Approved" : "Declined"
            let message = "\(answer.messageHeader)\n\(decision) \(answer.displaySource).\n\(answer.question)"
            let result = deliver(message, to: session, taskID: record.id, automaticPromptTurnEnd: turnEnd)
            switch result {
            case .delivered: settleApprovalAnswer(.sent, answer: answer, taskID: record.id)
            case .unavailable:
                answer.sessionID = nil
                settleApprovalAnswer(.queued, answer: answer, taskID: record.id)
            case .uncertain: break
            }
        }
    }

    @discardableResult
    private func settleApprovalAnswer(
        _ state: TaskApprovalAnswer.Delivery, answer: TaskApprovalAnswer, taskID: UUID, closeQuestion: Bool = false
    ) -> Bool {
        do {
            var updated = answer
            updated.delivery = state
            try saveMergeState(taskID: taskID) { record in
                record.lastApprovalAnswer = updated
                if state == .cancelled, record.replyRequest?.approvalID == answer.questionID {
                    // Give an unanswered card a fresh ID. A previously
                    // signed answer must stay spent even after regranting.
                    if closeQuestion {
                        record.replyRequest = nil
                    } else {
                        record.replyRequest?.approvalID = UUID()
                    }
                }
            }
            return true
        } catch {
            ToasttyLog.warning("Could not save a task approval answer", category: .tasks, metadata: [
                "task_id": taskID.uuidString, "answer_id": answer.id.uuidString, "delivery": state.rawValue,
            ])
            return false
        }
    }
}
