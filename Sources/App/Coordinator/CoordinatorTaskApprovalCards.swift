import ConversationUI
import CoreState
import SwiftUI

/// Approval questions belong to the task store and can be answered even
/// when the Coordinator agent is busy or its permission check is blocked.
struct CoordinatorTaskApprovalCards: View {
    let items: [TaskBoardItem]
    let coordinator: TaskCoordinator
    @ObservedObject var webhooks: TaskWebhookService
    @Environment(\.conversationTextScale) private var textScale
    @State private var selectedTaskID: UUID?

    var body: some View {
        let records = items.compactMap(\.record).filter { record in
            if record.replyRequest?.approvalID != nil || record.fleetAnswerGrant != nil {
                return coordinator.finishedReason(record) == nil
            }
            return record.lastApprovalAnswer.map {
                ($0.delivery == .sent || $0.delivery == .sentUnconfirmed)
                    && Date().timeIntervalSince($0.answeredAt) < TaskApprovalAnswer.questionLifetime
            } ?? false
        }
        if let record = records.first(where: { $0.id == selectedTaskID }) ?? records.first {
            VStack(alignment: .leading, spacing: 8) {
                if records.count > 1 {
                    Picker("Task question", selection: Binding(get: { record.id }, set: { selectedTaskID = $0 })) {
                        ForEach(records) { Text($0.title).tag($0.id) }
                    }
                }
                Card(record: record, coordinator: coordinator, webhooks: webhooks, textScale: textScale)
                    .id(record.id)
            }
        }
    }

    private struct Card: View {
        let record: TaskRecord
        let coordinator: TaskCoordinator
        let webhooks: TaskWebhookService
        let textScale: Double
        @State private var candidate: GrantCandidate?
        @State private var error: String?

        private struct GrantCandidate {
            let questionID: UUID
            let grant: TaskFleetAnswerGrant
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 7) {
                Text(record.title)
                    .font(.system(size: 12 * textScale, weight: .medium))
                    .foregroundStyle(ConversationDesignTokens.secondaryText)
                if let request = record.replyRequest, let questionID = request.approvalID {
                    questionCard(request, questionID: questionID)
                } else if let answer = record.lastApprovalAnswer, answer.delivery != .cancelled {
                    answerLabel(answer)
                }
                if let grant = record.fleetAnswerGrant {
                    HStack {
                        Text("Bot access for website \(grant.scope.version) · \(grant.webhookName)")
                            .font(.system(size: 12 * textScale))
                            .foregroundStyle(ConversationDesignTokens.secondaryText)
                        Button("Revoke bot access") {
                            perform { try coordinator.revokeFleetAnswers(taskID: record.id, grant: grant) }
                        }
                    }
                }
                if let error {
                    Text(error)
                        .font(.system(size: 12 * textScale))
                        .foregroundStyle(ConversationDesignTokens.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(ConversationDesignTokens.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("coordinator.task-approval")
            .confirmationDialog(
                "Allow \(candidate?.grant.webhookName ?? "this bot") to answer?",
                isPresented: Binding(get: { candidate != nil }, set: { if $0 == false { candidate = nil } }),
                presenting: candidate
            ) { candidate in
                Button("Allow these checks") {
                    perform {
                        try coordinator.grantFleetAnswers(taskID: record.id, questionID: candidate.questionID, grant: candidate.grant)
                    }
                }
            } message: { candidate in
                Text(candidate.grant.scope.detail + " This applies to matching questions in this task. You can revoke access here.")
            }
        }

        @ViewBuilder
        private func questionCard(_ request: TaskReplyRequest, questionID: UUID) -> some View {
            ViewThatFits(in: .vertical) {
                scopeText(request).fixedSize(horizontal: false, vertical: true)
                ScrollView { scopeText(request).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .frame(maxHeight: 140 * textScale)
            .textSelection(.enabled)
            if let answer = record.lastApprovalAnswer, answer.questionID == questionID, answer.delivery != .cancelled {
                answerLabel(answer)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack { buttons(request, questionID: questionID) }
                    VStack(alignment: .leading) { buttons(request, questionID: questionID) }
                }
            }
        }

        private func scopeText(_ request: TaskReplyRequest) -> some View {
            VStack(alignment: .leading, spacing: 7) {
                Text(request.question ?? "")
                    .font(.system(size: 14 * textScale, weight: .semibold))
                if let scope = request.fleetChecks {
                    Text(scope.detail)
                        .font(.system(size: 13 * textScale))
                        .foregroundStyle(ConversationDesignTokens.secondaryText)
                }
            }
        }

        @ViewBuilder
        private func buttons(_ request: TaskReplyRequest, questionID: UUID) -> some View {
            Button(request.fleetChecks == nil ? "Approve" : "Approve these checks") {
                perform { try coordinator.answerApproval(taskID: record.id, questionID: questionID, decision: .approve) }
            }
            .accessibilityIdentifier("coordinator.task-approval.approve")
            Button("Decline") {
                perform { try coordinator.answerApproval(taskID: record.id, questionID: questionID, decision: .decline) }
            }
            .accessibilityIdentifier("coordinator.task-approval.decline")
            if let scope = request.fleetChecks {
                let eligible = webhooks.webhooks.compactMap { webhooks.fleetAnswerGrant(for: $0, task: record, scope: scope) }
                if eligible.isEmpty == false {
                    Menu("Allow a bot to answer") {
                        ForEach(eligible, id: \.webhookID) { grant in
                            Button(grant.webhookName) { candidate = GrantCandidate(questionID: questionID, grant: grant) }
                        }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("coordinator.task-approval.allow-bot")
                }
            }
        }

        private func answerLabel(_ answer: TaskApprovalAnswer) -> some View {
            let decision = answer.decision == .approve ? "Approved" : "Declined"
            let status = switch answer.delivery {
            case .queued: " · Waiting for the task’s prompt"
            case .sentUnconfirmed: " · Check the task’s terminal"
            case .sent, .cancelled: ""
            }
            return Text("\(decision) \(answer.displaySource)\(status)")
                .font(.system(size: 13 * textScale))
                .foregroundStyle(ConversationDesignTokens.secondaryText)
        }

        private func perform(_ action: () throws -> Void) {
            do {
                try action()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
