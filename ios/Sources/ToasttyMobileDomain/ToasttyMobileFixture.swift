import Foundation
import RemoteProtocol

public enum ToasttyMobileFixture {
    public static let previewWorkspaceID = UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
    public static let panelOnlyWorkspaceID = UUID(uuidString: "A1000000-0000-0000-0000-000000000004")!
    public static let needsApprovalSubspaceID = UUID(uuidString: "A1000000-0000-0000-0000-000000000011")!
    public static let readySubspaceID = UUID(uuidString: "A1000000-0000-0000-0000-000000000012")!
    public static let workingSubspaceID = UUID(uuidString: "A1000000-0000-0000-0000-000000000013")!
    public static let doneSubspaceID = UUID(uuidString: "A1000000-0000-0000-0000-000000000014")!
    public static let scratchpadPanelID = UUID(uuidString: "C1000000-0000-0000-0000-000000000001")!
    public static let scratchpadConversationID = UUID(uuidString: "B1000000-0000-0000-0000-000000000007")!
    public static let documentPanelID = UUID(uuidString: "C1000000-0000-0000-0000-000000000002")!
    public static let htmlPanelID = UUID(uuidString: "C1000000-0000-0000-0000-000000000003")!
    public static let websitePanelID = UUID(uuidString: "C1000000-0000-0000-0000-000000000004")!
    public static let navigationScratchpadPanelID = UUID(uuidString: "C1000000-0000-0000-0000-000000000005")!

    public static let olderDocumentPanelID = UUID(uuidString: "C1000000-0000-0000-0000-000000000006")!
    public static let undatedDocumentPanelID = UUID(uuidString: "C1000000-0000-0000-0000-000000000007")!
    public static let smokeReportPanelID = UUID(uuidString: "C1000000-0000-0000-0000-000000000008")!
    public static let remoteReportPanelID = UUID(uuidString: "C1000000-0000-0000-0000-000000000009")!

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
                    age: "now", last: "Running the remote iOS test suite",
                    turnElapsedSeconds: 221, lastTurnDuration: 125
                ),
                conversation(
                    3, workspaceID: toasttyID, workspaceTitle: "toastty",
                    cwd: nil, agent: .claude,
                    title: "Panel focus bug", status: .ready,
                    availability: .unavailable(reason: "prompt not open"),
                    age: "18m", last: "Fixed panel focus and verified keyboard navigation",
                    isFlaggedForLater: true, lastTurnDuration: 754
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
                    age: "now", last: "Reading the handoff path",
                    turnElapsedSeconds: 47
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
                // Same-titled reports from two runs, told apart by folder.
                previewPanel(8, panelID: smokeReportPanelID, kind: "localDocument", title: "report.json",
                             tabNumber: 3, tabTitle: "Navigation",
                             filePath: "/fixtures/playground/artifacts/smoke/report.json"),
                previewPanel(9, panelID: remoteReportPanelID, kind: "localDocument", title: "report.json",
                             tabNumber: 3, tabTitle: "Navigation",
                             filePath: "/fixtures/playground/artifacts/remote/report.json"),
            ]
        )

        return MobileHomeSnapshot(
            hostName: "mac-studio",
            workspaces: [toastty, research, release, panelOnly] + subspaces(of: toasttyID)
        )
    }()

    /// Task worktrees spawned from the toastty workspace, one in each state
    /// a subspace row shows. Three come from the first session and one from
    /// the second, so the ⑂ filter has something to leave out.
    private static func subspaces(of parentID: UUID) -> [MobileWorkspace] {
        let firstSpawner = UUID(uuidString: "B1000000-0000-0000-0000-000000000001")!
        let secondSpawner = UUID(uuidString: "B1000000-0000-0000-0000-000000000002")!
        func pullRequest(_ text: String, _ number: Int) -> RemoteWorkspaceAnnotation {
            RemoteWorkspaceAnnotation(
                key: "github-pr", text: text,
                url: URL(string: "https://github.com/example/toastty/pull/\(number)"), color: "#5BA08A"
            )
        }
        return [
            MobileWorkspace(
                id: needsApprovalSubspaceID,
                title: "compact-session-rows",
                conversations: [
                    conversation(
                        9, workspaceID: needsApprovalSubspaceID, workspaceTitle: "compact-session-rows",
                        cwd: "~/GiantThings/repos/toastty-compact-session-rows", agent: .claude,
                        title: "Implement compact rows", status: .needsApproval,
                        availability: .pendingInteraction(preview: "Review the push on the Mac"),
                        age: "5m", last: "Push feat/compact-session-rows?"
                    ),
                    conversation(
                        13, workspaceID: needsApprovalSubspaceID, workspaceTitle: "compact-session-rows",
                        cwd: "~/GiantThings/repos/toastty-compact-session-rows", agent: .codex,
                        title: "Second-opinion review", status: .idle,
                        availability: .unavailable(reason: "prompt not open"),
                        age: "40m", last: "Two findings, both addressed"
                    ),
                ],
                annotations: [pullRequest("PR #36", 36)],
                parentWorkspaceID: parentID,
                spawningConversationID: firstSpawner
            ),
            MobileWorkspace(
                id: readySubspaceID,
                title: "early-session-titles",
                conversations: [
                    conversation(
                        10, workspaceID: readySubspaceID, workspaceTitle: "early-session-titles",
                        cwd: "~/GiantThings/repos/toastty-early-session-titles", agent: .claude,
                        title: "", status: .ready,
                        availability: .unavailable(reason: "prompt not open"),
                        age: "25m", last: "CI green, PR ready for review"
                    ),
                ],
                // The primary annotation wins the row's one chip over the
                // pull request.
                annotations: [
                    pullRequest("PR #45", 45),
                    RemoteWorkspaceAnnotation(key: "ticket", text: "TOAST-45", color: "#7AA2F7"),
                ],
                parentWorkspaceID: parentID,
                spawningConversationID: firstSpawner,
                primaryAnnotationKey: "ticket"
            ),
            MobileWorkspace(
                id: workingSubspaceID,
                title: "ios-subspaces",
                conversations: [
                    conversation(
                        11, workspaceID: workingSubspaceID, workspaceTitle: "ios-subspaces",
                        cwd: "~/GiantThings/repos/toastty-ios-subspaces", agent: .claude,
                        title: "Port subspaces to iOS", status: .working,
                        availability: .unavailable(reason: "working"),
                        age: "now", last: "Editing ToasttyHomeView.swift"
                    ),
                ] + (14...18).map { number in
                    // Enough idle sessions that its page caps the list.
                    conversation(
                        number, workspaceID: workingSubspaceID, workspaceTitle: "ios-subspaces",
                        cwd: "~/GiantThings/repos/toastty-ios-subspaces", agent: .codex,
                        title: "Subspace follow-up \(number - 13)", status: .idle,
                        availability: .unavailable(reason: "prompt not open"),
                        age: "\(number - 12)h", last: "Done."
                    )
                },
                parentWorkspaceID: parentID,
                spawningConversationID: secondSpawner
            ),
            MobileWorkspace(
                id: doneSubspaceID,
                title: "sidebar-done-subspaces",
                conversations: [
                    // The unread turn that set the mark; the mark hides it.
                    conversation(
                        12, workspaceID: doneSubspaceID, workspaceTitle: "sidebar-done-subspaces",
                        cwd: "~/GiantThings/repos/toastty-sidebar-done-subspaces", agent: .claude,
                        title: "Mark subspaces done", status: .ready,
                        availability: .unavailable(reason: "prompt not open"),
                        age: "4h", last: "Auto-merge enabled"
                    ),
                ],
                annotations: [pullRequest("#40 merged", 40)],
                parentWorkspaceID: parentID,
                spawningConversationID: firstSpawner,
                isDone: true
            ),
        ]
    }

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
        executionProfile: RemoteSessionExecutionProfile? = nil,
        isFlaggedForLater: Bool = false,
        turnElapsedSeconds: Int? = nil,
        lastTurnDuration: TimeInterval? = nil
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
            executionProfile: executionProfile,
            workspaceTabID: [1, 7, 8].contains(number) ? UUID(uuidString: "D1000000-0000-0000-0000-000000000001") : nil,
            workspaceTabTitle: [1, 7, 8].contains(number)
                ? "Release preparation — changelog, signing, and TestFlight verification" : nil,
            isFlaggedForLater: isFlaggedForLater,
            turnElapsed: turnElapsedSeconds.map {
                MobileActivityAge(secondsAtReceipt: $0, receivedAtMonotonicTime: fixtureReceiptTime)
            },
            lastTurnDuration: lastTurnDuration
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

// MARK: - Session start

public extension ToasttyMobileFixture {
    /// What a Mac would offer for a new session in `workspace`: two agents
    /// that can start and one that cannot, so the sheet's states are all
    /// reachable without a Mac.
    static func sessionStartOptions(for workspace: MobileWorkspace?) -> RemoteSessionStartOptionsResponse {
        guard let workspace else {
            return RemoteSessionStartOptionsResponse(permission: .allowed, workspace: .notFound)
        }
        return RemoteSessionStartOptionsResponse(
            permission: .allowed,
            workspace: .available,
            launchDirectory: workspace.conversations.lazy.compactMap(\.cwd).first
                ?? "~/GiantThings/repos/\(workspace.title)",
            agents: [
                RemoteSessionStartAgent(
                    profileID: "claude",
                    displayName: "Claude",
                    availability: .available,
                    supportsModel: true,
                    recentModels: ["claude-opus-5-5", "claude-fable-5-1"],
                    reasoningEfforts: ["low", "medium", "high", "xhigh"]
                ),
                RemoteSessionStartAgent(
                    profileID: "codex",
                    displayName: "Codex",
                    availability: .available,
                    supportsModel: true,
                    recentModels: ["gpt-6.1-sol"],
                    reasoningEfforts: ["low", "medium", "high", "xhigh"]
                ),
                RemoteSessionStartAgent(
                    profileID: "pi",
                    displayName: "Pi",
                    availability: .notInstalled,
                    supportsModel: true
                ),
            ]
        )
    }

    /// The session a fixture start adds to `workspace`, as the Mac's next
    /// snapshot would list it.
    static func startedConversation(
        id: UUID,
        request: RemoteSessionStartRequest,
        agentDisplayName: String,
        workspace: MobileWorkspace
    ) -> MobileConversation {
        let profile = RemoteSessionExecutionProfile(
            modelIdentifier: request.model,
            reasoningEffort: request.reasoningEffort
        )
        return MobileConversation(
            id: id,
            workspaceID: workspace.id,
            workspaceTitle: workspace.title,
            cwd: sessionStartOptions(for: workspace).launchDirectory,
            agent: AgentKind(rawValue: request.profileID) ?? .claude,
            title: "New \(agentDisplayName) session",
            state: MobileSessionStatus.working,
            inputAvailability: .unavailable(reason: "working"),
            age: "now",
            activityAge: MobileActivityAge(
                secondsAtReceipt: 0,
                receivedAtMonotonicTime: ProcessInfo.processInfo.systemUptime
            ),
            lastActivity: request.text,
            executionProfile: profile.isEmpty ? nil : profile,
            turnElapsed: MobileActivityAge(
                secondsAtReceipt: 0,
                receivedAtMonotonicTime: ProcessInfo.processInfo.systemUptime
            )
        )
    }
}
