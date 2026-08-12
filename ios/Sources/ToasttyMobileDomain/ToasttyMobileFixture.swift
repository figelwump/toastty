import Foundation
import RemoteProtocol

public enum ToasttyMobileFixture {
    public static let home: MobileHomeSnapshot = {
        let toasttyID = UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
        let researchID = UUID(uuidString: "A1000000-0000-0000-0000-000000000002")!
        let releaseID = UUID(uuidString: "A1000000-0000-0000-0000-000000000003")!

        let toastty = MobileWorkspace(
            id: toasttyID,
            title: "toastty",
            path: "~/GiantThings/repos/toastty",
            conversations: [
                conversation(
                    1, workspaceID: toasttyID, workspaceTitle: "toastty",
                    path: "~/GiantThings/repos/toastty", agent: .claude,
                    title: "Mobile gateway design", status: .needsApproval,
                    availability: .pendingInteraction(preview: "Review the gateway command on the Mac"),
                    age: "2m", last: "Ready for review — respond on the desktop"
                ),
                conversation(
                    2, workspaceID: toasttyID, workspaceTitle: "toastty",
                    path: "~/GiantThings/repos/toastty", agent: .codex,
                    title: "Sparkle updater fix", status: .working,
                    availability: .unavailable(reason: "working"),
                    age: "now", last: "Running xcodebuild tests…"
                ),
                conversation(
                    3, workspaceID: toasttyID, workspaceTitle: "toastty",
                    path: "~/GiantThings/repos/toastty", agent: .claude,
                    title: "Panel focus bug", status: .ready,
                    availability: .unavailable(reason: "prompt not open"),
                    age: "18m", last: "Fixed and committed"
                ),
                conversation(
                    4, workspaceID: toasttyID, workspaceTitle: "toastty",
                    path: "~/GiantThings/repos/toastty", agent: .codex,
                    title: "Release notes draft", status: .error,
                    availability: .unavailable(reason: "prompt not open"),
                    age: "1h", last: "Release note generation failed"
                ),
            ]
        )

        let research = MobileWorkspace(
            id: researchID,
            title: "herdr research",
            path: "~/GiantThings/playground/herdr",
            conversations: [
                conversation(
                    5, workspaceID: researchID, workspaceTitle: "herdr research",
                    path: "~/GiantThings/playground/herdr", agent: .claude,
                    title: "Architecture review", status: .working,
                    availability: .unavailable(reason: "working"),
                    age: "now", last: "Reading the handoff path"
                ),
                conversation(
                    6, workspaceID: researchID, workspaceTitle: "herdr research",
                    path: "~/GiantThings/playground/herdr", agent: .claude,
                    title: "Log spelunking", status: .idle,
                    availability: .unavailable(reason: "offline"),
                    age: "2d", last: "Conversation readable — resume on desktop"
                ),
            ]
        )

        let release = MobileWorkspace(
            id: releaseID,
            title: "release 0.9.0",
            path: "~/…/toastty-worktrees/release",
            conversations: [
                conversation(
                    7, workspaceID: releaseID, workspaceTitle: "release 0.9.0",
                    path: "~/…/toastty-worktrees/release", agent: .codex,
                    title: "Changelog + tag", status: .ready,
                    availability: .openPrompt,
                    age: "9m", last: "Which build number should I use?"
                ),
                conversation(
                    8, workspaceID: releaseID, workspaceTitle: "release 0.9.0",
                    path: "~/…/toastty-worktrees/release", agent: .claude,
                    title: "Smoke test triage", status: .ready,
                    availability: .localDraft,
                    age: "3h", last: "A desktop draft is in progress"
                ),
            ]
        )

        return MobileHomeSnapshot(hostName: "mac-studio", workspaces: [toastty, research, release])
    }()

    private static func conversation(
        _ number: Int,
        workspaceID: UUID,
        workspaceTitle: String,
        path: String,
        agent: AgentKind,
        title: String,
        status: RemoteSessionPresentationStatus,
        availability: MobileInputAvailability,
        age: String,
        last: String
    ) -> MobileConversation {
        MobileConversation(
            id: UUID(uuidString: String(format: "B1000000-0000-0000-0000-%012d", number))!,
            workspaceID: workspaceID,
            workspaceTitle: workspaceTitle,
            workspacePath: path,
            agent: agent,
            title: title,
            state: .known(status),
            inputAvailability: availability,
            age: age,
            lastActivity: last
        )
    }
}
