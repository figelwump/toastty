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
            [.error, .ready, .ready, .ready, .needsApproval, .working, .working, .idle]
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
            lastActivity: lastActivity
        )
    }
}
