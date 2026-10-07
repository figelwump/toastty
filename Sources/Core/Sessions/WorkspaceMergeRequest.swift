import Foundation

/// The pull request a workspace's `github-pr` annotation links to.
public struct WorkspacePullRequestLink: Codable, Equatable, Sendable {
    /// `<owner>/<repo>`.
    public let repository: String
    public let number: Int
    /// The pull request's canonical URL, `https://github.com/<owner>/<repo>/pull/<number>`.
    /// The pull request script checks it against the checkout's repository,
    /// because a number alone could name a pull request in another repository.
    public let url: String

    /// Reads a GitHub pull request URL, including one that points at a page
    /// of the pull request such as `/files`; `nil` for anything else.
    public init?(annotationURL: String?) {
        guard let annotationURL,
              let components = URLComponents(string: annotationURL),
              components.scheme == "https",
              components.host?.lowercased() == "github.com" else {
            return nil
        }
        let parts = components.path.split(separator: "/")
        guard parts.count >= 4,
              parts[2] == "pull",
              parts[3].allSatisfy(\.isASCIIDigit),
              let number = Int(parts[3]) else {
            return nil
        }
        self.number = number
        repository = "\(parts[0])/\(parts[1])"
        url = "https://github.com/\(repository)/pull/\(number)"
    }

    /// `<owner>/<repo>#<number>`, which names the pull request on its own.
    public var displayName: String {
        "\(repository)#\(number)"
    }
}

/// What a subspace's Merge button is doing for its pull request, from the
/// click until nothing is left to do. Toastty merges the pull request itself;
/// after a Merge and Clean it waits for the merge, then closes the workspace,
/// removes its worktree, and deletes its branches. Close Without Merging goes
/// through it too. Saved across launches while it waits for the merge,
/// because auto-merge can wait on checks for longer than Toastty runs.
public struct WorkspaceMergeRequest: Codable, Equatable, Sendable {
    public enum Phase: Codable, Equatable, Sendable {
        /// The pull request script is merging the pull request or turning on
        /// auto-merge. With `thenCleanUp`, the request then waits for the
        /// merge; otherwise it ends.
        case merging(thenCleanUp: Bool)
        /// The workspace is done; the pull request has not merged yet.
        case awaitingMerge
        case cleaningUp
        /// Cleanup did not finish. The workspace stays, and the user can retry
        /// or dismiss the request.
        case failed(reason: String)
        /// Close Without Merging is running: the script closes the pull
        /// request, then cleans up as it does after a merge.
        case closing
    }

    public let pullRequest: WorkspacePullRequestLink
    /// A checkout inside the task's worktree. The pull request script finds
    /// the repository's main checkout from it.
    public let repoPath: String
    public var phase: Phase

    public init(pullRequest: WorkspacePullRequestLink, repoPath: String, phase: Phase) {
        self.pullRequest = pullRequest
        self.repoPath = repoPath
        self.phase = phase
    }

    /// The request after a change to its workspace, or `nil` when it no longer
    /// applies. `pullRequest` is what the workspace's `github-pr` annotation
    /// links to now. A running script keeps its request until it reports
    /// back, because the script itself can close the workspace.
    public func reconciled(workspaceExists: Bool, isDone: Bool, pullRequest: WorkspacePullRequestLink?) -> Self? {
        if isRunning {
            return self
        }
        guard workspaceExists, pullRequest == self.pullRequest else {
            return nil
        }
        // New work in the workspace clears its done mark, and with it the
        // user's acceptance of the version that was to merge.
        return isDone ? self : nil
    }

    /// Whether the pull request script is running for this request.
    public var isRunning: Bool {
        switch phase {
        case .merging, .cleaningUp, .closing:
            return true
        case .awaitingMerge, .failed:
            return false
        }
    }

    /// The state to save, or `nil` for none. A cleanup that a quit
    /// interrupted starts over, which is safe because the script rechecks
    /// everything before each change. An interrupted merge or close is not
    /// repeated: the user starts it again if the workspace is still there.
    public var persisted: Self? {
        switch phase {
        case .cleaningUp:
            var next = self
            next.phase = .awaitingMerge
            return next
        case .merging, .closing:
            return nil
        case .awaitingMerge, .failed:
            return self
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
