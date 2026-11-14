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
/// click until nothing is left to do. Toastty merges the pull request itself,
/// waiting for checks when it has to, and only at the commit the user
/// accepted. After a Merge and Clean it then closes the workspace, removes
/// its worktree, and deletes its branches. Close Without Merging goes through
/// it too. Saved across launches while it waits, because checks can run for
/// longer than Toastty does.
public struct WorkspaceMergeRequest: Codable, Equatable, Sendable {
    public enum Phase: Codable, Equatable, Sendable {
        /// The pull request script is checking the pull request and merging it
        /// if it can. With `thenCleanUp`, a cleanup follows the merge.
        case merging(thenCleanUp: Bool)
        /// The workspace is done, and Toastty is waiting for checks or a
        /// required review before it merges `acceptedHead`, the pull request
        /// head when the user clicked. New commits on the pull request end
        /// the wait without merging.
        case awaitingChecks(acceptedHead: String, thenCleanUp: Bool)
        /// The workspace is done; the pull request has merged or is about to,
        /// and the cleanup waits for it.
        case awaitingMerge
        /// The pull request merged and the cleanup waits until `until`, so
        /// the user can still look at the task space. A task space gets
        /// this after its merge; other workspaces clean up at once.
        case holdingCleanup(until: Date)
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
    /// The target branch reported when a merge started waiting for checks.
    /// Older saved waits have no target and must be accepted again.
    public var acceptedBase: String?
    /// An adopted task with no saved checkout may close only its empty
    /// task space. A checkout found by branch name must stay untouched.
    public var requiresAbsentWorktree: Bool?
    /// The cleanup already waited in `.holdingCleanup`, so a retry or a
    /// relaunch after it cleans up without waiting again.
    public var cleanupHoldEnded: Bool?

    public init(
        pullRequest: WorkspacePullRequestLink, repoPath: String, phase: Phase,
        requiresAbsentWorktree: Bool? = nil
    ) {
        self.pullRequest = pullRequest
        self.repoPath = repoPath
        self.phase = phase
        self.requiresAbsentWorktree = requiresAbsentWorktree
    }

    /// Why a request no longer applies after a change to its workspace.
    public enum DropReason: Equatable, Sendable {
        case workspaceClosed
        /// The workspace's `github-pr` annotation links elsewhere, or nowhere.
        case pullRequestChanged
        /// New work in the workspace cleared its done mark, and with it the
        /// user's acceptance of the version that was to merge; or someone
        /// cleared the mark by hand.
        case doneMarkCleared
    }

    /// Why the request no longer applies after a change to its workspace, or
    /// `nil` while it still does. `pullRequest` is what the workspace's
    /// `github-pr` annotation links to now. A running script keeps its
    /// request until it reports back, because the script itself can close
    /// the workspace.
    public func dropReason(workspaceExists: Bool, isDone: Bool, pullRequest: WorkspacePullRequestLink?) -> DropReason? {
        if isRunning {
            return nil
        }
        guard workspaceExists else { return .workspaceClosed }
        guard pullRequest == self.pullRequest else { return .pullRequestChanged }
        return isDone ? nil : .doneMarkCleared
    }

    /// Whether the pull request script is running for this request.
    public var isRunning: Bool {
        switch phase {
        case .merging, .cleaningUp, .closing:
            return true
        case .awaitingChecks, .awaitingMerge, .holdingCleanup, .failed:
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
        case .awaitingChecks, .awaitingMerge, .holdingCleanup, .failed:
            return self
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
