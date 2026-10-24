import CoreState
import SwiftUI

@MainActor
struct CoordinatorReviewDetailView: View {
    let reviewID: UUID
    let task: TaskBoardItem?
    @ObservedObject var reviews: CoordinatorReviewStore
    let actions: CoordinatorReviewActions
    let openTask: (UUID) -> Void
    let peekTask: (UUID) -> Void
    let reviewedBrief: CoordinatorReviewItem?
    let currentReviewID: UUID?
    let reviewUpdateAvailable: Bool
    let reviewUpdated: () async -> Void

    @State private var feedbackTarget: CoordinatorReviewItem?
    @State private var isSubmitting = false
    @State private var isRefreshing = false
    @State private var actionError: String?

    private var isCurrentBrief: Bool { currentReviewID == reviewID }

    var body: some View {
        Group {
            if let current = reviews.item(id: reviewID) {
                let displayed = reviewedBrief?.id == reviewID ? reviewedBrief ?? current : current
                detail(displayed, current: current)
            } else {
                Text("This review is no longer available.")
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .padding(20)
            }
        }
        .sheet(item: $feedbackTarget) { review in
            CoordinatorReviewFeedbackSheet(review: review) { feedback in
                _ = try await actions.requestChanges(reviewID: review.id, expectedRevision: review.revision, feedback: feedback)
            }
        }
        .onChange(of: reviewedBrief?.revision) { _, _ in actionError = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coordinator.review.detail")
    }

    private func detail(_ review: CoordinatorReviewItem, current: CoordinatorReviewItem) -> some View {
        let state = CoordinatorReviewPresentation.state(current, task: task)
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heading(review, current: current, state: state)
                    if reviewUpdateAvailable || !isCurrentBrief || state == .headUnknown || state == .baseUnknown || state == .baseChanged || state == .headChanged {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Refresh to read the current brief and pull request facts before making a decision.")
                            Button(isRefreshing ? "Refreshing…" : "Refresh review") {
                                isRefreshing = true
                                Task { @MainActor in
                                    defer { isRefreshing = false }
                                    await reviewUpdated()
                                }
                            }
                            .buttonStyle(CoordinatorReviewButtonStyle())
                            .disabled(isRefreshing || isSubmitting)
                        }
                        .foregroundStyle(ToastyTheme.sessionNeedsApprovalText)
                        .accessibilityIdentifier("coordinator.review.updated")
                    }
                    section("What changes") { Text(review.brief.behaviorChange) }
                    section("Decision needed") { Text(review.brief.decisionNeeded) }
                    section("Verification") {
                        factList(review.brief.verification, empty: "No verification is recorded.")
                    }
                    section("Remaining gaps") {
                        factList(review.brief.gaps, empty: "No gaps are recorded in this brief.")
                    }
                    section("Recommendation") { Text(review.brief.recommendation) }
                    if review.brief.evidence.isEmpty == false {
                        section("Evidence") {
                            ForEach(Array(review.brief.evidence.enumerated()), id: \.offset) { _, evidence in
                                CoordinatorReviewEvidenceRow(evidence: evidence, managedURL: reviews.managedEvidenceURL(for: evidence))
                            }
                        }
                    }
                    if let action = current.userAction {
                        section("Decision and result") { actionFacts(action, review: current) }
                    }
                    if let history = current.actionHistory, history.isEmpty == false {
                        DisclosureGroup("Earlier decisions (\(history.count))") {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(history.reversed(), id: \.intentID) { action in
                                    decisionFacts(action)
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                }
                .font(.system(size: 12.5))
                .foregroundStyle(ToastyTheme.primaryText)
                .textSelection(.enabled)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            decisionBar(review, current: current)
        }
        .background(ToastyTheme.surfaceBackground)
    }

    private func heading(_ review: CoordinatorReviewItem, current: CoordinatorReviewItem, state: CoordinatorReviewPresentation.State) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(review.taskTitle)
                .font(.system(size: 18, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Label(state.title, systemImage: state.symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(state == .merged ? Color.green : state.needsAttention ? ToastyTheme.sessionNeedsApprovalText : ToastyTheme.inactiveText)
            HStack(spacing: 12) {
                if let url = URL(string: review.pullRequestURL) {
                    Link("Pull request ↗", destination: url)
                    Link("Diff ↗", destination: url.appendingPathComponent("files"))
                }
                Button("View task") { openTask(review.taskID) }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("coordinator.review.task")
                Button("Peek session") { peekTask(review.taskID) }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("coordinator.review.peek")
            }
            .font(.system(size: 11.5))
            VStack(alignment: .leading, spacing: 4) {
                Text("Reviewed head · revision \(review.revision)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(ToastyTheme.inactiveText)
                Text(review.headSHA)
                    .font(.system(size: 10.5, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("coordinator.review.head")
                Text("Destination: \(review.baseRefName ?? "Not recorded")")
                    .font(.system(size: 11.5, design: .monospaced))
                    .accessibilityIdentifier("coordinator.review.base")
            }
            if state == .headChanged {
                Text("The pull request changed after this brief. A fresh review is required before another decision.")
                    .foregroundStyle(ToastyTheme.sessionNeedsApprovalText)
            } else if state == .headUnknown {
                Text("The current pull request head has not been verified. Refresh the pull request state before deciding.")
                    .foregroundStyle(ToastyTheme.sessionNeedsApprovalText)
            } else if state == .baseChanged {
                Text("The pull request destination changed after this brief. A fresh brief is required before another decision.")
                    .foregroundStyle(ToastyTheme.sessionNeedsApprovalText)
            } else if state == .baseUnknown {
                Text(review.baseRefName == nil
                    ? "This saved brief does not name the destination branch. Publish a new brief before deciding."
                    : "The current destination branch has not been verified. Refresh the pull request state before deciding.")
                    .foregroundStyle(ToastyTheme.sessionNeedsApprovalText)
            } else if state == .mergedDifferentHead || state == .mergedDifferentBase {
                Text("GitHub confirms the pull request merged after its reviewed head or destination changed. This result does not confirm that the reviewed change was merged as shown.")
                    .foregroundStyle(ToastyTheme.sessionNeedsApprovalText)
                if let head = current.observedOutcome.headSHA ?? task?.pullRequestState?.headSHA {
                    Text("Observed head: \(head)").font(.system(size: 10.5, design: .monospaced))
                }
                if let base = current.observedOutcome.baseRefName ?? task?.pullRequestState?.baseRefName {
                    Text("Observed destination: \(base)").font(.system(size: 10.5, design: .monospaced))
                }
            } else if task?.pullRequestState?.isDraft == true {
                Text("The pull request is a draft. Mark it ready before approving a merge.")
                    .foregroundStyle(ToastyTheme.inactiveText)
            }
            if !isCurrentBrief, !state.isComplete {
                Text("This is a saved brief. Current pull request facts or a replacement brief are needed before a decision.")
                    .foregroundStyle(ToastyTheme.inactiveText)
            }
            if task == nil, !state.isComplete {
                Text("The task record is unavailable. This saved brief and its evidence remain available for inspection.")
                    .foregroundStyle(ToastyTheme.inactiveText)
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(ToastyTheme.inactiveText)
                .accessibilityAddTraits(.isHeader)
            content()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func factList(_ facts: [String], empty: String) -> some View {
        if facts.isEmpty {
            Text(empty).foregroundStyle(ToastyTheme.inactiveText)
        } else {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("•").foregroundStyle(ToastyTheme.inactiveText)
                    Text(fact)
                }
            }
        }
    }

    private func actionFacts(_ action: CoordinatorReviewAction, review: CoordinatorReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            decisionFacts(action)
            let state = CoordinatorReviewPresentation.state(review, task: task)
            if state == .merged || state == .mergedDifferentHead || state == .mergedDifferentBase {
                Text("GitHub confirms the pull request is merged.")
                    .foregroundStyle(.green)
                if let commit = review.observedOutcome.mergeCommit {
                    Text(commit).font(.system(size: 10.5, design: .monospaced))
                }
            } else {
                Text("GitHub has not confirmed a merge.")
                    .foregroundStyle(ToastyTheme.inactiveText)
            }
        }
    }

    private func decisionFacts(_ action: CoordinatorReviewAction) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(action.kind == .merge ? "You approved this exact head for merge." : "You requested changes to this head.")
            Text(action.requestedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 10.5)).foregroundStyle(ToastyTheme.inactiveText)
            Text(CoordinatorReviewPresentation.deliveryDescription(action.deliveryState))
                .foregroundStyle(ToastyTheme.inactiveText)
            if let detail = action.deliveryDetail {
                Text("Delivery: \(detail)").foregroundStyle(ToastyTheme.inactiveText)
            }
            if let feedback = action.feedback { Text(feedback) }
            if let outcome = action.agentOutcome {
                Text("Agent report: \(CoordinatorReviewPresentation.agentOutcomeDescription(outcome.state))")
                    .font(.system(size: 11.5, weight: .medium))
                if let message = outcome.message { Text(message) }
            }
        }
    }

    private func decisionBar(_ review: CoordinatorReviewItem, current: CoordinatorReviewItem) -> some View {
        let canDecide = CoordinatorReviewPresentation.canDecide(current, currentReviewID: currentReviewID, reviewed: reviewedBrief)
        return VStack(alignment: .leading, spacing: 10) {
            if let actionError {
                Text(actionError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(ToastyTheme.sessionNeedsApprovalText)
                    .accessibilityIdentifier("coordinator.review.error")
            }
            HStack(spacing: 8) {
                Button {
                    isSubmitting = true
                    actionError = nil
                    Task { @MainActor in
                        defer { isSubmitting = false }
                        do {
                            try await actions.approveAndMerge(reviewID: review.id, expectedRevision: review.revision)
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                } label: {
                    Label(isSubmitting ? "Checking head…" : "Approve & Merge", systemImage: "checkmark")
                }
                .buttonStyle(CoordinatorReviewButtonStyle(isPrimary: true))
                .disabled(isSubmitting || isRefreshing || reviews.loadError != nil || !canDecide || CoordinatorReviewPresentation.canApprove(current, task: task) == false)
                .accessibilityIdentifier("coordinator.review.approve")
                Button("Request changes…") { feedbackTarget = review }
                    .buttonStyle(CoordinatorReviewButtonStyle())
                    .disabled(isSubmitting || isRefreshing || reviews.loadError != nil || !canDecide || CoordinatorReviewPresentation.canRequestChanges(current, task: task) == false)
                    .accessibilityIdentifier("coordinator.review.requestChanges")
            }
            if CoordinatorReviewPresentation.canRetry(current, task: task) {
                Text(current.userAction?.deliveryState == .uncertain
                    ? "Inspect the task before retrying. The uncertain request may already have reached its agent."
                    : "Retry sends a new request and keeps the previous decision in its history.")
                    .font(.system(size: 11.5)).foregroundStyle(ToastyTheme.inactiveText)
                Button(isSubmitting ? "Retrying…" : "Retry request") {
                    isSubmitting = true
                    actionError = nil
                    Task { @MainActor in
                        defer { isSubmitting = false }
                        do {
                            try await actions.retryDelivery(reviewID: review.id, expectedRevision: review.revision)
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(CoordinatorReviewButtonStyle())
                .disabled(isSubmitting || isRefreshing || reviews.loadError != nil || !canDecide)
                .accessibilityIdentifier("coordinator.review.retry")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ToastyTheme.elevatedBackground)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct CoordinatorReviewEvidenceRow: View {
    let evidence: CoordinatorReviewEvidence
    let managedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let url = evidence.url ?? managedURL {
                Link(destination: url) {
                    Label(evidence.label, systemImage: "arrow.up.right.square")
                }
            } else {
                Label(evidence.label, systemImage: "doc.text")
                if evidence.managedFileName != nil {
                    Text("The saved evidence file is unavailable.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(ToastyTheme.sessionNeedsApprovalText)
                }
            }
            if let excerpt = evidence.excerpt {
                Text(excerpt)
                    .font(.system(size: 11.5))
                    .foregroundStyle(ToastyTheme.inactiveText)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ToastyTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct CoordinatorReviewFeedbackSheet: View {
    let review: CoordinatorReviewItem
    let submit: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var feedback = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var isFeedbackFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Request changes").font(.headline)
            Text(review.taskTitle).foregroundStyle(.secondary)
            TextEditor(text: $feedback)
                .font(.body)
                .focused($isFeedbackFocused)
                .frame(height: 150)
                .overlay { RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.15), lineWidth: 1) }
                .accessibilityLabel("Changes to request")
            Text("Feedback is saved for the reviewed head and sent to the task agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSubmitting)
                Button(isSubmitting ? "Sending…" : "Send request") {
                    isSubmitting = true
                    errorMessage = nil
                    Task { @MainActor in
                        defer { isSubmitting = false }
                        do {
                            try await submit(feedback.trimmingCharacters(in: .whitespacesAndNewlines))
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting || feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || feedback.count > CoordinatorReviewAction.maximumFeedbackLength)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { isFeedbackFocused = true }
    }
}

struct CoordinatorReviewButtonStyle: ButtonStyle {
    var isPrimary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(isPrimary ? ToastyTheme.accentDark : ToastyTheme.primaryText)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(isPrimary ? ToastyTheme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(isPrimary ? Color.clear : Color.white.opacity(0.15), lineWidth: 1) }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}
