import Foundation
import RemoteProtocol

public enum ToasttyMobileFixture {
    public static let previewWorkspaceID = UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
    public static let panelOnlyWorkspaceID = UUID(uuidString: "A1000000-0000-0000-0000-000000000004")!
    public static let scratchpadPanelID = UUID(uuidString: "C1000000-0000-0000-0000-000000000001")!
    public static let scratchpadConversationID = UUID(uuidString: "B1000000-0000-0000-0000-000000000007")!
    public static let documentPanelID = UUID(uuidString: "C1000000-0000-0000-0000-000000000002")!
    public static let htmlPanelID = UUID(uuidString: "C1000000-0000-0000-0000-000000000003")!
    public static let websitePanelID = UUID(uuidString: "C1000000-0000-0000-0000-000000000004")!
    public static let navigationScratchpadPanelID = UUID(uuidString: "C1000000-0000-0000-0000-000000000005")!

    public static let olderDocumentPanelID = UUID(uuidString: "C1000000-0000-0000-0000-000000000006")!
    public static let undatedDocumentPanelID = UUID(uuidString: "C1000000-0000-0000-0000-000000000007")!

    /// Fixed identities let UI fixtures exercise the same selection across reloads.
    public static let previewPanels: [RemoteWorkspacePanel] = [
        previewPanel(1, panelID: scratchpadPanelID, kind: "scratchpad", title: "Workspace map", revision: 1,
                     updatedAt: Date().addingTimeInterval(-120),
                     associatedConversationID: RemoteConversationID(rawValue: scratchpadConversationID)),
        previewPanel(2, panelID: documentPanelID, kind: "localDocument", title: "mobile-preview.md",
                     filePath: "/fixtures/toastty/docs/mobile-preview.md", updatedAt: Date().addingTimeInterval(-300)),
        previewPanel(3, panelID: htmlPanelID, kind: "browser", title: "preview.html",
                     url: URL(fileURLWithPath: "/fixtures/toastty/site/preview.html"), updatedAt: Date().addingTimeInterval(-3600)),
        previewPanel(4, panelID: websitePanelID, kind: "browser", title: "Example website",
                     tabNumber: 2, tabTitle: "Research", url: URL(string: "https://example.com"), updatedAt: Date().addingTimeInterval(-7200)),
        previewPanel(6, panelID: olderDocumentPanelID, kind: "localDocument", title: "Earlier notes",
                     updatedAt: Date().addingTimeInterval(-172800)),
        previewPanel(7, panelID: undatedDocumentPanelID, kind: "localDocument", title: "Undated notes"),
    ]

    public static let home: MobileHomeSnapshot = {
        let toasttyID = previewWorkspaceID
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
                    age: "2m", last: "Allow Toastty to run the focused iOS tests?",
                    executionProfile: RemoteSessionExecutionProfile(
                        modelIdentifier: "claude-opus-long-provider-model-identifier-for-accessibility-layout",
                        reasoningEffort: "high"
                    )
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
            ],
            panels: previewPanels,
            // Enough chips to wrap the home header, including one past the
            // 160pt chip cap.
            annotations: [
                RemoteWorkspaceAnnotation(key: "build", text: "build 0.8.3-35", color: "#B7AEA5"),
                RemoteWorkspaceAnnotation(
                    key: "git-branch", text: "feat/ios-workspace-annotations-and-chip-colors", color: "#7AA2F7"
                ),
                RemoteWorkspaceAnnotation(
                    key: "github-pr", text: "PR #12",
                    url: URL(string: "https://github.com/example/toastty/pull/12"), color: "#5BA08A"
                ),
                RemoteWorkspaceAnnotation(key: "review", text: "review: 2 open", color: "#E8A635"),
                RemoteWorkspaceAnnotation(key: "task-status", text: "Working", color: "#A78BFA"),
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
                    age: "9m", last: "Which build number should I use?",
                    executionProfile: RemoteSessionExecutionProfile(
                        modelIdentifier: "gpt-6", reasoningEffort: "xhigh"
                    )
                ),
                conversation(
                    8, workspaceID: releaseID, workspaceTitle: "release 0.9.0",
                    cwd: "~/…/toastty-worktrees/release-notes", agent: .claude,
                    title: "Smoke test triage", status: .ready,
                    availability: .localDraft,
                    age: "3h", last: "A desktop draft is in progress"
                ),
            ],
            annotations: [
                RemoteWorkspaceAnnotation(
                    key: "ci", text: "CI failing",
                    url: URL(string: "https://github.com/example/toastty/actions"), color: "#E55C5C"
                ),
                RemoteWorkspaceAnnotation(key: "deploy", text: "canary 20%", color: "#E8A635"),
                // A dark custom color, and a link only the Mac can reach.
                RemoteWorkspaceAnnotation(
                    key: "preview", text: "localhost:8080",
                    url: URL(string: "http://localhost:8080"), color: "#3B2A6E"
                ),
            ]
        )

        let panelOnly = MobileWorkspace(
            id: panelOnlyWorkspaceID,
            title: "Preview playground",
            conversations: [],
            panels: [
                previewPanel(5, panelID: navigationScratchpadPanelID, kind: "scratchpad",
                             title: "Navigation sketch", tabNumber: 3, tabTitle: "Navigation", revision: 1),
            ]
        )

        return MobileHomeSnapshot(hostName: "mac-studio", workspaces: [toastty, research, release, panelOnly])
    }()

    private static func previewPanel(
        _ number: Int,
        panelID: UUID,
        kind: String,
        title: String,
        tabNumber: Int = 1,
        tabTitle: String = "iOS preview",
        revision: Int? = nil,
        filePath: String? = nil,
        url: URL? = nil,
        updatedAt: Date? = nil,
        associatedConversationID: RemoteConversationID? = nil
    ) -> RemoteWorkspacePanel {
        RemoteWorkspacePanel(
            panelID: panelID,
            auxiliaryTabID: UUID(uuidString: String(format: "D1000000-0000-0000-0000-%012d", number))!,
            workspaceTabID: UUID(uuidString: String(format: "E1000000-0000-0000-0000-%012d", tabNumber))!,
            workspaceTabTitle: tabTitle,
            kind: kind,
            title: title,
            revision: revision,
            filePath: filePath,
            url: url,
            updatedAt: updatedAt,
            associatedConversationID: associatedConversationID
        )
    }

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
        last: String,
        executionProfile: RemoteSessionExecutionProfile? = nil
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
            lastActivity: last,
            executionProfile: executionProfile
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
