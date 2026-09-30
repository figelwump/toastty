import RemoteProtocol
import XCTest
@testable import ToasttyMobileDomain

final class ToasttyMobileModelsTests: XCTestCase {
    func testLegacyProtocolStatesFallBackToDesktopPresentationBuckets() {
        XCTAssertEqual(RemoteSessionState.awaitingInput.bucket, .ready)
        XCTAssertEqual(RemoteSessionState.starting.bucket, .working)
        XCTAssertEqual(RemoteSessionState.working.bucket, .working)
        XCTAssertEqual(RemoteSessionState.ready.bucket, .ready)
        XCTAssertEqual(RemoteSessionState.interrupted.bucket, .error)
        XCTAssertEqual(RemoteSessionState.error.bucket, .error)
        XCTAssertEqual(RemoteSessionState.ended.bucket, .idle)
        XCTAssertEqual(RemoteSessionState.offline.bucket, .idle)
    }

    func testActivityProjectionContainsEverySessionExactlyOnceInBucketOrder() {
        let snapshot = ToasttyMobileFixture.home

        let sourceSessions = snapshot.workspaces.flatMap(\.conversations)
        XCTAssertEqual(snapshot.activitySessions.count, sourceSessions.count)
        XCTAssertEqual(Set(snapshot.activitySessions.map(\.id)), Set(sourceSessions.map(\.id)))
        XCTAssertEqual(
            snapshot.activitySessions.map(\.state.bucket),
            [
                .error, .ready, .ready, .ready, .ready, .ready, .needsApproval, .needsApproval,
                .working, .working, .working, .idle, .idle,
            ]
        )
    }

    func testConversationNormalizesMissingAndBlankCWDToNil() {
        XCTAssertNil(conversation(cwd: nil).cwd)
        XCTAssertNil(conversation(cwd: "").cwd)
        XCTAssertNil(conversation(cwd: " \n\t ").cwd)
        XCTAssertEqual(conversation(cwd: "  /repos/toastty  ").cwd, "/repos/toastty")
    }

    func testConversationAbbreviatesCWDLikeDesktopSidebar() {
        XCTAssertNil(conversation(cwd: nil).abbreviatedCWD)
        XCTAssertEqual(
            conversation(cwd: "/Users/vishal/GiantThings/repos/emptyos").abbreviatedCWD,
            ".../emptyos"
        )
        XCTAssertEqual(conversation(cwd: "~/GiantThings/repos/toastty/").abbreviatedCWD, ".../toastty")
        XCTAssertEqual(conversation(cwd: "/").abbreviatedCWD, "/")
        XCTAssertEqual(conversation(cwd: "/emptyos").abbreviatedCWD, ".../emptyos")
        XCTAssertEqual(conversation(cwd: "emptyos").abbreviatedCWD, "emptyos")
        XCTAssertEqual(conversation(cwd: "~").abbreviatedCWD, "~")
        XCTAssertEqual(conversation(cwd: "~/").abbreviatedCWD, "~")
        XCTAssertEqual(conversation(cwd: "~agent").abbreviatedCWD, "~agent")
        XCTAssertEqual(conversation(cwd: ".").abbreviatedCWD, ".")
        XCTAssertEqual(conversation(cwd: "..").abbreviatedCWD, "..")
    }

    func testDisplayAgeSpellsOutElapsedContextButKeepsNow() {
        XCTAssertEqual(conversation(age: "now").displayAge, "now")
        XCTAssertEqual(conversation(age: "18m").displayAge, "18m ago")
        XCTAssertEqual(conversation(age: "2d").displayAge, "2d ago")
        XCTAssertEqual(conversation(age: "  ").displayAge, "")
    }

    func testFixtureCoversEveryDesktopPresentationStatus() {
        let statuses = Set(
            ToasttyMobileFixture.home.workspaces
                .flatMap(\.conversations)
                .compactMap { conversation -> RemoteSessionPresentationStatus? in
                    guard case .known(let status) = conversation.state else { return nil }
                    return status
                }
        )

        XCTAssertEqual(statuses, Set([
            .idle, .working, .needsApproval, .ready, .error,
        ]))
        let fixtureCWDs = ToasttyMobileFixture.home.workspaces
            .flatMap(\.conversations)
            .map(\.cwd)
        XCTAssertTrue(fixtureCWDs.contains(nil))
        XCTAssertGreaterThan(Set(fixtureCWDs.compactMap { $0 }).count, 3)
        XCTAssertTrue(
            ToasttyMobileFixture.home.activitySessions.allSatisfy {
                !$0.lastActivity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        )
    }

    func testStatusAccessibilitySummaryIncludesNonColorFacts() throws {
        let conversation = conversation(
            title: "/repos/toastty",
            state: .ready,
            cwd: "/repos/toastty",
            age: "18m",
            lastActivity: "Fixed and committed"
        )

        XCTAssertEqual(
            conversation.accessibilitySummary,
            "/repos/toastty, ready, Fixed and committed, Workspace, codex, /repos/toastty, 18m ago"
        )
    }

    func testWorkspaceSortPreservesStatusPriorityThenRecency() {
        let readyOlder = conversation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Ready older",
            state: .ready,
            activityAge: MobileActivityAge(secondsAtReceipt: 120, receivedAtMonotonicTime: 1_000)
        )
        let readyNewer = conversation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            title: "Ready newer",
            state: .ready,
            activityAge: MobileActivityAge(secondsAtReceipt: 60, receivedAtMonotonicTime: 1_000)
        )
        let working = conversation(title: "Working", state: .working)
        let approval = conversation(title: "Approval", state: .needsApproval)
        let error = conversation(title: "Error", state: .error)
        let idle = conversation(title: "Idle", state: .idle)
        let unknown = conversation(
            title: "A future status",
            state: .unsupported(rawValue: "future")
        )

        let sorted = MobileWorkspace(
            id: UUID(),
            title: "Workspace",
            conversations: [unknown, idle, error, approval, readyOlder, working, readyNewer]
        ).sortedConversations

        XCTAssertEqual(
            sorted.map(\.title),
            ["Error", "Ready newer", "Ready older", "Approval", "Working", "Idle", "A future status"]
        )
    }

    func testOrderingPrefersBucketEntryAnchorOverStreamedActivity() {
        let steadyWorker = conversation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Steady worker",
            state: .working,
            activityAge: MobileActivityAge(secondsAtReceipt: 1, receivedAtMonotonicTime: 1_000),
            stateEnteredAge: MobileActivityAge(secondsAtReceipt: 600, receivedAtMonotonicTime: 1_000)
        )
        let recentArrival = conversation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            title: "Recent arrival",
            state: .working,
            activityAge: MobileActivityAge(secondsAtReceipt: 240, receivedAtMonotonicTime: 1_000),
            stateEnteredAge: MobileActivityAge(secondsAtReceipt: 30, receivedAtMonotonicTime: 1_000)
        )

        let sorted = MobileWorkspace(
            id: UUID(),
            title: "Workspace",
            conversations: [steadyWorker, recentArrival]
        ).sortedConversations

        XCTAssertEqual(sorted.map(\.title), ["Recent arrival", "Steady worker"])
    }

    func testActivityOrderingUsesTitleThenIdentifierForDeterministicTies() {
        let zulu = conversation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Zulu",
            state: .ready
        )
        let alphaLaterID = conversation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            title: "alpha",
            state: .ready
        )
        let alphaEarlierID = conversation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            title: "alpha",
            state: .ready
        )

        let snapshot = MobileHomeSnapshot(
            hostName: "Mac",
            workspaces: [
                MobileWorkspace(
                    id: UUID(),
                    title: "Workspace",
                    conversations: [zulu, alphaLaterID, alphaEarlierID]
                ),
            ]
        )

        XCTAssertEqual(
            snapshot.activitySessions.map(\.id),
            [alphaEarlierID.id, alphaLaterID.id, zulu.id]
        )
    }

    func testWorkspaceProjectionRanksByUrgencyRecencyThenWorkspaceIdentity() {
        let errorWorkspace = workspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            title: "Error",
            conversations: [
                conversation(
                    title: "Old error",
                    state: .error,
                    activityAge: activityAge(seconds: 900)
                ),
            ]
        )
        let newerReady = workspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            title: "Zulu",
            conversations: [
                conversation(
                    title: "New ready",
                    state: .ready,
                    activityAge: activityAge(seconds: 30)
                ),
            ]
        )
        let alphaReady = workspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            title: "Alpha",
            conversations: [
                conversation(
                    title: "Same-age ready",
                    state: .ready,
                    activityAge: activityAge(seconds: 60)
                ),
            ]
        )
        let betaReady = workspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Beta",
            conversations: [
                conversation(
                    title: "Same-age ready",
                    state: .ready,
                    activityAge: activityAge(seconds: 60)
                ),
            ]
        )
        let idleWorkspace = workspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            title: "Idle",
            conversations: [conversation(title: "Idle", state: .idle)]
        )
        let emptyWorkspace = workspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
            title: "Empty",
            conversations: []
        )

        let snapshot = MobileHomeSnapshot(
            hostName: "Mac",
            workspaces: [
                emptyWorkspace,
                idleWorkspace,
                betaReady,
                alphaReady,
                newerReady,
                errorWorkspace,
            ]
        )

        XCTAssertEqual(
            snapshot.rankedWorkspaces.map(\.title),
            ["Error", "Zulu", "Alpha", "Beta", "Idle", "Empty"]
        )
        XCTAssertTrue(
            snapshot.rankedWorkspaces.allSatisfy {
                $0.conversations == $0.sortedConversations
            }
        )
    }

    func testIdleAndUnsupportedStatusesHaveNoVisibleBucket() {
        XCTAssertFalse(MobileSessionStatus.idle.bucket.isVisible)
        XCTAssertFalse(MobileSessionStatus.unsupported(rawValue: "future").bucket.isVisible)
        XCTAssertEqual(
            MobileSessionStatus.unsupported(rawValue: "future").accessibilityLabel,
            "status unavailable"
        )
    }

    func testActivityAgeAdvancesOnlyFromMonotonicReceiptAnchor() {
        let age = MobileActivityAge(
            secondsAtReceipt: 59,
            receivedAtMonotonicTime: 1_000
        )

        XCTAssertEqual(age.label(atMonotonicTime: 999), "now")
        XCTAssertEqual(age.label(atMonotonicTime: 1_001), "1m")
        XCTAssertEqual(age.label(atMonotonicTime: 4_541), "1h")
    }

    func testActivityAgeNormalizesNonfiniteMonotonicInputs() {
        let nanReceipt = MobileActivityAge(
            secondsAtReceipt: 60,
            receivedAtMonotonicTime: .nan
        )
        let infiniteReceipt = MobileActivityAge(
            secondsAtReceipt: 60,
            receivedAtMonotonicTime: .infinity
        )

        XCTAssertEqual(nanReceipt.receivedAtMonotonicTime, 0)
        XCTAssertEqual(infiniteReceipt.receivedAtMonotonicTime, 0)
        XCTAssertEqual(nanReceipt.label(atMonotonicTime: .nan), "1m")
        XCTAssertEqual(infiniteReceipt.label(atMonotonicTime: .infinity), "1m")
    }

    func testSubspaceRowsCombineSessionsAndSortLikeTheDesktopSidebar() {
        let parentID = UUID()
        func subspace(
            _ title: String,
            _ states: [MobileSessionStatus],
            isDone: Bool = false
        ) -> MobileWorkspace {
            MobileWorkspace(
                id: UUID(),
                title: title,
                conversations: states.enumerated().map { index, state in
                    conversation(title: "\(title) \(index)", state: state, lastActivity: "\(title) \(state.bucket.rawValue)")
                },
                parentWorkspaceID: parentID,
                isDone: isDone
            )
        }
        let snapshot = MobileHomeSnapshot(hostName: "Mac", workspaces: [
            workspace(id: parentID, title: "parent", conversations: []),
            subspace("idle", [.idle]),
            subspace("done", [.ready], isDone: true),
            subspace("done but asking", [.needsApproval], isDone: true),
            subspace("working", [.idle, .working]),
            subspace("error", [.working, .error]),
            // Approval outranks an error in the same subspace.
            subspace("approval", [.error, .needsApproval, .ready]),
            subspace("ready", [.ready, .idle]),
            subspace("empty", []),
        ])

        let rows = snapshot.subspaceRows(of: parentID)
        XCTAssertEqual(rows.map(\.workspace.title), [
            "ready", "approval", "done but asking", "error", "working", "empty", "idle", "done",
        ])
        XCTAssertEqual(rows.map(\.status), [
            .ready, .needsApproval, .needsApproval, .error, .working, .idle, .idle, .done,
        ])
        // The summary comes from the session that sets the status.
        XCTAssertEqual(rows[1].summary, "approval needs approval")
        XCTAssertEqual(rows[4].summary, "working working")
        XCTAssertNil(rows[5].summary)
        XCTAssertEqual(rows.filter(\.status.isActive).count, 5)
        XCTAssertEqual(rows.filter(\.status.showsDoneToggle).map(\.workspace.title), [
            "ready", "empty", "idle", "done",
        ])
    }

    func testOnlyLinksToListedTopLevelParentsNest() {
        let parentID = UUID()
        let childID = UUID()
        let grandchild = MobileWorkspace(id: UUID(), title: "grandchild", conversations: [], parentWorkspaceID: childID)
        let orphan = MobileWorkspace(id: UUID(), title: "orphan", conversations: [], parentWorkspaceID: UUID())
        let selfLinkedID = UUID()
        let snapshot = MobileHomeSnapshot(hostName: "Mac", workspaces: [
            workspace(id: parentID, title: "parent", conversations: []),
            MobileWorkspace(id: childID, title: "child", conversations: [], parentWorkspaceID: parentID),
            grandchild,
            orphan,
            MobileWorkspace(id: selfLinkedID, title: "self", conversations: [], parentWorkspaceID: selfLinkedID),
        ])

        XCTAssertEqual(snapshot.subspaceRows(of: parentID).map(\.id), [childID])
        XCTAssertEqual(
            Set(snapshot.topLevelWorkspaces.map(\.id)),
            [parentID, grandchild.id, orphan.id, selfLinkedID],
            "A workspace whose link does not hold stays visible at top level"
        )
        XCTAssertNil(snapshot.parent(of: grandchild.id))

        // A parent whose own link names a missing workspace is top level,
        // so its subspace still nests. The members of a cycle stay flat.
        let orphanChild = MobileWorkspace(
            id: UUID(), title: "orphan child", conversations: [], parentWorkspaceID: orphan.id
        )
        let firstID = UUID()
        let secondID = UUID()
        let malformed = MobileHomeSnapshot(hostName: "Mac", workspaces: [
            orphan,
            orphanChild,
            MobileWorkspace(id: firstID, title: "first", conversations: [], parentWorkspaceID: secondID),
            MobileWorkspace(id: secondID, title: "second", conversations: [], parentWorkspaceID: firstID),
        ])
        XCTAssertEqual(malformed.subspaceRows(of: orphan.id).map(\.id), [orphanChild.id])
        XCTAssertEqual(Set(malformed.topLevelWorkspaces.map(\.id)), [orphan.id, firstID, secondID])
    }

    func testTopLevelRankingCountsSubspaceSessions() {
        let quietParentID = UUID()
        let busyID = UUID()
        let snapshot = MobileHomeSnapshot(hostName: "Mac", workspaces: [
            workspace(id: busyID, title: "busy", conversations: [conversation(state: .working)]),
            workspace(id: quietParentID, title: "quiet parent", conversations: [conversation(state: .idle)]),
            MobileWorkspace(
                id: UUID(), title: "task", conversations: [conversation(state: .error)],
                parentWorkspaceID: quietParentID
            ),
        ])

        XCTAssertEqual(snapshot.topLevelWorkspaces.map(\.id), [quietParentID, busyID])
    }

    func testSubspaceChipPrefersThePrimaryAnnotationOverThePullRequest() {
        let pullRequest = RemoteWorkspaceAnnotation(key: "github-pr", text: "PR #1", color: "#5BA08A")
        let ticket = RemoteWorkspaceAnnotation(key: "ticket", text: "TOAST-1", color: "#7AA2F7")
        func row(_ annotations: [RemoteWorkspaceAnnotation], primary: String?) -> MobileSubspaceRow {
            MobileSubspaceRow(workspace: MobileWorkspace(
                id: UUID(), title: "task", conversations: [], annotations: annotations,
                parentWorkspaceID: UUID(), primaryAnnotationKey: primary
            ))
        }

        XCTAssertEqual(row([pullRequest, ticket], primary: "ticket").chip, ticket)
        XCTAssertEqual(row([pullRequest, ticket], primary: nil).chip, pullRequest)
        XCTAssertEqual(row([pullRequest, ticket], primary: "missing").chip, pullRequest)
        XCTAssertNil(row([ticket], primary: nil).chip)
    }

    private func workspace(
        id: UUID,
        title: String,
        conversations: [MobileConversation]
    ) -> MobileWorkspace {
        MobileWorkspace(
            id: id,
            title: title,
            conversations: conversations
        )
    }

    private func activityAge(seconds: Int) -> MobileActivityAge {
        MobileActivityAge(secondsAtReceipt: seconds, receivedAtMonotonicTime: 1_000)
    }

    private func conversation(
        id: UUID = UUID(),
        title: String = "Conversation",
        state: MobileSessionStatus = .idle,
        cwd: String? = "/repos/workspace",
        age: String = "now",
        activityAge: MobileActivityAge? = nil,
        stateEnteredAge: MobileActivityAge? = nil,
        lastActivity: String = "Conversation readable"
    ) -> MobileConversation {
        MobileConversation(
            id: id,
            workspaceID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            workspaceTitle: "Workspace",
            cwd: cwd,
            agent: .codex,
            title: title,
            state: state,
            inputAvailability: .unavailable(reason: "test"),
            age: age,
            activityAge: activityAge,
            stateEnteredAge: stateEnteredAge,
            lastActivity: lastActivity
        )
    }
}
