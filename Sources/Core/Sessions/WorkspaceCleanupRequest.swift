import Foundation

/// A cleanup the user asked for with Merge and Clean: once the workspace's
/// pull request merges, Toastty closes the workspace, removes its worktree,
/// and deletes its branches. It outlives the merge request, because the agent
/// can stop to ask about a prerequisite and set the done mark in a later turn,
/// and it is saved across launches, because auto-merge can wait on checks for
/// longer than Toastty runs.
public struct WorkspaceCleanupRequest: Codable, Equatable, Sendable {
    public enum Phase: Codable, Equatable, Sendable {
        /// The merge prompt went to the agent, which has not marked the
        /// workspace done yet.
        case awaitingDone
        /// The workspace is done; the pull request has not merged yet.
        case awaitingMerge
        case cleaningUp
        /// Cleanup did not finish. The workspace stays, and the user can retry
        /// or dismiss the request.
        case failed(reason: String)
    }

    public let pullRequestNumber: Int
    /// A checkout inside the task's worktree. The cleanup script finds the
    /// repository's main checkout from it.
    public let repoPath: String
    public var phase: Phase

    public init(pullRequestNumber: Int, repoPath: String, phase: Phase = .awaitingDone) {
        self.pullRequestNumber = pullRequestNumber
        self.repoPath = repoPath
        self.phase = phase
    }

    /// The request after a change to its workspace, or `nil` when it no longer
    /// applies. `pullRequestNumber` is the number the workspace's `github-pr`
    /// annotation names now. A running cleanup keeps its request until the
    /// run reports back, because the run itself closes the workspace.
    public func reconciled(workspaceExists: Bool, isDone: Bool, pullRequestNumber: Int?) -> Self? {
        if phase == .cleaningUp {
            return self
        }
        guard workspaceExists, pullRequestNumber == self.pullRequestNumber else {
            return nil
        }
        switch phase {
        case .awaitingDone:
            guard isDone else { return self }
            var next = self
            next.phase = .awaitingMerge
            return next
        case .awaitingMerge, .failed:
            // New work in the workspace clears its done mark, and with it the
            // user's acceptance of the version that was to merge.
            return isDone ? self : nil
        case .cleaningUp:
            return self
        }
    }

    /// The state to save. A run that a quit interrupted starts over, which is
    /// safe because the cleanup script rechecks everything before each change.
    public var persisted: Self {
        guard phase == .cleaningUp else { return self }
        var next = self
        next.phase = .awaitingMerge
        return next
    }

    /// The pull request number in a `github-pr` annotation: the number at the
    /// end of a pull request URL, or else a `#123` in its text.
    public static func pullRequestNumber(text: String, url: String?) -> Int? {
        if let url,
           let pullRange = url.range(of: "/pull/", options: .backwards) {
            var digits = url[pullRange.upperBound...]
            if digits.hasSuffix("/") {
                digits = digits.dropLast()
            }
            if digits.isEmpty == false, digits.allSatisfy(\.isASCIIDigit), let number = Int(digits) {
                return number
            }
        }
        guard let hashIndex = text.firstIndex(of: "#") else { return nil }
        let digits = text[text.index(after: hashIndex)...].prefix(while: \.isASCIIDigit)
        return Int(digits)
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
