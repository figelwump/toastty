import Foundation

/// The facts shown to the user before a decision about one PR head.
public struct CoordinatorReviewBrief: Codable, Equatable, Sendable {
    public enum Priority: String, Codable, Sendable, CaseIterable {
        case urgent
        case blocking
        case ready
    }

    public static let maximumTextLength = 8_000
    public static let maximumListCount = 32
    public static let maximumEvidenceCount = 12

    public var behaviorChange: String
    public var decisionNeeded: String
    public var verification: [String]
    public var gaps: [String]
    public var recommendation: String
    public var evidence: [CoordinatorReviewEvidence]
    public var priority: Priority

    public init(
        behaviorChange: String,
        decisionNeeded: String,
        verification: [String] = [],
        gaps: [String] = [],
        recommendation: String,
        evidence: [CoordinatorReviewEvidence] = [],
        priority: Priority = .ready
    ) {
        self.behaviorChange = behaviorChange
        self.decisionNeeded = decisionNeeded
        self.verification = verification
        self.gaps = gaps
        self.recommendation = recommendation
        self.evidence = evidence
        self.priority = priority
    }

    private enum CodingKeys: String, CodingKey {
        case behaviorChange, decisionNeeded, verification, gaps, recommendation, evidence, priority
    }

    /// Optional presentation fields have the same defaults over the API as
    /// they do for native callers. The three decision fields remain required.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        behaviorChange = try container.decode(String.self, forKey: .behaviorChange)
        decisionNeeded = try container.decode(String.self, forKey: .decisionNeeded)
        recommendation = try container.decode(String.self, forKey: .recommendation)
        verification = try container.decodeIfPresent([String].self, forKey: .verification) ?? []
        gaps = try container.decodeIfPresent([String].self, forKey: .gaps) ?? []
        evidence = try container.decodeIfPresent([CoordinatorReviewEvidence].self, forKey: .evidence) ?? []
        priority = try container.decodeIfPresent(Priority.self, forKey: .priority) ?? .ready
    }

    public func validate() throws {
        try CoordinatorReviewValidation.text(behaviorChange, field: "behaviorChange", maximum: Self.maximumTextLength)
        try CoordinatorReviewValidation.text(decisionNeeded, field: "decisionNeeded", maximum: Self.maximumTextLength)
        try CoordinatorReviewValidation.text(recommendation, field: "recommendation", maximum: Self.maximumTextLength)
        for (field, values) in [("verification", verification), ("gaps", gaps)] {
            guard values.count <= Self.maximumListCount else {
                throw CoordinatorReviewValidationError.invalidField(field, "Too many entries.")
            }
            for value in values {
                try CoordinatorReviewValidation.text(value, field: field, maximum: Self.maximumTextLength)
            }
        }
        guard evidence.count <= Self.maximumEvidenceCount else {
            throw CoordinatorReviewValidationError.invalidField("evidence", "Too many entries.")
        }
        for value in evidence { try value.validate() }
    }
}

/// A remote link or a store-owned copy. Source worktree paths are never saved.
public struct CoordinatorReviewEvidence: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case report
        case diff
        case test
        case screenshot
        case video
        case log
        case link
        case other
    }

    public static let maximumLabelLength = 200
    public static let maximumExcerptLength = 8_000
    public static let maximumURLLength = 2_048

    public var kind: Kind
    public var label: String
    public var excerpt: String?
    public var url: URL?
    /// A generated direct-child filename in the review store's evidence directory.
    public var managedFileName: String?

    public init(kind: Kind, label: String, excerpt: String? = nil, url: URL? = nil, managedFileName: String? = nil) {
        self.kind = kind
        self.label = label
        self.excerpt = excerpt
        self.url = url
        self.managedFileName = managedFileName
    }

    public func validate() throws {
        try CoordinatorReviewValidation.text(label, field: "evidence.label", maximum: Self.maximumLabelLength)
        if let excerpt {
            try CoordinatorReviewValidation.text(excerpt, field: "evidence.excerpt", maximum: Self.maximumExcerptLength)
        }
        if let url {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard url.absoluteString.count <= Self.maximumURLLength,
                  ["https", "http"].contains(components?.scheme),
                  components?.host?.isEmpty == false,
                  components?.user == nil, components?.password == nil else {
                throw CoordinatorReviewValidationError.invalidField("evidence.url", "Use a web URL or a managed file copy.")
            }
        }
        if let managedFileName, !Self.isValidManagedFileName(managedFileName) {
            throw CoordinatorReviewValidationError.invalidField("evidence.managedFileName", "Invalid managed filename.")
        }
    }

    public static func isValidManagedFileName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              let stem = parts.first, UUID(uuidString: String(stem)) != nil else { return false }
        guard parts.count == 2 else { return true }
        return !parts[1].isEmpty && parts[1].count <= 12
            && parts[1].utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) }
    }
}
