import Foundation

/// A decision made by the user. Delivery and an agent report do not prove a merge.
public struct CoordinatorReviewAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case merge
        case changesRequested
    }

    public enum DeliveryState: String, Codable, Sendable {
        case pending
        case dispatching
        case delivered
        case uncertain
        case failed
    }

    public struct AgentOutcome: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable {
            case queued
            case checking
            case blocked
            case failed
            case headChanged
            case merged
            case changesRequested
        }

        public var state: State
        public var message: String?
        public var reportedAt: Date

        public init(state: State, message: String? = nil, reportedAt: Date = Date()) {
            self.state = state
            self.message = message
            self.reportedAt = reportedAt
        }
    }

    public static let maximumFeedbackLength = 8_000
    public let intentID: UUID
    public let kind: Kind
    public let approvedHeadSHA: String
    public var feedback: String?
    public var deliveryState: DeliveryState
    /// The app's delivery result, kept separate from the agent's report.
    public var deliveryDetail: String?
    public var agentOutcome: AgentOutcome?
    public let requestedAt: Date
    public var updatedAt: Date
    public var deliveredAt: Date?

    public init(
        intentID: UUID = UUID(),
        kind: Kind,
        approvedHeadSHA: String,
        feedback: String? = nil,
        deliveryState: DeliveryState = .pending,
        deliveryDetail: String? = nil,
        agentOutcome: AgentOutcome? = nil,
        requestedAt: Date = Date(),
        updatedAt: Date? = nil,
        deliveredAt: Date? = nil
    ) {
        self.intentID = intentID
        self.kind = kind
        self.approvedHeadSHA = approvedHeadSHA
        self.feedback = feedback
        self.deliveryState = deliveryState
        self.deliveryDetail = deliveryDetail
        self.agentOutcome = agentOutcome
        self.requestedAt = requestedAt
        self.updatedAt = updatedAt ?? requestedAt
        self.deliveredAt = deliveredAt
    }

    public func validate() throws {
        guard CoordinatorReviewItem.isValidCommitID(approvedHeadSHA) else {
            throw CoordinatorReviewValidationError.invalidField("approvedHeadSHA", "Use a full commit ID.")
        }
        if let feedback {
            try CoordinatorReviewValidation.text(feedback, field: "feedback", maximum: Self.maximumFeedbackLength)
        }
        if let message = agentOutcome?.message {
            try CoordinatorReviewValidation.text(message, field: "agentOutcome.message", maximum: Self.maximumFeedbackLength)
        }
        if let deliveryDetail {
            try CoordinatorReviewValidation.text(deliveryDetail, field: "deliveryDetail", maximum: Self.maximumFeedbackLength)
        }
        try CoordinatorReviewValidation.date(requestedAt, field: "requestedAt")
        try CoordinatorReviewValidation.date(updatedAt, field: "action.updatedAt")
        if let deliveredAt { try CoordinatorReviewValidation.date(deliveredAt, field: "deliveredAt") }
        if let reportedAt = agentOutcome?.reportedAt { try CoordinatorReviewValidation.date(reportedAt, field: "reportedAt") }
        guard updatedAt >= requestedAt else {
            throw CoordinatorReviewValidationError.invalidField("action.updatedAt", "The update predates the request.")
        }
    }
}

/// Facts read from the PR service. Only this value can confirm a merge.
public struct CoordinatorReviewObservedOutcome: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case unknown
        case open
        case closed
        case merged
        case headChanged
    }

    public var state: State
    public var headSHA: String?
    public var baseRefName: String?
    public var mergeCommit: String?
    public var observedAt: Date?

    public init(state: State = .unknown, headSHA: String? = nil, baseRefName: String? = nil, mergeCommit: String? = nil, observedAt: Date? = nil) {
        self.state = state
        self.headSHA = headSHA
        self.baseRefName = baseRefName
        self.mergeCommit = mergeCommit
        self.observedAt = observedAt
    }

    public func validate() throws {
        if let baseRefName {
            try CoordinatorReviewValidation.text(baseRefName, field: "observedOutcome.baseRefName", maximum: 1_024)
        }
        for (field, value) in [("observedOutcome.headSHA", headSHA), ("observedOutcome.mergeCommit", mergeCommit)] {
            if let value, !CoordinatorReviewItem.isValidCommitID(value) {
                throw CoordinatorReviewValidationError.invalidField(field, "Use a full commit ID.")
            }
        }
        if let observedAt { try CoordinatorReviewValidation.date(observedAt, field: "observedAt") }
        guard state == .unknown || observedAt != nil else {
            throw CoordinatorReviewValidationError.invalidField("observedAt", "An observed outcome requires a timestamp.")
        }
    }
}
