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
            conversations: [
                conversation(
                    1, workspaceID: toasttyID, workspaceTitle: "toastty",
                    cwd: "~/GiantThings/repos/toastty", agent: .claude,
                    title: "Mobile gateway design", status: .needsApproval,
                    availability: .pendingInteraction(preview: "Review the gateway command on the Mac"),
                    age: "2m", last: "Allow Toastty to run the focused iOS tests?"
                ),
                conversation(
                    2, workspaceID: toasttyID, workspaceTitle: "toastty",
                    cwd: "~/GiantThings/repos/toastty-ios", agent: .codex,
                    title: "Sparkle updater fix", status: .working,
                    availability: .unavailable(reason: "working"),
                    age: "now", last: "Running the remote iOS test suite"
                ),
                conversation(
                    3, workspaceID: toasttyID, workspaceTitle: "toastty",
                    cwd: nil, agent: .claude,
                    title: "Panel focus bug", status: .ready,
                    availability: .unavailable(reason: "prompt not open"),
                    age: "18m", last: "Fixed panel focus and verified keyboard navigation"
                ),
                conversation(
                    4, workspaceID: toasttyID, workspaceTitle: "toastty",
                    cwd: "~/GiantThings/repos/toastty", agent: .codex,
                    title: "Release notes draft", status: .error,
                    availability: .unavailable(reason: "prompt not open"),
                    age: "1h", last: "Release note generation failed: missing metadata"
                ),
            ]
        )

        let research = MobileWorkspace(
            id: researchID,
            title: "herdr research",
            conversations: [
                conversation(
                    5, workspaceID: researchID, workspaceTitle: "herdr research",
                    cwd: "~/GiantThings/playground/herdr", agent: .claude,
                    title: "Architecture review", status: .working,
                    availability: .unavailable(reason: "working"),
                    age: "now", last: "Reading the handoff path"
                ),
                conversation(
                    6, workspaceID: researchID, workspaceTitle: "herdr research",
                    cwd: nil, agent: .claude,
                    title: "Log spelunking", status: .idle,
                    availability: .unavailable(reason: "offline"),
                    age: "2d", last: "Conversation readable — resume on desktop"
                ),
            ]
        )

        let release = MobileWorkspace(
            id: releaseID,
            title: "release 0.9.0",
            conversations: [
                conversation(
                    7, workspaceID: releaseID, workspaceTitle: "release 0.9.0",
                    cwd: "~/…/toastty-worktrees/release", agent: .codex,
                    title: "Changelog + tag", status: .ready,
                    availability: .openPrompt,
                    age: "9m", last: "Which build number should I use?"
                ),
                conversation(
                    8, workspaceID: releaseID, workspaceTitle: "release 0.9.0",
                    cwd: "~/…/toastty-worktrees/release-notes", agent: .claude,
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
        cwd: String?,
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
            cwd: cwd,
            agent: agent,
            title: title,
            state: .known(status),
            inputAvailability: availability,
            age: age,
            activityAge: MobileActivityAge(
                secondsAtReceipt: ageSeconds(age),
                receivedAtMonotonicTime: fixtureReceiptTime
            ),
            lastActivity: last
        )
    }

    private static func ageSeconds(_ age: String) -> Int {
        if age == "now" { return 0 }
        guard let unit = age.last, let value = Int(age.dropLast()) else { return .max }
        switch unit {
        case "m": return value * 60
        case "h": return value * 60 * 60
        case "d": return value * 24 * 60 * 60
        default: return .max
        }
    }

    private static let fixtureReceiptTime = ProcessInfo.processInfo.systemUptime
}
